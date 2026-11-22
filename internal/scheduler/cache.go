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
	// allocatedNodeBySlice remembers WHICH node each allocation sits on, so the
	// cache janitor can forget an allocated slice whose object no longer exists.
	allocatedNodeBySlice map[string]string

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
	Namespace          string
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
		allocatedNodeBySlice:  make(map[string]string),
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
// namespace rides the entry so the quota checker's in-flight ledger
// (PendingNamespaceBytes) can attribute holds to the right namespace.
func (c *VRAMCache) AssumeSlice(sliceUID, namespace, nodeName string, requestedBytes int64, ttl time.Duration) error {
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
		Namespace:          namespace,
		NodeName:           nodeName,
		RequestedVRAMBytes: requestedBytes,
		ExpiresAt:          time.Now().Add(ttl),
	}

	node.ReservedVRAMBytes += requestedBytes
	c.recalculateFreeVRAM(node)
	return nil
}

// ConfirmSliceOrRearm moves an assumed hold to confirmed. If the hold is gone —
// the TTL reaper rolled it back while a slow bind API call was in flight — the
// bind has nevertheless ALREADY happened, so the capacity is factually
// consumed: the confirmed entry is reconstructed from the caller's (namespace,
// node, bytes) and the node re-charged. Without the re-arm, a bound slice
// holds zero cache footprint until the NodeAgent reports Ready, and another
// slice can be admitted into the same physical bytes.
//
// Returns true when it had to re-arm. Callers surface that via the
// vgpu_scheduler_confirm_rearms_total counter — nonzero means bind latency is
// outrunning the reservation TTL (an operator warning, not a normal event).
func (c *VRAMCache) ConfirmSliceOrRearm(sliceUID, namespace, nodeName string, bytes int64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	if assumption, exists := c.assumedBySlice[sliceUID]; exists {
		c.confirmedBySlice[sliceUID] = assumption
		delete(c.assumedBySlice, sliceUID)
		return false
	}
	// Re-arm. Free may briefly floor at 0 if the reaped capacity was already
	// re-sold — that is the honest accounting of an over-admission that already
	// happened at bind time, and it stops further admissions immediately.
	c.confirmedBySlice[sliceUID] = &AssumedAllocation{
		SliceUID:           sliceUID,
		Namespace:          namespace,
		NodeName:           nodeName,
		RequestedVRAMBytes: bytes,
		ExpiresAt:          time.Now(), // informational only; confirmed entries are not TTL-reaped
	}
	if node, ok := c.nodes[nodeName]; ok {
		node.ReservedVRAMBytes += bytes
		c.recalculateFreeVRAM(node)
	} else {
		log.Printf("ConfirmSliceOrRearm: node %s missing for re-armed slice %s — entry recorded, node accounting skipped", nodeName, sliceUID)
	}
	return true
}

// PromoteSliceToAllocatedOnce applies the confirmed→allocated promotion exactly
// once per sliceUID. Subsequent calls for the same slice are no-ops. Round-3 fix.
//
// The check and the promotion happen in ONE critical section: the previous
// check-unlock-promote shape let two concurrent callers (the startup seed pass
// and the slice reconciler's initial informer flood both walk all Ready slices
// at leader failover) both pass the "already synced?" check and both take the
// restart-fallback direct-add path — double-counting the slice's bytes as
// allocated until the next restart.
func (c *VRAMCache) PromoteSliceToAllocatedOnce(sliceUID, nodeName string, actualBytes int64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.syncedPhaseBySlice[sliceUID] == "Ready" {
		return nil
	}
	err := c.promoteConfirmedToAllocatedLocked(sliceUID, nodeName, actualBytes)
	// Mark synced even on the fallback-error path (the allocation was still
	// applied) to prevent retry loops.
	c.syncedPhaseBySlice[sliceUID] = "Ready"
	c.allocatedBytesBySlice[sliceUID] = actualBytes
	c.allocatedNodeBySlice[sliceUID] = nodeName
	return err
}

