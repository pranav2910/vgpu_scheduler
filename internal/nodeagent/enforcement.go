package nodeagent

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Phase 3.4c — soft enforcement. 3.4b makes over-use *visible* on infrastructure
// objects (slice/job conditions, metrics, an Event). 3.4c is the first stage
// that *acts* on a sustained violation — but deliberately stops short of
// touching the running workload. In softwarn mode an over-use that persists past
// a grace period engages "soft" enforcement: it labels and annotates the
// offending pod (workload-owner-visible), records a MemoryEnforcement decision on
// the slice + job, emits events, and updates metrics. It NEVER evicts, throttles,
// changes the pod phase, or feeds the scheduler. Recovery reverses every surface.
//
// Hard enforcement (evict/throttle — 3.4d) and MIG partitioning (3.4e) are out of
// scope here and are intentionally NOT reachable from this build.

// EnforcementMode is the node agent's runtime over-use enforcement ceiling.
// Its integer value is exported via the vgpu_memory_enforcement_mode metric.
type EnforcementMode int

const (
	// EnforcementOff keeps 3.4b marking only — no pod surfaces, no enforcement.
	EnforcementOff EnforcementMode = iota
	// EnforcementSoftWarn is the 3.4c ceiling: label/annotate + record + warn,
	// never evict/throttle.
	EnforcementSoftWarn
	// (future: EnforcementThrottle, EnforcementEvict — Phase 3.4d.)
)

func (m EnforcementMode) String() string {
	switch m {
	case EnforcementSoftWarn:
		return "softwarn"
	default:
		return "off"
	}
}

// ParseEnforcementMode maps a config string to a mode. The default (empty) is
// softwarn — non-destructive, so it is safe on by default. Hard-enforcement
// values (evict, throttle) are intentionally NOT honored in this build: they
// fall back to softwarn with a warning, so turning on real teeth (3.4d) stays a
// deliberate, separate change rather than a one-character config edit.
func ParseEnforcementMode(s string) EnforcementMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "softwarn", "soft", "warn":
		return EnforcementSoftWarn
	case "off", "none", "disabled", "observe":
		return EnforcementOff
	case "evict", "throttle", "hard", "enforce":
		log.Printf("[enforcement] mode %q is not available in this build (hard enforcement is Phase 3.4d) — using softwarn (observe-and-warn only)", s)
		return EnforcementSoftWarn
	default:
		log.Printf("[enforcement] unknown mode %q — using softwarn", s)
		return EnforcementSoftWarn
	}
}

const (
	// enforcementGracePeriod is how long an over-use must persist *after* 3.4b
	// flags it (MemoryViolation=True) before soft enforcement engages. Wall-clock
	// so it is operator-meaningful (~90s detect + 60s grace ≈ 150s to SoftWarned).
	enforcementGracePeriod = 60 * time.Second

	memoryEnforcementCondition = "MemoryEnforcement"
	enforcementReasonEngaged   = "SoftWarnEngaged"
	enforcementReasonCleared   = "WithinGrant"
	enforcementJobReason       = "ChildSliceSoftWarn"

	// Pod surfaces (workload-owner visibility). The label is selector-friendly
	// (`kubectl get pods -l`); the annotations carry detail. The deadline is
	// INFORMATIONAL in softwarn — nothing is evicted; it marks when a future hard
	// mode (3.4d) would act. The note annotation states that explicitly so a pod
	// owner never mistakes the deadline for an impending kill.
	podViolationLabel      = "infrastructure.pranav2910.com/memory-violation"
	podEnforcementAnno     = "infrastructure.pranav2910.com/enforcement"
	podExcessBytesAnno     = "infrastructure.pranav2910.com/memory-excess-bytes"
	podViolationSinceAnno  = "infrastructure.pranav2910.com/violation-since"
	podDeadlineAnno        = "infrastructure.pranav2910.com/enforcement-deadline"
	podEnforcementNoteAnno = "infrastructure.pranav2910.com/enforcement-note"

	enforcementNote = "softwarn: warning only — this pod is NOT evicted or throttled; enforcement-deadline is informational and marks when a future hard-enforcement mode (3.4d) would act"
)

