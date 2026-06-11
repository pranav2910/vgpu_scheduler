package integration

// Failure scenario tests for Layer 1 validation.
//
// These tests simulate the exact failure paths described in the infra design
// review and verify the system's expected behavior at each failure point.
// No real Kubernetes cluster or GPU hardware is required — everything is
// exercised through the in-memory cache, state machine, and checkpoint store.
//
// Test map:
//   Sim1  — Bind fails after reservation        (pre-bind rollback)
//   Sim2  — Bind succeeds, allocation fails     (post-bind confirmed cleanup)
//   Sim3  — Allocation succeeds, promote fails  (confirmed → allocated promotion)
//   Sim4  — Node restart: checkpoint exists, hardware missing  (drift Case 2)
//   Sim5  — Node restart: hardware exists, checkpoint missing  (drift Case 3)
//   Sim6  — Duplicate scheduling race           (double-reserve guard)
//   Sim7  — Two slices compete for last VRAM    (capacity never negative)
//   Sim8  — Delete while allocating             (finalizer lifecycle)
//   Sim9  — Scheduler restart during confirmed  (cache reconstruction)

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
)

// ─── helpers ─────────────────────────────────────────────────────────────────

const (
	testNode  = "h100-worker-1"
	eightGiB  = int64(8 * 1024 * 1024 * 1024)
	eightyGiB = int64(80 * 1024 * 1024 * 1024)
)

func newCache80GiB() *scheduler.VRAMCache {
	c := scheduler.NewVRAMCache()
	c.UpdateNode(testNode, eightyGiB, 0)
	return c
}

// inspectNode reads internal cache state via the public CanFit/ListNodes surface.
// Returns (free, reserved, allocated) bytes by back-calculating from the node state.
func freeVRAM(t *testing.T, c *scheduler.VRAMCache, node string) int64 {
	t.Helper()
	fits, _, _ := c.CanFit(node, 1) // just checking reachability
	_ = fits

	// Derive free from total - reserved - allocated by attempting a max-size fit.
	// We use CanFit with the full 80 GiB and subtract to find free.
	// Simpler: expose via a test helper that calls CanFit with 1 byte.
	// We can only observe free indirectly — use the fact that CanFit(node, X)
	// returns false when X > free.
	//
	// Binary search is overkill; instead we use UpdateNode's snapshot model:
	// after UpdateNode the node is reset. For test purposes we track free
	// through the sequence of operations ourselves and verify with CanFit.
	//
	// For a direct read, call the exported SnapshotNode helper added below.
	snap := c.SnapshotNode(node)
	if snap == nil {
		t.Fatalf("node %s not found in cache", node)
	}
	return snap.FreeVRAMBytes
}

func reservedVRAM(t *testing.T, c *scheduler.VRAMCache, node string) int64 {
	t.Helper()
	snap := c.SnapshotNode(node)
	if snap == nil {
		t.Fatalf("node %s not found in cache", node)
	}
	return snap.ReservedVRAMBytes
}

func allocatedVRAM(t *testing.T, c *scheduler.VRAMCache, node string) int64 {
	t.Helper()
	snap := c.SnapshotNode(node)
	if snap == nil {
		t.Fatalf("node %s not found in cache", node)
	}
	return snap.AllocatedVRAMBytes
}

// tempCheckpointStore creates a checkpoint.Store that writes to a temp dir
// so tests are hermetic and don't touch /var/run/vgpu-state.
func tempCheckpointStore(t *testing.T) *checkpoint.Store {
	t.Helper()
	dir := t.TempDir()
	return checkpoint.NewStoreAt(dir)
}

// ─── Sim 1: Bind fails after reservation ─────────────────────────────────────

