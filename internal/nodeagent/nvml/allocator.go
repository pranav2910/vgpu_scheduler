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
