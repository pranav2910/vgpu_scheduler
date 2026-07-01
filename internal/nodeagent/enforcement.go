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
	policyv1 "k8s.io/api/policy/v1"
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
	// EnforcementSoftWarn (3.4c): label/annotate + record + warn, never destroys.
	EnforcementSoftWarn
	// EnforcementEvict (3.4d): everything softwarn does, plus — for over-use that
	// persists past the eviction deadline — evicts the offending pod (PDB-
	// respecting, rate-limited, exemptable) to reclaim VRAM. Opt-in only.
	EnforcementEvict
)

func (m EnforcementMode) String() string {
	switch m {
	case EnforcementEvict:
		return "evict"
	case EnforcementSoftWarn:
		return "softwarn"
	default:
		return "off"
	}
}

// ParseEnforcementMode maps a config string to a mode. The default (empty) is
// softwarn — non-destructive, so it is safe on by default. "evict" is opt-in and
// enables destructive enforcement (3.4d). "throttle"/"hard" are NOT honored
// (VRAM cannot be throttled per-process on a non-MIG GPU) and fall back to
// softwarn, so enabling eviction stays a deliberate, explicit choice.
func ParseEnforcementMode(s string) EnforcementMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "softwarn", "soft", "warn":
		return EnforcementSoftWarn
	case "off", "none", "disabled", "observe":
		return EnforcementOff
	case "evict", "evicting", "hard-evict":
		return EnforcementEvict
	case "throttle", "hard", "enforce":
		log.Printf("[enforcement] mode %q is not a valid VRAM-enforcement action (VRAM cannot be throttled per-process on a non-MIG GPU) — using softwarn; set 'evict' for opt-in eviction", s)
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

	// evictionGracePeriod (3.4d) is the ADDITIONAL grace after soft enforcement
	// engages before an over-using pod is evicted in evict mode — a window for the
	// workload to self-correct. The enforcement-deadline = onset + soft + evict
	// grace (≈ 90s detect + 60s warn + 120s ≈ 270s to eviction).
	evictionGracePeriod = 120 * time.Second

	// Per-node eviction rate limit — a backstop so a detection bug can't mass-
	// evict. Conservative by design.
	maxEvictionsPerWindow = 3
	evictionWindow        = 5 * time.Minute

	// enforcementExemptLabel opts a NAMESPACE's workloads out of eviction. They
	// are still detected, marked, and soft-warned — only the destructive step is
	// skipped. Honored on the namespace ONLY: a pod-level label would let a
	// workload self-exempt (see isExempt). Reuses the existing
	// infrastructure.pranav2910.com/ label domain.
	enforcementExemptLabel = "infrastructure.pranav2910.com/enforcement-exempt"

	memoryEnforcementCondition  = "MemoryEnforcement"
	enforcementReasonEngaged    = "SoftWarnEngaged"
	enforcementReasonCleared    = "WithinGrant"
	enforcementReasonEvicted    = "Evicted"
	enforcementJobReason        = "ChildSliceSoftWarn"
	enforcementJobReasonEvicted = "ChildSliceEvicted"

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
	softDeadline := start.Add(enforcementGracePeriod)
	if d.now().Before(softDeadline) {
		telemetry.MemoryEnforcementActive.WithLabelValues(d.nodeName, u.namespace, u.name).Set(0)
		return // Observed — within grace; enforcement not engaged yet.
	}
	// The enforcement-deadline shown to the workload is the EVICTION time, so it
	// is honest in both modes: in softwarn it is when evict mode WOULD act.
	evictDeadline := start.Add(enforcementGracePeriod + evictionGracePeriod)

	telemetry.MemoryEnforcementActive.WithLabelValues(d.nodeName, u.namespace, u.name).Set(1)
	if !d.enforced[key] {
		d.enforced[key] = true
		d.stampedPods[key] = append([]types.NamespacedName(nil), u.pods...)
		telemetry.MemoryEnforcementActionsTotal.WithLabelValues(d.nodeName, u.namespace, u.name, d.enforceMode.String(), "warn").Inc()
		d.profileOnSoftWarn(key) // 3.5: count the soft-enforcement engagement
		d.engageSoftWarn(ctx, u, excess, start, evictDeadline)
	}
	// 3.4d: once over-use persists past the eviction deadline, evict mode reclaims
	// VRAM by evicting the offending pod(s) — PDB-respecting, rate-limited, and
	// skipping exempt workloads. softwarn never reaches here.
	if d.enforceMode >= EnforcementEvict && !d.now().Before(evictDeadline) {
		d.maybeEvict(ctx, u, excess)
	}
}