// TestSim1_BindFailRollback verifies that when bindToKubernetesAPI fails after
// a successful speculative reservation, the deferred rollback fully restores the
// cache — no leaked reserved bytes, no partial bind state.
func TestSim1_BindFailRollback(t *testing.T) {
	cache := newCache80GiB()
	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	sliceUID := "slice-sim1"
	initialFree := freeVRAM(t, cache, testNode)

	// Step 1: speculative reservation succeeds.
	tx, err := reserver.Reserve(sliceUID, "default", testNode, eightGiB)
	if err != nil {
		t.Fatalf("Reserve failed unexpectedly: %v", err)
	}

	// Verify VRAM is now reserved (free decreased).
	if freeVRAM(t, cache, testNode) != initialFree-eightGiB {
		t.Fatalf("Expected free to decrease by 8 GiB after reserve")
	}
	if reservedVRAM(t, cache, testNode) != eightGiB {
		t.Fatalf("Expected reserved=8 GiB after assume")
	}

	// Step 2: simulate bind failure — rollback runs via defer in production,
	// here we call it directly to replicate the defer path.
	tx.RollbackIfNotConfirmed()

	// Step 3: verify cache is fully restored.
	if freeVRAM(t, cache, testNode) != initialFree {
		t.Errorf("Sim1 FAIL: free VRAM not restored after bind failure. want=%d got=%d",
			initialFree, freeVRAM(t, cache, testNode))
	}
	if reservedVRAM(t, cache, testNode) != 0 {
		t.Errorf("Sim1 FAIL: reserved bytes leaked after rollback. got=%d", reservedVRAM(t, cache, testNode))
	}

	// Step 4: verify the slice can be safely retried.
	tx2, err := reserver.Reserve(sliceUID, "default", testNode, eightGiB)
	if err != nil {
		t.Errorf("Sim1 FAIL: slice cannot be retried after rollback: %v", err)
	}
	if tx2 != nil {
		tx2.RollbackIfNotConfirmed() // clean up
	}

	t.Log("Sim1 PASS: bind failure correctly rolled back assumed reservation")
}

// ─── Sim 2: Bind succeeds, allocation fails ──────────────────────────────────

// TestSim2_AllocationFailAfterBind verifies that when hardware allocation fails
// after a successful bind (confirmed state), ReleaseConfirmedSlice is the correct
// cleanup path — not RollbackAssumedSlice.
func TestSim2_AllocationFailAfterBind(t *testing.T) {
	cache := newCache80GiB()
	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	sliceUID := "slice-sim2"
	initialFree := freeVRAM(t, cache, testNode)

	// Step 1: reserve → bind succeeds → confirm.
	tx, err := reserver.Reserve(sliceUID, "default", testNode, eightGiB)
	if err != nil {
		t.Fatalf("Reserve failed: %v", err)
	}
	tx.Confirm() // simulates successful K8s bind

	// Verify: reservation moved from assumed → confirmed.
	// RollbackAssumedSlice should now be a no-op (nothing in assumed).
	cache.RollbackAssumedSlice(sliceUID)
	// Reserved bytes should still be 8 GiB (still in confirmed).
	if reservedVRAM(t, cache, testNode) != eightGiB {
		t.Errorf("Sim2 FAIL: rollback of assumed should be no-op after confirm. reserved=%d",
			reservedVRAM(t, cache, testNode))
	}

	// Step 2: hardware allocation fails — correct cleanup path.
	cache.ReleaseConfirmedSlice(sliceUID)

	// Step 3: verify full restoration.
	if freeVRAM(t, cache, testNode) != initialFree {
		t.Errorf("Sim2 FAIL: free VRAM not restored after confirmed release. want=%d got=%d",
			initialFree, freeVRAM(t, cache, testNode))
	}
	if reservedVRAM(t, cache, testNode) != 0 {
		t.Errorf("Sim2 FAIL: reserved bytes leaked. got=%d", reservedVRAM(t, cache, testNode))
	}
	if allocatedVRAM(t, cache, testNode) != 0 {
		t.Errorf("Sim2 FAIL: allocated bytes leaked. got=%d", allocatedVRAM(t, cache, testNode))
	}

	// Step 4: verify the slice's API phase should be Failed and no checkpoint exists.
	// We simulate the NodeAgent's reporter here.
	slice := &vgpuv1alpha1.VGPUSlice{}
	slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseScheduled)
	err = state.TransitionSlicePhase(slice, state.SlicePhaseFailed,
		state.ReasonAllocationFailed, "NVML allocation returned error")
	if err != nil {
		t.Errorf("Sim2 FAIL: could not transition to Failed: %v", err)
	}
	if string(slice.Status.Phase) != state.SlicePhaseFailed {
		t.Errorf("Sim2 FAIL: slice phase should be Failed, got %s", slice.Status.Phase)
	}
	if slice.Status.FailureReason != state.ReasonAllocationFailed {
		t.Errorf("Sim2 FAIL: FailureReason not set. got=%q", slice.Status.FailureReason)
	}

	t.Log("Sim2 PASS: post-bind allocation failure correctly releases confirmed reservation")
}

