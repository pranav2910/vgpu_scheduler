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
	Cache     *VRAMCache
	Reserver  *ReservationManager
	K8sClient client.Client
}

func NewSliceScheduler(cache *VRAMCache, k8sClient client.Client) *SliceScheduler {
	return &SliceScheduler{
		Cache:     cache,
		Reserver:  NewReservationManager(cache, 30*time.Second),
		K8sClient: k8sClient,
	}
}

// Schedule runs one full scheduling cycle for a Pending VGPUSlice.
// nn is the NamespacedName of the slice (for the direct Get in bindToKubernetesAPI).
// sliceUID is the K8s UID (reservation key in the cache).
// Bug #5 fix.
func (s *SliceScheduler) Schedule(ctx context.Context, nn types.NamespacedName, sliceUID string, reqBytes int64, bestEffort bool) (string, error) {
	log.Printf("Scheduling cycle started for Slice %s (req: %d bytes)", nn, reqBytes)

	// Layer 2 Phase 2.2a: enforce VGPUQuota before searching for nodes.
	// "no quota = unlimited" — Check returns allowed=true when no quota matches.
	if s.QuotaChecker != nil {
		if ok, reason, msg := s.QuotaChecker.Check(ctx, nn.Namespace, reqBytes); !ok {
			log.Printf("Scheduling rejected for Slice %s by quota: %s — %s",
				nn, reason, msg)
			return "", &SchedulingError{Reason: reason, Message: msg}
		}
	}

	var validNodes []string
	for _, node := range s.Cache.ListNodes() {
		fits, _, _ := s.Cache.CanFit(node, reqBytes)
		if fits {
			validNodes = append(validNodes, node)
		}
	}

	if len(validNodes) == 0 {
		telemetry.RecordScheduleAttempt(false)
		// Layer 2 Phase 2.3: try preemption before declaring capacity failure.
		if s.Preemptor != nil {
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
		// Idempotent — only adds bytes the FIRST time we observe Ready for this sliceUID.
		// Without this guard, every reconcile event leaks allocatedBytes into the cache.
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
