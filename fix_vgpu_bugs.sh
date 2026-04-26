#!/usr/bin/env bash
# =============================================================================
# vGPU Scheduler — comprehensive bug-fix script
#
# Applies fixes for all bugs identified in the code review:
#   Bug A  — VGPUSlice default phase was "Allocating" (scheduler skipped everything)
#   Bug B  — PromoteConfirmedToAllocated / ReleaseAllocated were dead code
#   Bug C  — CDI firewall was never generated or torn down
#   Bug D  — seedCacheFromNodes ran before mgr.Start() (informer cache unsynced)
#   Bug E  — allocatedVRAMOnNode naming/comments were misleading
#   Bug F  — Scheduling failures were swallowed with no requeue
#   Bug #1 — Reporter never wrote to Kubernetes
#   Bug #2 — UpdateNode zeroed ReservedVRAMBytes, wiping speculative locks
#   Bug #3 — Assumed allocation TTLs were never reaped
#   Bug #4 — checkpoint.Save silently discarded corrupt files
#   Bug #5 — bindToKubernetesAPI did a cluster-wide list on every bind
#   Bug #6 — handleDelete returned a sentinel error to force requeue
#   Bug #7 — OwnerReference missing Controller + BlockOwnerDeletion
#   Bug #8 — Releasing invariant fired on pre-allocation deletes
#   Bug #9 — Score reached into cache internals bypassing the abstraction
#   Bug #10 — AssumeSlice did not recheck node health under the write lock
#   Bug #11 — req.SliceUID[:8] panicked on short UIDs
#   Bug #12 — fragmentPenalty was a negative constant (magnitude confusion)
#   Bug #13 — Drift detector swallowed errors with `_ =`
#   Bug #14 — MutatePod injected claimName instead of AllocationID
#
# Usage:   ./fix_vgpu_bugs.sh           # run from the project root (where go.mod is)
# Safety:  creates .bug_fix_backup_<timestamp> before touching anything.
# Requires: bash, sed, mkdir, cp, date, go (for the final `go build ./...` check).
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$ROOT/go.mod" ]]; then
    echo "ERROR: must be run from project root (go.mod not found at $ROOT)"
    echo "Place this script in the vgpu-scheduler/ directory and re-run."
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$ROOT/.bug_fix_backup_${STAMP}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  vGPU Scheduler — applying all bug fixes                 ║"
echo "║  Backup: .bug_fix_backup_${STAMP}                    ║"
echo "╚══════════════════════════════════════════════════════════╝"

backup() {
    local src="$1"
    local dst="$BACKUP/$(dirname "$src")"
    mkdir -p "$dst"
    [[ -f "$ROOT/$src" ]] && cp -p "$ROOT/$src" "$dst/$(basename "$src")" || true
}

for f in \
    api/v1alpha1/vgpuslice_types.go \
    internal/scheduler/cache.go \
    internal/scheduler/score.go \
    internal/scheduler/plugin.go \
    internal/scheduler/reserve.go \
    internal/controller/vgpuclaim_reconciler.go \
    internal/controller/vgpuslice_reconciler.go \
    internal/nodeagent/reporter.go \
    internal/nodeagent/manager.go \
    internal/nodeagent/nvml/allocator.go \
    internal/nodeagent/checkpoint/checkpoint.go \
    internal/nodeagent/drift/detector.go \
    internal/state/invariants.go \
    internal/webhook/mutating_pod.go \
    cmd/scheduler/main.go
do
    backup "$f"
done
echo "✓ backup written to $BACKUP"
echo ""

# =============================================================================
# Bug A — api/v1alpha1/vgpuslice_types.go
# Change default phase from Allocating to Pending so the scheduler actually sees
# new slices.
# =============================================================================
sed -i 's|// +kubebuilder:default=Allocating|// +kubebuilder:default=Pending|' \
    "$ROOT/api/v1alpha1/vgpuslice_types.go"
echo "✓ Bug A  — VGPUSlice default phase: Allocating → Pending"

# =============================================================================
# Bugs #2, #3, #10, #9 (partial) — internal/scheduler/cache.go
# - Preserve ReservedVRAMBytes in UpdateNode
# - Add StartTTLReaper + reapExpiredAssumptions
# - Re-check node.Healthy in AssumeSlice
# - Add SnapshotAllNodes for Bug #9 (used by score.go)
# - Add SetNodeHealth helper
# =============================================================================
cat > "$ROOT/internal/scheduler/cache.go" <<'GOEOF'
package scheduler

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"
)

// Canonical Rejection Reasons
const (
	ReasonNodeNotFound     = "NODE_NOT_FOUND"
	ReasonNodeUnhealthy    = "NODE_UNHEALTHY"
	ReasonInsufficientVRAM = "INSUFFICIENT_VRAM"
)

type VRAMCache struct {
	mu               sync.RWMutex
	nodes            map[string]*NodeState
	assumedBySlice   map[string]*AssumedAllocation
	confirmedBySlice map[string]*AssumedAllocation
}

type NodeState struct {
	NodeName           string
	TotalVRAMBytes     int64
	AllocatedVRAMBytes int64
	ReservedVRAMBytes  int64
	FreeVRAMBytes      int64
	Healthy            bool
}

type AssumedAllocation struct {
	SliceUID           string
	NodeName           string
	RequestedVRAMBytes int64
	ExpiresAt          time.Time
}

func NewVRAMCache() *VRAMCache {
	return &VRAMCache{
		nodes:            make(map[string]*NodeState),
		assumedBySlice:   make(map[string]*AssumedAllocation),
		confirmedBySlice: make(map[string]*AssumedAllocation),
	}
}

// StartTTLReaper launches a goroutine that rolls back speculative reservations
// whose TTL has elapsed. Without this, a failed scheduling attempt (pre-bind
// crash, lost defer, etc.) would permanently leak reserved VRAM.
// Bug #3 fix.
func (c *VRAMCache) StartTTLReaper(ctx context.Context, interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				c.reapExpiredAssumptions()
			case <-ctx.Done():
				return
			}
		}
	}()
}

func (c *VRAMCache) reapExpiredAssumptions() {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	for sliceUID, alloc := range c.assumedBySlice {
		if now.After(alloc.ExpiresAt) {
			if node, ok := c.nodes[alloc.NodeName]; ok {
				node.ReservedVRAMBytes -= alloc.RequestedVRAMBytes
				if node.ReservedVRAMBytes < 0 {
					node.ReservedVRAMBytes = 0
				}
				c.recalculateFreeVRAM(node)
			}
			delete(c.assumedBySlice, sliceUID)
			log.Printf("TTL reaper: rolled back expired assumption for slice %s", sliceUID)
		}
	}
}

