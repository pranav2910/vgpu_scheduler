package controller

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// Pod-ownership constants (Phase: "VGPUJob owns the Pod"). The label/annotation
// keys MUST match internal/webhook (the mutating pod webhook keys on them to
// inject the GPU). They are duplicated here — not imported — to mirror the
// existing per-package convention (see internal/nodeagent/slice_violation.go)
// and keep the controller decoupled from the admission layer.
const (
	// vgpuClaimLabel / vgpuClaimAnnotation: contract with internal/webhook
	// (VGPUClaimLabel / VGPUClaimAnnotation).
	vgpuClaimLabel      = "vgpu-claim"
	vgpuClaimAnnotation = "infrastructure.pranav2910.com/claim-ref"

	// workloadPodSuffix mirrors the CLI's deterministic naming: job X → pod
	// X-workload.
	workloadPodSuffix = "-workload"

	// Condition types surfaced on the VGPUJob for the pod lifecycle — the
	// explainability wedge: a reader always knows WHY a job isn't running yet.
	condTypeWaitingForSlice = "WaitingForSlice"
	condTypePodCreated      = "PodCreated"

	// Contract with internal/nodeagent enforcement (3.4d): when a workload is
	// evicted for sustained GPU memory over-use (opt-in evict mode), the parent
	// VGPUJob is stamped with this condition+reason. A pod-owning Job MUST honor
	// it as terminal and NOT recreate the pod — otherwise the controller would
	// fight the evictor in a recreate→evict loop.
	enforcementConditionType = "MemoryEnforcement"
	enforcementEvictedReason = "ChildSliceEvicted"

	// podAllocationRequeue is how often we re-check for slice allocation while a
	// pod-owning job waits (the webhook rejects the pod until it is allocated).
	podAllocationRequeue = 3 * time.Second
)

// workloadPodName is the deterministic Pod name for a pod-owning VGPUJob.
func workloadPodName(jobName string) string { return jobName + workloadPodSuffix }

// VGPUJobReconciler manages the lifecycle of VGPUJob resources.
// In Phase 2.1a it ensures each Job has a corresponding VGPUClaim materialized
// from claimTemplate, and mirrors the claim's status into the Job's phase.
// Phase 3.6 adds a non-blocking VRAM-rightsizing advisory driven by the job's
// workload profile.
type VGPUJobReconciler struct {
	Client   client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	// RecommendationMode gates the 3.7 advisory event (recommendOnly emits none;
	// warn/requireOverride do). The requireOverride admission block lives in the
	// VGPUJob validating webhook, not here. Zero value behaves as recommendOnly.
	RecommendationMode recommendation.Mode
}

// SetupWithManager registers the reconciler with the controller manager.
func (r *VGPUJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUJob{}).
		Owns(&vgpuv1alpha1.VGPUClaim{}).
		// "VGPUJob owns the Pod": a status change on the workload Pod (Pending →
		// Running → Succeeded/Failed) re-reconciles the owning Job so we mirror it.
		Owns(&corev1.Pod{}).
		// Phase 3.6: a profile update (new recommendation) re-evaluates the
		// advisory for its workload. The profile is named 1:1 with the job.
		Watches(
			&vgpuv1alpha1.VGPUWorkloadProfile{},
			handler.EnqueueRequestsFromMapFunc(func(_ context.Context, obj client.Object) []reconcile.Request {
				return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: obj.GetNamespace(), Name: obj.GetName()}}}
			}),
		).
		Complete(r)
}

// claimNameForJob is deterministic so we can find/recreate without races.
func claimNameForJob(jobName string) string {
	return jobName + "-claim"
}

