package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VGPUClaimSpec defines the desired state of VGPUClaim (Owned by User)
type VGPUClaimSpec struct {
	// RequestedVRAMBytes specifies the exact amount of GPU memory required in bytes (e.g. 8589934592 for 8 GiB).
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=85899345920
	RequestedVRAMBytes int64 `json:"requestedVramBytes"`

	// ServiceTier enforces the workload isolation priority.
	// +kubebuilder:validation:Enum=Guaranteed;BestEffort
	// +kubebuilder:default=Guaranteed
	ServiceTier ServiceTier `json:"serviceTier,omitempty"`

	// JobRef is the name of the parent VGPUJob in the same namespace,
	// if this claim was created by a Job. Empty for standalone claims.
	// +optional
	JobRef string `json:"jobRef,omitempty"`
}

// VGPUClaimStatus defines the observed state of VGPUClaim (Owned by Controller)
type VGPUClaimStatus struct {
	// Phase tracks the high-level scheduling state.
	// +kubebuilder:default=Pending
	Phase VGPUClaimPhase `json:"phase,omitempty"`

	// BoundSliceName is the exact name of the VGPUSlice fulfilling this claim.
	// +kubebuilder:validation:Optional
	BoundSliceName string `json:"boundSliceName,omitempty"`

	// FailureReason is a machine-readable failure code (e.g. NoCapacity, NodeUnhealthy).
	// +kubebuilder:validation:Optional
	FailureReason string `json:"failureReason,omitempty"`

	// Conditions hold structured state transitions and failure reasons.
	// +kubebuilder:validation:Optional
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="VRAM",type="integer",JSONPath=".spec.requestedVramBytes",description="Requested VRAM bytes"
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase",description="Current Phase"
// +kubebuilder:printcolumn:name="Slice",type="string",JSONPath=".status.boundSliceName",description="Bound Slice"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// VGPUClaim is the Schema for the vgpuclaims API
type VGPUClaim struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUClaimSpec   `json:"spec,omitempty"`
	Status VGPUClaimStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// VGPUClaimList contains a list of VGPUClaim
type VGPUClaimList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUClaim `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUClaim{}, &VGPUClaimList{})
}