func (c *VRAMCache) recalculateFreeVRAM(node *NodeState) {
	node.FreeVRAMBytes = node.TotalVRAMBytes - node.AllocatedVRAMBytes - node.ReservedVRAMBytes
	if node.FreeVRAMBytes < 0 {
		node.FreeVRAMBytes = 0
	}
}

func (c *VRAMCache) ListNodes() []string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	list := make([]string, 0, len(c.nodes))
	for name := range c.nodes {
		list = append(list, name)
	}
	return list
}

func (c *VRAMCache) CanFit(nodeName string, requestedBytes int64) (bool, string, string) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	node, exists := c.nodes[nodeName]
	if !exists {
		return false, ReasonNodeNotFound, "Node does not exist in cache"
	}
	if !node.Healthy {
		return false, ReasonNodeUnhealthy, "Node marked offline"
	}
	if node.FreeVRAMBytes < requestedBytes {
		return false, ReasonInsufficientVRAM, fmt.Sprintf("req=%d, free=%d", requestedBytes, node.FreeVRAMBytes)
	}
	return true, "", ""
}

// AssumeSlice speculatively reserves VRAM. Re-checks node health and capacity
// under the write lock to close the TOCTOU window with CanFit. Bug #10 fix.
func (c *VRAMCache) AssumeSlice(sliceUID, nodeName string, requestedBytes int64, ttl time.Duration) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if _, exists := c.assumedBySlice[sliceUID]; exists {
		return fmt.Errorf("duplicate: slice %s already assumed", sliceUID)
	}
	if _, exists := c.confirmedBySlice[sliceUID]; exists {
		return fmt.Errorf("duplicate: slice %s already confirmed", sliceUID)
	}

	node, exists := c.nodes[nodeName]
	if !exists {
		return fmt.Errorf("race condition: node %s not found", nodeName)
	}
	if !node.Healthy {
		return fmt.Errorf("race condition: node %s is unhealthy", nodeName)
	}
	if node.FreeVRAMBytes < requestedBytes {
		return fmt.Errorf("race condition: node %s lacks capacity (req=%d, free=%d)",
			nodeName, requestedBytes, node.FreeVRAMBytes)
	}

	c.assumedBySlice[sliceUID] = &AssumedAllocation{
		SliceUID:           sliceUID,
		NodeName:           nodeName,
		RequestedVRAMBytes: requestedBytes,
		ExpiresAt:          time.Now().Add(ttl),
	}

	node.ReservedVRAMBytes += requestedBytes
	c.recalculateFreeVRAM(node)
	return nil
}

func (c *VRAMCache) ConfirmSlice(sliceUID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if assumption, exists := c.assumedBySlice[sliceUID]; exists {
		c.confirmedBySlice[sliceUID] = assumption
		delete(c.assumedBySlice, sliceUID)
	}
}

func (c *VRAMCache) PromoteConfirmedToAllocated(sliceUID, nodeName string, actualBytes int64) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	node, exists := c.nodes[nodeName]
	if !exists {
		return fmt.Errorf("node %s not found for promotion", nodeName)
	}

	if assumption, exists := c.confirmedBySlice[sliceUID]; exists {
		node.ReservedVRAMBytes -= assumption.RequestedVRAMBytes
		if node.ReservedVRAMBytes < 0 {
			node.ReservedVRAMBytes = 0
		}
		node.AllocatedVRAMBytes += actualBytes
		delete(c.confirmedBySlice, sliceUID)
		c.recalculateFreeVRAM(node)
		return nil
	}
	// Best-effort path for scheduler restarts: the confirmation was lost but
	// the NodeAgent reported Ready anyway, so we reconcile by adding directly.
	node.AllocatedVRAMBytes += actualBytes
	c.recalculateFreeVRAM(node)
	return fmt.Errorf("slice %s not in confirmed state (applied direct allocation as fallback)", sliceUID)
}

func (c *VRAMCache) RollbackAssumedSlice(sliceUID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if assumption, exists := c.assumedBySlice[sliceUID]; exists {
		if node, ok := c.nodes[assumption.NodeName]; ok {
			node.ReservedVRAMBytes -= assumption.RequestedVRAMBytes
			if node.ReservedVRAMBytes < 0 {
				node.ReservedVRAMBytes = 0
			}
			c.recalculateFreeVRAM(node)
		}
		delete(c.assumedBySlice, sliceUID)
	}
}

func (c *VRAMCache) ReleaseConfirmedSlice(sliceUID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if assumption, exists := c.confirmedBySlice[sliceUID]; exists {
		if node, ok := c.nodes[assumption.NodeName]; ok {
			node.ReservedVRAMBytes -= assumption.RequestedVRAMBytes
			if node.ReservedVRAMBytes < 0 {
				node.ReservedVRAMBytes = 0
			}
			c.recalculateFreeVRAM(node)
		}
		delete(c.confirmedBySlice, sliceUID)
	}
}

func (c *VRAMCache) ReleaseAllocated(nodeName string, freedBytes int64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if node, exists := c.nodes[nodeName]; exists {
		node.AllocatedVRAMBytes -= freedBytes
		if node.AllocatedVRAMBytes < 0 {
			node.AllocatedVRAMBytes = 0
		}
		c.recalculateFreeVRAM(node)
	}
}

// UpdateNode sets a node's capacity and externally-reported allocation figure
// WITHOUT clobbering in-flight ReservedVRAMBytes. Bug #2 fix.
func (c *VRAMCache) UpdateNode(nodeName string, totalBytes, allocatedBytes int64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	node, exists := c.nodes[nodeName]
	if !exists {
		node = &NodeState{NodeName: nodeName, Healthy: true}
		c.nodes[nodeName] = node
	}
	node.TotalVRAMBytes = totalBytes
	node.AllocatedVRAMBytes = allocatedBytes
	// Do NOT touch ReservedVRAMBytes — it is managed by AssumeSlice /
	// RollbackAssumedSlice / PromoteConfirmedToAllocated and must survive node
	// watch events.
	c.recalculateFreeVRAM(node)
}

func (c *VRAMCache) UpdateNodeCapacity(nodeName string, totalGiB int64) {
	c.UpdateNode(nodeName, totalGiB*1024*1024*1024, 0)
}

// SetNodeHealth toggles a node's Healthy flag without disturbing VRAM accounting.
func (c *VRAMCache) SetNodeHealth(nodeName string, healthy bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if node, exists := c.nodes[nodeName]; exists {
		node.Healthy = healthy
	}
}