func (r *VGPUJobReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var job vgpuv1alpha1.VGPUJob
	if err := r.Client.Get(ctx, req.NamespacedName, &job); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	// Job is being deleted: OwnerReferences handle cascade. Nothing to do.
	if !job.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// A terminal Job stays terminal. Without this guard, deleting a finished
	// job's claim (a natural way to free its slice) hit the claim-recreate path
	// below, which overwrote Succeeded/Failed back to ClaimCreated — defeating
	// reconcileWorkloadPod's no-resurrect guard (it keys on the terminal phase).
	// The recreated claim then got a fresh slice bound (capacity consumed by a
	// finished job at minimum), and if the completed pod had been GC'd, the
	// workload was recreated and re-ran.
	if job.Status.Phase == vgpuv1alpha1.JobPhaseSucceeded ||
		job.Status.Phase == vgpuv1alpha1.JobPhaseFailed ||
		job.Status.Phase == vgpuv1alpha1.JobPhaseCompleted {
		return reconcile.Result{}, nil
	}

	// 1. Ensure a Claim exists for this Job.
	claimName := claimNameForJob(job.Name)
	var claim vgpuv1alpha1.VGPUClaim
	err := r.Client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: claimName}, &claim)
	switch {
	case errors.IsNotFound(err):
		if err := r.createClaim(ctx, &job); err != nil {
			return reconcile.Result{}, fmt.Errorf("creating claim: %w", err)
		}
		log.Printf("VGPUJob %s/%s: created claim %s", job.Namespace, job.Name, claimName)
		return r.updatePhase(ctx, &job, vgpuv1alpha1.JobPhaseClaimCreated, "VGPUClaim materialized from template")
	case err != nil:
		return reconcile.Result{}, err
	}

	// 2. Mirror Claim/Slice phase into Job phase (the resource-request view).
	desired, msg := derivePhaseFromClaim(&claim, job.Status.Phase)

	// 3. If the Job OWNS a Pod (podTemplate set), the Pod lifecycle drives the
	//    phase once the slice is allocated; the claim-derived phase only applies
	//    while we are still waiting for allocation. Otherwise (no podTemplate)
	//    the Job is a pure resource request and the claim phase stands.
	if job.Spec.PodTemplate != nil {
		res, err := r.reconcileWorkloadPod(ctx, &job, &claim, desired, msg)
		if err != nil {
			return reconcile.Result{}, err
		}
		// The rightsizing advisory is independent of phase; keep it running.
		if err := r.reconcileAdvisory(ctx, &job); err != nil {
			return reconcile.Result{}, err
		}
		return res, nil
	}

	if job.Status.Phase != desired || job.Status.ClaimRef != claimName {
		if _, err := r.updatePhase(ctx, &job, desired, msg); err != nil {
			return reconcile.Result{}, err
		}
	}

	// Phase 3.6: non-blocking VRAM-rightsizing advisory from the profile.
	if err := r.reconcileAdvisory(ctx, &job); err != nil {
		return reconcile.Result{}, err
	}

	return reconcile.Result{}, nil
}

// createClaim materializes the VGPUClaim from the Job's claimTemplate and
// sets OwnerReference for cascade-delete. JobRef is stamped in spec for
// the scheduler to walk back to the Job during scoring.
// gang-wiring fix applied: propagate gang annotations from Job to Claim.
func (r *VGPUJobReconciler) createClaim(ctx context.Context, job *vgpuv1alpha1.VGPUJob) error {
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:        claimNameForJob(job.Name),
			Namespace:   job.Namespace,
			Annotations: FilterGangAnnotations(job.Annotations),
		},
		Spec: job.Spec.ClaimTemplate.Spec,
	}
	// Stamp JobRef so scheduler can resolve priority/class.
	claim.Spec.JobRef = job.Name

	if err := controllerutil.SetControllerReference(job, claim, r.Scheme); err != nil {
		return fmt.Errorf("setting owner reference: %w", err)
	}

	return r.Client.Create(ctx, claim)
}

// derivePhaseFromClaim collapses claim+slice state into the Job's phase.
// current is the job's existing phase, and the mapping is MONOTONIC: a derived
// phase never moves the job backwards. Claim-side teardown blips and informer
// flaps must not regress an already-Scheduled (or Running) job's phase in
// `vgpu status` — phases report furthest progress; conditions carry detail.
// Explicit phase writes elsewhere (terminal transitions, pod-derived phases)
// do not route through here and are unaffected.
//
// The old "Released" → Completed arm was dead code: no claim writer ever sets
// phase Released (Bound/Failed/Deleting/Scheduled/Pending only). Completed is
// owned by the pod watch for pod-owning jobs; a pure-resource grant has no
// completion event by design.
func derivePhaseFromClaim(claim *vgpuv1alpha1.VGPUClaim, current vgpuv1alpha1.VGPUJobPhase) (vgpuv1alpha1.VGPUJobPhase, string) {
	var desired vgpuv1alpha1.VGPUJobPhase
	var msg string
	switch claim.Status.Phase {
	case "Bound":
		// Claim is Bound but Slice could still be in any state.
		// Treat Bound as "Scheduled" — the actual workload running is Phase 2.1b.
		desired, msg = vgpuv1alpha1.JobPhaseScheduled, "Slice scheduled and ready"
	case "Scheduled":
		// The claim reconciler reports "Scheduled" while the slice is placed but
		// not yet allocated; mapping it to the default (ClaimCreated) regressed
		// an already-scheduled job's phase.
		desired, msg = vgpuv1alpha1.JobPhaseScheduled, "Slice scheduled; awaiting allocation"
	case "Pending", "":
		desired, msg = vgpuv1alpha1.JobPhaseClaimCreated, "Awaiting scheduler"
	case "Failed":
		desired, msg = vgpuv1alpha1.JobPhaseFailed, "Claim entered Failed phase"
	case "Deleting":
		// Teardown in progress is neither job progress nor failure — keep the
		// phase the job already earned (the message still surfaces the state).
		return current, fmt.Sprintf("Claim in phase %s", claim.Status.Phase)
	default:
		// Unknown claim phase: never guess BACKWARDS from it.
		return current, fmt.Sprintf("Claim in phase %s", claim.Status.Phase)
	}
	if jobPhaseRank(desired) < jobPhaseRank(current) {
		return current, msg // monotonic: derived phases never downgrade
	}
	return desired, msg
}

