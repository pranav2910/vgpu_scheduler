package v1alpha1

// ServiceTier defines the strictness of the VRAM reservation.
type ServiceTier string

const (
	// ServiceTierGuaranteed ensures strict VRAM reservation and zero preemption.
	ServiceTierGuaranteed ServiceTier = "Guaranteed"
	// ServiceTierBestEffort allows flexible placement but may be preempted.
	ServiceTierBestEffort ServiceTier = "BestEffort"
)

// VGPUClaimPhase represents the current lifecycle state of a Claim.
// Authoritative phase string values are defined in internal/state/phases.go.
type VGPUClaimPhase string

// VGPUSlicePhase represents the physical hardware allocation state.
// Authoritative phase string values are defined in internal/state/phases.go.
type VGPUSlicePhase string

// Common Condition Types used across Claims and Slices.
const (
	ConditionTypeScheduled = "Scheduled"
	ConditionTypeAllocated = "Allocated"
	ConditionTypeReady     = "Ready"
)
