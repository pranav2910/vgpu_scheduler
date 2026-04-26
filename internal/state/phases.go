package state

// Claim Phases (User Intent)
const (
	ClaimPhasePending      = "Pending"      // Waiting for scheduler
	ClaimPhaseSliceCreated = "SliceCreated" // Slice exists, awaiting node
	ClaimPhaseScheduled    = "Scheduled"    // Node assigned, awaiting hardware
	ClaimPhaseBound        = "Bound"        // Hardware allocated and ready
	ClaimPhaseFailed       = "Failed"       // Irrecoverable error
	ClaimPhaseDeleting     = "Deleting"     // Pending cleanup
)

// Slice Phases (System Execution)
const (
	SlicePhasePending    = "Pending"    // Awaiting scheduler
	SlicePhaseScheduled  = "Scheduled"  // Node assigned via spec.nodeName
	SlicePhaseAllocating = "Allocating" // NodeAgent is building the CDI firewall
	SlicePhaseReady      = "Ready"      // Hardware is locked and usable
	SlicePhaseReleasing  = "Releasing"  // NodeAgent is tearing down CDI
	SlicePhaseReleased   = "Released"   // Hardware is free, awaiting finalizer removal
	SlicePhaseFailed     = "Failed"     // Hardware allocation crashed
)

// Canonical Failure Reasons
const (
	ReasonValidationFailed    = "ValidationFailed"
	ReasonNoCapacity          = "NoCapacity"
	ReasonNodeUnhealthy       = "NodeUnhealthy"
	ReasonAllocationFailed    = "AllocationFailed"
	ReasonDriftDetected       = "DriftDetected"
	ReasonCheckpointCorrupted = "CheckpointCorrupted"
)