// jobPhaseRank orders job phases for the monotonic guard. Terminal phases rank
// highest so a claim-level Failed can always surface over any in-flight phase —
// while terminal currents themselves are already guarded upstream (a terminal
// job returns before any derivation runs).
func jobPhaseRank(p vgpuv1alpha1.VGPUJobPhase) int {
	switch p {
	case vgpuv1alpha1.JobPhasePending, "":
		return 0
	case vgpuv1alpha1.JobPhaseClaimCreated:
		return 1
	case vgpuv1alpha1.JobPhaseScheduled:
		return 2
	case vgpuv1alpha1.JobPhasePodCreating:
		return 3
	case vgpuv1alpha1.JobPhaseRunning:
		return 4
	case vgpuv1alpha1.JobPhaseSucceeded, vgpuv1alpha1.JobPhaseFailed, vgpuv1alpha1.JobPhaseCompleted:
		return 5
	}
	return 0
}

// updatePhase patches Job status with retry-on-conflict so concurrent updates
// (e.g. from a webhook) don't drop our changes.
func (r *VGPUJobReconciler) updatePhase(ctx context.Context, job *vgpuv1alpha1.VGPUJob, phase vgpuv1alpha1.VGPUJobPhase, msg string) (reconcile.Result, error) {
	key := types.NamespacedName{Namespace: job.Namespace, Name: job.Name}
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		fresh.Status.Phase = phase
		fresh.Status.Message = msg
		fresh.Status.ClaimRef = claimNameForJob(fresh.Name)
		return r.Client.Status().Update(ctx, &fresh)
	})
	return reconcile.Result{}, err
}

// ───────────────────────── "VGPUJob owns the Pod" ────────────────────────────
// When a Job carries a podTemplate, the controller is responsible for the whole
// workload Pod lifecycle: wait for the slice to be allocated (the webhook rejects
// a pod before then), create the Pod from the template (stamped with the claim-ref
// label+annotation + an OwnerReference), watch it, and mirror its phase into the
// Job. This is what makes `kubectl apply -f vgpujob.yaml` alone run a workload.

