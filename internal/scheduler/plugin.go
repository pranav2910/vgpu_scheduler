package scheduler

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
)

const (
	// TopologyZoneLabel is the node label declaring its topology zone.
	// Phase 2.5a (node-level topology awareness).
	TopologyZoneLabel = "topology.vgpu.pranav2910.com/zone"
	// TopologyPreferredZoneAnnotation is the workload's soft topology-zone
	// preference. Propagated Job→Claim→Slice via FilterGangAnnotations.
	TopologyPreferredZoneAnnotation = "topology.vgpu.pranav2910.com/preferred-zone"
)

// SliceScheduler is the stateful scheduling engine.
type SliceScheduler struct {
	QuotaChecker *QuotaChecker
	Preemptor    *Preemptor
	GangGate     *GangBindingGate
	Cache        *VRAMCache
	Reserver     *ReservationManager
	K8sClient    client.Client
}

func NewSliceScheduler(cache *VRAMCache, k8sClient client.Client) *SliceScheduler {
	return &SliceScheduler{
		Cache:     cache,
		Reserver:  NewReservationManager(cache, 30*time.Second),
		K8sClient: k8sClient,
	}
}

// gangHoldTTL bounds how long a deferred gang member's cache reservation can
// survive without making progress. Should be longer than the slice TTL (30s)
// so a held reservation isn't reaped while the gang is converging, and
// shorter than the gang reservation deadline (60s default) so a stuck gang
// eventually frees its cache holds even if the controller fails to mark
// the reservation Failed.
const gangHoldTTL = 50 * time.Second

// bindPinTTL is how long the pre-bind pin extends a hold. The bind is a pair
// of API calls (spec patch + status patch) that normally completes in
// milliseconds; 30s of headroom means only severe API-server distress can
// outlive the pin — and if it somehow does, Confirm's re-arm path still
// recovers the accounting.
const bindPinTTL = 30 * time.Second

