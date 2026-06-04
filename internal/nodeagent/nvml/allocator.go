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
	now := time.Now().UnixNano()
	allocID := fmt.Sprintf("alloc-%s-%d", short, now)
	// Bug #21: unique UUID per allocation so CDI files don't collide.
	devUUID := fmt.Sprintf("GPU-MOCK-%s-%d", short, now)

	if !a.mockMode {
		// Real build: bind the slice to a physical GPU and record its TRUE UUID
		// (physicalGPUUUID is build-tagged — real NVML under -tags nvml, a no-op
		// stub otherwise). This product models one GPU per node, so the slice
		// maps to that GPU; per-process VRAM isolation is the runtime-enforcement
		// layer (Phase 3.4), not a hardware partition. NOTE: the device-node /
		// driver-library injection that lets the container actually open the GPU
		// is finalized + validated on real hardware — see docs/runtime-enforcement.md.
		uuid, err := physicalGPUUUID()
		if err != nil {
			return nil, fmt.Errorf("binding physical GPU: %w", err)
		}
		if uuid != "" {
			devUUID = uuid
		}
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
