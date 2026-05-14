package scheduler

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// GangCheckResult: gate decisions.
type GangCheckResult int

const (
	GangNotApplicable GangCheckResult = iota // slice has no gang annotation
	GangBindAllowed                          // gang quorum reached, this slice may bind
	GangBindDeferred                         // waiting for siblings; reservation HELD
	GangBindRejected                         // reservation in terminal phase (Failed/Released)
)

// gangMember represents a single slice's "I'm here, holding my reservation"
// registration in the gate. The gate tracks one entry per (gang, sliceUID).
type gangMember struct {
	sliceUID string
	nodeName string
	bytes    int64
	heldAt   time.Time
}

// gangCohort tracks a single gang's members across reconcile cycles. Once
// all gangSize members are present, cohort transitions to "released" — the
// next gate-check for any sibling returns Allowed.
type gangCohort struct {
	gangSize  int32
	members   map[string]gangMember // sliceUID -> registration
	released  bool                  // true once quorum reached; sticky
	createdAt time.Time
}

// GangBindingGate decides whether a slice may bind based on whether enough
// of its sibling gang members are also "ready to bind" (i.e. holding cache
// reservations). The gate's state is in-memory and per-scheduler-instance.
//
// Hold-the-reservation design:
//
//  1. When a slice arrives at the gate:
//     - If gang cohort doesn't exist, create it.
//     - Register self as a member (record sliceUID, node, bytes).
//     - If members count < gangSize: return Deferred. The CALLER is expected
//     to NOT release the cache reservation (Schedule() calls tx.Confirm()
//     on Deferred so the speculative lock is held).
//     - If members count >= gangSize: mark cohort released, return Allowed.
//
//  2. Subsequent reconciles for sibling slices observe cohort.released=true
//     and return Allowed immediately (their reservation may still need to be
//     created or refreshed, but the gate doesn't gate them).
//
//  3. Cleanup: stale cohorts (members heldAt older than maxHoldAge) are
//     reaped. This catches the case where a gang's reservation transitions
//     to Failed but the gate state isn't notified.
//
// CRITICAL CORRECTNESS INVARIANTS:
//
//   - The gate is consulted AFTER cache.AssumeSlice succeeds. So when the
//     gate registers a member, that member's bytes ARE held in the cache.
//
//   - When cohort tips to released, it stays released. Subsequent siblings
//     can bind without re-checking quorum.
//
//   - The gate DOES NOT release cache reservations directly. That's the
//     scheduler's job (via tx.Rollback or the cache's TTL reaper).
//
//   - The reservation reconciler in the controller continues to drive the
//     CRD-side state machine (Reserving → Reserved → Committed). The gate
//     uses the CRD only for terminal-phase rejection (Failed/Released).
type GangBindingGate struct {
	client client.Client

	mu      sync.Mutex
	cohorts map[string]*gangCohort // key: namespace/reservationName
}

// NewGangBindingGate constructs a gate with an empty cohort map.
func NewGangBindingGate(c client.Client) *GangBindingGate {
	return &GangBindingGate{
		client:  c,
		cohorts: make(map[string]*gangCohort),
	}
}

// gateMaxHoldAge bounds how long a cohort can sit half-formed before the
// gate gives up and forgets its members. Should be longer than the slice
// reservation TTL but shorter than the gang reservation deadline.
const gateMaxHoldAge = 90 * time.Second