// Schedule runs one full scheduling cycle for a Pending VGPUSlice.
// nn is the NamespacedName of the slice (for the direct Get in bindToKubernetesAPI).
// sliceUID is the K8s UID (reservation key in the cache).
// Bug #5 fix.
//
// Option B (hold-the-reservation) addition: if this slice already has a held
// cache reservation from a prior cycle, we fast-forward past Filter/Score/
// Reserve and go straight to the gate. This is what enables a cohort of N
// gang members to converge: each member arrives, takes a hold, defers; on
// the Nth arrival the gate releases the cohort, and on subsequent reconciles
// the previously-deferred members find their hold still alive and proceed.
func (s *SliceScheduler) Schedule(ctx context.Context, nn types.NamespacedName, sliceUID string, reqBytes int64, bestEffort bool) (string, error) {
	// Warm-up gate: refuse to place anything until the cache has been seeded with
	// node capacity AND the consumption of all already-bound slices. Without this,
	// a freshly restarted scheduler (cold cache, free=full) can place a pending
	// slice into capacity that is actually occupied by slices it has not yet
	// re-observed → over-admission. The reconciler retries quickly on this error.
	if !s.Cache.IsSeeded() {
		return "", &CacheNotReadyError{}
	}

	// Measure the wall-clock cost of a real scheduling cycle (post warm-up).
	start := time.Now()
	defer func() { telemetry.SliceScheduleLatency.Observe(time.Since(start).Seconds()) }()

	log.Printf("Scheduling cycle started for Slice %s (req: %d bytes)", nn, reqBytes)

	// Layer 2 Phase 2.2a: enforce VGPUQuota before searching for nodes. For a
	// gang member, the whole gang's demand is weighed against the quota so a gang
	// is admitted all-or-none (never partially past quota).
	if s.QuotaChecker != nil {
		gangRef, gangTotal, gqErr := s.gangQuotaContext(ctx, nn, reqBytes)
		if gqErr != nil {
			// Fail CLOSED (sweep S7): a transient reservation read must not
			// downgrade a gang member to per-slice quota — one member could
			// pass a quota the gang as a whole exceeds, hold capacity in the
			// admitting cohort, and starve the quota-compliant work until the
			// reservation deadline. Retry the cycle instead.
			return "", fmt.Errorf("resolving gang quota context: %w", gqErr)
		}
		if ok, reason, msg := s.QuotaChecker.Check(ctx, nn.Namespace, reqBytes, gangRef, gangTotal); !ok {
			log.Printf("Scheduling rejected for Slice %s by quota: %s — %s",
				nn, reason, msg)
			return "", &SchedulingError{Reason: reason, Message: msg}
		}
	}

	// Option B fast-forward: if we already hold a speculative reservation
	// for this slice (from a prior gang-defer cycle), reuse it. PinAssumption
	// verifies the hold and extends its TTL in ONE critical section — the old
	// IsAssumed-then-RefreshAssumption pair let the TTL reaper fire between
	// the two calls, so we could proceed on a reservation that no longer
	// existed. If the hold is gone, fall through to a fresh Reserve.
	if heldNode, heldBytes, ok := s.Cache.PinAssumption(sliceUID, gangHoldTTL); ok {
		// Construct a Tx wrapping the existing held reservation. We don't
		// re-Reserve (would fail with "duplicate"); we just thread the
		// held capacity through the gate-and-bind path.
		tx := NewReservationTxForHeld(s.Cache, sliceUID, nn.Namespace, heldNode, heldBytes)
		defer tx.RollbackIfNotConfirmed()

		log.Printf("[gang] fast-forward: slice %s has held reservation on %s",
			nn, heldNode)
		return s.gateAndBind(ctx, nn, sliceUID, heldNode, heldBytes, tx)
	}

	// Fresh attempt: standard Filter/Score/Reserve.
	var validNodes []string
	for _, node := range s.Cache.ListNodes() {
		fits, _, _ := s.Cache.CanFit(node, reqBytes)
		if fits {
			validNodes = append(validNodes, node)
		}
	}

	if len(validNodes) == 0 {
		telemetry.RecordScheduleResult("error", "insufficient_capacity")
		// wave1 fix applied: gang-member slices skip preemption.
		// Gang membership is governed by the gang's atomic reserve-or-fail
		// semantic, not single-slice preemption.
		isGangMember := false
		{
			var slice vgpuv1alpha1.VGPUSlice
			if err := s.K8sClient.Get(ctx, nn, &slice); err == nil {
				if slice.Annotations != nil {
					if rsv, ok := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]; ok && rsv != "" {
						isGangMember = true
					}
				}
			}
		}
		// Layer 2 Phase 2.3: try preemption before declaring capacity failure.
		// Gang members skip this path entirely.
		if s.Preemptor != nil && !isGangMember {
			if plan, err := s.tryPreemptionForSlice(ctx, nn, reqBytes); err == nil && plan != nil {
				return "", &PreemptionInProgressError{Plan: plan}
			} else if err != nil {
				log.Printf("[preemption] TryPreempt failed for %s: %v", nn, err)
			}
		}
		return "", fmt.Errorf("no node has sufficient VRAM for %d bytes", reqBytes)
	}

	// Phase 2.5a: honor a soft topology-zone preference (strong weight — in-zone
	// nodes outrank out-of-zone, bin-packing orders within the zone).
	preferredZone := s.slicePreferredZone(ctx, nn)
	scores := ScoreWithTopology(s.Cache, validNodes, reqBytes, bestEffort, preferredZone)
	if len(scores) == 0 {
		return "", fmt.Errorf("scoring returned 0 candidates despite passing filter — cache inconsistency")
	}

	winningNode := scores[0].NodeName

	tx, err := s.Reserver.Reserve(sliceUID, nn.Namespace, winningNode, reqBytes)
	if err != nil {
		telemetry.RecordScheduleResult("error", "reserve_failed")
		return "", fmt.Errorf("speculative reserve failed: %w", err)
	}
	defer tx.RollbackIfNotConfirmed()

	return s.gateAndBind(ctx, nn, sliceUID, winningNode, reqBytes, tx)
}

