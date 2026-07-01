package nvml

// M-GPU regression tests: best-fit card selection, the per-card ledger,
// release/restore symmetry, and the fail-loud fragmentation contract — all on
// mock multi-GPU nodes (VGPU_FAKE_* env), no hardware needed.

import (
	"context"
	"strings"
	"testing"
)

const tGiB = int64(1) << 30

func mockNode(t *testing.T, cards int, memBytes int64) *Allocator {
	t.Helper()
	t.Setenv("VGPU_FAKE_GPU_COUNT", itoa(cards))
	t.Setenv("VGPU_FAKE_GPU_MEM_BYTES", i64toa(memBytes))
	return NewAllocator(true)
}

func itoa(n int) string { return i64toa(int64(n)) }
func i64toa(n int64) string {
	// strconv-free helper keeps the test file import list tiny.
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [24]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func alloc(t *testing.T, a *Allocator, uid string, bytes int64) *AllocationResult {
	t.Helper()
	res, err := a.Allocate(context.Background(), AllocationRequest{SliceUID: uid, RequestedVRAMBytes: bytes})
	if err != nil {
		t.Fatalf("Allocate(%s, %d): %v", uid, bytes, err)
	}
	return res
}

// One slice → one card; requested bytes fit on that card; spreading happens
// only because best-fit forces it (identical empty cards tie-break to a single
// card until it can no longer fit).
func TestBestFitPacksOneCardBeforeSpilling(t *testing.T) {
	a := mockNode(t, 8, 80*tGiB)

	// 4× 16Gi: identical cards → best-fit packs the SAME card ever tighter
	// (after the first grant, that card has the smallest fitting hole).
	first := alloc(t, a, "uid-0", 16*tGiB)
	for i := 1; i < 4; i++ {
		r := alloc(t, a, "uid-"+itoa(i), 16*tGiB)
		if r.DeviceUUID != first.DeviceUUID {
			t.Fatalf("slice %d landed on %s, want %s (best-fit must prefer the tightest fitting card)", i, r.DeviceUUID, first.DeviceUUID)
		}
	}
	if got := a.CommittedBytes(first.DeviceUUID); got != 64*tGiB {
		t.Fatalf("card ledger = %d, want %d", got, 64*tGiB)
	}

	// 5th 16Gi: 16Gi free remains on the packed card — still best-fit there.
	r5 := alloc(t, a, "uid-4", 16*tGiB)
	if r5.DeviceUUID != first.DeviceUUID {
		t.Fatalf("5th slice on %s, want %s (16Gi hole is the tightest fit)", r5.DeviceUUID, first.DeviceUUID)
	}
	// 6th: the packed card is FULL → must spill to a fresh card, never over-pack.
	r6 := alloc(t, a, "uid-5", 16*tGiB)
	if r6.DeviceUUID == first.DeviceUUID {
		t.Fatalf("6th slice over-packed the full card %s", first.DeviceUUID)
	}
	if got := a.CommittedBytes(first.DeviceUUID); got != 80*tGiB {
		t.Fatalf("full card ledger = %d, want %d (exactly its capacity, never more)", got, 80*tGiB)
	}
}

func TestBestFitPrefersTightestHole(t *testing.T) {
	a := mockNode(t, 3, 80*tGiB)
	// Shape the holes: card A → 40 free, card B → 16 free, card C → 80 free.
	rA := alloc(t, a, "uid-a", 40*tGiB)
	rB := alloc(t, a, "uid-b", 64*tGiB)
	if rA.DeviceUUID == rB.DeviceUUID {
		t.Fatalf("setup: expected two distinct cards")
	}
	// A 10Gi request fits all three; best-fit must take the 16Gi hole (card B).
	r := alloc(t, a, "uid-c", 10*tGiB)
	if r.DeviceUUID != rB.DeviceUUID {
		t.Fatalf("10Gi went to %s, want the tightest hole on %s", r.DeviceUUID, rB.DeviceUUID)
	}
}

// The fail-loud contract: node-pooled free space is plenty, but no single card
// fits → FragmentationError with the EXACT message format, no allocation, no
// ledger mutation.
func TestFragmentationFailsLoud(t *testing.T) {
	a := mockNode(t, 2, 80*tGiB)
	alloc(t, a, "uid-a", 48*tGiB) // card 1: 32 free
	alloc(t, a, "uid-b", 48*tGiB) // card 2: 32 free  → node free = 64

	_, err := a.Allocate(context.Background(), AllocationRequest{SliceUID: "uid-frag", RequestedVRAMBytes: 40 * tGiB})
	if err == nil {
		t.Fatalf("40Gi into 2×32Gi holes must fail (no single card fits)")
	}
	var frag *FragmentationError
	if !asFrag(err, &frag) {
		t.Fatalf("error type = %T, want *FragmentationError", err)
	}
	want := "No single GPU has 40Gi free; node has 64Gi free across GPUs. Fragmented capacity."
	if err.Error() != want {
		t.Fatalf("message contract broken:\n got %q\nwant %q", err.Error(), want)
	}
	// No ledger mutation on failure.
	if total := a.CommittedBytes("GPU-FAKE-00000000") + a.CommittedBytes("GPU-FAKE-00000001"); total != 96*tGiB {
		t.Fatalf("ledger mutated on failed allocation: total committed %d, want %d", total, 96*tGiB)
	}
}

func asFrag(err error, target **FragmentationError) bool {
	for err != nil {
		if f, ok := err.(*FragmentationError); ok {
			*target = f
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

// Release returns capacity to the RIGHT card, and the freed hole is reusable.
func TestReleaseRestoresCardCapacity(t *testing.T) {
	a := mockNode(t, 2, 80*tGiB)
	r1 := alloc(t, a, "uid-1", 60*tGiB)
	r2 := alloc(t, a, "uid-2", 60*tGiB)
	if r1.DeviceUUID == r2.DeviceUUID {
		t.Fatalf("setup: 2×60Gi must land on distinct 80Gi cards")
	}
	// 30Gi cannot fit anywhere now (20-free holes only).
	if _, err := a.Allocate(context.Background(), AllocationRequest{SliceUID: "uid-3", RequestedVRAMBytes: 30 * tGiB}); err == nil {
		t.Fatalf("30Gi must not fit before release")
	}
	if err := a.Release(context.Background(), r1.AllocationID); err != nil {
		t.Fatalf("release: %v", err)
	}
	if got := a.CommittedBytes(r1.DeviceUUID); got != 0 {
		t.Fatalf("released card ledger = %d, want 0", got)
	}
	r3 := alloc(t, a, "uid-3", 30*tGiB)
	if r3.DeviceUUID != r1.DeviceUUID {
		t.Fatalf("post-release 30Gi on %s, want the freed card %s", r3.DeviceUUID, r1.DeviceUUID)
	}
	// Double-release is a safe no-op.
	if err := a.Release(context.Background(), r1.AllocationID); err != nil {
		t.Fatalf("double release: %v", err)
	}
}

// Restart resilience: a fresh allocator re-seeded from checkpoint records must
// refuse to over-promise the cards those records occupy.
func TestRestoreFromCheckpointsPreventsOverPromise(t *testing.T) {
	a := mockNode(t, 2, 80*tGiB)
	// Simulate the manager's startup seed: two persisted 60Gi allocations.
	a.RestoreAllocation("alloc-old-1", "uid-old-1", "GPU-FAKE-00000000", 60*tGiB)
	a.RestoreAllocation("alloc-old-2", "uid-old-2", "GPU-FAKE-00000001", 60*tGiB)
	a.RestoreAllocation("alloc-old-2", "uid-old-2", "GPU-FAKE-00000001", 60*tGiB) // duplicate: ignored

	if _, err := a.Allocate(context.Background(), AllocationRequest{SliceUID: "uid-x", RequestedVRAMBytes: 30 * tGiB}); err == nil {
		t.Fatalf("a re-seeded allocator must not over-promise checkpointed cards")
	}
	// And the restored entries release like live ones.
	if err := a.Release(context.Background(), "alloc-old-1"); err != nil {
		t.Fatalf("release restored: %v", err)
	}
	r := alloc(t, a, "uid-x", 30*tGiB)
	if r.DeviceUUID != "GPU-FAKE-00000000" {
		t.Fatalf("post-release landed on %s, want GPU-FAKE-00000000", r.DeviceUUID)
	}
}

// Mock cards carry the SAME stable UUIDs as the fake observation provider, so
// kind-cluster metrics join slices to the cards the monitor sees.
func TestMockUUIDsAreStableAndProviderConsistent(t *testing.T) {
	a := mockNode(t, 8, 80*tGiB)
	r := alloc(t, a, "uid-1", 8*tGiB)
	if !strings.HasPrefix(r.DeviceUUID, "GPU-FAKE-") {
		t.Fatalf("mock device UUID = %s, want stable GPU-FAKE-%%08d (matching the fake provider)", r.DeviceUUID)
	}
	r2 := alloc(t, a, "uid-2", 8*tGiB)
	if r2.DeviceUUID != r.DeviceUUID {
		t.Fatalf("identical empty-ish cards: best-fit should reuse the tightest card, got %s then %s", r.DeviceUUID, r2.DeviceUUID)
	}
}

func TestRejectsNonPositiveRequests(t *testing.T) {
	a := mockNode(t, 1, 80*tGiB)
	for _, bad := range []int64{0, -1} {
		if _, err := a.Allocate(context.Background(), AllocationRequest{SliceUID: "uid", RequestedVRAMBytes: bad}); err == nil {
			t.Fatalf("RequestedVRAMBytes=%d must be rejected", bad)
		}
	}
}