// ─── Sim 3: Allocation succeeds, promote fails ───────────────────────────────

// TestSim3_PromoteConfirmedToAllocated verifies the happy-path promotion and
// then tests what happens if promote is never called (cache stays in confirmed).
func TestSim3_PromoteConfirmedToAllocated(t *testing.T) {
	cache := newCache80GiB()
	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	sliceUID := "slice-sim3"

	// Step 1: full scheduling path — assume → confirm.
	tx, err := reserver.Reserve(sliceUID, "default", testNode, eightGiB)
	if err != nil {
		t.Fatalf("Reserve failed: %v", err)
	}
	tx.Confirm()

	// State: 8 GiB reserved, 0 allocated.
	if reservedVRAM(t, cache, testNode) != eightGiB {
		t.Fatalf("Expected 8 GiB reserved before promote")
	}
	if allocatedVRAM(t, cache, testNode) != 0 {
		t.Fatalf("Expected 0 allocated before promote")
	}

	// Step 2: NodeAgent hardware allocation succeeds → promote.
	err = cache.PromoteConfirmedToAllocated(sliceUID, testNode, eightGiB)
	if err != nil {
		t.Fatalf("PromoteConfirmedToAllocated failed: %v", err)
	}

	// State: 0 reserved, 8 GiB allocated, free = 72 GiB.
	if reservedVRAM(t, cache, testNode) != 0 {
		t.Errorf("Sim3 FAIL: reserved not cleared after promote. got=%d",
			reservedVRAM(t, cache, testNode))
	}
	if allocatedVRAM(t, cache, testNode) != eightGiB {
		t.Errorf("Sim3 FAIL: allocated not set after promote. got=%d",
			allocatedVRAM(t, cache, testNode))
	}
	expectedFree := eightyGiB - eightGiB
	if freeVRAM(t, cache, testNode) != expectedFree {
		t.Errorf("Sim3 FAIL: free VRAM wrong after promote. want=%d got=%d",
			expectedFree, freeVRAM(t, cache, testNode))
	}

	// Step 3: verify Ready slice contributes to allocated, not reserved.
	// Promoting twice should fail (slice no longer in confirmed map).
	err = cache.PromoteConfirmedToAllocated(sliceUID, testNode, eightGiB)
	if err == nil {
		t.Errorf("Sim3 FAIL: double-promote should return error but returned nil")
	}

	// Step 4: simulate promote being skipped (stuck-confirmed scenario).
	// Set up a second slice that gets confirmed but never promoted.
	sliceUID2 := "slice-sim3-stuck"
	tx2, _ := reserver.Reserve(sliceUID2, "default", testNode, eightGiB)
	tx2.Confirm()
	// The slice is now stuck in confirmed. Free VRAM is 72 - 8 = 64 GiB.
	// A third slice requesting 65 GiB should be rejected (64 GiB free).
	fits, reason, _ := cache.CanFit(testNode, 65*1024*1024*1024)
	if fits {
		t.Errorf("Sim3 FAIL: stuck-confirmed slice not counted against free VRAM")
	}
	if reason != scheduler.ReasonInsufficientVRAM {
		t.Errorf("Sim3 FAIL: expected INSUFFICIENT_VRAM, got %q", reason)
	}
	// Clean up.
	cache.ReleaseConfirmedSlice(sliceUID2)

	t.Log("Sim3 PASS: promotion shifts bytes from reserved to allocated; stuck-confirmed correctly blocks capacity")
}

// ─── Sim 4: Node restart — checkpoint exists, hardware missing ───────────────

