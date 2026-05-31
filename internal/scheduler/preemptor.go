package scheduler

import (
	"context"
	"fmt"
	"log"
	"sort"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	PreemptionCooldown    = 60 * time.Second
	PreemptionPriorityGap = int32(100)
	DefaultGraceSeconds   = int32(30)
	// MaxGraceSeconds bounds the in-flight window so a misconfigured
	// VGPUJob can't lock out preemption for unbounded time.
	MaxGraceSeconds = int32(3600)

	// PreemptionInFlightWindow is the *floor* on the dedup gate — short
	// preemptions still get at least this much protection. The gate also
	// considers the requester's actual grace setting (see
	// effectiveInFlightWindow) so long-grace configs can't stack a
	// second wave before victims have drained.
	PreemptionInFlightWindow = 60 * time.Second

	// AnnotationPreemptionTriggeredAt is set on a requester slice when its
	// preemption plan is generated. Subsequent TryPreempt calls within the
	// in-flight window are no-ops to prevent over-eviction.
	AnnotationPreemptionTriggeredAt = "infrastructure.pranav2910.com/preemption-triggered-at"
)

// PreemptionPlan describes a planned eviction.
type PreemptionPlan struct {
	Requester   *vgpuv1alpha1.VGPUSlice
	Victims     []VictimSelection
	FreedBytes  int64
	NeededBytes int64
	CreatedAt   time.Time
}

// VictimSelection is one slice marked for eviction in a plan.
type VictimSelection struct {
	Slice          *vgpuv1alpha1.VGPUSlice
	Job            *vgpuv1alpha1.VGPUJob
	Priority       int32
	GraceSeconds   int32
	AllocatedBytes int64
}

// PreemptionInProgressError signals scheduling-failed-due-to-preemption.
// The reconciler should requeue with a delay >= grace period.
type PreemptionInProgressError struct {
	Plan *PreemptionPlan
}

func (e *PreemptionInProgressError) Error() string {
	return fmt.Sprintf("preemption in progress: %d victims, %d bytes",
		len(e.Plan.Victims), e.Plan.FreedBytes)
}

// Preemptor owns preemption state.
type Preemptor struct {
	client client.Client

	mu       sync.Mutex
	cooldown map[string]time.Time // key: namespace/claimName -> until
}

// NewPreemptor constructs a Preemptor.
func NewPreemptor(c client.Client) *Preemptor {
	p := &Preemptor{
		client:   c,
		cooldown: make(map[string]time.Time),
	}
	// Background reaper for stale cooldown entries. The map would
	// otherwise grow unbounded over the scheduler's lifetime — every
	// preempt pass adds entries and nothing was clearing them.
	// Lives for the process; clean shutdown is a v0.2 concern.
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			p.CleanupCooldown()
		}
	}()
	return p
}

