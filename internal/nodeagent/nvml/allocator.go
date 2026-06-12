package nvml

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
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

// allocDevice is one physical GPU as the allocator sees it: identity plus the
// memory figures that matter for placement.
type allocDevice struct {
	uuid     string
	total    int64
	reserved int64 // driver-reserved — allocatable to nobody
}

// Allocator places slices onto physical GPUs (M-GPU: multiple cards per node).
//
// Placement is BEST-FIT: the healthy card with the smallest free space that
// still fits, which preserves large holes for large future slices. "Free" is
//
//	available = card total − driver reserved − committed ledger
//
// NOT raw NVML free: a slice can be granted before its workload starts using
// VRAM, and raw free would let that promised-but-idle capacity be sold twice.
// The ledger is the allocator's own per-card bookkeeping; it survives agent
// restarts by being re-seeded from the checkpoint store (RestoreAllocation).
//
// One slice maps to exactly ONE card — never split across cards. If no single
// card fits, Allocate fails LOUD with FragmentationError (the node-pooled
// scheduler may admit a slice the cards cannot host; the allocator is the last
// line of defense and must say so, not retry silently).
type Allocator struct {
	mockMode    bool
	initialized bool

	mu        sync.Mutex
	committed map[string]int64       // device UUID → bytes promised to slices
	byAlloc   map[string]ledgerEntry // allocationID → entry (Release returns the right card's bytes)
	bySlice   map[string]string      // slice UID → allocationID (idempotency + wedge-recovery release)
}

type ledgerEntry struct {
	sliceUID   string
	deviceUUID string
	bytes      int64
}

func NewAllocator(mock bool) *Allocator {
	return &Allocator{
		mockMode:    mock,
		initialized: true,
		committed:   make(map[string]int64),
		byAlloc:     make(map[string]ledgerEntry),
		bySlice:     make(map[string]string),
	}
}

// FragmentationError: the node has enough free VRAM in total, but no single
// GPU can host the request. The message format is part of the fail-loud
// contract surfaced on the slice/job — keep it stable.
type FragmentationError struct {
	RequestedBytes int64
	NodeFreeBytes  int64
}

func (e *FragmentationError) Error() string {
	return fmt.Sprintf("No single GPU has %s free; node has %s free across GPUs. Fragmented capacity.",
		humanGi(e.RequestedBytes), humanGi(e.NodeFreeBytes))
}

func humanGi(b int64) string {
	if b%(1<<30) == 0 {
		return fmt.Sprintf("%dGi", b>>30)
	}
	return fmt.Sprintf("%.1fGi", float64(b)/(1<<30))
}

func (a *Allocator) Allocate(ctx context.Context, req AllocationRequest) (*AllocationResult, error) {
	if !a.initialized {
		return nil, fmt.Errorf("allocator not initialised")
	}
	if req.SliceUID == "" {
		return nil, fmt.Errorf("allocation request missing SliceUID")
	}
	if req.RequestedVRAMBytes <= 0 {
		return nil, fmt.Errorf("allocation request for %q has non-positive RequestedVRAMBytes (%d)",
			req.SliceUID, req.RequestedVRAMBytes)
	}

	devices, err := a.devices()
	if err != nil {
		return nil, fmt.Errorf("enumerating GPUs: %w", err)
	}

	// Bug #11 fix: don't assume 8+ characters.
	short := req.SliceUID
	if len(short) > 8 {
		short = short[:8]
	}
	allocID := fmt.Sprintf("alloc-%s-%d", short, time.Now().UnixNano())

	a.mu.Lock()
	defer a.mu.Unlock()

	// IDEMPOTENT per slice: a reconcile RETRY for a slice whose previous
	// Allocate already committed (e.g. the Ready status write hit a conflict
	// and the slice is being re-driven from Allocating) must return the SAME
	// allocation — a fresh one would double-commit the ledger and orphan the
	// original CDI spec + checkpoint.
	if prior, ok := a.bySlice[req.SliceUID]; ok {
		e := a.byAlloc[prior]
		return &AllocationResult{
			AllocationID:   prior,
			DeviceUUID:     e.deviceUUID,
			AllocatedBytes: e.bytes,
		}, nil
	}

	uuid, err := a.pickBestFitLocked(devices, req.RequestedVRAMBytes)
	if err != nil {
		return nil, err
	}
	a.committed[uuid] += req.RequestedVRAMBytes
	a.byAlloc[allocID] = ledgerEntry{sliceUID: req.SliceUID, deviceUUID: uuid, bytes: req.RequestedVRAMBytes}
	a.bySlice[req.SliceUID] = allocID

	return &AllocationResult{
		AllocationID:   allocID,
		DeviceUUID:     uuid,
		AllocatedBytes: req.RequestedVRAMBytes,
	}, nil
}