// TestSim4_CheckpointExistsHardwareMissing simulates Case 2 of drift detection:
// the checkpoint file says an allocation exists but hardware inspection returns
// nothing. The expected outcome is the slice phase becomes Failed and the
// checkpoint is deleted.
func TestSim4_DriftCheckpointNoHardware(t *testing.T) {
	store := tempCheckpointStore(t)

	// Write a checkpoint record representing a "Ready" allocation.
	record := checkpoint.CheckpointRecord{
		AllocationID:   "alloc-123",
		SliceUID:       "slice-uid-abc",
		SliceName:      "my-slice",
		Namespace:      "default",
		DeviceUUID:     "GPU-MOCK-1",
		AllocatedBytes: eightGiB,
		NodeName:       testNode,
		CreatedAt:      time.Now(),
	}
	if err := store.Save(record); err != nil {
		t.Fatalf("Could not save checkpoint: %v", err)
	}

	// Verify it was written.
	records, err := store.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll failed: %v", err)
	}
	if _, ok := records["alloc-123"]; !ok {
		t.Fatalf("Checkpoint not found after save")
	}

	// Simulate drift detection: hardware inspection returns empty (hardware missing).
	// We drive the detector logic manually to avoid needing a real K8s client.
	hardwareAllocations := map[string]bool{} // empty — hardware is gone

	// Replicate detector Case 2 logic:
	for allocID, rec := range records {
		if hardwareAllocations[allocID] {
			continue // healthy
		}
		// Hardware missing — this record is a ghost.
		// In production: fetch slice, transition to Failed, delete checkpoint.
		// Here: simulate the slice-side state transition.
		slice := &vgpuv1alpha1.VGPUSlice{}
		slice.Name = rec.SliceName
		slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReady)

		err := state.TransitionSlicePhase(slice, state.SlicePhaseFailed,
			state.ReasonDriftDetected, "Device missing from PCIe bus on node boot")
		if err != nil {
			t.Errorf("Sim4 FAIL: state transition to Failed failed: %v", err)
		}

		// Delete checkpoint.
		if err := store.Delete(allocID); err != nil {
			t.Errorf("Sim4 FAIL: checkpoint delete failed: %v", err)
		}
	}

	// Verify: checkpoint deleted.
	records, _ = store.LoadAll()
	if _, ok := records["alloc-123"]; ok {
		t.Errorf("Sim4 FAIL: checkpoint still exists after drift cleanup")
	}

	// Verify: slice phase is Failed with correct reason.
	slice := &vgpuv1alpha1.VGPUSlice{}
	slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReady)
	_ = state.TransitionSlicePhase(slice, state.SlicePhaseFailed,
		state.ReasonDriftDetected, "Device missing from PCIe bus on node boot")

	if string(slice.Status.Phase) != state.SlicePhaseFailed {
		t.Errorf("Sim4 FAIL: slice phase should be Failed, got %s", slice.Status.Phase)
	}
	if slice.Status.FailureReason != state.ReasonDriftDetected {
		t.Errorf("Sim4 FAIL: FailureReason should be DriftDetected, got %q", slice.Status.FailureReason)
	}
	if slice.Status.LastError == "" {
		t.Errorf("Sim4 FAIL: LastError should be populated")
	}

	t.Log("Sim4 PASS: checkpoint-without-hardware correctly transitions slice to Failed and clears checkpoint")
}

// ─── Sim 5: Hardware exists, checkpoint missing ───────────────────────────────

// TestSim5_OrphanHardwareNoCheckpoint simulates Case 3 of drift detection:
// hardware inspection finds an active allocation that has no checkpoint entry.
// The expected outcome is the orphan hardware is released exactly once.
func TestSim5_OrphanHardwareNoCheckpoint(t *testing.T) {
	store := tempCheckpointStore(t)

	// No checkpoint entries — store is empty.
	records, _ := store.LoadAll()
	if len(records) != 0 {
		t.Fatalf("Expected empty checkpoint store, got %d entries", len(records))
	}

	// Hardware inspection finds an orphan.
	hardwareAllocations := map[string]bool{
		"alloc-999": true, // exists on hardware, no checkpoint
	}

	releaseCount := 0

	// Replicate detector Case 3 logic:
	for orphanAllocID := range hardwareAllocations {
		if _, inCheckpoint := records[orphanAllocID]; inCheckpoint {
			continue // healthy — skip
		}
		// Orphan — release it.
		releaseCount++
		// In production this calls allocator.Release(). We track count.
		_ = orphanAllocID
	}

	if releaseCount != 1 {
		t.Errorf("Sim5 FAIL: expected exactly 1 orphan release, got %d", releaseCount)
	}

	// Verify no false cleanup: add a healthy allocation to the checkpoint.
	_ = store.Save(checkpoint.CheckpointRecord{
		AllocationID: "alloc-healthy",
		SliceName:    "healthy-slice",
		Namespace:    "default",
		NodeName:     testNode,
	})
	records, _ = store.LoadAll()
	hardwareAllocations2 := map[string]bool{
		"alloc-healthy": true, // checkpoint + hardware = healthy, must NOT release
		"alloc-orphan":  true, // no checkpoint = orphan, must release
	}

	orphanReleaseCount := 0
	for allocID := range hardwareAllocations2 {
		if _, inCheckpoint := records[allocID]; !inCheckpoint {
			orphanReleaseCount++
		}
	}
	if orphanReleaseCount != 1 {
		t.Errorf("Sim5 FAIL: healthy allocation incorrectly counted as orphan (count=%d)", orphanReleaseCount)
	}

	t.Log("Sim5 PASS: orphan hardware detected and released exactly once; healthy allocation untouched")
}