// TryPreempt attempts to free neededBytes of capacity by evicting eligible
// lower-priority victims in the requester's namespace.
//
// Returns:
//   - (*PreemptionPlan, nil) if a viable plan was found and victims marked
//   - (nil, nil) if no plan possible (no eligible victims, gap too small, etc)
//   - (nil, err) on infrastructure failure
func (p *Preemptor) TryPreempt(
	ctx context.Context,
	requester *vgpuv1alpha1.VGPUSlice,
	requesterPriority int32,
	requesterClaim *vgpuv1alpha1.VGPUClaim,
	neededBytes int64,
) (*PreemptionPlan, error) {

	// 0. Atomic dedup gate: claim ownership of this preemption plan via
	// Kubernetes optimistic concurrency. Stamp the annotation FIRST.
	// If our Update succeeds, we own this plan and proceed.
	// If another reconcile stamped first (annotation present and recent),
	// or if our Update conflicts (resourceVersion mismatch), bail out.
	// This eliminates the TOCTOU race where two concurrent reconciles
	// could both pass a read-only gate before either stamped the annotation.
	owned, err := p.claimPlanOwnership(ctx, requester)
	if err != nil {
		// Conflict / not-found / transient error — another reconcile owns
		// the plan or the slice changed under us. Don't proceed.
		log.Printf("[preemptor] %s/%s: could not claim plan ownership: %v — skip",
			requester.Namespace, requester.Name, err)
		telemetry.PreemptionBlocked.WithLabelValues("ownership_lost").Inc()
		return nil, nil
	}
	if !owned {
		// Annotation already present and recent — another plan in flight.
		telemetry.PreemptionBlocked.WithLabelValues("ownership_lost").Inc()
		return nil, nil
	}

	// 1. Cooldown on requester's claim.
	if requesterClaim != nil {
		key := requester.Namespace + "/" + requesterClaim.Name
		p.mu.Lock()
		if until, ok := p.cooldown[key]; ok && time.Now().Before(until) {
			p.mu.Unlock()
			log.Printf("[preemptor] %s/%s in cooldown until %v",
				requester.Namespace, requester.Name, until.Format(time.RFC3339))
			telemetry.PreemptionBlocked.WithLabelValues("cooldown").Inc()
			return nil, nil
		}
		p.mu.Unlock()
	}

	// 2. List slices in requester's namespace.
	var slices vgpuv1alpha1.VGPUSliceList
	if err := p.client.List(ctx, &slices, client.InNamespace(requester.Namespace)); err != nil {
		return nil, fmt.Errorf("listing slices: %w", err)
	}

	// 3. Build candidate list: Ready, preemptible, big-enough priority gap.
	candidates := make([]VictimSelection, 0)
	for i := range slices.Items {
		s := &slices.Items[i]

		if s.Name == requester.Name {
			continue
		}
		if s.Status.Phase != "Ready" {
			continue
		}
		if s.Status.AllocatedBytes <= 0 {
			continue
		}
		if s.Spec.ClaimRef == "" {
			continue
		}

		var claim vgpuv1alpha1.VGPUClaim
		if err := p.client.Get(ctx, client.ObjectKey{Namespace: s.Namespace, Name: s.Spec.ClaimRef}, &claim); err != nil {
			continue
		}
		if claim.Spec.JobRef == "" {
			continue
		}

		var job vgpuv1alpha1.VGPUJob
		if err := p.client.Get(ctx, client.ObjectKey{Namespace: s.Namespace, Name: claim.Spec.JobRef}, &job); err != nil {
			continue
		}

		if !job.Spec.Preemptible {
			continue
		}
		if requesterPriority-job.Spec.Priority < PreemptionPriorityGap {
			continue
		}

		// Per-victim cooldown.
		victimKey := s.Namespace + "/" + claim.Name
		p.mu.Lock()
		if until, ok := p.cooldown[victimKey]; ok && time.Now().Before(until) {
			p.mu.Unlock()
			continue
		}
		p.mu.Unlock()

		grace := DefaultGraceSeconds
		if job.Spec.PreemptionGraceSeconds != nil {
			grace = *job.Spec.PreemptionGraceSeconds
		}

		candidates = append(candidates, VictimSelection{
			Slice:          s.DeepCopy(),
			Job:            job.DeepCopy(),
			Priority:       job.Spec.Priority,
			GraceSeconds:   grace,
			AllocatedBytes: s.Status.AllocatedBytes,
		})
	}

	if len(candidates) == 0 {
		log.Printf("[preemptor] no eligible victims in %s for %s (priority=%d)",
			requester.Namespace, requester.Name, requesterPriority)
		telemetry.PreemptionBlocked.WithLabelValues("no_victims").Inc()
		return nil, nil
	}

	// 4. Sort: lowest priority -> smallest VRAM -> oldest.
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].Priority != candidates[j].Priority {
			return candidates[i].Priority < candidates[j].Priority
		}
		if candidates[i].AllocatedBytes != candidates[j].AllocatedBytes {
			return candidates[i].AllocatedBytes < candidates[j].AllocatedBytes
		}
		return candidates[i].Slice.CreationTimestamp.Before(&candidates[j].Slice.CreationTimestamp)
	})

	// 5. Selection algorithm — minimize eviction damage.
	//
	// Strategy:
	//   1. Look for the smallest single victim whose AllocatedBytes alone
	//      covers neededBytes. This minimizes both bytes-freed and
	//      number-of-victims when one victim is enough.
	//   2. If no single victim suffices, accumulate from the candidate list
	//      (already sorted: lowest priority -> smallest VRAM -> oldest).
	plan := &PreemptionPlan{
		Requester:   requester.DeepCopy(),
		Victims:     []VictimSelection{},
		NeededBytes: neededBytes,
		CreatedAt:   time.Now(),
	}

	// Phase 1: find the smallest single victim that covers the need.
	// Iterate in size-ascending order to find the smallest one >= neededBytes.
	// Build a size-sorted view of candidates without disturbing the original
	// priority/age order (used as fallback in Phase 2).
	bySize := make([]VictimSelection, len(candidates))
	copy(bySize, candidates)
	sort.SliceStable(bySize, func(i, j int) bool {
		return bySize[i].AllocatedBytes < bySize[j].AllocatedBytes
	})

	var single *VictimSelection
	for i := range bySize {
		if bySize[i].AllocatedBytes >= neededBytes {
			single = &bySize[i]
			break
		}
	}
	if single != nil {
		plan.Victims = []VictimSelection{*single}
		plan.FreedBytes = single.AllocatedBytes
	} else {
		// Phase 2: no single victim big enough — accumulate.
		// Use the original (priority-sorted) order so we still evict
		// lowest-priority/smallest/oldest first.
		for _, c := range candidates {
			plan.Victims = append(plan.Victims, c)
			plan.FreedBytes += c.AllocatedBytes
			if plan.FreedBytes >= neededBytes {
				break
			}
		}
	}

	if plan.FreedBytes < neededBytes {
		log.Printf("[preemptor] insufficient eligible capacity in %s: needed=%d freeable=%d",
			requester.Namespace, neededBytes, plan.FreedBytes)
		telemetry.PreemptionBlocked.WithLabelValues("insufficient_capacity").Inc()
		return nil, nil
	}

	// 6. Mark victims as Preempting.
	if err := p.markVictimsPreempting(ctx, plan); err != nil {
		return nil, fmt.Errorf("marking victims: %w", err)
	}

	// 7. Cooldown each victim's claim.
	p.mu.Lock()
	until := time.Now().Add(PreemptionCooldown)
	for _, v := range plan.Victims {
		p.cooldown[v.Slice.Namespace+"/"+v.Job.Name+"-claim"] = until
	}
	p.mu.Unlock()

	graces := make([]int32, 0, len(plan.Victims))
	for _, v := range plan.Victims {
		graces = append(graces, v.GraceSeconds)
	}
	telemetry.RecordPreemptionPlan(len(plan.Victims), plan.FreedBytes, graces)

	log.Printf("[preemptor] PLAN: requester=%s/%s priority=%d victims=%d freed=%d/%d bytes",
		requester.Namespace, requester.Name, requesterPriority,
		len(plan.Victims), plan.FreedBytes, neededBytes)

	return plan, nil
}