// NodeSnapshot is a point-in-time copy of a node's VRAM accounting.
type NodeSnapshot struct {
	NodeName           string
	TotalVRAMBytes     int64
	AllocatedVRAMBytes int64
	ReservedVRAMBytes  int64
	FreeVRAMBytes      int64
	Healthy            bool
}

func (c *VRAMCache) SnapshotNode(nodeName string) *NodeSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	node, exists := c.nodes[nodeName]
	if !exists {
		return nil
	}
	s := snapshotOf(node)
	return &s
}

// SnapshotAllNodes returns a consistent copy of every node's state, taken under
// one read lock. Callers can iterate without holding the lock. Bug #9 fix.
func (c *VRAMCache) SnapshotAllNodes() []NodeSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]NodeSnapshot, 0, len(c.nodes))
	for _, node := range c.nodes {
		out = append(out, snapshotOf(node))
	}
	return out
}

func snapshotOf(node *NodeState) NodeSnapshot {
	return NodeSnapshot{
		NodeName:           node.NodeName,
		TotalVRAMBytes:     node.TotalVRAMBytes,
		AllocatedVRAMBytes: node.AllocatedVRAMBytes,
		ReservedVRAMBytes:  node.ReservedVRAMBytes,
		FreeVRAMBytes:      node.FreeVRAMBytes,
		Healthy:            node.Healthy,
	}
}
GOEOF
echo "✓ Bug #2, #3, #9, #10 — scheduler/cache.go"

# =============================================================================
# Bugs #9, #12 — internal/scheduler/score.go
# - Use SnapshotAllNodes instead of poking cache internals
# - fragmentPenaltyBytes is a positive constant, negation is explicit at use site
# =============================================================================
cat > "$ROOT/internal/scheduler/score.go" <<'GOEOF'
package scheduler

import (
	"log"
	"sort"
)

const (
	// scoreWeightVRAMBytes is the reference VRAM used for bin-packing score normalisation (80 GiB).
	scoreWeightVRAMBytes = int64(80_000_000_000)
	// fragmentThresholdBytes is the minimum leftover considered "usable".
	fragmentThresholdBytes = int64(4_000_000_000)
	// fragmentPenaltyBytes is the magnitude of the penalty; the sign is applied
	// at the use site. Bug #12 fix.
	fragmentPenaltyBytes = int64(5_000_000_000)
)

type ScoreBreakdown struct {
	BinPackScore       int64
	FragmentationScore int64
	Total              int64
}

type NodeScore struct {
	NodeName string
	Score    ScoreBreakdown
}

// Score ranks eligible nodes by bin-packing efficiency and fragmentation penalty.
// Uses SnapshotAllNodes so the loop is lock-free. Bug #9 fix.
func Score(cache *VRAMCache, validNodes []string, requestedBytes int64) []NodeScore {
	snaps := cache.SnapshotAllNodes()
	byName := make(map[string]NodeSnapshot, len(snaps))
	for _, s := range snaps {
		byName[s.NodeName] = s
	}

	var scores []NodeScore

	for _, nodeName := range validNodes {
		node, exists := byName[nodeName]
		if !exists {
			continue
		}

		leftover := node.FreeVRAMBytes - requestedBytes

		// Bin-packing: higher score → less leftover (filling nearly-full nodes first).
		binPack := scoreWeightVRAMBytes - leftover

		// Fragmentation penalty: unusable slivers below the threshold are penalised.
		frag := int64(0)
		if leftover > 0 && leftover < fragmentThresholdBytes {
			frag = -fragmentPenaltyBytes
		}

		total := binPack + frag

		scores = append(scores, NodeScore{
			NodeName: nodeName,
			Score: ScoreBreakdown{
				BinPackScore:       binPack,
				FragmentationScore: frag,
				Total:              total,
			},
		})
	}

	sort.Slice(scores, func(i, j int) bool {
		return scores[i].Score.Total > scores[j].Score.Total
	})

	if len(scores) > 0 {
		log.Printf("Scoring winner: [%s] score=%d", scores[0].NodeName, scores[0].Score.Total)
	}

	return scores
}
GOEOF
echo "✓ Bug #9, #12 — scheduler/score.go"

# =============================================================================
# Bug #5, Bug B — internal/scheduler/plugin.go
# - Schedule takes NamespacedName so bindToKubernetesAPI uses Get, not List
# - Add SyncCacheFromSlice so NodeAgent's Ready/Released events reach the cache
# =============================================================================
cat > "$ROOT/internal/scheduler/plugin.go" <<'GOEOF'
package scheduler

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// SliceScheduler is the stateful scheduling engine.
type SliceScheduler struct {
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
func (s *SliceScheduler) Schedule(ctx context.Context, nn types.NamespacedName, sliceUID string, reqBytes int64) (string, error) {
	log.Printf("Scheduling cycle started for Slice %s (req: %d bytes)", nn, reqBytes)

	var validNodes []string
	for _, node := range s.Cache.ListNodes() {
		fits, _, _ := s.Cache.CanFit(node, reqBytes)
		if fits {
			validNodes = append(validNodes, node)
		}
	}

	if len(validNodes) == 0 {
		return "", fmt.Errorf("no node has sufficient VRAM for %d bytes", reqBytes)
	}

	scores := Score(s.Cache, validNodes, reqBytes)
	if len(scores) == 0 {
		return "", fmt.Errorf("scoring returned 0 candidates despite passing filter — cache inconsistency")
	}

	winningNode := scores[0].NodeName

	tx, err := s.Reserver.Reserve(sliceUID, winningNode, reqBytes)
	if err != nil {
		return "", fmt.Errorf("speculative reserve failed: %w", err)
	}
	defer tx.RollbackIfNotConfirmed()

	if err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {
		return "", fmt.Errorf("bind to Kubernetes API failed: %w", err)
	}

	tx.Confirm()
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
		if err := s.Cache.PromoteConfirmedToAllocated(sliceUID, nodeName, allocatedBytes); err != nil {
			log.Printf("Cache sync (Ready) for slice %s: %v", sliceUID, err)
		}
	case "Released":
		s.Cache.ReleaseAllocated(nodeName, allocatedBytes)
	}
}
GOEOF
echo "✓ Bug #5, B — scheduler/plugin.go"

# =============================================================================
# internal/scheduler/reserve.go — no functional change, but the signature of
# Reserve is unchanged so this stays put. Leaving as-is.
# =============================================================================

