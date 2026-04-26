package webhook

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// ValidateVGPUClaim ensures garbage data never enters the reconciliation loop.
func ValidateVGPUClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {
	// 1. Validate VRAM bounds (must be positive and within max physical card capacity).
	if claim.Spec.RequestedVRAMBytes <= 0 {
		return fmt.Errorf("validation failed: RequestedVRAMBytes must be > 0")
	}
	const maxVRAMBytes = int64(85_899_345_920) // 80 GiB — adjust per hardware fleet
	if claim.Spec.RequestedVRAMBytes > maxVRAMBytes {
		return fmt.Errorf("validation failed: RequestedVRAMBytes %d exceeds max capacity %d",
			claim.Spec.RequestedVRAMBytes, maxVRAMBytes)
	}

	// 2. Validate ServiceTier against the canonical set defined in api/v1alpha1.
	tier := claim.Spec.ServiceTier
	if tier != "" &&
		tier != vgpuv1alpha1.ServiceTierGuaranteed &&
		tier != vgpuv1alpha1.ServiceTierBestEffort {
		return fmt.Errorf("validation failed: unsupported ServiceTier %q (want Guaranteed or BestEffort)", tier)
	}

	return nil
}

// ValidateClaimUpdate ensures users cannot change the VRAM request after hardware is locked.
func ValidateClaimUpdate(ctx context.Context, oldClaim, newClaim *vgpuv1alpha1.VGPUClaim) error {
	if oldClaim.Spec.RequestedVRAMBytes != newClaim.Spec.RequestedVRAMBytes {
		return fmt.Errorf("immutability violation: cannot change RequestedVRAMBytes after creation")
	}
	return nil
}