func (p *Preemptor) markVictimsPreempting(ctx context.Context, plan *PreemptionPlan) error {
	// Track successfully-marked victims so we can roll them back on partial
	// failure. Without this, a mid-loop error would leave N-1 victims evicted
	// for nothing.
	marked := make([]int, 0, len(plan.Victims))
	for i := range plan.Victims {
		v := &plan.Victims[i]
		key := client.ObjectKey{Namespace: v.Slice.Namespace, Name: v.Slice.Name}

		err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var fresh vgpuv1alpha1.VGPUSlice
			if err := p.client.Get(ctx, key, &fresh); err != nil {
				return err
			}
			if fresh.Status.Phase != "Ready" {
				return nil // someone else moved it; abort silently
			}

			fresh.Status.Phase = "Preempting"

			cond := metav1.Condition{
				Type:   "Preempting",
				Status: metav1.ConditionTrue,
				Reason: "HigherPriorityWorkload",
				Message: fmt.Sprintf("Preempted by %s/%s; grace=%ds",
					plan.Requester.Namespace, plan.Requester.Name, v.GraceSeconds),
				LastTransitionTime: metav1.Now(),
			}
			fresh.Status.Conditions = upsertCondition(fresh.Status.Conditions, cond)

			return p.client.Status().Update(ctx, &fresh)
		})
		if err != nil {
			log.Printf("[preemptor] failed to mark victim %s/%s: %v",
				v.Slice.Namespace, v.Slice.Name, err)
			// Roll back already-marked victims back to Ready (best-effort).
			// If rollback also fails, the next reconcile will heal it once
			// the in-flight annotation expires.
			p.rollbackPreemptingMarks(ctx, plan.Victims, marked)
			return err
		}
		marked = append(marked, i)
	}
	return nil
}

func upsertCondition(conds []metav1.Condition, c metav1.Condition) []metav1.Condition {
	for i := range conds {
		if conds[i].Type == c.Type {
			conds[i] = c
			return conds
		}
	}
	return append(conds, c)
}

