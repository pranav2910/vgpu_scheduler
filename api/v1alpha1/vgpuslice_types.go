package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VGPUSliceSpec defines the desired hardware state (Owned by Controller)
type VGPUSliceSpec struct {
	// ClaimRef is the name of the VGPUClaim this slice satisfies.
	// +kubebuilder:validation:Required
	ClaimRef string `json:"claimRef"`

	// NodeName is populated by the Scheduler once placement is decided.
	// +kubebuilder:validation:Optional
	NodeName string `json:"nodeName,omitempty"`

	// RequestedVRAMBytes is the exact memory to carve out on the physical hardware, in bytes.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	RequestedVRAMBytes int64 `json:"requestedVramBytes"`
}

// VGPUSliceStatus defines the observed hardware state (Split Ownership: NodeAgent / Controller)
type VGPUSliceStatus struct {
	// Phase tracks the hardware allocation lifecycle.
	// +kubebuilder:default=Pending
	Phase VGPUSlicePhase `json:"phase,omitempty"`

	// DeviceUUID is the physical NVIDIA UUID of the isolated partition.
	// Must be populated before transitioning to Ready.
	// +kubebuilder:validation:Optional
	DeviceUUID string `json:"deviceUuid,omitempty"`

	// AllocationID is the durable identifier written to the on-disk checkpoint.
	// Required for Ready and Releasing states.
	// +kubebuilder:validation:Optional
	AllocationID string `json:"allocationId,omitempty"`

	// AllocatedBytes is the actual number of bytes locked on the physical device.
	// +kubebuilder:validation:Optional
	AllocatedBytes int64 `json:"allocatedBytes,omitempty"`

	// FailureReason provides a machine-readable failure code for fast ops debugging.
	// +kubebuilder:validation:Optional
	FailureReason string `json:"failureReason,omitempty"`

	// LastError provides a human-readable failure message.
	// +kubebuilder:validation:Optional
	LastError string `json:"lastError,omitempty"`

	// Conditions hold structured state transitions (e.g., IsolationVerified).
	// +kubebuilder:validation:Optional
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`

	// ── Phase 3.5 runtime feedback (written by the node agent, observe-only) ──
	// Accumulated GPU-memory behavior for this slice. The controller aggregates
	// these per workload into a VGPUWorkloadProfile. Never affects scheduling.

	// ObservedVRAMBytes is the most recent attributed GPU memory use, in bytes.
	// +optional
	ObservedVRAMBytes int64 `json:"observedVramBytes,omitempty"`
	// PeakObservedVRAMBytes is the maximum attributed GPU memory ever observed (monotonic).
	// +optional
	PeakObservedVRAMBytes int64 `json:"peakObservedVramBytes,omitempty"`
	// AvgObservedVRAMBytes is a recency-weighted (EWMA) average of observed use.
	// +optional
	AvgObservedVRAMBytes int64 `json:"avgObservedVramBytes,omitempty"`
	// Observations is the number of accumulated samples (cumulative).
	// +optional
	Observations int64 `json:"observations,omitempty"`
	// ViolationCount counts sustained over-use onsets (3.4b), cumulative.
	// +optional
	ViolationCount int64 `json:"violationCount,omitempty"`
	// SoftWarnCount counts soft-enforcement engagements (3.4c), cumulative.
	// +optional
	SoftWarnCount int64 `json:"softWarnCount,omitempty"`
	// EvictionCount counts evictions (3.4d), cumulative.
	// +optional
	EvictionCount int64 `json:"evictionCount,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Node",type="string",JSONPath=".spec.nodeName",description="Assigned Node"
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase",description="Current Phase"
// +kubebuilder:printcolumn:name="UUID",type="string",JSONPath=".status.deviceUuid",description="Physical Device UUID"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// VGPUSlice is the Schema for the vgpuslices API
type VGPUSlice struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUSliceSpec   `json:"spec,omitempty"`
	Status VGPUSliceStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// VGPUSliceList contains a list of VGPUSlice
type VGPUSliceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUSlice `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUSlice{}, &VGPUSliceList{})
}

// PhasePreempting is the slice phase during graceful pre-eviction (Phase 2.3).
const PhasePreempting = "Preempting"