// enforce drives the grace-gated soft-enforcement state machine for one slice,
// given 3.4b's per-slice over-use signal (excess/violating). Called every cycle.
//
//	violating=false           → ensure cleared (reverse any engaged surfaces)
//	violating, within grace   → Observed (recorded by 3.4b; enforcement waits)
//	violating, grace elapsed  → SoftWarned (engage soft enforcement, once)
func (d *SliceViolationDetector) enforce(ctx context.Context, u *sliceUsage, excess int64, violating bool) {
	if d.enforceMode == EnforcementOff {
		return
	}
	key := sliceKey(u.namespace, u.name)

	if !violating {
		if d.enforced[key] {
			d.clearEnforcement(ctx, u, key)
		}
		delete(d.violationStart, key)
		telemetry.MemoryEnforcementActive.WithLabelValues(d.nodeName, u.namespace, u.name).Set(0)
		return
	}

	// Sustained over-use (3.4b violating). Start/await the grace timer.
	start, ok := d.violationStart[key]
	if !ok {
		start = d.now()
		d.violationStart[key] = start
	}
	deadline := start.Add(enforcementGracePeriod)
	if d.now().Before(deadline) {
		telemetry.MemoryEnforcementActive.WithLabelValues(d.nodeName, u.namespace, u.name).Set(0)
		return // Observed — within grace; enforcement not engaged yet.
	}

	telemetry.MemoryEnforcementActive.WithLabelValues(d.nodeName, u.namespace, u.name).Set(1)
	if d.enforced[key] {
		return // already engaged; surfaces are in place.
	}
	d.enforced[key] = true
	d.stampedPods[key] = append([]types.NamespacedName(nil), u.pods...)
	telemetry.MemoryEnforcementActionsTotal.WithLabelValues(d.nodeName, u.namespace, u.name, d.enforceMode.String(), "warn").Inc()
	d.engageSoftWarn(ctx, u, excess, start, deadline)
}

// engageSoftWarn applies every soft-enforcement surface for a slice that has been
// over-budget past the grace period: slice condition, job mirror, pod stamps.
func (d *SliceViolationDetector) engageSoftWarn(ctx context.Context, u *sliceUsage, excess int64, since, deadline time.Time) {
	msg := fmt.Sprintf("Soft enforcement engaged (warn-only, mode=%s): slice exceeded its VRAM grant by %d MiB for over %ds. The pod is labeled/annotated and is NOT evicted or throttled. enforcement-deadline=%s is informational (when a future hard mode would act).",
		d.enforceMode.String(), excess>>20, int(enforcementGracePeriod.Seconds()), deadline.UTC().Format(time.RFC3339))

	d.setSliceEnforcementCondition(ctx, u, metav1.ConditionTrue, enforcementReasonEngaged, msg)
	d.mirrorEnforcementToJob(ctx, u, true)
	for _, nn := range d.stampedPods[sliceKey(u.namespace, u.name)] {
		d.stampPod(ctx, nn, excess, since, deadline)
	}
	log.Printf("[enforcement] slice %s/%s SOFT-WARN engaged (excess=%d MiB, mode=%s) — pod(s) labeled/annotated, no eviction",
		u.namespace, u.name, excess>>20, d.enforceMode.String())
}

// clearEnforcement reverses every soft-enforcement surface when a slice returns
// within its grant. Recovery is first-class: pod stamps removed, conditions
// flipped, a Normal event emitted, the action counted.
func (d *SliceViolationDetector) clearEnforcement(ctx context.Context, u *sliceUsage, key string) {
	for _, nn := range d.stampedPods[key] {
		d.clearPod(ctx, nn)
	}
	d.setSliceEnforcementCondition(ctx, u, metav1.ConditionFalse, enforcementReasonCleared,
		"GPU memory returned within grant; soft-enforcement surfaces cleared")
	d.mirrorEnforcementToJob(ctx, u, false)
	telemetry.MemoryEnforcementActionsTotal.WithLabelValues(d.nodeName, u.namespace, u.name, d.enforceMode.String(), "clear").Inc()
	delete(d.enforced, key)
	delete(d.stampedPods, key)
	log.Printf("[enforcement] slice %s/%s soft-enforcement cleared (within grant) — pod surfaces removed", u.namespace, u.name)
}