// claimPlanOwnership atomically reserves the right to generate a preemption
// plan for this requester. Returns:
//
//	(true,  nil) — we won the race and stamped the annotation; proceed.
//	(false, nil) — another reconcile already has a fresh annotation; skip.
//	(false, err) — resource changed under us (conflict) or other error;
//	               caller should treat this as "skip to be safe".
//
// This is the atomic alternative to a separate read-then-stamp dedup,
// which had a TOCTOU race window where two concurrent reconciles could
// both pass a read-only gate before either stamped the annotation.
func (p *Preemptor) claimPlanOwnership(ctx context.Context, requester *vgpuv1alpha1.VGPUSlice) (bool, error) {
	key := client.ObjectKey{Namespace: requester.Namespace, Name: requester.Name}
	var fresh vgpuv1alpha1.VGPUSlice
	if err := p.client.Get(ctx, key, &fresh); err != nil {
		return false, err
	}

	// If a recent annotation already exists, we don't own this plan.
	if fresh.Annotations != nil {
		if ts, ok := fresh.Annotations[AnnotationPreemptionTriggeredAt]; ok {
			if t, perr := time.Parse(time.RFC3339, ts); perr == nil {
				if time.Since(t) < p.effectiveInFlightWindow(ctx, requester) {
					return false, nil
				}
			}
		}
	}

	// Stamp it. Update uses optimistic concurrency: if another reconcile
	// has modified `fresh` since our Get (e.g. by stamping the annotation
	// themselves), this Update returns a conflict and we treat it as
	// "we lost the race".
	if fresh.Annotations == nil {
		fresh.Annotations = make(map[string]string)
	}
	fresh.Annotations[AnnotationPreemptionTriggeredAt] = time.Now().UTC().Format(time.RFC3339)

	if err := p.client.Update(ctx, &fresh); err != nil {
		// Conflict or other error — caller treats as "skip".
		return false, err
	}
	return true, nil
}

// CleanupCooldown prunes stale cooldown entries.
func (p *Preemptor) CleanupCooldown() {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	for k, until := range p.cooldown {
		if now.After(until) {
			delete(p.cooldown, k)
		}
	}
}

// rollbackPreemptingMarks reverts already-marked victims from Preempting
// back to Ready. Called when markVictimsPreempting fails partway through.
// Best-effort: failures are logged but not propagated, since the caller
// is already returning an error and the in-flight annotation will expire,
// allowing the next reconcile to retry cleanly.
func (p *Preemptor) rollbackPreemptingMarks(ctx context.Context, victims []VictimSelection, indices []int) {
	for _, idx := range indices {
		v := &victims[idx]
		key := client.ObjectKey{Namespace: v.Slice.Namespace, Name: v.Slice.Name}
		err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var fresh vgpuv1alpha1.VGPUSlice
			if err := p.client.Get(ctx, key, &fresh); err != nil {
				return err
			}
			if fresh.Status.Phase != "Preempting" {
				return nil // someone else already moved it
			}
			fresh.Status.Phase = "Ready"
			// Strip the Preempting condition we added.
			out := fresh.Status.Conditions[:0]
			for _, c := range fresh.Status.Conditions {
				if c.Type != "Preempting" {
					out = append(out, c)
				}
			}
			fresh.Status.Conditions = out
			return p.client.Status().Update(ctx, &fresh)
		})
		if err != nil {
			log.Printf("[preemptor] WARN: rollback of victim %s/%s failed: %v (will heal on next reconcile)",
				v.Slice.Namespace, v.Slice.Name, err)
		}
	}
}

// effectiveInFlightWindow returns the dedup-gate duration for this requester.
// PreemptionInFlightWindow is a floor; the actual window is the longer of
// that floor and the longest grace period configured on any preemptible
// VGPUJob in the requester's namespace, plus a 30-second buffer.
//
// Without this, a job with grace=600s could be the victim of a preemption,
// and 60s later (when the static window expired) a second preemption wave
// could fire on top of the first while the original victims were still
// draining.
func (p *Preemptor) effectiveInFlightWindow(ctx context.Context, requester *vgpuv1alpha1.VGPUSlice) time.Duration {
	floor := PreemptionInFlightWindow

	var jobs vgpuv1alpha1.VGPUJobList
	if err := p.client.List(ctx, &jobs, client.InNamespace(requester.Namespace)); err != nil {
		return floor
	}
	maxGrace := DefaultGraceSeconds
	for i := range jobs.Items {
		j := &jobs.Items[i]
		if !j.Spec.Preemptible {
			continue
		}
		grace := DefaultGraceSeconds
		if j.Spec.PreemptionGraceSeconds != nil {
			grace = *j.Spec.PreemptionGraceSeconds
		}
		if grace > MaxGraceSeconds {
			grace = MaxGraceSeconds
		}
		if grace > maxGrace {
			maxGrace = grace
		}
	}
	dynamic := time.Duration(maxGrace+30) * time.Second
	if dynamic > floor {
		return dynamic
	}
	return floor
}