// reconcileWorkloadPod drives the pod lifecycle for a pod-owning Job. claimPhase/
// claimMsg are the claim-derived phase shown while still waiting for allocation.
func (r *VGPUJobReconciler) reconcileWorkloadPod(
	ctx context.Context,
	job *vgpuv1alpha1.VGPUJob,
	claim *vgpuv1alpha1.VGPUClaim,
	claimPhase vgpuv1alpha1.VGPUJobPhase,
	claimMsg string,
) (reconcile.Result, error) {
	key := types.NamespacedName{Namespace: job.Namespace, Name: job.Name}
	claimRef := claimNameForJob(job.Name)
	podName := workloadPodName(job.Name)

	// Once a Job reaches a terminal pod state we never recreate the pod (so a
	// completed/failed workload doesn't crash-loop or resurrect after cleanup).
	terminal := job.Status.Phase == vgpuv1alpha1.JobPhaseSucceeded ||
		job.Status.Phase == vgpuv1alpha1.JobPhaseFailed

	var pod corev1.Pod
	getErr := r.Client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: podName}, &pod)
	podExists := getErr == nil
	if getErr != nil && !errors.IsNotFound(getErr) {
		return reconcile.Result{}, getErr
	}

	slice, allocated, err := r.resolveAllocatedSlice(ctx, job.Namespace, claim)
	if err != nil {
		return reconcile.Result{}, err
	}
	node, uuid := "", ""
	if allocated {
		node, uuid = slice.Spec.NodeName, slice.Status.DeviceUUID
	}

	// Pod exists → mirror its phase into the Job.
	if podExists {
		// A pod being deleted transitions through Failed/Succeeded *while it
		// terminates*. Mirroring that transient state would mark the Job terminal
		// and defeat self-heal — a pod deleted out from under us would never be
		// recreated. A terminating pod is distinguished from one that genuinely
		// ran-and-exited by its DeletionTimestamp. Skip while terminating; the
		// Owns(Pod) delete event re-reconciles once it is gone and the
		// missing-pod path decides whether to recreate.
		if pod.DeletionTimestamp != nil {
			return reconcile.Result{}, nil
		}
		phase, msg := derivePhaseFromPod(&pod)
		if node == "" {
			node = pod.Spec.NodeName
		}
		return reconcile.Result{}, r.jobStatusUpdate(ctx, key, phase, msg, claimRef, podName, node, uuid,
			condWaitingForSlice(false), condPodCreated(true, podName))
	}

	// Pod missing + job already finished → nothing to do (don't resurrect).
	if terminal {
		return reconcile.Result{}, nil
	}

	// Pod missing because enforcement EVICTED this workload (opt-in evict mode):
	// honor the evictor — do NOT recreate (that would loop recreate→evict). Mark
	// the Job terminal once; the MemoryEnforcement condition already explains why.
	if jobEnforcementEvicted(job) {
		return reconcile.Result{}, r.jobStatusUpdate(ctx, key, vgpuv1alpha1.JobPhaseFailed,
			"Workload pod evicted for sustained GPU memory over-use (policy=evict); not recreated.",
			claimRef, "", "", "")
	}

	// Pod missing + not yet allocated → record WHY we're waiting, requeue.
	if !allocated {
		if err := r.jobStatusUpdate(ctx, key, claimPhase, claimMsg, claimRef, "", "", "",
			condWaitingForSlice(true), condPodCreated(false, podName)); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{RequeueAfter: podAllocationRequeue}, nil
	}

	// Allocated + no pod yet → create it (idempotent on AlreadyExists).
	newPod := r.buildWorkloadPod(job, claimRef)
	if err := controllerutil.SetControllerReference(job, newPod, r.Scheme); err != nil {
		return reconcile.Result{}, fmt.Errorf("setting pod owner reference: %w", err)
	}
	if err := r.Client.Create(ctx, newPod); err != nil && !errors.IsAlreadyExists(err) {
		return reconcile.Result{}, fmt.Errorf("creating workload pod: %w", err)
	}
	log.Printf("VGPUJob %s/%s: created workload pod %s on %s (GPU %s)",
		job.Namespace, job.Name, podName, node, uuid)
	if r.Recorder != nil {
		r.Recorder.Eventf(job, corev1.EventTypeNormal, "WorkloadPodCreated",
			"Created workload pod %s on node %s (GPU %s) — the mutating webhook injects the device.",
			podName, node, uuid)
	}
	if err := r.jobStatusUpdate(ctx, key, vgpuv1alpha1.JobPhasePodCreating,
		"Slice allocated; workload pod created (GPU injected by the webhook).",
		claimRef, podName, node, uuid,
		condWaitingForSlice(false), condPodCreated(true, podName)); err != nil {
		return reconcile.Result{}, err
	}
	// Owns(&corev1.Pod{}) re-triggers reconcile as the pod's phase advances.
	return reconcile.Result{}, nil
}

// resolveAllocatedSlice returns the VGPUSlice backing the claim and whether it
// has been allocated (allocationId present). "Not yet bound / not yet allocated"
// is the normal waiting case → (slice-or-nil, false, nil), not an error.
func (r *VGPUJobReconciler) resolveAllocatedSlice(ctx context.Context, ns string, claim *vgpuv1alpha1.VGPUClaim) (*vgpuv1alpha1.VGPUSlice, bool, error) {
	sliceName := claim.Status.BoundSliceName
	if sliceName == "" {
		return nil, false, nil
	}
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.Client.Get(ctx, types.NamespacedName{Namespace: ns, Name: sliceName}, &slice); err != nil {
		if errors.IsNotFound(err) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return &slice, slice.Status.AllocationID != "", nil
}

// buildWorkloadPod renders the workload Pod from the Job's podTemplate, always
// stamping the claim-ref label+annotation the mutating webhook keys on and
// defaulting restartPolicy to Never (a one-shot workload, not a long service).
func (r *VGPUJobReconciler) buildWorkloadPod(job *vgpuv1alpha1.VGPUJob, claimRef string) *corev1.Pod {
	tmpl := job.Spec.PodTemplate
	labels := map[string]string{}
	annotations := map[string]string{}
	for k, v := range tmpl.Labels {
		labels[k] = v
	}
	for k, v := range tmpl.Annotations {
		annotations[k] = v
	}
	// Override any template value so the pod is unambiguously bound to THIS
	// job's claim — this is the contract the webhook resolves the slice from.
	labels[vgpuClaimLabel] = claimRef
	annotations[vgpuClaimAnnotation] = claimRef

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:        workloadPodName(job.Name),
			Namespace:   job.Namespace,
			Labels:      labels,
			Annotations: annotations,
		},
		Spec: *tmpl.Spec.DeepCopy(),
	}
	if pod.Spec.RestartPolicy == "" {
		pod.Spec.RestartPolicy = corev1.RestartPolicyNever
	}
	return pod
}