// ReleaseSliceOnce applies ReleaseAllocated exactly once per sliceUID.
func (c *VRAMCache) ReleaseSliceOnce(sliceUID, nodeName string) {
	c.mu.Lock()
	if c.syncedPhaseBySlice[sliceUID] == "Released" {
		c.mu.Unlock()
		return
	}
	bytes, tracked := c.allocatedBytesBySlice[sliceUID]
	if !tracked && c.syncedPhaseBySlice[sliceUID] == "" {
		// Never tracked: nothing to release, and writing a tombstone for every
		// UID ever observed grows the map unboundedly on a long-lived leader
		// (sweep S8). A later duplicate event also finds nothing — safe.
		c.mu.Unlock()
		return
	}
	c.syncedPhaseBySlice[sliceUID] = "Released"
	delete(c.allocatedBytesBySlice, sliceUID)
	delete(c.allocatedNodeBySlice, sliceUID)
	c.mu.Unlock()
	c.ReleaseAllocated(nodeName, bytes)
}

// HasNode reports whether the node is currently in the candidate set. The
// node reconciler uses it to detect a (re-)registration and trigger the
// slice re-walk that re-charges live allocations (sweep S3).
func (c *VRAMCache) HasNode(nodeName string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	_, ok := c.nodes[nodeName]
	return ok
}

// FailSliceOnce releases every hold a FAILED slice still has, exactly once.
// A slice that binds and then fails hardware allocation (fragmentation, NVML
// error) sits in confirmedBySlice — which is deliberately never TTL-reaped —
// and its object still exists, so the janitor (objects-gone only) never
// forgets it either (sweep S2: a solo job's failed 60Gi slice made 60Gi of
// the node unschedulable until scheduler restart). Failed is terminal for a
// slice, so releasing here is safe: the phase machine never resurrects it.
// The speculative (assumed) hold, if any, is left to the TTL reaper.
func (c *VRAMCache) FailSliceOnce(sliceUID, nodeName string) {
	c.mu.Lock()
	if p := c.syncedPhaseBySlice[sliceUID]; p == "Failed" || p == "Released" {
		c.mu.Unlock()
		return
	}
	if _, confirmed := c.confirmedBySlice[sliceUID]; !confirmed {
		if _, alloc := c.allocatedBytesBySlice[sliceUID]; !alloc && c.syncedPhaseBySlice[sliceUID] == "" {
			c.mu.Unlock() // never tracked → nothing to release, no tombstone (S8)
			return
		}
	}
	bytes := c.allocatedBytesBySlice[sliceUID]
	c.syncedPhaseBySlice[sliceUID] = "Failed"
	delete(c.allocatedBytesBySlice, sliceUID)
	delete(c.allocatedNodeBySlice, sliceUID)
	c.mu.Unlock()
	if bytes > 0 {
		c.ReleaseAllocated(nodeName, bytes)
	}
	c.ReleaseConfirmedSlice(sliceUID) // post-bind, pre-Ready hold — the leak
}

// TrackedSliceUIDs returns every slice UID the cache currently accounts
// capacity for (assumed, confirmed, or allocated), mapped to its node. This is
// the janitor's working set: every release path in the system is EDGE-
// triggered (an event arrives, or it doesn't — and a missed edge leaks
// forever); the janitor compares this set against the API's level and forgets
// entries whose objects no longer exist.
func (c *VRAMCache) TrackedSliceUIDs() map[string]string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make(map[string]string, len(c.assumedBySlice)+len(c.confirmedBySlice)+len(c.allocatedBytesBySlice))
	for uid, a := range c.assumedBySlice {
		out[uid] = a.NodeName
	}
	for uid, a := range c.confirmedBySlice {
		out[uid] = a.NodeName
	}
	for uid, n := range c.allocatedNodeBySlice {
		out[uid] = n
	}
	return out
}

func (c *VRAMCache) PromoteConfirmedToAllocated(sliceUID, nodeName string, actualBytes int64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.promoteConfirmedToAllocatedLocked(sliceUID, nodeName, actualBytes)
}

