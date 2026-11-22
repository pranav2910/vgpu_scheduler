package scheduler

import (
	"sync"
	"testing"
	"time"
)

const testGiB = int64(1024 * 1024 * 1024)

// TestPromoteOnceIsAtomicUnderConcurrency is the regression test for the
// check-then-act race in PromoteSliceToAllocatedOnce: the "already synced?"
// check and the promotion used to run under two separate lock acquisitions, so
// the startup seed pass and the slice reconciler's informer flood — which both
// walk every Ready slice at leader failover — could both pass the check and
// both apply the restart-fallback direct allocation, double-counting the slice
// until the next restart.
func TestPromoteOnceIsAtomicUnderConcurrency(t *testing.T) {
	for iter := 0; iter < 200; iter++ {
		c := NewVRAMCache()
		c.UpdateNode("n1", 80*testGiB, 0)

		var wg sync.WaitGroup
		for g := 0; g < 8; g++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				// Restart path: no prior assumption exists → fallback direct-add.
				_ = c.PromoteSliceToAllocatedOnce("slice-uid-1", "n1", 16*testGiB)
			}()
		}
		wg.Wait()

		snap := c.SnapshotNode("n1")
		if snap.AllocatedVRAMBytes != 16*testGiB {
			t.Fatalf("iter %d: allocated = %d, want %d (slice promoted more than once)",
				iter, snap.AllocatedVRAMBytes, 16*testGiB)
		}
	}
}

// TestRemoveNodeDropsGhostCandidate is the regression test for deleted nodes
// living in the cache forever: a drained/deleted node kept its full free
// capacity and, once live nodes filled, won placement — binding slices to a
// node with no kubelet behind it.
func TestRemoveNodeDropsGhostCandidate(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("ghost", 80*testGiB, 0)
	c.UpdateNode("live", 80*testGiB, 0)

	// A held reservation against the ghost must die with it.
	if err := c.AssumeSlice("uid-r", "default", "ghost", 8*testGiB, 30*time.Second); err != nil {
		t.Fatalf("assume: %v", err)
	}

	c.RemoveNode("ghost")

	if ok, reason, _ := c.CanFit("ghost", testGiB); ok || reason != ReasonNodeNotFound {
		t.Fatalf("ghost node still placeable after removal: ok=%t reason=%s", ok, reason)
	}
	for _, n := range c.ListNodes() {
		if n == "ghost" {
			t.Fatalf("ghost node still listed after removal")
		}
	}
	if node, _, held := c.IsAssumed("uid-r"); held {
		t.Fatalf("reservation against removed node still held (node=%s)", node)
	}
	// Removing an unknown node is a no-op, not a panic.
	c.RemoveNode("never-existed")

	// The survivor is untouched.
	if ok, _, _ := c.CanFit("live", 70*testGiB); !ok {
		t.Fatalf("live node lost capacity when ghost was removed")
	}
}

// TestRemoveNodeClearsSliceLedgerForReRegistration is the regression test for
// the audit's over-admit-on-re-register edge: RemoveNode deleted the NodeState
// (allocated figure dies) but KEPT the per-slice ledger ("already synced
// Ready" markers). When a same-named node re-registered with live Ready
// slices, PromoteSliceToAllocatedOnce early-returned on every one, the fresh
// node showed allocated=0, and the scheduler over-admitted onto a full node.
func TestRemoveNodeClearsSliceLedgerForReRegistration(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("n1", 80*testGiB, 0)
	c.UpdateNode("n2", 80*testGiB, 0)

	// Live workloads: 64 GiB on n1, 16 GiB on n2. No prior assumption exists in
	// this synthetic setup, so promote takes the restart-fallback direct-add
	// path, which returns an informational error while still applying — same
	// convention as TestPromoteOnceIsAtomicUnderConcurrency.
	for _, uid := range []string{"a", "b", "c", "d"} {
		_ = c.PromoteSliceToAllocatedOnce("uid-"+uid, "n1", 16*testGiB)
	}
	_ = c.PromoteSliceToAllocatedOnce("uid-n2", "n2", 16*testGiB)

	// Node object deleted (drain, restart, transient loss)…
	c.RemoveNode("n1")
	// …and a same-named node re-registers. The API reports allocated=0 (no
	// kubelet bookkeeping for the extended resource).
	c.UpdateNode("n1", 80*testGiB, 0)

	// The informer re-walks the still-Ready slices (fallback direct-add again —
	// informational error, allocation applied). Before the fix these all
	// early-returned on the stale "Ready" markers.
	for _, uid := range []string{"a", "b", "c", "d"} {
		_ = c.PromoteSliceToAllocatedOnce("uid-"+uid, "n1", 16*testGiB)
	}

	snap := c.SnapshotNode("n1")
	if snap.AllocatedVRAMBytes != 64*testGiB {
		t.Fatalf("allocated after re-register = %d GiB, want 64 GiB (over-admit window)",
			snap.AllocatedVRAMBytes/testGiB)
	}
	// The over-admission itself: only 16 GiB is really free; 32 must not fit.
	if ok, _, _ := c.CanFit("n1", 32*testGiB); ok {
		t.Fatalf("CanFit admitted 32 GiB onto a node with 16 GiB free — over-admission")
	}

	// Precision: n2's ledger was untouched — a re-observed promote there must
	// still be a no-op (no double count).
	if err := c.PromoteSliceToAllocatedOnce("uid-n2", "n2", 16*testGiB); err != nil {
		t.Fatalf("re-promote on n2: %v", err)
	}
	if snap := c.SnapshotNode("n2"); snap.AllocatedVRAMBytes != 16*testGiB {
		t.Fatalf("n2 allocated = %d GiB, want 16 GiB (ledger over-cleared → double count)",
			snap.AllocatedVRAMBytes/testGiB)
	}

	// Books still balance: releasing a re-promoted slice returns its bytes.
	c.ReleaseSliceOnce("uid-a", "n1")
	if snap := c.SnapshotNode("n1"); snap.AllocatedVRAMBytes != 48*testGiB {
		t.Fatalf("allocated after release = %d GiB, want 48 GiB", snap.AllocatedVRAMBytes/testGiB)
	}
}

