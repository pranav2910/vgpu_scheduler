package webhook

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// ValidateVGPUGangJob enforces v1 gang-scheduling invariants. The reconciler
// assumes these properties; the webhook is the contract that guarantees them.
//
// v1 invariants:
//
//  1. minAvailable == gangSize. Elastic gangs (partial-success scheduling) are
//     rejected. The reconciler has no retry-with-fewer-children path.
//
//  2. gangSize is in [2, 256]. Single-member "gangs" should use plain
//     VGPUJob; gangs over 256 are rejected because the reservation status
//     map would balloon kubectl output without practical benefit.
//
//  3. PodTemplate.Spec.RequestedVRAMBytes > 0. Same upper-bound check as
//     ValidateVGPUClaim.
//
//  4. ReservationTimeoutSeconds, if set, is in [10, 600]. Defaults handle
//     the unset case.
func ValidateVGPUGangJob(ctx context.Context, gang *vgpuv1alpha1.VGPUGangJob) error {
	if gang.Spec.GangSize < 2 || gang.Spec.GangSize > 256 {
		return fmt.Errorf("validation failed: gangSize must be in [2, 256], got %d", gang.Spec.GangSize)
	}
	if gang.Spec.MinAvailable != gang.Spec.GangSize {
		return fmt.Errorf(
			"validation failed: v1 supports strict gangs only (minAvailable must equal gangSize); "+
				"got minAvailable=%d, gangSize=%d. Elastic gangs are planned for v2.",
			gang.Spec.MinAvailable, gang.Spec.GangSize,
		)
	}

	if gang.Spec.ReservationTimeoutSeconds != nil {
		t := *gang.Spec.ReservationTimeoutSeconds
		if t < 10 || t > 600 {
			return fmt.Errorf("validation failed: reservationTimeoutSeconds must be in [10, 600], got %d", t)
		}
	}

	if gang.Spec.PodTemplate.Spec.RequestedVRAMBytes <= 0 {
		return fmt.Errorf("validation failed: podTemplate.spec.requestedVramBytes must be > 0")
	}
	const maxVRAMBytes = int64(85_899_345_920) // 80 GiB
	if gang.Spec.PodTemplate.Spec.RequestedVRAMBytes > maxVRAMBytes {
		return fmt.Errorf("validation failed: podTemplate.spec.requestedVramBytes %d exceeds max %d",
			gang.Spec.PodTemplate.Spec.RequestedVRAMBytes, maxVRAMBytes)
	}

	tier := gang.Spec.PodTemplate.Spec.ServiceTier
	if tier != "" &&
		tier != vgpuv1alpha1.ServiceTierGuaranteed &&
		tier != vgpuv1alpha1.ServiceTierBestEffort {
		return fmt.Errorf("validation failed: unsupported ServiceTier %q in podTemplate", tier)
	}

	return nil
}

// ValidateGangJobUpdate prevents post-creation mutation of fields that the
// reservation has already been built from. After admission, the reservation
// CRD has already denormalized GangSize and ChildClaims; mutating the gang
// would create state divergence the reconciler can't resolve.
func ValidateGangJobUpdate(ctx context.Context, oldGang, newGang *vgpuv1alpha1.VGPUGangJob) error {
	if oldGang.Spec.GangSize != newGang.Spec.GangSize {
		return fmt.Errorf("immutability violation: cannot change gangSize after creation")
	}
	if oldGang.Spec.MinAvailable != newGang.Spec.MinAvailable {
		return fmt.Errorf("immutability violation: cannot change minAvailable after creation")
	}
	if oldGang.Spec.PodTemplate.Spec.RequestedVRAMBytes != newGang.Spec.PodTemplate.Spec.RequestedVRAMBytes {
		return fmt.Errorf("immutability violation: cannot change podTemplate.spec.requestedVramBytes after creation")
	}
	return nil
}