// promoteConfirmedToAllocatedLocked is the promotion body; c.mu must be held.
func (c *VRAMCache) promoteConfirmedToAllocatedLocked(sliceUID, nodeName string, actualBytes int64) error {
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
	c.RollbackAssumedSlice(sliceUID)  // speculative hold, if any
	c.ReleaseConfirmedSlice(sliceUID) // confirmed-but-not-allocated, if any
	if nodeName != "" {
		c.ReleaseSliceOnce(sliceUID, nodeName) // allocated, if any
	}
	// Forget = the OBJECT is gone; UIDs are never reused, so no future event
	// needs the once-guard. Drop the tombstone or it lives forever (sweep S8).
	c.mu.Lock()
	delete(c.syncedPhaseBySlice, sliceUID)
	c.mu.Unlock()
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

// RemoveNode drops a deleted node from the cache entirely. Without this, a
// deleted/drained node lives in the candidate set forever with its full free
// capacity — once the live nodes fill up, the ghost node looks like the best
// fit, wins Filter/Score, and slices bind to a spec.nodeName with no kubelet
// or node agent behind it, hanging in Scheduled until a human notices.
// Reservations held against the node are dropped with it (the TTL reaper would
// only have skipped their node-side bookkeeping anyway).
//
// The per-slice ledger for the node's slices is cleared WITH the node. Keeping
// it (the old behavior, meant to avoid double-counting) meant the "already
// synced Ready" markers survived while the node's AllocatedVRAMBytes died with
// its NodeState — so when a same-named node re-registered with live Ready
// slices, PromoteSliceToAllocatedOnce early-returned on every one of them, the
// fresh node showed allocated=0, and the scheduler over-admitted onto a full
// node. Clearing both together makes re-registration re-account from zero:
// each re-observed Ready slice promotes exactly once against the fresh state,
// so there is still no double-count.
func (c *VRAMCache) RemoveNode(nodeName string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.nodes[nodeName]; !exists {
		return
	}
	for uid, a := range c.assumedBySlice {
		if a.NodeName == nodeName {
			delete(c.assumedBySlice, uid)
		}
	}
	for uid, a := range c.confirmedBySlice {
		if a.NodeName == nodeName {
			delete(c.confirmedBySlice, uid)
		}
	}
	for uid, n := range c.allocatedNodeBySlice {
		if n == nodeName {
			delete(c.allocatedNodeBySlice, uid)
			delete(c.allocatedBytesBySlice, uid)
			delete(c.syncedPhaseBySlice, uid)
		}
	}
	delete(c.nodes, nodeName)
	// Zero the node's capacity gauges so dashboards don't show a ghost.
	telemetry.RecordNodeVRAM(nodeName, 0, 0, 0, 0)
	c.emitReservationGauge()
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

// PinAssumption atomically verifies a held reservation still exists and
// extends its TTL, returning the held node and bytes. This replaces the
// IsAssumed-then-RefreshAssumption pair: two lock acquisitions let the TTL
// reaper fire between them, so a caller could proceed to bind on a
// reservation that no longer existed. Callers pin (a) when re-entering the
// fast-forward gang path and (b) immediately before every bind API call, so
// the reaper can never roll a hold back mid-bind.
func (c *VRAMCache) PinAssumption(sliceUID string, ttl time.Duration) (string, int64, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if a, ok := c.assumedBySlice[sliceUID]; ok {
		a.ExpiresAt = time.Now().Add(ttl)
		return a.NodeName, a.RequestedVRAMBytes, true
	}
	return "", 0, false
}

// PendingNamespaceBytes sums this scheduler's in-flight admissions (assumed +
// confirmed holds) for a namespace, excluding UIDs the caller already counted
// from its API list. The quota checker reads the informer for committed usage;
// the informer cannot see a bind this scheduler performed milliseconds ago,
// nor the held reservations of a still-converging gang — this ledger closes
// that staleness window. It may briefly include a hold whose slice was just
// deleted (until ForgetSlice runs); that errs toward rejecting at the quota
// edge, never admitting past it.
func (c *VRAMCache) PendingNamespaceBytes(namespace string, countedUIDs map[string]struct{}) int64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	var total int64
	for uid, a := range c.assumedBySlice {
		if a.Namespace != namespace {
			continue
		}
		if _, counted := countedUIDs[uid]; counted {
			continue
		}
		total += a.RequestedVRAMBytes
	}
	for uid, a := range c.confirmedBySlice {
		if a.Namespace != namespace {
			continue
		}
		if _, counted := countedUIDs[uid]; counted {
			continue
		}
		total += a.RequestedVRAMBytes
	}
	return total
}