// gateAndBind runs the gang gate decision and binds if allowed. Shared by
// the fresh-Reserve path and the fast-forward held-reservation path.
//
// On Allowed: bind, tx.Confirm() (cache moves slice from assumed to confirmed).
// On Deferred: tx.MarkHeld() so the cache assumption survives function return.
//
//	The deferred RollbackIfNotConfirmed becomes a no-op.
//
// On Rejected: leave tx un-confirmed and un-held; the deferred Rollback fires.
// On NotApplicable (no gang annotation): proceed to bind as a solo slice.
func (s *SliceScheduler) gateAndBind(
	ctx context.Context,
	nn types.NamespacedName,
	sliceUID string,
	winningNode string,
	reqBytes int64,
	tx *ReservationTx,
) (string, error) {
	if s.GangGate != nil {
		var slice vgpuv1alpha1.VGPUSlice
		if err := s.K8sClient.Get(ctx, nn, &slice); err != nil {
			// FAIL CLOSED: without the slice we cannot know whether it is a
			// gang member, and binding on a transient read error could admit a
			// gang member solo — breaking all-or-nothing. The deferred rollback
			// releases the hold; the reconciler's error backoff retries.
			telemetry.RecordScheduleResult("error", "gate_read_failed")
			return "", fmt.Errorf("gang gate: fetching slice %s (failing closed, will retry): %w", nn, err)
		}
		res, reason, gerr := s.GangGate.CheckSliceWithCohort(ctx, &slice, winningNode, reqBytes)
		if gerr != nil {
			// Gang state undetermined (transient reservation read error). Same
			// rule as the slice read above: an unknown gang state never binds.
			// Error backoff paces the retries.
			telemetry.RecordScheduleResult("error", "gate_retry")
			return "", fmt.Errorf("gang gate undetermined for %s (failing closed, will retry): %w", nn, gerr)
		}
		switch res {
		case GangRetry:
			// Knowably transient (no error): the reservation isn't visible yet —
			// a gang being BORN (slice events outran the reservation watch) or
			// one mid-teardown. Release the hold and retry on the fast 500ms
			// path: a being-born gang's reservation appears within milliseconds,
			// and a torn-down gang's slices are cascade-deleted moments later,
			// which ends the retries.
			telemetry.RecordScheduleResult("wait", "gang_reservation_pending")
			log.Printf("[gang] %s retrying: %s (RELEASING reservation)", nn, reason)
			return "", &GangDeferredError{Reason: reason}
		case GangBindDeferred:
			telemetry.RecordScheduleResult("deferred", "gang_quorum")
			// Hold the speculative cache reservation across function
			// return. Subsequent reconcile cycles will fast-forward
			// past Reserve and re-enter the gate; eventually the
			// cohort tips quorum and this slice's next call gets
			// GangBindAllowed.
			tx.MarkHeld()
			log.Printf("[gang] %s deferred: %s (HOLDING reservation)", nn, reason)
			return "", &GangDeferredError{Reason: reason}
		case GangBindWait:
			telemetry.RecordScheduleResult("wait", "gang_admission")
			// Another gang owns the admission slot. Do NOT MarkHeld — the
			// deferred RollbackIfNotConfirmed releases this slice's
			// speculative reservation so non-admitted gangs hold zero
			// capacity and cannot fragment it. Requeue quickly; once the
			// admitting gang commits (or stalls and backs off) this slice's
			// gang gets its turn at the slot.
			log.Printf("[gang] %s waiting: %s (RELEASING reservation)", nn, reason)
			return "", &GangDeferredError{Reason: reason}
		case GangBindRejected:
			telemetry.RecordScheduleResult("rejected", "gang_terminal")
			log.Printf("[gang] %s rejected: %s", nn, reason)
			return "", fmt.Errorf("gang reservation rejected bind: %s", reason)
		case GangBindAllowed:
			log.Printf("[gang] %s allowed: %s", nn, reason)
		case GangNotApplicable:
			// positive finding (no gang annotations) — proceed to bind solo
		}
	}

	// Pin the hold across the bind API call: atomically extend the TTL so the
	// reaper cannot roll the reservation back mid-bind. A reaped hold plus a
	// successful bind is a bound slice with zero cache footprint until the
	// NodeAgent reports Ready — capacity the cache would happily re-sell.
	if _, _, ok := s.Cache.PinAssumption(sliceUID, bindPinTTL); !ok {
		telemetry.RecordScheduleResult("error", "hold_lost")
		return "", fmt.Errorf("reservation for slice %s expired before bind; requeueing for a fresh reserve", nn)
	}

	if err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {
		telemetry.RecordScheduleResult("error", "bind_failed")
		return "", fmt.Errorf("bind to Kubernetes API failed: %w", err)
	}

	tx.Confirm()
	telemetry.RecordScheduleResult("success", "")
	log.Printf("Slice %s bound to node %s", nn, winningNode)
	return winningNode, nil
}