# =============================================================================
# Bug #7 — internal/controller/vgpuclaim_reconciler.go
# OwnerReference with Controller=true + BlockOwnerDeletion=true
# =============================================================================
cat > "$ROOT/internal/controller/vgpuclaim_reconciler.go" <<'GOEOF'
package controller

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type VGPUClaimReconciler struct {
	Client client.Client
}

func (r *VGPUClaimReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUClaim{}).
		Complete(r)
}

func (r *VGPUClaimReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, req.NamespacedName, &claim); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUClaim: %w", err)
	}

	if err := r.reconcileClaim(ctx, &claim); err != nil {
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}

func (r *VGPUClaimReconciler) reconcileClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {
	if !claim.DeletionTimestamp.IsZero() {
		return nil
	}

	slice, err := r.ensureSliceExists(ctx, claim)
	if err != nil {
		return fmt.Errorf("ensuring slice exists: %w", err)
	}

	return r.syncClaimStatusFromSlice(ctx, claim, slice)
}

func (r *VGPUClaimReconciler) ensureSliceExists(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) (*vgpuv1alpha1.VGPUSlice, error) {
	sliceName := claim.Name + "-slice"

	var existing vgpuv1alpha1.VGPUSlice
	err := r.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: claim.Namespace}, &existing)
	if err == nil {
		return &existing, nil
	}
	if !errors.IsNotFound(err) {
		return nil, fmt.Errorf("fetching existing slice: %w", err)
	}

	// Bug #7 fix: include Controller=true and BlockOwnerDeletion=true on the
	// OwnerReference so Kubernetes GC propagates correctly and the claim
	// cannot vanish before the slice's finalizer runs.
	truePtr := true
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:      sliceName,
			Namespace: claim.Namespace,
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion:         vgpuv1alpha1.GroupVersion.String(),
					Kind:               "VGPUClaim",
					Name:               claim.Name,
					UID:                claim.UID,
					Controller:         &truePtr,
					BlockOwnerDeletion: &truePtr,
				},
			},
		},
		Spec: vgpuv1alpha1.VGPUSliceSpec{
			ClaimRef:           claim.Name,
			RequestedVRAMBytes: claim.Spec.RequestedVRAMBytes,
		},
	}

	if err := r.Client.Create(ctx, slice); err != nil {
		return nil, fmt.Errorf("creating VGPUSlice: %w", err)
	}
	return slice, nil
}

func (r *VGPUClaimReconciler) syncClaimStatusFromSlice(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim, slice *vgpuv1alpha1.VGPUSlice) error {
	return PatchClaimStatus(ctx, r.Client, claim, func() {
		claim.Status.BoundSliceName = slice.Name

		switch string(slice.Status.Phase) {
		case state.SlicePhaseReady:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseBound)
		case state.SlicePhaseFailed:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseFailed)
			claim.Status.FailureReason = slice.Status.FailureReason
		default:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhasePending)
		}
	})
}
GOEOF
echo "✓ Bug #7 — controller/vgpuclaim_reconciler.go"

# =============================================================================
# Bug #6 — internal/controller/vgpuslice_reconciler.go
# Use RequeueAfter instead of abusing a fmt.Errorf("requeue: ...") sentinel
# =============================================================================
cat > "$ROOT/internal/controller/vgpuslice_reconciler.go" <<'GOEOF'
package controller

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type VGPUSliceReconciler struct {
	Client client.Client
}

func (r *VGPUSliceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(r)
}

func (r *VGPUSliceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.Client.Get(ctx, req.NamespacedName, &slice); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUSlice: %w", err)
	}

	if err := r.reconcileSlice(ctx, &slice); err != nil {
		return reconcile.Result{}, err
	}

	// Bug #6 fix: if the slice is mid-delete and the NodeAgent hasn't confirmed
	// Released yet, politely re-check every 5s instead of returning a sentinel
	// error that would trigger exponential back-off.
	if !slice.DeletionTimestamp.IsZero() && string(slice.Status.Phase) != state.SlicePhaseReleased {
		return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
	}
	return reconcile.Result{}, nil
}

func (r *VGPUSliceReconciler) reconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	if !slice.DeletionTimestamp.IsZero() {
		return r.handleDelete(ctx, slice)
	}

	if EnsureFinalizer(slice, SliceFinalizerName) {
		return r.Client.Update(ctx, slice)
	}

	return nil
}

func (r *VGPUSliceReconciler) handleDelete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	log.Printf("Deletion triggered for Slice %s", slice.Name)

	currentPhase := string(slice.Status.Phase)

	if currentPhase != state.SlicePhaseReleasing && currentPhase != state.SlicePhaseReleased {
		return PatchSliceStatus(ctx, r.Client, slice, func() {
			_ = state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "", "Deletion requested")
		})
	}

	if currentPhase == state.SlicePhaseReleased {
		log.Printf("Hardware freed. Removing finalizer from Slice %s", slice.Name)
		if RemoveFinalizer(slice, SliceFinalizerName) {
			return r.Client.Update(ctx, slice)
		}
	}

	// Currently Releasing — nothing to do until the NodeAgent patches the
	// status to Released. The parent Reconcile returns RequeueAfter.
	return nil
}

var _ reconcile.Reconciler = &VGPUSliceReconciler{}
var _ reconcile.Reconciler = &VGPUClaimReconciler{}
GOEOF
echo "✓ Bug #6 — controller/vgpuslice_reconciler.go"

# =============================================================================
# Bug #1 — internal/nodeagent/reporter.go
# Actually write to Kubernetes. NewReporter takes a client.Client.
# Adds TransitionToAllocating for the new Allocating-phase transition in
# manager.go (part of Bug C fix).
# =============================================================================
cat > "$ROOT/internal/nodeagent/reporter.go" <<'GOEOF'
package nodeagent

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Reporter patches VGPUSlice status back to the Kubernetes API after each
// hardware event. Bug #1 fix: previously the Update calls were commented out
// and the entire lifecycle stalled at Scheduled.
type Reporter struct {
	client client.Client
}

func NewReporter(k8sClient client.Client) *Reporter {
	return &Reporter{client: k8sClient}
}

// TransitionToAllocating is called by the Manager before it begins NVML work,
// so the controller and operators can see that hardware allocation has started.
func (r *Reporter) TransitionToAllocating(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseAllocating, "", "NodeAgent beginning hardware allocation"); err != nil {
		return fmt.Errorf("state transition to Allocating: %w", err)
	}
	if r.client == nil {
		return nil // test mode
	}
	return r.client.Status().Update(ctx, slice)
}

