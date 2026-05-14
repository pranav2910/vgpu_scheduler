package scheduler

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
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
	log.Printf("Scheduling cycle started for Slice %s (req: %d bytes)", nn, reqBytes)

	// Layer 2 Phase 2.2a: enforce VGPUQuota before searching for nodes.
	if s.QuotaChecker != nil {
		if ok, reason, msg := s.QuotaChecker.Check(ctx, nn.Namespace, reqBytes); !ok {
			log.Printf("Scheduling rejected for Slice %s by quota: %s — %s",
				nn, reason, msg)
			return "", &SchedulingError{Reason: reason, Message: msg}
		}
	}

	// Option B fast-forward: if we already hold a speculative reservation
	// for this slice (from a prior gang-defer cycle), reuse it.
	if heldNode, heldBytes, ok := s.Cache.IsAssumed(sliceUID); ok {
		// Refresh TTL so the reaper doesn't kill us while the gang converges.
		s.Cache.RefreshAssumption(sliceUID, gangHoldTTL)

		// Construct a Tx wrapping the existing held reservation. We don't
		// re-Reserve (would fail with "duplicate"); we just thread the
		// held capacity through the gate-and-bind path.
		tx := NewReservationTxForHeld(s.Cache, sliceUID, heldNode)
		defer tx.RollbackIfNotConfirmed()

		// If reqBytes drifted from heldBytes (shouldn't happen for VGPU
		// slices since claim bytes are immutable, but defensive), prefer
		// the held value.
		_ = heldBytes

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
		telemetry.RecordScheduleAttempt(false)
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

	scores := ScoreWithTier(s.Cache, validNodes, reqBytes, bestEffort)
	if len(scores) == 0 {
		return "", fmt.Errorf("scoring returned 0 candidates despite passing filter — cache inconsistency")
	}

	winningNode := scores[0].NodeName

	tx, err := s.Reserver.Reserve(sliceUID, winningNode, reqBytes)
	if err != nil {
		telemetry.RecordScheduleAttempt(false)
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
		if err := s.K8sClient.Get(ctx, nn, &slice); err == nil {
			res, reason, gerr := s.GangGate.CheckSliceWithCohort(ctx, &slice, winningNode, reqBytes)
			if gerr != nil {
				log.Printf("[gang] gate error for %s: %v", nn, gerr)
			}
			switch res {
			case GangBindDeferred:
				telemetry.RecordScheduleAttempt(false)
				// Hold the speculative cache reservation across function
				// return. Subsequent reconcile cycles will fast-forward
				// past Reserve and re-enter the gate; eventually the
				// cohort tips quorum and this slice's next call gets
				// GangBindAllowed.
				tx.MarkHeld()
				log.Printf("[gang] %s deferred: %s (HOLDING reservation)", nn, reason)
				return "", &GangDeferredError{Reason: reason}
			case GangBindRejected:
				telemetry.RecordScheduleAttempt(false)
				log.Printf("[gang] %s rejected: %s", nn, reason)
				return "", fmt.Errorf("gang reservation rejected bind: %s", reason)
			case GangBindAllowed:
				log.Printf("[gang] %s allowed: %s", nn, reason)
			case GangNotApplicable:
				// proceed to bind
			}
		}
	}

	if err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {
		telemetry.RecordScheduleAttempt(false)
		return "", fmt.Errorf("bind to Kubernetes API failed: %w", err)
	}

	tx.Confirm()
	telemetry.RecordScheduleAttempt(true)
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
	if err := s.K8sClient.Status().Patch(ctx, &target, statusBase); err != nil {
		return fmt.Errorf("patching status.phase to Scheduled: %w", err)
	}

	return nil
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
	}
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