// bindToKubernetesAPI patches spec.nodeName on the slice and advances the phase
// to Scheduled. Uses a direct Get rather than a cluster-wide List. Bug #5 fix.
func (s *SliceScheduler) bindToKubernetesAPI(ctx context.Context, nn types.NamespacedName, nodeName string) error {
	var target vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &target); err != nil {
		return fmt.Errorf("fetching slice %s: %w", nn, err)
	}

	base := client.MergeFrom(target.DeepCopy())
	target.Spec.NodeName = nodeName
	if err := s.K8sClient.Patch(ctx, &target, base); err != nil {
		return fmt.Errorf("patching spec.nodeName: %w", err)
	}

	statusBase := client.MergeFrom(target.DeepCopy())
	target.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Scheduled")

	// Phase 2.5a: explainable topology placement. If the workload expressed a
	// soft zone preference, record — observably, on the slice — whether we
	// honored it or fell back to another zone. This is the wedge: not just
	// topology-aware, but topology-aware with an auditable reason.
	if pref := target.Annotations[TopologyPreferredZoneAnnotation]; pref != "" {
		placedZone := s.Cache.NodeZone(nodeName)
		cond := metav1.Condition{
			Type:               "TopologyPreferenceSatisfied",
			LastTransitionTime: metav1.Now(),
		}
		if placedZone == pref {
			cond.Status = metav1.ConditionTrue
			cond.Reason = "PreferredZoneHonored"
			cond.Message = fmt.Sprintf("scheduled in preferred zone %q", pref)
		} else {
			cond.Status = metav1.ConditionFalse
			cond.Reason = "TopologyPreferenceMiss"
			cond.Message = fmt.Sprintf("preferred zone %q unavailable; scheduled in zone %q", pref, placedZone)
			log.Printf("[topology] %s: %s", nn, cond.Message)
		}
		telemetry.RecordTopologyPlacement(placedZone, placedZone == pref)
		target.Status.Conditions = upsertCondition(target.Status.Conditions, cond)
	}

	if err := s.K8sClient.Status().Patch(ctx, &target, statusBase); err != nil {
		return fmt.Errorf("patching status.phase to Scheduled: %w", err)
	}

	return nil
}

// slicePreferredZone reads the soft topology-zone preference annotation off the
// slice, returning "" if absent or unreadable. Phase 2.5a.
func (s *SliceScheduler) slicePreferredZone(ctx context.Context, nn types.NamespacedName) string {
	var slice vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &slice); err != nil {
		return ""
	}
	if slice.Annotations == nil {
		return ""
	}
	return slice.Annotations[TopologyPreferredZoneAnnotation]
}

// SyncCacheFromSlice reconciles the scheduler cache with the NodeAgent's
// hardware events. Called from the slice reconciler when it observes Ready
// or Released phases. Bug B fix — bridges the two-process accounting gap.
func (s *SliceScheduler) SyncCacheFromSlice(sliceUID, nodeName, phase string, allocatedBytes int64) {
	switch phase {
	case "Ready":
		if err := s.Cache.PromoteSliceToAllocatedOnce(sliceUID, nodeName, allocatedBytes); err != nil {
			log.Printf("Cache sync (Ready) for slice %s: %v", sliceUID, err)
		}
	case "Released":
		s.Cache.ReleaseSliceOnce(sliceUID, nodeName)
	case "Failed":
		s.Cache.FailSliceOnce(sliceUID, nodeName)
	}
}