// engageSoftWarn applies every soft-enforcement surface for a slice that has been
// over-budget past the grace period: slice condition, job mirror, pod stamps.
func (d *SliceViolationDetector) engageSoftWarn(ctx context.Context, u *sliceUsage, excess int64, since, deadline time.Time) {
	msg := fmt.Sprintf("Soft enforcement engaged (warn-only, mode=%s): slice exceeded its VRAM grant by %d MiB for over %ds. The pod is labeled/annotated and is NOT evicted or throttled. enforcement-deadline=%s is informational (when a future hard mode would act).",
		d.enforceMode.String(), excess>>20, int(enforcementGracePeriod.Seconds()), deadline.UTC().Format(time.RFC3339))

	d.setSliceEnforcementCondition(ctx, u, metav1.ConditionTrue, enforcementReasonEngaged, msg, "MemoryEnforcementSoftWarn")
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
		"GPU memory returned within grant; soft-enforcement surfaces cleared", "MemoryEnforcementCleared")
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
// slice and emits a slice Event with the given reason (empty = no event). The
// event type follows the status (True → Warning, False → Normal). The slice
// phase is never changed.
func (d *SliceViolationDetector) setSliceEnforcementCondition(ctx context.Context, u *sliceUsage, status metav1.ConditionStatus, reason, msg, eventReason string) {
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
	if d.recorder == nil || eventReason == "" {
		return
	}
	etype := corev1.EventTypeWarning
	if status != metav1.ConditionTrue {
		etype = corev1.EventTypeNormal
	}
	d.recorder.Eventf(&slice, etype, eventReason, "%s", msg)
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

// ── Phase 3.4d: opt-in eviction ──────────────────────────────────────────────

// maybeEvict attempts to evict the pod(s) currently over-using the slice's grant,
// once over-use has persisted past the eviction deadline (evict mode only). Each
// pod runs the full safety gauntlet — exemption, per-node rate limit, then a
// PDB-respecting Eviction API call — and every block is recorded, never silent.
func (d *SliceViolationDetector) maybeEvict(ctx context.Context, u *sliceUsage, excess int64) {
	for _, nn := range u.pods {
		podK := nn.Namespace + "/" + nn.Name
		if _, done := d.evictHandled[podK]; done {
			continue // already evicted or exempted — terminal, do not reprocess
		}
		if d.isExempt(ctx, nn) {
			// Deliberately NOT recorded in evictHandled: exemption is a live,
			// user-editable label, not a terminal outcome. Caching it meant
			// removing the label had no effect while the violation persisted —
			// eviction never re-engaged until an agent restart. Re-check every
			// cycle instead (notifyBlocked dedups the event by pod+reason).
			d.notifyBlocked(u, nn, "exempt",
				fmt.Sprintf("Pod's namespace is exempt from eviction (%s=true on the namespace); over-use stays marked + soft-warned but the pod is NOT evicted", enforcementExemptLabel))
			continue
		}
		if !d.evictionAllowed() {
			d.notifyBlocked(u, nn, "ratelimited",
				fmt.Sprintf("Per-node eviction rate limit reached (%d per %s); deferring eviction", maxEvictionsPerWindow, evictionWindow))
			continue // transient — retry next cycle
		}
		if err := d.evictFn(ctx, nn); err != nil {
			switch {
			case apierrors.IsNotFound(err):
				d.evictHandled[podK] = "evicted" // pod already gone
			case apierrors.IsTooManyRequests(err):
				d.notifyBlocked(u, nn, "pdb",
					"Eviction blocked by a PodDisruptionBudget — not deleting; over-use stays marked + soft-warned")
			default:
				log.Printf("[enforcement] evict pod %s: %v", podK, err)
			}
			continue
		}
		// Evicted.
		d.evictHandled[podK] = "evicted"
		delete(d.blockedNotified, podK)
		d.recordEvictionTime()
		telemetry.MemoryEnforcementActionsTotal.WithLabelValues(d.nodeName, u.namespace, u.name, d.enforceMode.String(), "evict").Inc()
		d.profileOnEviction(sliceKey(u.namespace, u.name)) // 3.5: count the eviction
		d.recordEvictionAudit(ctx, u, nn, excess)
	}
}

// evictViaAPI issues a Kubernetes Eviction (pods/eviction subresource) — PDB-
// respecting and graceful, never a raw delete or force-delete. It is the default
// evictFn; tests override evictFn to exercise the policy without a live cluster.
func (d *SliceViolationDetector) evictViaAPI(ctx context.Context, nn types.NamespacedName) error {
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: nn.Namespace, Name: nn.Name}}
	eviction := &policyv1.Eviction{ObjectMeta: metav1.ObjectMeta{Namespace: nn.Namespace, Name: nn.Name}}
	return d.client.SubResource("eviction").Create(ctx, pod, eviction)
}