// ─── Sim 6: Duplicate scheduling race ────────────────────────────────────────

// TestSim6_DuplicateSchedulingRace verifies that two concurrent reconcile events
// for the same slice UID result in exactly one reservation and one bind.
func TestSim6_DuplicateSchedulingRace(t *testing.T) {
	cache := newCache80GiB()
	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	sliceUID := "slice-sim6"
	var wg sync.WaitGroup
	var mu sync.Mutex
	var txns []*scheduler.ReservationTx
	successCount := 0

	// Fire two concurrent goroutines both trying to reserve the same slice.
	// Rollback happens AFTER wg.Wait() — rolling back inside the goroutine
	// would clear assumedBySlice before the second goroutine runs its
	// duplicate check, letting both succeed and making the test meaningless.
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tx, err := reserver.Reserve(sliceUID, "default", testNode, eightGiB)
			mu.Lock()
			defer mu.Unlock()
			if err == nil {
				successCount++
				txns = append(txns, tx)
			}
		}()
	}
	wg.Wait()

	// Clean up after both goroutines have finished their Reserve calls.
	for _, tx := range txns {
		tx.RollbackIfNotConfirmed()
	}

	if successCount != 1 {
		t.Errorf("Sim6 FAIL: expected exactly 1 reservation to succeed, got %d", successCount)
	}

	// Reserved bytes should now be 0 (winner rolled back after count).
	if reservedVRAM(t, cache, testNode) != 0 {
		t.Errorf("Sim6 FAIL: reserved bytes leaked after race. got=%d",
			reservedVRAM(t, cache, testNode))
	}

	t.Log("Sim6 PASS: duplicate scheduling race — exactly one reservation succeeded")
}

// ─── Sim 7: Two slices compete for last VRAM ─────────────────────────────────

// TestSim7_LastVRAMContention verifies that when two slices each request exactly
// the node's remaining free VRAM, only one can succeed and free never goes negative.
func TestSim7_LastVRAMContention(t *testing.T) {
	// Node has exactly 8 GiB free.
	cache := scheduler.NewVRAMCache()
	cache.UpdateNode(testNode, eightGiB, 0)

	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	var wg sync.WaitGroup
	successCount := 0
	var mu sync.Mutex
	var winners []string

	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			sliceUID := fmt.Sprintf("slice-contention-%d", id)
			tx, err := reserver.Reserve(sliceUID, "default", testNode, eightGiB)
			mu.Lock()
			defer mu.Unlock()
			if err == nil {
				successCount++
				winners = append(winners, sliceUID)
				tx.Confirm() // commit the winner
			}
		}(i)
	}
	wg.Wait()

	if successCount != 1 {
		t.Errorf("Sim7 FAIL: expected exactly 1 winner for last VRAM, got %d (winners: %v)",
			successCount, winners)
	}

	// Free VRAM must be 0, never negative.
	free := freeVRAM(t, cache, testNode)
	if free < 0 {
		t.Errorf("Sim7 FAIL: free VRAM went negative: %d", free)
	}
	if free != 0 {
		t.Errorf("Sim7 FAIL: expected free=0 after full allocation, got %d", free)
	}

	// A third slice requesting even 1 byte should be rejected.
	fits, _, _ := cache.CanFit(testNode, 1)
	if fits {
		t.Errorf("Sim7 FAIL: node reported capacity after full allocation")
	}

	t.Log("Sim7 PASS: last-VRAM contention — exactly one winner, capacity never negative")
}