// TestSetNodeHealthGatesPlacement: CanFit/AssumeSlice must refuse a NotReady
// node (the flag used to be set by nothing, making the rejection path dead).
func TestSetNodeHealthGatesPlacement(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("n1", 80*testGiB, 0)
	c.SetNodeHealth("n1", false)
	if ok, reason, _ := c.CanFit("n1", testGiB); ok || reason != ReasonNodeUnhealthy {
		t.Fatalf("NotReady node accepted: ok=%t reason=%s", ok, reason)
	}
	if err := c.AssumeSlice("uid-h", "default", "n1", testGiB, 30*time.Second); err == nil {
		t.Fatalf("AssumeSlice succeeded on an unhealthy node")
	}
	c.SetNodeHealth("n1", true)
	if ok, _, _ := c.CanFit("n1", testGiB); !ok {
		t.Fatalf("recovered node still rejected")
	}
}

// TestFailedSliceReleasesConfirmedHold is the regression test for sweep S2: a
// slice that binds (assume→confirm) and then FAILS hardware allocation
// (fragmentation) left its bytes in confirmedBySlice forever — confirmed holds
// are deliberately not TTL-reaped, the janitor forgets only object-gone UIDs,
// and SyncCacheFromSlice handled only Ready/Released. The node lost that
// capacity until a scheduler restart.
func TestFailedSliceReleasesConfirmedHold(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("n1", 80*testGiB, 0)

	// A 60Gi slice binds: assume, then confirm (the post-bind hold).
	if err := c.AssumeSlice("uid-fail", "default", "n1", 60*testGiB, 30*time.Second); err != nil {
		t.Fatalf("assume: %v", err)
	}
	c.ConfirmSliceOrRearm("uid-fail", "default", "n1", 60*testGiB)
	if ok, _, _ := c.CanFit("n1", 30*testGiB); ok {
		t.Fatalf("confirm must charge the node (80-60=20 free; 30 must not fit)")
	}

	// NodeAgent fails the allocation → slice phase Failed → reconciler syncs.
	c.FailSliceOnce("uid-fail", "n1")
	if ok, _, _ := c.CanFit("n1", 30*testGiB); !ok {
		t.Fatalf("Failed slice must release its confirmed hold — node still charged")
	}

	// Idempotent: a re-reconcile of the same Failed slice releases nothing new.
	c.FailSliceOnce("uid-fail", "n1")
	if ok, _, _ := c.CanFit("n1", 79*testGiB); !ok {
		t.Fatalf("double-fail must not double-release (free should be exactly 80GiB)")
	}

	// A Ready slice that later fails (drift) releases its ALLOCATED bytes too.
	_ = c.PromoteSliceToAllocatedOnce("uid-drift", "n1", 40*testGiB)
	if ok, _, _ := c.CanFit("n1", 50*testGiB); ok {
		t.Fatalf("allocated slice must charge the node")
	}
	c.FailSliceOnce("uid-drift", "n1")
	if ok, _, _ := c.CanFit("n1", 79*testGiB); !ok {
		t.Fatalf("Ready->Failed must release allocated bytes")
	}
}
