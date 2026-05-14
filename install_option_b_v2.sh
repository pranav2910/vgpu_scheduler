#!/usr/bin/env bash
# ============================================================================
# install_option_b_v2.sh — self-contained install of the hold-the-reservation
# gang gate. No external file dependencies; the four file contents are
# embedded as heredocs.
#
# Fixes the v1 script's bug where staging files in the repo root collided
# with `go build ./...` and triggered the auto-restore.
# ============================================================================

set -euo pipefail

C_FILE="internal/scheduler/cache.go"
R_FILE="internal/scheduler/reserve.go"
G_FILE="internal/scheduler/gang.go"
P_FILE="internal/scheduler/plugin.go"

if [[ ! -f "$C_FILE" || ! -f "$R_FILE" || ! -f "$G_FILE" || ! -f "$P_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "Option B (hold-the-reservation)" "$P_FILE" 2>/dev/null; then
    echo "✓ Option B already installed."
    exit 0
fi

TS=$(date +%s)
cp "$C_FILE" "${C_FILE}.bak.${TS}"
cp "$R_FILE" "${R_FILE}.bak.${TS}"
cp "$G_FILE" "${G_FILE}.bak.${TS}"
cp "$P_FILE" "${P_FILE}.bak.${TS}"
echo "Backups: *.bak.${TS}"

restore() {
    cp "${C_FILE}.bak.${TS}" "$C_FILE"
    cp "${R_FILE}.bak.${TS}" "$R_FILE"
    cp "${G_FILE}.bak.${TS}" "$G_FILE"
    cp "${P_FILE}.bak.${TS}" "$P_FILE"
}
trap 'restore; echo "ABORTED — files restored"' ERR

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — patch cache.go (append IsAssumed + RefreshAssumption)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[1/5] Patching cache.go..."
python3 - "$C_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
addition = '''

// IsAssumed reports whether sliceUID has a held speculative reservation.
// Returns the held node and bytes for callers that want to rebuild a Tx.
// Option B (hold-the-reservation gang gate).
func (c *VRAMCache) IsAssumed(sliceUID string) (string, int64, bool) {
\tc.mu.RLock()
\tdefer c.mu.RUnlock()
\tif a, ok := c.assumedBySlice[sliceUID]; ok {
\t\treturn a.NodeName, a.RequestedVRAMBytes, true
\t}
\treturn "", 0, false
}

// RefreshAssumption extends ExpiresAt for an existing held reservation.
// Returns true if the slice was actually held (and refreshed), false if no
// held reservation exists. Option B (hold-the-reservation gang gate).
func (c *VRAMCache) RefreshAssumption(sliceUID string, ttl time.Duration) bool {
\tc.mu.Lock()
\tdefer c.mu.Unlock()
\tif a, ok := c.assumedBySlice[sliceUID]; ok {
\t\ta.ExpiresAt = time.Now().Add(ttl)
\t\treturn true
\t}
\treturn false
}
'''
src = src.rstrip() + addition + "\n"
p.write_text(src)
PYEOF
echo "  ~ $C_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — write reserve.go
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[2/5] Writing reserve.go..."
cat > "$R_FILE" <<'RESERVE_EOF'
package scheduler

import (
	"log"
	"sync/atomic"
	"time"
)

type ReservationManager struct {
	cache *VRAMCache
	ttl   time.Duration
}

// ReservationTx is a two-phase commit handle for a speculative reservation.
// Bug #33: confirmed is atomic.Bool so defer + panic on another goroutine is
// memory-safe.
//
// Option B addition: `held` atomic.Bool for the hold-the-reservation gang
// gate. When the gate defers a slice, it calls MarkHeld() to keep the
// speculative cache lock alive past the function return. The cache's TTL
// reaper will eventually free a hold that doesn't converge into a bind.
type ReservationTx struct {
	SliceUID  string
	NodeName  string
	cache     *VRAMCache
	confirmed atomic.Bool
	held      atomic.Bool
}

func NewReservationManager(cache *VRAMCache, ttl time.Duration) *ReservationManager {
	return &ReservationManager{cache: cache, ttl: ttl}
}

func (rm *ReservationManager) Reserve(sliceUID, nodeName string, bytes int64) (*ReservationTx, error) {
	if err := rm.cache.AssumeSlice(sliceUID, nodeName, bytes, rm.ttl); err != nil {
		return nil, err
	}
	return &ReservationTx{SliceUID: sliceUID, NodeName: nodeName, cache: rm.cache}, nil
}

// NewReservationTxForHeld constructs a Tx wrapping an already-existing
// assumedBySlice entry. Used by Schedule()'s fast-forward path when a
// gang member's reservation persists across reconcile cycles.
func NewReservationTxForHeld(cache *VRAMCache, sliceUID, nodeName string) *ReservationTx {
	return &ReservationTx{SliceUID: sliceUID, NodeName: nodeName, cache: cache}
}

func (tx *ReservationTx) Confirm() {
	tx.confirmed.Store(true)
	tx.cache.ConfirmSlice(tx.SliceUID)
	log.Printf("Reservation Confirmed: Slice %s locked in API", tx.SliceUID)
}

// MarkHeld signals that the cache assumption should outlive this Tx's
// scope. Used by the gang gate's Deferred path: the slice stays in
// assumedBySlice across reconcile cycles, refreshed by gate calls, until
// the gang either tips quorum (next call: Confirm + bind) or the TTL
// reaper reclaims it.
func (tx *ReservationTx) MarkHeld() {
	tx.held.Store(true)
}

func (tx *ReservationTx) RollbackIfNotConfirmed() {
	if tx.confirmed.Load() || tx.held.Load() {
		return
	}
	log.Printf("Reservation Rollback: Slice %s dropping speculative lock", tx.SliceUID)
	tx.cache.RollbackAssumedSlice(tx.SliceUID)
}
RESERVE_EOF
echo "  ~ $R_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — write gang.go
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[3/5] Writing gang.go..."
cat > "$G_FILE" <<'GANG_EOF'
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
	gangSize int32
	members  map[string]gangMember // sliceUID -> registration
	released bool                  // true once quorum reached; sticky
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
//       to NOT release the cache reservation (Schedule() calls tx.Confirm()
//       on Deferred so the speculative lock is held).
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
GANG_EOF
echo "  ~ $G_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — write plugin.go
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[4/5] Writing plugin.go..."
cat > "$P_FILE" <<'PLUGIN_EOF'
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
//              The deferred RollbackIfNotConfirmed becomes a no-op.
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
PLUGIN_EOF
echo "  ~ $P_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — gofmt + go build
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[5/5] Running gofmt + go build..."
gofmt -w "$C_FILE" "$R_FILE" "$G_FILE" "$P_FILE" 2>/dev/null || true

trap - ERR
if go build ./...; then
    echo "  ✓ go build clean"
else
    echo "  ✗ go build FAILED — restoring"
    restore
    exit 1
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "✅ Option B installed."
echo "════════════════════════════════════════════════════════════"
echo
echo "Verify with:"
echo "  grep -c 'IsAssumed\\|MarkHeld\\|gangCohort\\|gateAndBind' \\"
echo "    $C_FILE $R_FILE $G_FILE $P_FILE"
echo "  (expect non-zero in all four files)"
echo
echo "Then deploy:"
echo "  make docker-build"
echo "  kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  kind load docker-image vgpu-scheduler:latest  --name vgpu-test"
echo "  kubectl rollout restart deployment/vgpu-controller deployment/vgpu-scheduler -n vgpu-system"
echo "  kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo "  kubectl rollout status deployment/vgpu-scheduler  -n vgpu-system --timeout=120s"
echo
echo "Then test:"
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  sleep 5"
echo "  bash real_world_test.sh"