// isExempt reports whether a pod's NAMESPACE opted it out of eviction. An
// exempt workload is still detected, marked, and soft-warned; only the
// destructive step is skipped.
//
// Namespace-only by design (audit fix): honoring the label on the pod itself
// let a workload SELF-exempt — whoever writes the pod spec could dodge the one
// hard VRAM-reclamation mechanism by adding a label to their own pod. A
// namespace label is set by whoever administers the namespace, which is the
// correct authority for an enforcement carve-out.
func (d *SliceViolationDetector) isExempt(ctx context.Context, nn types.NamespacedName) bool {
	var ns corev1.Namespace
	if err := d.apiReader.Get(ctx, types.NamespacedName{Name: nn.Namespace}, &ns); err == nil && ns.Labels[enforcementExemptLabel] == "true" {
		return true
	}
	return false
}

// evictionAllowed reports whether the per-node eviction budget has headroom,
// pruning timestamps outside the sliding window.
func (d *SliceViolationDetector) evictionAllowed() bool {
	cutoff := d.now().Add(-evictionWindow)
	kept := d.evictionTimes[:0]
	for _, t := range d.evictionTimes {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	d.evictionTimes = kept
	return len(d.evictionTimes) < maxEvictionsPerWindow
}

func (d *SliceViolationDetector) recordEvictionTime() {
	d.evictionTimes = append(d.evictionTimes, d.now())
}

// notifyBlocked records a blocked eviction once per (pod, reason) episode — the
// metric + Event fire on the transition, not every cycle, so a persistently
// blocked pod does not spam.
func (d *SliceViolationDetector) notifyBlocked(u *sliceUsage, nn types.NamespacedName, reason, msg string) {
	podK := nn.Namespace + "/" + nn.Name
	if d.blockedNotified[podK] == reason {
		return
	}
	d.blockedNotified[podK] = reason
	telemetry.MemoryEvictionsBlocked.WithLabelValues(d.nodeName, u.namespace, u.name, reason).Inc()
	if d.recorder != nil {
		pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: nn.Namespace, Name: nn.Name}}
		d.recorder.Eventf(pod, corev1.EventTypeWarning, "MemoryEvictionBlocked", "%s", msg)
	}
	log.Printf("[enforcement] eviction blocked (%s): pod %s/%s slice %s — %s", reason, nn.Namespace, nn.Name, u.name, msg)
}

// recordEvictionAudit emits the durable audit trail for an eviction: a pod Event,
// the slice MemoryEnforcement condition (reason=Evicted), and the job mirror.
func (d *SliceViolationDetector) recordEvictionAudit(ctx context.Context, u *sliceUsage, nn types.NamespacedName, excess int64) {
	msg := fmt.Sprintf("Evicted pod %s for sustained GPU VRAM over-use (%d MiB over grant) past the enforcement deadline — reclaiming VRAM (policy=evict, PDB-respecting)", nn.Name, excess>>20)
	if d.recorder != nil {
		pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: nn.Namespace, Name: nn.Name}}
		d.recorder.Eventf(pod, corev1.EventTypeWarning, "MemoryEnforcementEvicted", "%s", msg)
	}
	d.setSliceEnforcementCondition(ctx, u, metav1.ConditionTrue, enforcementReasonEvicted, msg, "MemoryEnforcementEvicted")
	d.mirrorEvictionToJob(ctx, u)
	log.Printf("[enforcement] EVICTED pod %s/%s (slice %s, excess=%d MiB) to reclaim VRAM", nn.Namespace, nn.Name, u.name, excess>>20)
}

// mirrorEvictionToJob marks the parent VGPUJob's MemoryEnforcement summary with
// reason ChildSliceEvicted (slice → claim.JobRef → job).
func (d *SliceViolationDetector) mirrorEvictionToJob(ctx context.Context, u *sliceUsage) {
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
	job.Status.Conditions = upsertNodeCondition(job.Status.Conditions, metav1.Condition{
		Type:               memoryEnforcementCondition,
		Status:             metav1.ConditionTrue,
		Reason:             enforcementJobReasonEvicted,
		Message:            "A child slice's pod was evicted for sustained GPU memory over-use (policy=evict)",
		LastTransitionTime: metav1.Now(),
	})
	if err := d.client.Status().Update(ctx, &job); err != nil {
		log.Printf("[enforcement] mirror eviction to job %s/%s: %v", job.Namespace, job.Name, err)
	}
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