// cleanupEnforcement is the prune path: the slice itself vanished (deleted or
// unbound). Best-effort un-stamp any pods we marked — the pod may be gone too
// (Get NotFound → skip). No events: the slice no longer exists to attach them to.
func (d *SliceViolationDetector) cleanupEnforcement(ctx context.Context, key string) {
	if d.enforced[key] {
		for _, nn := range d.stampedPods[key] {
			d.clearPod(ctx, nn)
		}
	}
	delete(d.enforced, key)
	delete(d.violationStart, key)
	delete(d.stampedPods, key)
}

// setSliceEnforcementCondition upserts the MemoryEnforcement condition on the
// slice and emits the matching slice Event. The slice phase is never changed.
func (d *SliceViolationDetector) setSliceEnforcementCondition(ctx context.Context, u *sliceUsage, status metav1.ConditionStatus, reason, msg string) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: u.namespace, Name: u.name}, &slice); err != nil {
		return
	}
	slice.Status.Conditions = upsertNodeCondition(slice.Status.Conditions, metav1.Condition{
		Type:               memoryEnforcementCondition,
		Status:             status,
		Reason:             reason,
		Message:            msg,
		LastTransitionTime: metav1.Now(),
	})
	if err := d.client.Status().Update(ctx, &slice); err != nil {
		log.Printf("[enforcement] update slice %s/%s MemoryEnforcement: %v", u.namespace, u.name, err)
		return
	}
	if d.recorder == nil {
		return
	}
	if status == metav1.ConditionTrue {
		d.recorder.Eventf(&slice, corev1.EventTypeWarning, "MemoryEnforcementSoftWarn", "%s", msg)
	} else {
		d.recorder.Eventf(&slice, corev1.EventTypeNormal, "MemoryEnforcementCleared", "%s", msg)
	}
}

// mirrorEnforcementToJob writes a summary MemoryEnforcement condition onto the
// slice's parent VGPUJob (slice → claim.JobRef → job).
func (d *SliceViolationDetector) mirrorEnforcementToJob(ctx context.Context, u *sliceUsage, engaged bool) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: u.namespace, Name: u.name}, &slice); err != nil || slice.Spec.ClaimRef == "" {
		return
	}
	var claim vgpuv1alpha1.VGPUClaim
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: u.namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil || claim.Spec.JobRef == "" {
		return
	}
	var job vgpuv1alpha1.VGPUJob
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: u.namespace, Name: claim.Spec.JobRef}, &job); err != nil {
		return
	}
	status := metav1.ConditionFalse
	msg := "No child slice is under soft enforcement"
	if engaged {
		status = metav1.ConditionTrue
		msg = fmt.Sprintf("A child slice is under soft enforcement (mode=%s, warn-only — no eviction)", d.enforceMode.String())
	}
	job.Status.Conditions = upsertNodeCondition(job.Status.Conditions, metav1.Condition{
		Type:               memoryEnforcementCondition,
		Status:             status,
		Reason:             enforcementJobReason,
		Message:            msg,
		LastTransitionTime: metav1.Now(),
	})
	if err := d.client.Status().Update(ctx, &job); err != nil {
		log.Printf("[enforcement] mirror enforcement to job %s/%s: %v", job.Namespace, job.Name, err)
	}
}

