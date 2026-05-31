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
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Manager struct {
	NodeName  string
	Allocator *nvml.Allocator
	Store     *checkpoint.Store
	Reporter  *Reporter
	Detector  *drift.Detector
}

// NewManager builds the node-agent manager. mock selects the allocator's
// hardware mode; callers derive it from the build tag (gpu.RealBuild) so the
// allocation path and the observation path agree on whether real hardware is
// present.
func NewManager(nodeName string, k8sClient client.Client, mock bool) *Manager {
	store := checkpoint.NewStore()
	allocator := nvml.NewAllocator(mock)
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
			telemetry.RecordHardwareAllocation(m.NodeName, false)
			return fmt.Errorf("NVML allocate: %w", err)
		}
		telemetry.RecordHardwareAllocation(m.NodeName, true)

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
