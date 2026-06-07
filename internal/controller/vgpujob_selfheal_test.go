package controller

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// These tests lock the pod-lifecycle decisions of reconcileWorkloadPod against a
// fake client — the exact logic the kind run exercised, captured so the subtle
// self-heal/terminal bug (a deleted Running pod transitions through Failed while
// terminating) can never silently regress in CI.

func selfhealScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("add vgpu scheme: %v", err)
	}
	if err := corev1.AddToScheme(s); err != nil {
		t.Fatalf("add corev1 scheme: %v", err)
	}
	return s
}

func podOwningJob(phase vgpuv1alpha1.VGPUJobPhase) *vgpuv1alpha1.VGPUJob {
	return &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: "j", Namespace: "ns"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{Spec: vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: 1 << 33}},
			PodTemplate: &corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "workload", Image: "img"}}},
			},
		},
		Status: vgpuv1alpha1.VGPUJobStatus{Phase: phase},
	}
}

func allocatedClaimAndSlice() (*vgpuv1alpha1.VGPUClaim, *vgpuv1alpha1.VGPUSlice) {
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "j-claim", Namespace: "ns"},
		Status:     vgpuv1alpha1.VGPUClaimStatus{BoundSliceName: "j-claim-slice"},
	}
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "j-claim-slice", Namespace: "ns"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{ClaimRef: "j-claim", NodeName: "n1", RequestedVRAMBytes: 1 << 33},
		Status:     vgpuv1alpha1.VGPUSliceStatus{AllocationID: "alloc-x", DeviceUUID: "GPU-x"},
	}
	return claim, slice
}

func newReconciler(s *runtime.Scheme, objs ...client.Object) *VGPUJobReconciler {
	cl := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(objs...).
		WithStatusSubresource(&vgpuv1alpha1.VGPUJob{}).
		Build()
	return &VGPUJobReconciler{Client: cl, Scheme: s}
}

func getSelfhealJob(t *testing.T, r *VGPUJobReconciler) *vgpuv1alpha1.VGPUJob {
	t.Helper()
	var j vgpuv1alpha1.VGPUJob
	if err := r.Client.Get(context.Background(), client.ObjectKey{Namespace: "ns", Name: "j"}, &j); err != nil {
		t.Fatalf("get job: %v", err)
	}
	return &j
}

func podExists(r *VGPUJobReconciler) bool {
	var p corev1.Pod
	err := r.Client.Get(context.Background(), client.ObjectKey{Namespace: "ns", Name: "j-workload"}, &p)
	return err == nil
}

// A) Missing pod + allocated slice + non-terminal job → the controller CREATES
//    the pod (owned, claim-stamped) and moves the job to PodCreating.
func TestReconcileWorkloadPod_CreatesWhenMissing(t *testing.T) {
	s := selfhealScheme(t)
	job := podOwningJob("")
	claim, slice := allocatedClaimAndSlice()
	r := newReconciler(s, job, claim, slice)

	if _, err := r.reconcileWorkloadPod(context.Background(), job, claim, vgpuv1alpha1.JobPhaseScheduled, "scheduled"); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if !podExists(r) {
		t.Fatal("expected the controller to create the workload pod")
	}
	var p corev1.Pod
	_ = r.Client.Get(context.Background(), client.ObjectKey{Namespace: "ns", Name: "j-workload"}, &p)
	if len(p.OwnerReferences) == 0 || p.OwnerReferences[0].Kind != "VGPUJob" {
		t.Errorf("pod not owned by VGPUJob: %+v", p.OwnerReferences)
	}
	if p.Labels[vgpuClaimLabel] != "j-claim" || p.Annotations[vgpuClaimAnnotation] != "j-claim" {
		t.Errorf("claim keys not stamped: labels=%v annotations=%v", p.Labels, p.Annotations)
	}
	if got := getSelfhealJob(t, r).Status.Phase; got != vgpuv1alpha1.JobPhasePodCreating {
		t.Errorf("job phase: got %s want PodCreating", got)
	}
}