// CheckSliceWithCohort answers whether bind is permitted for this slice,
// updating the gate's per-gang readiness state in the process.
//
// nodeName and bytes describe the speculative reservation the slice already
// holds in the cache (via AssumeSlice). The gate records them so that on
// reaping or rejection it can release the right capacity.
func (g *GangBindingGate) CheckSliceWithCohort(
	ctx context.Context,
	slice *vgpuv1alpha1.VGPUSlice,
	nodeName string,
	bytes int64,
) (GangCheckResult, string, error) {
	if slice == nil || slice.Annotations == nil {
		return GangNotApplicable, "no annotations", nil
	}
	rsvName, ok := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]
	if !ok || rsvName == "" {
		return GangNotApplicable, "no reservation annotation", nil
	}

	// Look up the reservation CRD only to (a) get gangSize and (b) catch
	// terminal phases that should reject this slice.
	var rsv vgpuv1alpha1.VGPUGangReservation
	err := g.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: rsvName}, &rsv)
	if errors.IsNotFound(err) {
		return GangBindRejected,
			fmt.Sprintf("reservation %s not found (gang torn down)", rsvName),
			nil
	}
	if err != nil {
		// Cache not synced or transient failure. Don't make a decision; ask
		// caller to retry without making cohort changes.
		return GangNotApplicable, "", fmt.Errorf("getting reservation: %w", err)
	}

	switch rsv.Status.Phase {
	case vgpuv1alpha1.ReservationPhaseFailed,
		vgpuv1alpha1.ReservationPhaseReleased:
		// Terminal. Forget any cohort state for this gang and reject.
		g.forgetCohort(slice.Namespace + "/" + rsvName)
		return GangBindRejected,
			fmt.Sprintf("reservation %s in terminal phase %s", rsvName, rsv.Status.Phase),
			nil
	}

	gangSize := rsv.Spec.GangSize
	if gangSize <= 0 {
		return GangNotApplicable,
			fmt.Sprintf("invalid gangSize %d", gangSize),
			nil
	}

	cohortKey := slice.Namespace + "/" + rsvName

	g.mu.Lock()
	defer g.mu.Unlock()

	// Reap stale cohorts proactively (cheap; runs on every gate call).
	g.reapStaleCohortsLocked(time.Now())

	cohort, exists := g.cohorts[cohortKey]
	if !exists {
		cohort = &gangCohort{
			gangSize:  gangSize,
			members:   make(map[string]gangMember, gangSize),
			createdAt: time.Now(),
		}
		g.cohorts[cohortKey] = cohort
	}

	// If the cohort is already released, this slice may bind regardless of
	// whether it's been seen before. Tip from previous reconciles already
	// committed the cohort.
	if cohort.released {
		return GangBindAllowed,
			fmt.Sprintf("gang %s cohort released (siblings ready)", rsvName),
			nil
	}

	// Register or refresh this slice's membership.
	cohort.members[string(slice.UID)] = gangMember{
		sliceUID: string(slice.UID),
		nodeName: nodeName,
		bytes:    bytes,
		heldAt:   time.Now(),
	}

	if int32(len(cohort.members)) >= gangSize {
		// Quorum! Tip the cohort. From now on, every sibling gets Allowed.
		cohort.released = true
		log.Printf("[gang] cohort %s reached quorum (%d/%d) — releasing for bind",
			cohortKey, len(cohort.members), gangSize)
		return GangBindAllowed,
			fmt.Sprintf("gang %s quorum reached (%d/%d)", rsvName, len(cohort.members), gangSize),
			nil
	}

	// Not yet quorum. Slice's reservation should be HELD by the caller.
	return GangBindDeferred,
		fmt.Sprintf("gang %s holding %d/%d members", rsvName, len(cohort.members), gangSize),
		nil
}

// forgetCohort removes the gate's state for a gang. Used when the gang's
// reservation reaches a terminal phase. Held reservations from members will
// be released by the cache TTL reaper or by the slice reconciler advancing
// the slice into Failed phase.
func (g *GangBindingGate) forgetCohort(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.cohorts, key)
}

// reapStaleCohortsLocked removes cohorts whose oldest member registration is
// older than gateMaxHoldAge AND haven't reached quorum. Released cohorts are
// kept indefinitely (until the controller transitions the reservation to
// terminal and forgetCohort() runs). Caller must hold g.mu.
func (g *GangBindingGate) reapStaleCohortsLocked(now time.Time) {
	for key, cohort := range g.cohorts {
		if cohort.released {
			continue
		}
		if now.Sub(cohort.createdAt) > gateMaxHoldAge {
			log.Printf("[gang] reaping stale cohort %s (members=%d/%d, age=%v)",
				key, len(cohort.members), cohort.gangSize, now.Sub(cohort.createdAt))
			delete(g.cohorts, key)
		}
	}
}

// CheckSlice is the legacy entry point (no node/bytes) — preserved for any
// non-Schedule caller. Routes through CheckSliceWithCohort with empty node
// info so the cohort tracks membership but can't release capacity itself.
func (g *GangBindingGate) CheckSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) (GangCheckResult, string, error) {
	return g.CheckSliceWithCohort(ctx, slice, "", 0)
}