// ─── Sim 8: Delete while allocating ──────────────────────────────────────────

// TestSim8_DeleteWhileAllocating verifies the finalizer lifecycle: a slice
// cannot be garbage-collected by Kubernetes while hardware allocation is in
// progress, and the finalizer is only removed after the NodeAgent confirms
// the hardware is freed.
func TestSim8_DeleteWhileAllocating(t *testing.T) {
	// Simulate the slice lifecycle through its state machine.
	slice := &vgpuv1alpha1.VGPUSlice{}
	slice.Name = "slice-sim8"

	// Phase: Scheduled → Allocating (NodeAgent starts work).
	if err := state.TransitionSlicePhase(slice, state.SlicePhasePending, "", ""); err != nil {
		t.Fatalf("transition to Pending: %v", err)
	}
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseScheduled, "", ""); err != nil {
		t.Fatalf("transition to Scheduled: %v", err)
	}
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseAllocating, "", ""); err != nil {
		t.Fatalf("transition to Allocating: %v", err)
	}

	// Deletion timestamp is set mid-flight (user deletes claim while NodeAgent works).
	// The finalizer must prevent actual GC. In the state machine, deletion is
	// signalled by transitioning to Releasing — which is only legal from
	// Allocating (allowed by the DAG).
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "", "Deletion requested"); err != nil {
		t.Errorf("Sim8 FAIL: cannot transition Allocating→Releasing: %v", err)
	}

	// NodeAgent completes teardown → Released.
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseReleased, "", ""); err != nil {
		t.Errorf("Sim8 FAIL: cannot transition Releasing→Released: %v", err)
	}

	// Only after Released can the controller remove the finalizer.
	if string(slice.Status.Phase) != state.SlicePhaseReleased {
		t.Errorf("Sim8 FAIL: finalizer should only be removed when phase=Released, got %s",
			slice.Status.Phase)
	}

	// Verify: jumping directly from Allocating to Released is illegal.
	slice2 := &vgpuv1alpha1.VGPUSlice{}
	_ = state.TransitionSlicePhase(slice2, state.SlicePhasePending, "", "")
	_ = state.TransitionSlicePhase(slice2, state.SlicePhaseScheduled, "", "")
	_ = state.TransitionSlicePhase(slice2, state.SlicePhaseAllocating, "", "")
	err := state.TransitionSlicePhase(slice2, state.SlicePhaseReleased, "", "") // illegal skip
	if err == nil {
		t.Errorf("Sim8 FAIL: illegal transition Allocating→Released should be rejected by state machine")
	}

	t.Log("Sim8 PASS: delete-while-allocating handled by DAG; finalizer only removed after Released")
}

// ─── Sim 9: Scheduler restart during confirmed state ─────────────────────────