func (r *Reporter) ReportAllocationReady(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice, result *nvml.AllocationResult) error {
	if err := state.MarkSliceReady(slice, result.AllocationID, result.DeviceUUID, result.AllocatedBytes); err != nil {
		return fmt.Errorf("marking slice Ready: %w", err)
	}
	if r.client == nil {
		return nil
	}
	return r.client.Status().Update(ctx, slice)
}

func (r *Reporter) ReportReleaseComplete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseReleased, "CleanupComplete", "Hardware freed"); err != nil {
		return fmt.Errorf("state transition to Released: %w", err)
	}
	// Invariant: Released slices must not retain an active DeviceUUID.
	slice.Status.DeviceUUID = ""
	if r.client == nil {
		return nil
	}
	return r.client.Status().Update(ctx, slice)
}
GOEOF
echo "✓ Bug #1 — nodeagent/reporter.go"

# =============================================================================
# Bug #4 — internal/nodeagent/checkpoint/checkpoint.go
# Save must not silently reset on corruption — that's how node reboots lose
# every other allocation. Return ErrCorruptCheckpoint instead.
# =============================================================================
cat > "$ROOT/internal/nodeagent/checkpoint/checkpoint.go" <<'GOEOF'
package checkpoint

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var ErrCorruptCheckpoint = errors.New("checkpoint file is corrupt")

const (
	defaultCheckpointDir = "/var/run/vgpu-state"
	CheckpointDir        = defaultCheckpointDir
	CheckpointFile       = "allocations.json"
)

type CheckpointRecord struct {
	AllocationID   string    `json:"allocationID"`
	SliceUID       string    `json:"sliceUID"`
	SliceName      string    `json:"sliceName"`
	Namespace      string    `json:"namespace"`
	ClaimName      string    `json:"claimName"`
	DeviceUUID     string    `json:"deviceUUID"`
	AllocatedBytes int64     `json:"allocatedBytes"`
	NodeName       string    `json:"nodeName"`
	CreatedAt      time.Time `json:"createdAt"`
}

type Store struct {
	mu  sync.RWMutex
	dir string
}

func NewStore() *Store {
	return &Store{dir: defaultCheckpointDir}
}

func NewStoreAt(dir string) *Store {
	return &Store{dir: dir}
}

func (s *Store) path() string {
	return filepath.Join(s.dir, CheckpointFile)
}

func (s *Store) LoadAll() (map[string]CheckpointRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	data, err := os.ReadFile(s.path())
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]CheckpointRecord), nil
		}
		return nil, fmt.Errorf("checkpoint read failed: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCorruptCheckpoint, err)
	}
	return records, nil
}

func (s *Store) Save(record CheckpointRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(s.dir, 0750); err != nil {
		return fmt.Errorf("checkpoint dir creation failed: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if data, err := os.ReadFile(s.path()); err == nil {
		if err := json.Unmarshal(data, &records); err != nil {
			// Bug #4 fix: refuse to overwrite a corrupt file. Silently
			// resetting here caused every reboot-after-corruption to lose
			// every allocation that wasn't the one being saved right now.
			return fmt.Errorf("%w: refusing to overwrite existing unparseable checkpoint: %v",
				ErrCorruptCheckpoint, err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("checkpoint read failed during save: %w", err)
	}

	records[record.AllocationID] = record

	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("checkpoint serialisation failed: %w", err)
	}
	return os.WriteFile(s.path(), out, 0640)
}

func (s *Store) Delete(allocationID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("checkpoint read failed during delete: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return fmt.Errorf("%w: %v", ErrCorruptCheckpoint, err)
	}

	delete(records, allocationID)

	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("checkpoint serialisation failed during delete: %w", err)
	}
	return os.WriteFile(s.path(), out, 0640)
}
GOEOF
echo "✓ Bug #4 — nodeagent/checkpoint/checkpoint.go"

# =============================================================================
# Bug C — internal/nodeagent/manager.go
# - Call cdi.GenerateFirewall on allocation, cdi.TeardownFirewall on release
# - Transition Scheduled → Allocating before NVML Allocate (observability)
# - Pass k8sClient through NewReporter (Bug #1 wiring)
# - Guard release against empty AllocationID/DeviceUUID (Scheduled→Releasing path)
# =============================================================================
cat > "$ROOT/internal/nodeagent/manager.go" <<'GOEOF'
package nodeagent

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/cdi"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/drift"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Manager struct {
	NodeName  string
	Allocator *nvml.Allocator
	Store     *checkpoint.Store
	Reporter  *Reporter
	Detector  *drift.Detector
}

func NewManager(nodeName string, k8sClient client.Client) *Manager {
	store := checkpoint.NewStore()
	allocator := nvml.NewAllocator(true)
	return &Manager{
		NodeName:  nodeName,
		Store:     store,
		Allocator: allocator,
		Reporter:  NewReporter(k8sClient),
		Detector:  drift.NewDetector(store, allocator, k8sClient),
	}
}

// ReconcileSlice drives a Slice through allocation or release based on its phase.
func (m *Manager) ReconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	// ALLOCATION PATH
	if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseScheduled) {
		// 1. Announce Allocating (observability).
		if err := m.Reporter.TransitionToAllocating(ctx, slice); err != nil {
			return fmt.Errorf("transitioning to Allocating: %w", err)
		}

		// 2. Physically allocate on the GPU.
		req := nvml.AllocationRequest{
			SliceUID:           string(slice.UID),
			ClaimName:          slice.Spec.ClaimRef,
			RequestedVRAMBytes: slice.Spec.RequestedVRAMBytes,
		}
		result, err := m.Allocator.Allocate(ctx, req)
		if err != nil {
			return fmt.Errorf("NVML allocate: %w", err)
		}

		// 3. Write the CDI firewall so containerd can bind the container to
		//    this specific partition. Bug C fix.
		if err := cdi.GenerateFirewall(slice.Name, result.DeviceUUID); err != nil {
			return fmt.Errorf("generating CDI firewall: %w", err)
		}

		// 4. Persist durable checkpoint for drift-detection after reboot.
		if err := m.Store.Save(checkpoint.CheckpointRecord{
			AllocationID:   result.AllocationID,
			SliceUID:       req.SliceUID,
			SliceName:      slice.Name,
			Namespace:      slice.Namespace,
			ClaimName:      req.ClaimName,
			DeviceUUID:     result.DeviceUUID,
			AllocatedBytes: result.AllocatedBytes,
			NodeName:       m.NodeName,
			CreatedAt:      time.Now(),
		}); err != nil {
			return fmt.Errorf("saving checkpoint: %w", err)
		}

		log.Printf("Successfully allocated hardware for %s (alloc=%s uuid=%s)",
			req.SliceUID, result.AllocationID, result.DeviceUUID)
		return m.Reporter.ReportAllocationReady(ctx, slice, result)
	}

	// RELEASE PATH
	if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReleasing) ||
		!slice.DeletionTimestamp.IsZero() {

		// Guard: a slice deleted before ever reaching Allocating has no
		// DeviceUUID / AllocationID. Bug C + Bug #8 co-fix.
		if slice.Status.DeviceUUID != "" {
			if err := cdi.TeardownFirewall(slice.Status.DeviceUUID); err != nil {
				return fmt.Errorf("tearing down CDI firewall: %w", err)
			}
		}
		if slice.Status.AllocationID != "" {
			if err := m.Allocator.Release(ctx, slice.Status.AllocationID); err != nil {
				return fmt.Errorf("NVML release: %w", err)
			}
			if err := m.Store.Delete(slice.Status.AllocationID); err != nil {
				return fmt.Errorf("deleting checkpoint: %w", err)
			}
		}

		log.Printf("Successfully released hardware for %s", slice.UID)
		return m.Reporter.ReportReleaseComplete(ctx, slice)
	}

	return nil
}
GOEOF
echo "✓ Bug C — nodeagent/manager.go"