// pickBestFitLocked returns the card with the smallest available space that
// still fits the request. Caller must hold a.mu.
func (a *Allocator) pickBestFitLocked(devices []allocDevice, req int64) (string, error) {
	best := ""
	var bestAvail int64 = -1
	var nodeFree int64
	for _, d := range devices {
		avail := d.total - d.reserved - a.committed[d.uuid]
		if avail < 0 {
			avail = 0
		}
		nodeFree += avail
		if avail >= req && (bestAvail < 0 || avail < bestAvail) {
			best, bestAvail = d.uuid, avail
		}
	}
	if best == "" {
		return "", &FragmentationError{RequestedBytes: req, NodeFreeBytes: nodeFree}
	}
	return best, nil
}

// Release returns the allocation's bytes to its card in the ledger. Idempotent:
// an unknown allocationID (already released, or never restored) is a no-op.
func (a *Allocator) Release(ctx context.Context, allocationID string) error {
	if !a.initialized {
		return fmt.Errorf("allocator not initialised")
	}
	if allocationID == "" {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.releaseLocked(allocationID)
	return nil
}

// ReleaseBySlice releases whatever allocation the ledger holds for a slice,
// returning its allocationID ("" if none). This is the WEDGE-RECOVERY path:
// a slice whose Ready status write failed holds a committed allocation that
// was never recorded on its status (AllocationID empty) — when that slice is
// deleted, releasing by status alone would leak the ledger entry permanently
// (and its CDI spec + checkpoint). The ledger remembers what status couldn't.
func (a *Allocator) ReleaseBySlice(ctx context.Context, sliceUID string) (string, error) {
	if !a.initialized {
		return "", fmt.Errorf("allocator not initialised")
	}
	if sliceUID == "" {
		return "", nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	allocID, ok := a.bySlice[sliceUID]
	if !ok {
		return "", nil
	}
	a.releaseLocked(allocID)
	return allocID, nil
}

// releaseLocked removes one allocation from the ledger. Caller holds a.mu.
func (a *Allocator) releaseLocked(allocationID string) {
	e, ok := a.byAlloc[allocationID]
	if !ok {
		return
	}
	a.committed[e.deviceUUID] -= e.bytes
	if a.committed[e.deviceUUID] <= 0 {
		delete(a.committed, e.deviceUUID)
	}
	delete(a.byAlloc, allocationID)
	if e.sliceUID != "" {
		delete(a.bySlice, e.sliceUID)
	}
}

// RestoreAllocation re-seeds the per-card ledger from a persisted checkpoint
// record at agent startup, so commitments survive restarts — without this, a
// restarted agent would see every card as empty and could over-promise cards
// that already host slices. sliceUID restores the idempotency/wedge-recovery
// index too. Duplicate allocationIDs are ignored (idempotent).
func (a *Allocator) RestoreAllocation(allocationID, sliceUID, deviceUUID string, bytes int64) {
	if allocationID == "" || deviceUUID == "" || bytes <= 0 {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, dup := a.byAlloc[allocationID]; dup {
		return
	}
	a.committed[deviceUUID] += bytes
	a.byAlloc[allocationID] = ledgerEntry{sliceUID: sliceUID, deviceUUID: deviceUUID, bytes: bytes}
	if sliceUID != "" {
		a.bySlice[sliceUID] = allocationID
	}
}

// CommittedBytes reports the ledger for one card (tests + observability).
func (a *Allocator) CommittedBytes(deviceUUID string) int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.committed[deviceUUID]
}

// devices returns the cards the allocator may place on. Mock mode synthesizes
// them from the same env knobs as the fake GPU provider — and with the SAME
// stable UUIDs (GPU-FAKE-%08d) — so on kind the allocator's cards and the
// observer's cards are the same cards. The real path is build-tagged
// (enumerateDevices in allocator_nvml.go).
func (a *Allocator) devices() ([]allocDevice, error) {
	if a.mockMode {
		count := envIntDefault("VGPU_FAKE_GPU_COUNT", 1)
		if count < 0 {
			count = 0
		}
		mem := envInt64Default("VGPU_FAKE_GPU_MEM_BYTES", 80<<30)
		if mem < 0 {
			mem = 0
		}
		out := make([]allocDevice, 0, count)
		for i := 0; i < count; i++ {
			out = append(out, allocDevice{uuid: fmt.Sprintf("GPU-FAKE-%08d", i), total: mem})
		}
		return out, nil
	}
	return enumerateDevices()
}

func envIntDefault(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envInt64Default(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}

// InspectAllHardware enumerates live hardware allocations, returning
// (allocations, true) when an authoritative inventory was actually taken.
//
// Today it returns (nil, false) in BOTH modes: allocations are bookkeeping on
// shared GPUs (no MIG partitioning yet), so the hardware cannot enumerate
// them. The supported flag exists because the drift detector must not confuse
// "I cannot inspect" with "the hardware is empty" — treating an empty map as
// authoritative would mass-fail every Ready slice with a persisted checkpoint
// on agent restart ("Device missing from PCIe bus" for 100% of records).
// Real enumeration arrives with MIG-backed partitioning (3.4e).
func (a *Allocator) InspectAllHardware() (map[string]bool, bool) {
	return nil, false
}