// gangQuotaContext returns (gangRef, gangTotalBytes) for a gang member so quota
// can be enforced gang-atomically, or ("", 0) for a solo slice (or on any
// lookup failure — a safe fall-back to per-slice quota). gangTotal = gangSize ×
// this slice's request; gang members are built from one pod template and share
// an identical request.
func (s *SliceScheduler) gangQuotaContext(ctx context.Context, nn types.NamespacedName, reqBytes int64) (string, int64, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &slice); err != nil {
		// NotFound: the slice vanished mid-cycle — solo semantics are fine,
		// the cycle will fail on its own Get. Anything else fails closed.
		if apierrors.IsNotFound(err) {
			return "", 0, nil
		}
		return "", 0, err
	}
	if slice.Annotations == nil {
		return "", 0, nil
	}
	gangRef := slice.Annotations[vgpuv1alpha1.AnnotationGangRef]
	rsvName := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]
	if gangRef == "" || rsvName == "" {
		return "", 0, nil
	}
	var rsv vgpuv1alpha1.VGPUGangReservation
	if err := s.K8sClient.Get(ctx, types.NamespacedName{Namespace: nn.Namespace, Name: rsvName}, &rsv); err != nil {
		// A gang member whose reservation can't be read: NotFound means the
		// gang is being torn down (member will fail soon anyway) — but a
		// TRANSIENT error must not silently demote gang-atomic quota to
		// per-slice quota (sweep S7).
		if apierrors.IsNotFound(err) {
			return "", 0, nil
		}
		return "", 0, err
	}
	if rsv.Spec.GangSize <= 0 {
		return "", 0, nil
	}
	return gangRef, int64(rsv.Spec.GangSize) * reqBytes, nil
}

// SetQuotaChecker wires a quota checker into the scheduler. nil disables
// quota enforcement (no quota = unlimited).
func (s *SliceScheduler) SetQuotaChecker(q *QuotaChecker) {
	s.QuotaChecker = q
}

// SchedulingError carries a structured rejection reason from Schedule().
type SchedulingError struct {
	Reason  string
	Message string
}

func (e *SchedulingError) Error() string { return e.Reason + ": " + e.Message }

// SetPreemptor wires preemption into the scheduler.
func (s *SliceScheduler) SetPreemptor(p *Preemptor) {
	s.Preemptor = p
}

// tryPreemptionForSlice resolves the requester's priority and invokes the
// Preemptor. The Preemptor handles eligibility + victim selection + marking.
func (s *SliceScheduler) tryPreemptionForSlice(ctx context.Context, nn types.NamespacedName, neededBytes int64) (*PreemptionPlan, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &slice); err != nil {
		return nil, err
	}

	var requesterPriority int32 = 50
	var claim vgpuv1alpha1.VGPUClaim
	if slice.Spec.ClaimRef != "" {
		if err := s.K8sClient.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
			if claim.Spec.JobRef != "" {
				var job vgpuv1alpha1.VGPUJob
				if err := s.K8sClient.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
					requesterPriority = job.Spec.Priority
				}
			}
		}
	}

	return s.Preemptor.TryPreempt(ctx, &slice, requesterPriority, &claim, neededBytes)
}

// GangDeferredError signals that a slice's bind was deferred because its
// gang has not yet reached cohort quorum at the gate. The caller should
// requeue quickly (500ms) and try again. The slice's speculative cache
// reservation is HELD across this defer so siblings can converge.
type GangDeferredError struct {
	Reason string
}

func (e *GangDeferredError) Error() string {
	return "gang bind deferred: " + e.Reason
}

// CacheNotReadyError is returned by Schedule before the cache warm-up has
// completed (just after a scheduler (re)start). The reconciler retries quickly
// rather than backing off. This gate is what prevents over-admission on
// restart: no slice is placed until the cache reflects all existing bound
// consumption.
type CacheNotReadyError struct{}

func (e *CacheNotReadyError) Error() string {
	return "scheduler cache not yet seeded; deferring placement"
}