# =============================================================================
# Bug #11 — internal/nodeagent/nvml/allocator.go
# Safe UID slicing.
# =============================================================================
cat > "$ROOT/internal/nodeagent/nvml/allocator.go" <<'GOEOF'
package nvml

import (
	"context"
	"fmt"
	"time"
)

type AllocationRequest struct {
	SliceUID           string
	ClaimName          string
	RequestedVRAMBytes int64
}

type AllocationResult struct {
	AllocationID   string
	DeviceUUID     string
	AllocatedBytes int64
}

type Allocator struct {
	mockMode    bool
	initialized bool
}

func NewAllocator(mock bool) *Allocator {
	return &Allocator{mockMode: mock, initialized: true}
}

func (a *Allocator) Allocate(ctx context.Context, req AllocationRequest) (*AllocationResult, error) {
	if !a.initialized {
		return nil, fmt.Errorf("allocator not initialised")
	}
	if req.SliceUID == "" {
		return nil, fmt.Errorf("allocation request missing SliceUID")
	}

	// Bug #11 fix: don't assume 8+ characters.
	short := req.SliceUID
	if len(short) > 8 {
		short = short[:8]
	}
	allocID := fmt.Sprintf("alloc-%s-%d", short, time.Now().Unix())
	devUUID := "GPU-MOCK-ENTERPRISE-1"

	if !a.mockMode {
		// TODO: real NVML C-binding calls go here.
	}

	return &AllocationResult{
		AllocationID:   allocID,
		DeviceUUID:     devUUID,
		AllocatedBytes: req.RequestedVRAMBytes,
	}, nil
}

func (a *Allocator) Release(ctx context.Context, allocationID string) error {
	if !a.initialized {
		return fmt.Errorf("allocator not initialised")
	}
	if allocationID == "" {
		return nil
	}
	// TODO: teardown CDI firewall and free NVML memory partition.
	return nil
}

func (a *Allocator) InspectAllHardware() map[string]bool {
	if !a.initialized || a.mockMode {
		return make(map[string]bool)
	}
	return make(map[string]bool)
}
GOEOF
echo "✓ Bug #11 — nodeagent/nvml/allocator.go"

# =============================================================================
# Bug #13 — internal/nodeagent/drift/detector.go
# Collect and return errors instead of swallowing them with `_ =`.
# =============================================================================
cat > "$ROOT/internal/nodeagent/drift/detector.go" <<'GOEOF'
package drift

import (
	"context"
	"errors"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Detector struct {
	store     *checkpoint.Store
	allocator *nvml.Allocator
	k8sClient client.Client
}

func NewDetector(store *checkpoint.Store, allocator *nvml.Allocator, k8sClient client.Client) *Detector {
	return &Detector{store: store, allocator: allocator, k8sClient: k8sClient}
}

func (d *Detector) DetectAndHeal(ctx context.Context) error {
	diskRecords, err := d.store.LoadAll()
	if err != nil {
		return fmt.Errorf("loading checkpoint: %w", err)
	}

	hardwareAllocations := d.allocator.InspectAllHardware()

	// Bug #13 fix: accumulate errors rather than dropping them.
	var errs []error

	for allocID, record := range diskRecords {
		if hardwareAllocations[allocID] {
			delete(hardwareAllocations, allocID)
			continue
		}

		log.Printf("Recovery [Case 2]: Allocation %s missing from hardware", allocID)

		if d.k8sClient == nil {
			log.Printf("  -> No K8s client configured; pruning orphan checkpoint %s", allocID)
			if err := d.store.Delete(allocID); err != nil {
				errs = append(errs, fmt.Errorf("pruning orphan checkpoint %s: %w", allocID, err))
			}
			continue
		}

		var slice vgpuv1alpha1.VGPUSlice
		key := client.ObjectKey{Namespace: record.Namespace, Name: record.SliceName}
		if err := d.k8sClient.Get(ctx, key, &slice); err != nil {
			log.Printf("  -> Slice not in K8s API (%v). Pruning dead checkpoint %s", err, allocID)
			if err := d.store.Delete(allocID); err != nil {
				errs = append(errs, fmt.Errorf("pruning dead checkpoint %s: %w", allocID, err))
			}
			continue
		}

		if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReady) {
			log.Printf("  -> API expects Ready. Signalling Failed.")
			if err := state.TransitionSlicePhase(&slice, state.SlicePhaseFailed,
				state.ReasonDriftDetected, "Device missing from PCIe bus on node boot"); err != nil {
				errs = append(errs, fmt.Errorf("state transition for %s: %w", allocID, err))
			} else if err := d.k8sClient.Status().Update(ctx, &slice); err != nil {
				errs = append(errs, fmt.Errorf("updating slice %s status: %w", allocID, err))
			}
			if err := d.store.Delete(allocID); err != nil {
				errs = append(errs, fmt.Errorf("pruning checkpoint %s after drift: %w", allocID, err))
			}
		}
	}

	for orphanAllocID := range hardwareAllocations {
		log.Printf("Recovery [Case 3]: Orphaned hardware allocation %s — releasing.", orphanAllocID)
		if err := d.allocator.Release(ctx, orphanAllocID); err != nil {
			errs = append(errs, fmt.Errorf("releasing orphan allocation %s: %w", orphanAllocID, err))
		}
	}

	return errors.Join(errs...)
}
GOEOF
echo "✓ Bug #13 — nodeagent/drift/detector.go"