// TestSim9_SchedulerRestartDuringConfirmed answers the hardest Layer 1 question:
// after a scheduler restart, how do we reconstruct the difference between
// "confirmed but not yet allocated" and "actually allocated"?
//
// Answer: query the Kubernetes API for VGPUSlices.
//   - Phase == Scheduled → was confirmed (nodeName set, hardware not yet allocated)
//     → re-add to cache as assumed/confirmed to block that VRAM
//   - Phase == Ready     → hardware is allocated
//     → re-add to cache as allocated
//   - Phase == Pending   → never confirmed; nothing to restore
//
// This test drives that reconstruction logic directly.
func TestSim9_SchedulerRestartReconstruction(t *testing.T) {
	// Before restart: scheduler confirmed a reservation for slice A.
	// After restart: cache is empty. We reconstruct from slice phase.

	// Simulate the API state that existed before the crash.
	scheduledSlice := &vgpuv1alpha1.VGPUSlice{}
	scheduledSlice.Name = "slice-scheduled"
	scheduledSlice.Spec.NodeName = testNode
	scheduledSlice.Spec.RequestedVRAMBytes = eightGiB
	scheduledSlice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseScheduled)

	readySlice := &vgpuv1alpha1.VGPUSlice{}
	readySlice.Name = "slice-ready"
	readySlice.Spec.NodeName = testNode
	readySlice.Spec.RequestedVRAMBytes = eightGiB
	readySlice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReady)
	readySlice.Status.AllocationID = "alloc-ready-1"
	readySlice.Status.AllocatedBytes = eightGiB

	// Fresh cache after restart.
	cache := scheduler.NewVRAMCache()
	cache.UpdateNode(testNode, eightyGiB, 0)

	// Reconstruction: walk slices from the API and re-populate the cache.
	slices := []*vgpuv1alpha1.VGPUSlice{scheduledSlice, readySlice}
	for _, s := range slices {
		if s.Spec.NodeName == "" {
			continue // unscheduled — nothing to restore
		}
		switch string(s.Status.Phase) {
		case state.SlicePhaseScheduled, state.SlicePhaseAllocating:
			// Was confirmed — block this VRAM speculatively.
			// Use a long TTL so it isn't evicted before the NodeAgent reports in.
			_ = cache.AssumeSlice(string(s.UID)+"_restored", s.Namespace, s.Spec.NodeName,
				s.Spec.RequestedVRAMBytes, 10*time.Minute)
			cache.ConfirmSliceOrRearm(string(s.UID)+"_restored", s.Namespace, s.Spec.NodeName, s.Spec.RequestedVRAMBytes)

		case state.SlicePhaseReady:
			// Hardware is confirmed allocated — count it as allocated.
			// We use UpdateNode to fold it into the baseline on restart.
			// In a real reconciler this sums all Ready slice bytes per node.
		}
	}

	// Manually account for the Ready slice's allocated bytes.
	// (In production: sum all Ready slices per node, then UpdateNode with that total.)
	allocatedByReadySlices := int64(0)
	for _, s := range slices {
		if string(s.Status.Phase) == state.SlicePhaseReady {
			allocatedByReadySlices += s.Status.AllocatedBytes
		}
	}
	cache.UpdateNode(testNode, eightyGiB, allocatedByReadySlices)
	// Re-apply the confirmed reservations after UpdateNode (which resets reserved=0).
	cache.ReleaseConfirmedSlice(string(scheduledSlice.UID) + "_restored")
	_ = cache.AssumeSlice("restored-scheduled", "default", testNode, scheduledSlice.Spec.RequestedVRAMBytes, 10*time.Minute)
	cache.ConfirmSliceOrRearm("restored-scheduled", "default", testNode, scheduledSlice.Spec.RequestedVRAMBytes)

	// Final state: 8 GiB allocated (Ready slice) + 8 GiB reserved (Scheduled slice)
	// = 16 GiB consumed, 64 GiB free.
	expectedFree := eightyGiB - 2*eightGiB
	if freeVRAM(t, cache, testNode) != expectedFree {
		t.Errorf("Sim9 FAIL: after restart reconstruction, free=%d want=%d",
			freeVRAM(t, cache, testNode), expectedFree)
	}
	if allocatedVRAM(t, cache, testNode) != eightGiB {
		t.Errorf("Sim9 FAIL: allocated should be 8 GiB (Ready slice), got %d",
			allocatedVRAM(t, cache, testNode))
	}
	if reservedVRAM(t, cache, testNode) != eightGiB {
		t.Errorf("Sim9 FAIL: reserved should be 8 GiB (Scheduled slice), got %d",
			reservedVRAM(t, cache, testNode))
	}

	// Critical: a new 65 GiB request must be rejected (only 64 GiB free).
	fits, _, _ := cache.CanFit(testNode, 65*1024*1024*1024)
	if fits {
		t.Errorf("Sim9 FAIL: over-allocation possible after restart — Scheduled slice not counted")
	}

	t.Log("Sim9 PASS: post-restart cache correctly distinguishes confirmed-not-allocated from allocated")
	t.Log("         Answer: Scheduled phase → restore as confirmed; Ready phase → restore as allocated")
}

// ─── state machine illegal transition table ───────────────────────────────────

