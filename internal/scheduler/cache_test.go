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