# =============================================================================
# Bug #8 — internal/state/invariants.go
# Releasing invariant must tolerate pre-allocation deletes.
# =============================================================================
cat > "$ROOT/internal/state/invariants.go" <<'GOEOF'
package state

import (
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// ValidateSliceInvariant checks phase-conditional invariants on a slice.
func ValidateSliceInvariant(slice *vgpuv1alpha1.VGPUSlice) error {
	switch slice.Status.Phase {

	case SlicePhaseScheduled, SlicePhaseAllocating:
		if slice.Spec.NodeName == "" {
			return fmt.Errorf("invariant violation: phase %s requires Spec.NodeName", slice.Status.Phase)
		}

	case SlicePhaseReady:
		if slice.Spec.NodeName == "" {
			return fmt.Errorf("invariant violation: Ready slice missing Spec.NodeName")
		}
		if slice.Status.AllocationID == "" {
			return fmt.Errorf("invariant violation: Ready slice missing durable AllocationID")
		}
		if slice.Status.DeviceUUID == "" {
			return fmt.Errorf("invariant violation: Ready slice missing physical DeviceUUID")
		}
		if slice.Status.AllocatedBytes <= 0 {
			return fmt.Errorf("invariant violation: Ready slice must have > 0 AllocatedBytes")
		}

	case SlicePhaseReleasing:
		// Bug #8 fix: only require AllocationID if hardware was actually
		// allocated. A slice deleted while in Scheduled (pre-NodeAgent pickup)
		// legitimately enters Releasing with no AllocationID.
		if slice.Status.AllocatedBytes > 0 && slice.Status.AllocationID == "" {
			return fmt.Errorf("invariant violation: cannot release allocated hardware without an AllocationID")
		}

	case SlicePhaseFailed:
		if slice.Status.FailureReason == "" {
			return fmt.Errorf("invariant violation: Failed slice must include FailureReason")
		}

	case SlicePhaseReleased:
		if slice.Status.DeviceUUID != "" {
			return fmt.Errorf("invariant violation: Released slice should not retain active DeviceUUID")
		}
	}

	return nil
}
GOEOF
echo "✓ Bug #8 — state/invariants.go"

# =============================================================================
# Bug #14 — internal/webhook/mutating_pod.go
# Resolve the slice's durable AllocationID instead of injecting claimName.
# =============================================================================
cat > "$ROOT/internal/webhook/mutating_pod.go" <<'GOEOF'
package webhook

import (
	"context"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/pranav2910/vgpu-scheduler/internal/security"
)

const (
	VGPUClaimAnnotation = "infrastructure.pranav2910.com/claim-ref"
)

// PodMutator carries a K8s client so the webhook can resolve the bound slice.
type PodMutator struct {
	Client client.Client
}

// MutatePod injects the CDI device reference resolved from the bound slice's
// durable AllocationID. Bug #14 fix: the previous free function injected the
// user-provided claimName, which containerd's CDI resolver does not recognise.
func (m *PodMutator) MutatePod(ctx context.Context, pod *corev1.Pod) error {
	claimName, exists := pod.Annotations[VGPUClaimAnnotation]
	if !exists {
		return nil
	}

	if err := security.ValidatePodSecurity(pod); err != nil {
		return err
	}

	if m.Client == nil {
		return fmt.Errorf("pod mutator not wired with a K8s client")
	}

	// Resolve the slice bound to this claim. The claim reconciler names the
	// slice deterministically as <claim>-slice in the same namespace.
	sliceName := claimName + "-slice"
	var slice vgpuv1alpha1.VGPUSlice
	if err := m.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: pod.Namespace}, &slice); err != nil {
		return fmt.Errorf("resolving vGPU slice %s/%s: %w", pod.Namespace, sliceName, err)
	}
	if slice.Status.AllocationID == "" {
		return fmt.Errorf("vGPU slice %s/%s not yet allocated (phase=%s)", pod.Namespace, sliceName, slice.Status.Phase)
	}

	cdiDeviceName := fmt.Sprintf("vgpu.pranav2910.com/device=%s", slice.Status.AllocationID)

	for i := range pod.Spec.Containers {
		pod.Spec.Containers[i].Env = append(pod.Spec.Containers[i].Env, corev1.EnvVar{
			Name:  "NVIDIA_VISIBLE_DEVICES",
			Value: cdiDeviceName,
		})
	}

	log.Printf("Pod %s/%s mutated for vGPU claim %s (alloc=%s)",
		pod.Namespace, pod.Name, claimName, slice.Status.AllocationID)
	return nil
}
GOEOF
echo "✓ Bug #14 — webhook/mutating_pod.go"

# =============================================================================
# Bugs D, E, F — cmd/scheduler/main.go
# - Bug D: seedCacheFromNodes runs as a manager Runnable (after cache sync)
# - Bug E: rename variables in allocatedVRAMOnNode to reflect correct semantics
# - Bug F: return RequeueAfter on scheduling failure
# - Wire Schedule(namespacedName, uid, bytes) per Bug #5
# - Wire SyncCacheFromSlice on Ready/Released per Bug B
# - Start the TTL reaper per Bug #3
# =============================================================================
cat > "$ROOT/cmd/scheduler/main.go" <<'GOEOF'
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
	_ "github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const vramResourceName corev1.ResourceName = "nvidia.com/vram-bytes"

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))
	log.Println("Booting vGPU Scheduler...")

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Fatalf("registering client-go scheme: %v", err)
	}
	if err := vgpuv1alpha1.AddToScheme(scheme); err != nil {
		log.Fatalf("registering vgpu scheme: %v", err)
	}

	cfg, err := ctrl.GetConfig()
	if err != nil {
		log.Fatalf("getting kubeconfig: %v", err)
	}

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		MetricsBindAddress:     ":8081",
		HealthProbeBindAddress: ":8082",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-scheduler-lock",
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	cache := scheduler.NewVRAMCache()
	sched := scheduler.NewSliceScheduler(cache, mgr.GetClient())

	// Bug D fix: seed the cache as a Runnable so it fires AFTER the informer
	// cache has synced. Calling mgr.GetClient() before mgr.Start() blocks.
	if err := mgr.Add(&seedRunnable{client: mgr.GetClient(), cache: cache}); err != nil {
		log.Fatalf("adding cache-seed runnable: %v", err)
	}

	// Bug #3 fix: start the TTL reaper so expired speculative reservations
	// get rolled back.
	if err := mgr.Add(&ttlReaperRunnable{cache: cache, interval: 10 * time.Second}); err != nil {
		log.Fatalf("adding TTL reaper runnable: %v", err)
	}

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(&sliceSchedulingReconciler{sched: sched, client: mgr.GetClient()}); err != nil {
		log.Fatalf("setting up slice scheduling reconciler: %v", err)
	}

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Node{}).
		Complete(&nodeCapacityReconciler{cache: cache, client: mgr.GetClient()}); err != nil {
		log.Fatalf("setting up node capacity reconciler: %v", err)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Fatalf("adding healthz check: %v", err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Fatalf("adding readyz check: %v", err)
	}

	log.Println("Scheduler initialised. Listening for Pending slices...")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("scheduler manager crashed: %v", err)
	}
}