// derivePhaseFromPod collapses the workload Pod's phase into the Job phase.
func derivePhaseFromPod(pod *corev1.Pod) (vgpuv1alpha1.VGPUJobPhase, string) {
	switch pod.Status.Phase {
	case corev1.PodRunning:
		return vgpuv1alpha1.JobPhaseRunning, "Workload pod is running on the shared GPU."
	case corev1.PodSucceeded:
		return vgpuv1alpha1.JobPhaseSucceeded, "Workload pod completed successfully (exit 0)."
	case corev1.PodFailed:
		return vgpuv1alpha1.JobPhaseFailed, "Workload pod failed."
	case corev1.PodPending:
		return vgpuv1alpha1.JobPhasePodCreating, "Workload pod pending (scheduling / image pull)."
	default:
		return vgpuv1alpha1.JobPhasePodCreating, "Workload pod created."
	}
}

// jobStatusUpdate is a change-detecting status writer for the pod-owning path:
// it sets phase/message/refs + conditions and writes ONLY when something actually
// changed, so we don't churn status and hot-loop via For(&VGPUJob{}). Empty ref
// strings are treated as "leave unchanged".
func (r *VGPUJobReconciler) jobStatusUpdate(
	ctx context.Context,
	key types.NamespacedName,
	phase vgpuv1alpha1.VGPUJobPhase,
	message, claimRef, podRef, nodeName, deviceUUID string,
	conds ...metav1.Condition,
) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var j vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &j); err != nil {
			return client.IgnoreNotFound(err)
		}
		changed := false
		setStr := func(dst *string, val string) {
			if val != "" && *dst != val {
				*dst = val
				changed = true
			}
		}
		if j.Status.Phase != phase {
			j.Status.Phase = phase
			changed = true
		}
		if j.Status.Message != message {
			j.Status.Message = message
			changed = true
		}
		setStr(&j.Status.ClaimRef, claimRef)
		setStr(&j.Status.PodRef, podRef)
		setStr(&j.Status.NodeName, nodeName)
		setStr(&j.Status.DeviceUUID, deviceUUID)
		for i := range conds {
			c := conds[i]
			if existing := apimeta.FindStatusCondition(j.Status.Conditions, c.Type); existing == nil ||
				existing.Status != c.Status || existing.Reason != c.Reason || existing.Message != c.Message {
				apimeta.SetStatusCondition(&j.Status.Conditions, c)
				changed = true
			}
		}
		if !changed {
			return nil
		}
		return r.Client.Status().Update(ctx, &j)
	})
}

func condWaitingForSlice(waiting bool) metav1.Condition {
	if waiting {
		return metav1.Condition{
			Type:    condTypeWaitingForSlice,
			Status:  metav1.ConditionTrue,
			Reason:  "SliceNotReady",
			Message: "Waiting for VGPUSlice allocation before creating the workload pod.",
		}
	}
	return metav1.Condition{
		Type:    condTypeWaitingForSlice,
		Status:  metav1.ConditionFalse,
		Reason:  "SliceAllocated",
		Message: "Slice allocated; the workload pod can be created.",
	}
}

// jobEnforcementEvicted reports whether enforcement (opt-in evict mode) has
// reclaimed this workload — in which case the pod must not be recreated.
func jobEnforcementEvicted(job *vgpuv1alpha1.VGPUJob) bool {
	c := apimeta.FindStatusCondition(job.Status.Conditions, enforcementConditionType)
	return c != nil && c.Status == metav1.ConditionTrue && c.Reason == enforcementEvictedReason
}

func condPodCreated(created bool, podName string) metav1.Condition {
	if created {
		return metav1.Condition{
			Type:    condTypePodCreated,
			Status:  metav1.ConditionTrue,
			Reason:  "WorkloadPodCreated",
			Message: fmt.Sprintf("Workload pod %s created and owned by this VGPUJob.", podName),
		}
	}
	return metav1.Condition{
		Type:    condTypePodCreated,
		Status:  metav1.ConditionFalse,
		Reason:  "PodNotCreated",
		Message: "Workload pod not created yet (awaiting slice allocation).",
	}
}
