package scheduler

import (
	"context"
	"fmt"
	"log"
	"strconv"
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
	GangBindDeferred                         // admitted gang, sub-quorum; reservation HELD
	GangBindRejected                         // reservation in terminal phase (Failed/Released)
	GangBindWait                             // another gang holds the admission slot; do NOT hold — release the reservation and retry
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
	priority  int32                 // gang scheduling priority; higher admits first
	members   map[string]gangMember // sliceUID -> registration
	released  bool                  // true once quorum reached; sticky
	createdAt time.Time             // first time the gate observed this gang (≈ age)
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
//
// SERIALIZED ADMISSION (liveness fix):
//
//	The naive cohort gate let every contending gang hold capacity concurrently.
//	Under contention that fragments capacity: N gangs each park a sub-quorum of
//	slices, none reaches quorum, and the cluster under-packs even though some
//	subset of gangs would fit if admitted one at a time. The gate is "safe" (no
//	over-admission) but not "live".
//
//	The fix gives the gate a single admission slot. Only the gang holding the
//	slot (the "admitting" gang) may hold cache reservations; its siblings get
//	Deferred (hold). Every other contending gang gets GangBindWait — the caller
//	releases that slice's reservation, so non-admitted gangs hold ZERO capacity
//	and cannot fragment it. When the slot is free it is claimed by the head of
//	the contending set, ordered priority desc → age asc → name asc. Admission is
//	sticky: once a gang holds the slot it keeps it until it reaches quorum
//	(commit, slot frees) or stalls past gangAdmissionTimeout (backoff, slot
//	frees) so an impossible gang cannot starve the rest.
type GangBindingGate struct {
	client client.Client

	mu      sync.Mutex
	cohorts map[string]*gangCohort // key: namespace/reservationName

	// Single admission slot. admitting is the cohort key currently allowed to
	// hold capacity ("" = slot free). backoff maps a cohort key to the time
	// until which it is skipped for slot selection (set when a gang stalls).
	admitting      string
	admittingSince time.Time
	backoff        map[string]time.Time
}

// NewGangBindingGate constructs a gate with an empty cohort map.
func NewGangBindingGate(c client.Client) *GangBindingGate {
	return &GangBindingGate{
		client:  c,
		cohorts: make(map[string]*gangCohort),
		backoff: make(map[string]time.Time),
	}
}

// gateMaxHoldAge bounds how long a cohort can sit half-formed before the
// gate gives up and forgets its members. Should be longer than the slice
// reservation TTL but shorter than the gang reservation deadline.
const gateMaxHoldAge = 90 * time.Second

// gangAdmissionTimeout bounds how long the admitting gang may hold the slot
// without reaching quorum. Past this, the gate assumes the gang cannot
// assemble (e.g. it needs more capacity than is free), backs it off, and frees
// the slot for the next contender. Must be shorter than the gang reservation
// deadline so the slot recycles several times before a gang's reservation
// fails outright.
const gangAdmissionTimeout = 20 * time.Second

// gangAdmissionBackoff is how long a stalled gang is skipped for slot
// selection after it loses the slot, giving other contenders a clear run.
// After it elapses the gang is eligible again — so a genuinely-impossible gang
// cycles (claim → stall → backoff) rather than failing fast, but it never
// blocks others for more than gangAdmissionTimeout at a time.
const gangAdmissionBackoff = 15 * time.Second

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

	// Priority rides the slice as a propagated annotation (see
	// AnnotationGangPriority). Missing/garbled → priority 0 (lowest), so older
	// gangs still admit first by the age tiebreaker.
	priority := int32(0)
	if ps := slice.Annotations[vgpuv1alpha1.AnnotationGangPriority]; ps != "" {
		if p, perr := strconv.Atoi(ps); perr == nil {
			priority = int32(p)
		}
	}

	g.mu.Lock()
	defer g.mu.Unlock()

	// Reap stale cohorts proactively (cheap; runs on every gate call).
	g.reapStaleCohortsLocked(time.Now())

	now := time.Now()

	cohort, exists := g.cohorts[cohortKey]
	if !exists {
		cohort = &gangCohort{
			gangSize:  gangSize,
			priority:  priority,
			members:   make(map[string]gangMember, gangSize),
			createdAt: now,
		}
		g.cohorts[cohortKey] = cohort
	} else {
		cohort.priority = priority // keep fresh; cheap and tolerant of spec edits
	}

	// If the cohort is already released, this slice may bind regardless of
	// whether it's been seen before. Tip from previous reconciles already
	// committed the cohort.
	if cohort.released {
		return GangBindAllowed,
			fmt.Sprintf("gang %s cohort released (siblings ready)", rsvName),
			nil
	}

	// ── Serialized admission ──────────────────────────────────────────────
	// Free the slot if the current holder has stalled past the timeout, then
	// (if free) hand it to the head of the contending set. Only the gang
	// holding the slot may keep capacity; everyone else is told to release.
	if g.admitting != "" && now.Sub(g.admittingSince) > gangAdmissionTimeout {
		log.Printf("[gang] admitting gang %s stalled (%v without quorum) — backing off, freeing slot",
			g.admitting, now.Sub(g.admittingSince).Round(time.Second))
		g.backoff[g.admitting] = now.Add(gangAdmissionBackoff)
		g.releaseHoldsLocked(g.admitting)
		g.admitting = ""
	}
	if g.admitting == "" {
		if head := g.pickAdmissionHeadLocked(now); head != "" {
			g.admitting = head
			g.admittingSince = now
		}
	}

	if g.admitting != cohortKey {
		// Another gang owns the admission slot (or no slot could be claimed for
		// us this round). Do NOT hold capacity — the caller releases this
		// slice's reservation so non-admitted gangs never fragment capacity.
		// Drop any prior membership we may have recorded while admitted.
		delete(cohort.members, string(slice.UID))
		reason := "no gang eligible for admission"
		if g.admitting != "" {
			reason = fmt.Sprintf("gang %s admitting first", g.admitting)
		}
		return GangBindWait,
			fmt.Sprintf("gang %s waiting for admission slot (%s)", rsvName, reason),
			nil
	}

	// We hold the admission slot. Register or refresh this slice's membership.
	cohort.members[string(slice.UID)] = gangMember{
		sliceUID: string(slice.UID),
		nodeName: nodeName,
		bytes:    bytes,
		heldAt:   now,
	}

	if int32(len(cohort.members)) >= gangSize {
		// Quorum! Tip the cohort and free the admission slot for the next gang.
		cohort.released = true
		g.admitting = ""
		delete(g.backoff, cohortKey)
		log.Printf("[gang] cohort %s reached quorum (%d/%d) — releasing for bind, freeing admission slot",
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

// pickAdmissionHeadLocked returns the cohort key that should claim the free
// admission slot, ordered priority desc → age asc → name asc. Released cohorts
// and cohorts in active backoff are skipped. Returns "" if none are eligible.
// Caller must hold g.mu.
func (g *GangBindingGate) pickAdmissionHeadLocked(now time.Time) string {
	best := ""
	var bestCohort *gangCohort
	for key, cohort := range g.cohorts {
		if cohort.released {
			continue
		}
		if until, backed := g.backoff[key]; backed {
			if now.Before(until) {
				continue
			}
			delete(g.backoff, key) // backoff elapsed; eligible again
		}
		if bestCohort == nil || admissionLess(cohort, key, bestCohort, best) {
			best, bestCohort = key, cohort
		}
	}
	return best
}

// admissionLess reports whether cohort a (keyed aKey) outranks cohort b (keyed
// bKey) for admission: higher priority first, then older (earlier createdAt),
// then lexicographically smaller key as a stable tiebreaker.
func admissionLess(a *gangCohort, aKey string, b *gangCohort, bKey string) bool {
	if a.priority != b.priority {
		return a.priority > b.priority
	}
	if !a.createdAt.Equal(b.createdAt) {
		return a.createdAt.Before(b.createdAt)
	}
	return aKey < bKey
}

// releaseHoldsLocked forgets the membership of a gang that lost the admission
// slot so its slots no longer count toward quorum. The cache reservations the
// members held are released by the caller's rollback path (GangBindWait) and
// the cache TTL reaper. Caller must hold g.mu.
func (g *GangBindingGate) releaseHoldsLocked(key string) {
	if cohort, ok := g.cohorts[key]; ok && !cohort.released {
		cohort.members = make(map[string]gangMember, cohort.gangSize)
	}
}

// forgetCohort removes the gate's state for a gang. Used when the gang's
// reservation reaches a terminal phase. Held reservations from members will
// be released by the cache TTL reaper or by the slice reconciler advancing
// the slice into Failed phase.
func (g *GangBindingGate) forgetCohort(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.cohorts, key)
	delete(g.backoff, key)
	if g.admitting == key {
		g.admitting = "" // free the slot so the next gang can be admitted
	}
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
			delete(g.backoff, key)
			if g.admitting == key {
				g.admitting = "" // freed a stale holder; let the next gang in
			}
		}
	}
}

// CheckSlice is the legacy entry point (no node/bytes) — preserved for any
// non-Schedule caller. Routes through CheckSliceWithCohort with empty node
// info so the cohort tracks membership but can't release capacity itself.
func (g *GangBindingGate) CheckSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) (GangCheckResult, string, error) {
	return g.CheckSliceWithCohort(ctx, slice, "", 0)
}