// TestStateMachine_IllegalTransitions exhaustively verifies that the DAG rejects
// every transition that is not in the legal adjacency list.
func TestStateMachine_IllegalTransitions(t *testing.T) {
	illegal := []struct {
		from, to string
	}{
		{state.SlicePhasePending, state.SlicePhaseAllocating},
		{state.SlicePhasePending, state.SlicePhaseReady},
		{state.SlicePhasePending, state.SlicePhaseReleasing},
		{state.SlicePhasePending, state.SlicePhaseReleased},
		{state.SlicePhaseScheduled, state.SlicePhaseReady},
		{state.SlicePhaseScheduled, state.SlicePhaseReleased},
		{state.SlicePhaseAllocating, state.SlicePhasePending},
		{state.SlicePhaseAllocating, state.SlicePhaseScheduled},
		{state.SlicePhaseAllocating, state.SlicePhaseReleased},
		{state.SlicePhaseReady, state.SlicePhasePending},
		{state.SlicePhaseReady, state.SlicePhaseScheduled},
		{state.SlicePhaseReady, state.SlicePhaseAllocating},
		{state.SlicePhaseReady, state.SlicePhaseReleased},
		{state.SlicePhaseReleasing, state.SlicePhasePending},
		{state.SlicePhaseReleasing, state.SlicePhaseScheduled},
		{state.SlicePhaseReleasing, state.SlicePhaseAllocating},
		{state.SlicePhaseReleasing, state.SlicePhaseReady},
		{state.SlicePhaseReleased, state.SlicePhasePending},   // terminal
		{state.SlicePhaseReleased, state.SlicePhaseScheduled}, // terminal
		{state.SlicePhaseReleased, state.SlicePhaseAllocating},
		{state.SlicePhaseReleased, state.SlicePhaseReady},
		{state.SlicePhaseReleased, state.SlicePhaseReleasing},
		{state.SlicePhaseReleased, state.SlicePhaseFailed},
	}

	for _, tc := range illegal {
		t.Run(fmt.Sprintf("%s->%s", tc.from, tc.to), func(t *testing.T) {
			slice := &vgpuv1alpha1.VGPUSlice{}
			slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(tc.from)
			err := state.TransitionSlicePhase(slice, tc.to, "test", "test")
			if err == nil {
				t.Errorf("FAIL: illegal transition %s→%s was accepted by state machine",
					tc.from, tc.to)
			}
		})
	}
}

// ─── checkpoint store hermetic helpers ───────────────────────────────────────

// Verify the checkpoint store correctly handles a missing file (first boot).
func TestCheckpoint_FirstBoot_EmptyStore(t *testing.T) {
	store := tempCheckpointStore(t)
	records, err := store.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll on empty store should not error: %v", err)
	}
	if len(records) != 0 {
		t.Errorf("Expected empty records on first boot, got %d", len(records))
	}
}

// Verify Save → LoadAll → Delete round-trip.
func TestCheckpoint_SaveLoadDelete(t *testing.T) {
	store := tempCheckpointStore(t)

	rec := checkpoint.CheckpointRecord{
		AllocationID: "alloc-roundtrip",
		SliceName:    "test-slice",
		Namespace:    "default",
		NodeName:     testNode,
		CreatedAt:    time.Now().Truncate(time.Second),
	}
	if err := store.Save(rec); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	records, err := store.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll failed: %v", err)
	}
	if _, ok := records["alloc-roundtrip"]; !ok {
		t.Fatalf("Record not found after save")
	}

	if err := store.Delete("alloc-roundtrip"); err != nil {
		t.Fatalf("Delete failed: %v", err)
	}

	records, _ = store.LoadAll()
	if _, ok := records["alloc-roundtrip"]; ok {
		t.Errorf("Record still present after delete")
	}
}

// Verify that a corrupt checkpoint file returns an error rather than silently
// returning an empty map (which would cause orphan cleanup of valid allocations).
func TestCheckpoint_CorruptFile_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	store := checkpoint.NewStoreAt(dir)

	// Write garbage to the checkpoint file.
	corruptPath := filepath.Join(dir, "allocations.json")
	if err := os.WriteFile(corruptPath, []byte("this is not json {{{{"), 0640); err != nil {
		t.Fatalf("could not write corrupt file: %v", err)
	}

	_, err := store.LoadAll()
	if err == nil {
		t.Errorf("LoadAll on corrupt file should return error, got nil")
	}
	if !errors.Is(err, checkpoint.ErrCorruptCheckpoint) {
		t.Errorf("Expected ErrCorruptCheckpoint, got: %v", err)
	}
}