// ─── Runnables ───────────────────────────────────────────────────────────────

type seedRunnable struct {
	client client.Client
	cache  *scheduler.VRAMCache
}

func (s *seedRunnable) Start(ctx context.Context) error {
	if err := seedCacheFromNodes(ctx, s.client, s.cache); err != nil {
		log.Printf("WARNING: seed from nodes failed: %v (cache will populate on reconcile)", err)
	}
	<-ctx.Done()
	return nil
}

type ttlReaperRunnable struct {
	cache    *scheduler.VRAMCache
	interval time.Duration
}

func (r *ttlReaperRunnable) Start(ctx context.Context) error {
	r.cache.StartTTLReaper(ctx, r.interval)
	<-ctx.Done()
	return nil
}

// ─── Slice scheduling reconciler ─────────────────────────────────────────────

type sliceSchedulingReconciler struct {
	sched  *scheduler.SliceScheduler
	client client.Client
}

func (r *sliceSchedulingReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.client.Get(ctx, req.NamespacedName, &slice); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	phase := string(slice.Status.Phase)

	// Bug B fix: bridge NodeAgent hardware events into the scheduler cache.
	if slice.Spec.NodeName != "" && (phase == "Ready" || phase == "Released") {
		r.sched.SyncCacheFromSlice(
			string(slice.UID),
			slice.Spec.NodeName,
			phase,
			slice.Status.AllocatedBytes,
		)
	}

	// Only schedule Pending slices with no node yet.
	if phase != "" && phase != "Pending" {
		return reconcile.Result{}, nil
	}
	if slice.Spec.NodeName != "" {
		return reconcile.Result{}, nil
	}

	_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes)
	if err != nil {
		// Bug F fix: requeue instead of silently dropping the slice.
		log.Printf("Scheduling failed for Slice %s/%s: %v — will retry in 30s",
			slice.Namespace, slice.Name, err)
		return reconcile.Result{RequeueAfter: 30 * time.Second}, nil
	}
	return reconcile.Result{}, nil
}

// ─── Node capacity reconciler ────────────────────────────────────────────────

type nodeCapacityReconciler struct {
	cache  *scheduler.VRAMCache
	client client.Client
}

func (r *nodeCapacityReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var node corev1.Node
	if err := r.client.Get(ctx, req.NamespacedName, &node); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	totalVRAM, ok := node.Status.Capacity[vramResourceName]
	if !ok {
		return reconcile.Result{}, nil
	}

	consumed := consumedVRAMOnNode(&node)
	r.cache.UpdateNode(node.Name, totalVRAM.Value(), consumed)
	log.Printf("Cache updated: node %s total=%d consumed=%d",
		node.Name, totalVRAM.Value(), consumed)
	return reconcile.Result{}, nil
}

// consumedVRAMOnNode returns the VRAM already consumed by scheduled workloads
// using the extended resource. For extended resources, Kubernetes populates
// Allocatable = Capacity - consumed_by_pods (system-reserved does not apply),
// so Capacity - Allocatable is the pod consumption figure. Bug E clarification.
func consumedVRAMOnNode(node *corev1.Node) int64 {
	allocatable := node.Status.Allocatable[vramResourceName]
	capacity := node.Status.Capacity[vramResourceName]
	consumed := capacity.Value() - allocatable.Value()
	if consumed < 0 {
		return 0
	}
	return consumed
}

// seedCacheFromNodes pre-populates the VRAM cache at startup.
func seedCacheFromNodes(ctx context.Context, k8sClient client.Client, cache *scheduler.VRAMCache) error {
	var nodeList corev1.NodeList
	if err := k8sClient.List(ctx, &nodeList); err != nil {
		return fmt.Errorf("listing nodes: %w", err)
	}

	for i := range nodeList.Items {
		node := &nodeList.Items[i]
		totalVRAM, ok := node.Status.Capacity[vramResourceName]
		if !ok {
			continue
		}
		consumed := consumedVRAMOnNode(node)
		cache.UpdateNode(node.Name, totalVRAM.Value(), consumed)
		log.Printf("Seeded cache: node %s total=%d consumed=%d",
			node.Name, totalVRAM.Value(), consumed)
	}
	return nil
}
GOEOF
echo "✓ Bug D, E, F — cmd/scheduler/main.go"

# =============================================================================
# Housekeeping: remove Windows Zone.Identifier detritus (ends with Z# noise)
# =============================================================================
find "$ROOT" -name '*#Uf03aZone.Identifier' -print -delete 2>/dev/null || true

# =============================================================================
# Housekeeping: backup snapshots left by previous fix scripts are noise —
# move them into the backup dir so the working tree is clean.
# =============================================================================
for d in "$ROOT"/.fix_backup_* "$ROOT"/.fix_runtime_backup_*; do
    if [[ -d "$d" ]]; then
        mv "$d" "$BACKUP/" || true
    fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  All bug fixes applied. Running \`go build ./...\`         ║"
echo "╚══════════════════════════════════════════════════════════╝"
cd "$ROOT"
if go build ./... 2>&1; then
    echo ""
    echo "✅ Build succeeded. Backup at: $BACKUP"
    echo ""
    echo "Next steps:"
    echo "  1. Run \`go vet ./...\` to catch any lint issues."
    echo "  2. Run \`go test ./...\` — some failure_scenarios_test.go cases may"
    echo "     need updating because Schedule() now takes a NamespacedName."
    echo "  3. Rebuild containers and re-deploy."
else
    echo ""
    echo "⚠️  Build failed. Restore with:"
    echo "      cp -rp $BACKUP/* $ROOT/"
    exit 1
fi