// stampPod labels + annotates a pod whose workload is over-using GPU memory. A
// merge patch (never an update) so it cannot clobber concurrent writes, and only
// touches labels/annotations — never the pod spec. Emits a Warning event.
func (d *SliceViolationDetector) stampPod(ctx context.Context, nn types.NamespacedName, excess int64, since, deadline time.Time) {
	var pod corev1.Pod
	// Read via the API reader (direct, uncached) — the node agent runs no Pod
	// informer, so a cached Get would fail. Same path as the 3.4b pod list.
	if err := d.apiReader.Get(ctx, nn, &pod); err != nil {
		if !apierrors.IsNotFound(err) {
			log.Printf("[enforcement] stamp pod %s/%s: get: %v", nn.Namespace, nn.Name, err)
		}
		return // pod vanished — nothing to stamp
	}
	base := client.MergeFrom(pod.DeepCopy())
	if pod.Labels == nil {
		pod.Labels = map[string]string{}
	}
	pod.Labels[podViolationLabel] = "true"
	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}
	pod.Annotations[podEnforcementAnno] = "SoftWarn"
	pod.Annotations[podExcessBytesAnno] = strconv.FormatInt(excess, 10)
	pod.Annotations[podViolationSinceAnno] = since.UTC().Format(time.RFC3339)
	pod.Annotations[podDeadlineAnno] = deadline.UTC().Format(time.RFC3339)
	pod.Annotations[podEnforcementNoteAnno] = enforcementNote
	if err := d.client.Patch(ctx, &pod, base); err != nil {
		log.Printf("[enforcement] stamp pod %s/%s: %v", nn.Namespace, nn.Name, err)
		return
	}
	if d.recorder != nil {
		d.recorder.Eventf(&pod, corev1.EventTypeWarning, "MemoryEnforcementSoftWarn",
			"Pod's GPU VRAM use exceeded its slice grant by %d MiB; soft enforcement (warn-only) engaged — pod is NOT evicted (deadline %s is informational)",
			excess>>20, deadline.UTC().Format(time.RFC3339))
	}
}

// clearPod removes the soft-enforcement label/annotations from a pod and emits a
// Normal "cleared" event if anything was actually removed.
func (d *SliceViolationDetector) clearPod(ctx context.Context, nn types.NamespacedName) {
	if !d.unstampPod(ctx, nn) {
		return
	}
	if d.recorder != nil {
		pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: nn.Namespace, Name: nn.Name}}
		d.recorder.Eventf(pod, corev1.EventTypeNormal, "MemoryEnforcementCleared",
			"Pod's GPU VRAM use returned within its slice grant; soft-enforcement label/annotations removed")
	}
}

// unstampPod removes our label/annotations via a merge patch. Returns true if a
// patch was applied (the pod existed and carried our stamp). No event — callers
// decide whether to emit one.
func (d *SliceViolationDetector) unstampPod(ctx context.Context, nn types.NamespacedName) bool {
	var pod corev1.Pod
	if err := d.apiReader.Get(ctx, nn, &pod); err != nil {
		if !apierrors.IsNotFound(err) {
			log.Printf("[enforcement] unstamp pod %s/%s: get: %v", nn.Namespace, nn.Name, err)
		}
		return false
	}
	if pod.Labels[podViolationLabel] == "" && pod.Annotations[podEnforcementAnno] == "" {
		return false // not stamped — nothing to do
	}
	base := client.MergeFrom(pod.DeepCopy())
	delete(pod.Labels, podViolationLabel)
	delete(pod.Annotations, podEnforcementAnno)
	delete(pod.Annotations, podExcessBytesAnno)
	delete(pod.Annotations, podViolationSinceAnno)
	delete(pod.Annotations, podDeadlineAnno)
	delete(pod.Annotations, podEnforcementNoteAnno)
	if err := d.client.Patch(ctx, &pod, base); err != nil {
		log.Printf("[enforcement] unstamp pod %s/%s: %v", nn.Namespace, nn.Name, err)
		return false
	}
	return true
}

// sweepOrphanStamps runs once at startup: it drops any soft-enforcement pod
// stamps left behind by a previous detector lifetime (in-memory enforcement
// state does not survive a restart). The detection loop re-establishes stamps —
// after the grace period — for any slice that is still over-using, so this
// guarantees no orphaned stamp can outlive the condition that caused it. Quiet
// (no events): a still-violating slice would otherwise log a misleading "cleared".
func (d *SliceViolationDetector) sweepOrphanStamps(ctx context.Context) {
	if d.enforceMode == EnforcementOff {
		return
	}
	var pods corev1.PodList
	if err := d.apiReader.List(ctx, &pods, client.HasLabels{podViolationLabel}); err != nil {
		return
	}
	for i := range pods.Items {
		p := &pods.Items[i]
		if p.Spec.NodeName != d.nodeName {
			continue
		}
		if d.unstampPod(ctx, types.NamespacedName{Namespace: p.Namespace, Name: p.Name}) {
			log.Printf("[enforcement] startup: cleared stale soft-enforcement stamp on pod %s/%s", p.Namespace, p.Name)
		}
	}
}
