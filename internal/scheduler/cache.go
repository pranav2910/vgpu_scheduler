package scheduler

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
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
	// syncedPhaseBySlice tracks the last phase we reconciled into the
	// cache per slice so repeated 'Ready'/'Released' events don't double-count.
	syncedPhaseBySlice map[string]string
	// allocatedBytesBySlice remembers per-slice allocations so ReleaseAllocated
	// can decrement the exact amount even if the caller's bytes arg is stale.
	allocatedBytesBySlice map[string]int64

	// seeded is set once the cache has been warmed at startup with node capacity
	// AND the consumption of all already-bound slices. The scheduler refuses to
	// place slices until this is true, so a freshly (re)started scheduler cannot
	// over-admit into capacity that is actually occupied by slices it has not
	// yet re-observed. Closes the scheduler-restart over-admission window.
	seeded bool
}

// MarkSeeded records that the cache has been warmed and scheduling may begin.
func (c *VRAMCache) MarkSeeded() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seeded = true
}

// IsSeeded reports whether the startup warm-up has completed.
func (c *VRAMCache) IsSeeded() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.seeded
}

type NodeState struct {
	NodeName           string
	TotalVRAMBytes     int64
	AllocatedVRAMBytes int64
	ReservedVRAMBytes  int64
	FreeVRAMBytes      int64
	Healthy            bool
	// TopologyZone is the node's topology zone, from the
	// topology.vgpu.pranav2910.com/zone label. Empty if the node is
	// unlabeled. Phase 2.5a: node-level topology awareness.
	TopologyZone string
}

type AssumedAllocation struct {
	SliceUID           string
	NodeName           string
	RequestedVRAMBytes int64
	ExpiresAt          time.Time
}