// B) THE REGRESSION GUARD: a terminating pod (DeletionTimestamp set) must NOT be
//    mirrored as terminal — the job phase stays Running so self-heal can recreate
//    it once it's gone.
func TestReconcileWorkloadPod_SkipsTerminatingPod(t *testing.T) {
	s := selfhealScheme(t)
	job := podOwningJob(vgpuv1alpha1.JobPhaseRunning)
	claim, slice := allocatedClaimAndSlice()
	now := metav1.Now()
	terminating := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "j-workload", Namespace: "ns",
			DeletionTimestamp: &now,
			Finalizers:        []string{"kubernetes"}, // fake client requires a finalizer to retain a deleting obj
		},
		Status: corev1.PodStatus{Phase: corev1.PodFailed}, // transient terminal phase while terminating
	}
	r := newReconciler(s, job, claim, slice, terminating)

	if _, err := r.reconcileWorkloadPod(context.Background(), job, claim, vgpuv1alpha1.JobPhaseScheduled, "scheduled"); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if got := getSelfhealJob(t, r).Status.Phase; got != vgpuv1alpha1.JobPhaseRunning {
		t.Errorf("terminating pod must NOT mark the job terminal: got phase %s want Running", got)
	}
}

// C) A genuinely failed pod (exists, NO DeletionTimestamp) → the job goes Failed
//    and the pod is left in place (no crash-loop recreate).
func TestReconcileWorkloadPod_GenuineFailureStaysFailed(t *testing.T) {
	s := selfhealScheme(t)
	job := podOwningJob(vgpuv1alpha1.JobPhaseRunning)
	claim, slice := allocatedClaimAndSlice()
	failed := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "j-workload", Namespace: "ns"},
		Status:     corev1.PodStatus{Phase: corev1.PodFailed},
	}
	r := newReconciler(s, job, claim, slice, failed)

	if _, err := r.reconcileWorkloadPod(context.Background(), job, claim, vgpuv1alpha1.JobPhaseScheduled, "scheduled"); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if got := getSelfhealJob(t, r).Status.Phase; got != vgpuv1alpha1.JobPhaseFailed {
		t.Errorf("genuine failure: got phase %s want Failed", got)
	}
}

// D) Missing pod + already-terminal job (Succeeded) → do NOT recreate.
func TestReconcileWorkloadPod_NoRecreateAfterSucceeded(t *testing.T) {
	s := selfhealScheme(t)
	job := podOwningJob(vgpuv1alpha1.JobPhaseSucceeded)
	claim, slice := allocatedClaimAndSlice()
	r := newReconciler(s, job, claim, slice)

	if _, err := r.reconcileWorkloadPod(context.Background(), job, claim, vgpuv1alpha1.JobPhaseScheduled, "scheduled"); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if podExists(r) {
		t.Fatal("a completed job must not have its pod recreated")
	}
}

// F) Missing pod + the Job was EVICTED by enforcement (opt-in evict mode) → do
//    NOT recreate (honor the evictor; no recreate→evict loop). Marks job Failed.
func TestReconcileWorkloadPod_NoRecreateAfterEnforcementEviction(t *testing.T) {
	s := selfhealScheme(t)
	job := podOwningJob(vgpuv1alpha1.JobPhaseRunning)
	// Stamp the condition exactly as internal/nodeagent enforcement does.
	job.Status.Conditions = []metav1.Condition{{
		Type:   "MemoryEnforcement",
		Status: metav1.ConditionTrue,
		Reason: "ChildSliceEvicted",
	}}
	claim, slice := allocatedClaimAndSlice()
	r := newReconciler(s, job, claim, slice)

	if _, err := r.reconcileWorkloadPod(context.Background(), job, claim, vgpuv1alpha1.JobPhaseScheduled, "scheduled"); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if podExists(r) {
		t.Fatal("an enforcement-evicted workload must NOT have its pod recreated")
	}
	if got := getSelfhealJob(t, r).Status.Phase; got != vgpuv1alpha1.JobPhaseFailed {
		t.Errorf("evicted job phase: got %s want Failed", got)
	}
}

// E) Missing pod + claim not yet allocated → wait (requeue), do NOT create a pod
//    (the webhook would reject it pre-allocation).
func TestReconcileWorkloadPod_WaitsForAllocation(t *testing.T) {
	s := selfhealScheme(t)
	job := podOwningJob("")
	claim := &vgpuv1alpha1.VGPUClaim{ObjectMeta: metav1.ObjectMeta{Name: "j-claim", Namespace: "ns"}} // no boundSliceName
	r := newReconciler(s, job, claim)

	res, err := r.reconcileWorkloadPod(context.Background(), job, claim, vgpuv1alpha1.JobPhaseClaimCreated, "awaiting")
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if res.RequeueAfter == 0 {
		t.Error("expected a requeue while waiting for allocation")
	}
	if podExists(r) {
		t.Fatal("must not create a pod before the slice is allocated")
	}
	if got := getSelfhealJob(t, r).Status.Phase; got != vgpuv1alpha1.JobPhaseClaimCreated {
		t.Errorf("waiting phase: got %s want ClaimCreated", got)
	}
}
