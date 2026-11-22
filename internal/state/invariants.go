package state

import (
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// ValidateSliceInvariant checks phase-conditional invariants on a slice.
func ValidateSliceInvariant(slice *vgpuv1alpha1.VGPUSlice) error {
	switch slice.Status.Phase {

	case SlicePhaseScheduled, SlicePhaseAllocating:
		if slice.Spec.NodeName == "" {
			return fmt.Errorf("invariant violation: phase %s requires Spec.NodeName", slice.Status.Phase)
		}

	case SlicePhaseReady:
		if slice.Spec.NodeName == "" {
			return fmt.Errorf("invariant violation: Ready slice missing Spec.NodeName")
		}
		if slice.Status.AllocationID == "" {
			return fmt.Errorf("invariant violation: Ready slice missing durable AllocationID")
		}
		if slice.Status.DeviceUUID == "" {
			return fmt.Errorf("invariant violation: Ready slice missing physical DeviceUUID")
		}
		if slice.Status.AllocatedBytes <= 0 {
			return fmt.Errorf("invariant violation: Ready slice must have > 0 AllocatedBytes")
		}

	case SlicePhaseReleasing:
		// Bug #8 fix: only require AllocationID if hardware was actually
		// allocated. A slice deleted while in Scheduled (pre-NodeAgent pickup)
		// legitimately enters Releasing with no AllocationID.
		if slice.Status.AllocatedBytes > 0 && slice.Status.AllocationID == "" {
			return fmt.Errorf("invariant violation: cannot release allocated hardware without an AllocationID")
		}

	case SlicePhaseFailed:
		if slice.Status.FailureReason == "" {
			return fmt.Errorf("invariant violation: Failed slice must include FailureReason")
		}

	case SlicePhaseReleased:
		if slice.Status.DeviceUUID != "" || slice.Status.AllocationID != "" || slice.Status.AllocatedBytes != 0 {
			return fmt.Errorf("invariant violation: Released slice must have zero DeviceUUID/AllocationID/AllocatedBytes")
		}
	}

	return nil
}