func NewVRAMCache() *VRAMCache {
	return &VRAMCache{
		nodes:                 make(map[string]*NodeState),
		assumedBySlice:        make(map[string]*AssumedAllocation),
		confirmedBySlice:      make(map[string]*AssumedAllocation),
		syncedPhaseBySlice:    make(map[string]string),
		allocatedBytesBySlice: make(map[string]int64),
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
	// Bug #18: emit Prometheus gauge updates — full capacity breakdown per node.
	telemetry.RecordNodeVRAM(node.NodeName, node.TotalVRAMBytes,
		node.ReservedVRAMBytes, node.AllocatedVRAMBytes, node.FreeVRAMBytes)
	c.emitReservationGauge()
}

// emitReservationGauge publishes len(assumed) for observability. Caller
// must hold the write lock (or the read lock for pure reads).
func (c *VRAMCache) emitReservationGauge() {
	telemetry.ReservationsActive.Set(float64(len(c.assumedBySlice)))
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

// PromoteSliceToAllocatedOnce applies PromoteConfirmedToAllocated exactly once
// per sliceUID. Subsequent calls for the same slice are no-ops. Round-3 fix.
func (c *VRAMCache) PromoteSliceToAllocatedOnce(sliceUID, nodeName string, actualBytes int64) error {
	c.mu.Lock()
	if c.syncedPhaseBySlice[sliceUID] == "Ready" {
		c.mu.Unlock()
		return nil
	}
	c.mu.Unlock()

	if err := c.PromoteConfirmedToAllocated(sliceUID, nodeName, actualBytes); err != nil {
		// Fallback path is an error today; we still mark as synced to prevent retry loops.
		c.mu.Lock()
		c.syncedPhaseBySlice[sliceUID] = "Ready"
		c.allocatedBytesBySlice[sliceUID] = actualBytes
		c.mu.Unlock()
		return err
	}
	c.mu.Lock()
	c.syncedPhaseBySlice[sliceUID] = "Ready"
	c.allocatedBytesBySlice[sliceUID] = actualBytes
	c.mu.Unlock()
	return nil
}

// ReleaseSliceOnce applies ReleaseAllocated exactly once per sliceUID.
func (c *VRAMCache) ReleaseSliceOnce(sliceUID, nodeName string) {
	c.mu.Lock()
	if c.syncedPhaseBySlice[sliceUID] == "Released" {
		c.mu.Unlock()
		return
	}
	bytes := c.allocatedBytesBySlice[sliceUID]
	c.syncedPhaseBySlice[sliceUID] = "Released"
	delete(c.allocatedBytesBySlice, sliceUID)
	c.mu.Unlock()
	c.ReleaseAllocated(nodeName, bytes)
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

// ForgetSlice releases a slice's entire cache footprint regardless of which
// state it's in (assumed / confirmed / allocated). Call this when a slice is
// deleted so its capacity is reclaimed immediately, rather than depending on
// the scheduler observing a Released phase (which a fast namespace delete can
// skip) or the TTL reaper (assumed only). Each sub-release is an idempotent
// no-op for states the slice isn't in, and a slice is only ever in one of the
// three states, so there is no risk of double-release.
func (c *VRAMCache) ForgetSlice(sliceUID, nodeName string) {
	c.RollbackAssumedSlice(sliceUID) // speculative hold, if any
	c.ReleaseConfirmedSlice(sliceUID) // confirmed-but-not-allocated, if any
	if nodeName != "" {
		c.ReleaseSliceOnce(sliceUID, nodeName) // allocated, if any
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
	// Bug fix (parallel allocation): the API server does not track vGPU
	// consumption (no kubelet bookkeeping for our extended resource), so a
	// naive UpdateNode call from the node-watch reconciler reports
	// allocatedBytes=0 even when slices are Ready. Trusting that value
	// resets the cache's view of consumed capacity and lets parallel
	// allocations exceed the node's actual size.
	//
	// The scheduler's own cache (driven by PromoteSliceToAllocatedOnce /
	// ReleaseSliceOnce) is the authoritative source. Only honor a higher
	// allocatedBytes from the API (e.g. on initial seed for a node that
	// already has workloads from a previous scheduler instance).
	if allocatedBytes > node.AllocatedVRAMBytes {
		node.AllocatedVRAMBytes = allocatedBytes
	}
	// Do NOT touch ReservedVRAMBytes — it is managed by AssumeSlice /
	// RollbackAssumedSlice / PromoteConfirmedToAllocated and must survive
	// node watch events.
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
	TopologyZone       string
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
		TopologyZone:       node.TopologyZone,
	}
}

// SetNodeZone records a node's topology zone (from its
// topology.vgpu.pranav2910.com/zone label). Creates the node entry if the
// node-watch reconciler hasn't seen it yet, so zone and capacity can arrive
// in either order. Phase 2.5a.
func (c *VRAMCache) SetNodeZone(nodeName, zone string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	node, exists := c.nodes[nodeName]
	if !exists {
		node = &NodeState{NodeName: nodeName, Healthy: true}
		c.nodes[nodeName] = node
	}
	node.TopologyZone = zone
}

// NodeZone returns a node's topology zone, or "" if unknown/unlabeled.
func (c *VRAMCache) NodeZone(nodeName string) string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if node, ok := c.nodes[nodeName]; ok {
		return node.TopologyZone
	}
	return ""
}

// IsAssumed reports whether sliceUID has a held speculative reservation.
// Returns the held node and bytes for callers that want to rebuild a Tx.
// Option B (hold-the-reservation gang gate).
func (c *VRAMCache) IsAssumed(sliceUID string) (string, int64, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if a, ok := c.assumedBySlice[sliceUID]; ok {
		return a.NodeName, a.RequestedVRAMBytes, true
	}
	return "", 0, false
}

// RefreshAssumption extends ExpiresAt for an existing held reservation.
// Returns true if the slice was actually held (and refreshed), false if no
// held reservation exists. Option B (hold-the-reservation gang gate).
func (c *VRAMCache) RefreshAssumption(sliceUID string, ttl time.Duration) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if a, ok := c.assumedBySlice[sliceUID]; ok {
		a.ExpiresAt = time.Now().Add(ttl)
		return true
	}
	return false
}
