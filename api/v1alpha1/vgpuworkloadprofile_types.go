package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// Phase 3.5 — Runtime Feedback Engine. A VGPUWorkloadProfile is the learned
// GPU-memory behavior of a workload (a VGPUJob), aggregated by the controller
// from per-slice observations the node agent records. It is OBSERVE-ONLY: the
// scheduler does not act on it in 3.5 (that is 3.6). Profiles have no owner
// reference, so they survive job deletion and accumulate across re-runs.

// ProfileConfidence expresses how trustworthy a profile's recommendation is.
type ProfileConfidence string

const (
	ProfileConfidenceLow    ProfileConfidence = "Low"
	ProfileConfidenceMedium ProfileConfidence = "Medium"
	ProfileConfidenceHigh   ProfileConfidence = "High"
)

const (
	// ProfileHeadroomPercent is the safety margin added to the observed peak when
	// recommending a VRAM grant (Phase 3.5 default: 15%).
	ProfileHeadroomPercent = 15
	// profileConfidenceMediumMin / profileConfidenceHighMin are the observation
	// thresholds for Medium / High confidence.
	profileConfidenceMediumMin = 20
	profileConfidenceHighMin   = 100
)

// RecommendedVRAMBytes returns the recommended grant for an observed peak:
// peak × (1 + headroom). Returns 0 for a non-positive peak.
func RecommendedVRAMBytes(peakBytes int64) int64 {
	if peakBytes <= 0 {
		return 0
	}
	return peakBytes + peakBytes*ProfileHeadroomPercent/100
}

// Confidence grades a recommendation from the sample count and whether the peak
// has stabilized. High requires BOTH enough samples AND a peak that has stopped
// growing — a still-climbing peak means the true maximum may not be known yet.
func Confidence(observations int64, peakStable bool) ProfileConfidence {
	switch {
	case observations < profileConfidenceMediumMin:
		return ProfileConfidenceLow
	case observations < profileConfidenceHighMin:
		return ProfileConfidenceMedium
	case !peakStable:
		return ProfileConfidenceMedium
	default:
		return ProfileConfidenceHigh
	}
}

// VGPUWorkloadProfileSpec links a profile to the workload it describes.
type VGPUWorkloadProfileSpec struct {
	// WorkloadRef is the VGPUJob name this profile aggregates (same namespace).
	// +optional
	WorkloadRef string `json:"workloadRef,omitempty"`
}

// VGPUWorkloadProfileStatus is the learned GPU-memory behavior of a workload.
// Entirely observed; the scheduler does not act on it in Phase 3.5.
type VGPUWorkloadProfileStatus struct {
	// Observations is the high-water sample count across the workload's slices.
	// +optional
	Observations int64 `json:"observations,omitempty"`
	// RequestedVRAMBytes is the workload's current per-slice grant.
	// +optional
	RequestedVRAMBytes int64 `json:"requestedVramBytes,omitempty"`
	// PeakObservedVRAMBytes is the max attributed GPU memory ever seen (monotonic).
	// +optional
	PeakObservedVRAMBytes int64 `json:"peakObservedVramBytes,omitempty"`
	// AvgObservedVRAMBytes is a recency-weighted average of observed use.
	// +optional
	AvgObservedVRAMBytes int64 `json:"avgObservedVramBytes,omitempty"`
	// RecommendedVRAMBytes is peak × (1 + headroom) — what the grant should be.
	// +optional
	RecommendedVRAMBytes int64 `json:"recommendedVramBytes,omitempty"`
	// ViolationCount / SoftWarnCount / EvictionCount are high-water incident counts.
	// +optional
	ViolationCount int64 `json:"violationCount,omitempty"`
	// +optional
	SoftWarnCount int64 `json:"softWarnCount,omitempty"`
	// +optional
	EvictionCount int64 `json:"evictionCount,omitempty"`
	// Confidence is Low | Medium | High.
	// +optional
	Confidence ProfileConfidence `json:"confidence,omitempty"`
	// LastUpdated is when the controller last refreshed this profile.
	// +optional
	LastUpdated *metav1.Time `json:"lastUpdated,omitempty"`
	// Conditions hold structured state (e.g. Underprovisioned).
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Requested",type=integer,JSONPath=`.status.requestedVramBytes`
// +kubebuilder:printcolumn:name="Peak",type=integer,JSONPath=`.status.peakObservedVramBytes`
// +kubebuilder:printcolumn:name="Recommended",type=integer,JSONPath=`.status.recommendedVramBytes`
// +kubebuilder:printcolumn:name="Confidence",type=string,JSONPath=`.status.confidence`
// +kubebuilder:printcolumn:name="Evictions",type=integer,JSONPath=`.status.evictionCount`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// VGPUWorkloadProfile is the learned GPU-memory behavior profile of a workload.
type VGPUWorkloadProfile struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUWorkloadProfileSpec   `json:"spec,omitempty"`
	Status VGPUWorkloadProfileStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// VGPUWorkloadProfileList contains a list of VGPUWorkloadProfile.
type VGPUWorkloadProfileList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUWorkloadProfile `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUWorkloadProfile{}, &VGPUWorkloadProfileList{})
}

// ── hand-written deepcopy (no controller-gen in this repo) ───────────────────

func (p *VGPUWorkloadProfile) DeepCopyObject() runtime.Object {
	if p == nil {
		return nil
	}
	out := new(VGPUWorkloadProfile)
	p.DeepCopyInto(out)
	return out
}

func (p *VGPUWorkloadProfile) DeepCopy() *VGPUWorkloadProfile {
	if p == nil {
		return nil
	}
	out := new(VGPUWorkloadProfile)
	p.DeepCopyInto(out)
	return out
}

func (p *VGPUWorkloadProfile) DeepCopyInto(out *VGPUWorkloadProfile) {
	*out = *p
	out.TypeMeta = p.TypeMeta
	p.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = p.Spec
	p.Status.DeepCopyInto(&out.Status)
}

func (s *VGPUWorkloadProfileStatus) DeepCopyInto(out *VGPUWorkloadProfileStatus) {
	*out = *s
	if s.LastUpdated != nil {
		out.LastUpdated = &metav1.Time{Time: s.LastUpdated.Time}
	}
	if s.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(s.Conditions))
		for i := range s.Conditions {
			s.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
}

func (l *VGPUWorkloadProfileList) DeepCopyObject() runtime.Object {
	if l == nil {
		return nil
	}
	out := new(VGPUWorkloadProfileList)
	l.DeepCopyInto(out)
	return out
}

func (l *VGPUWorkloadProfileList) DeepCopy() *VGPUWorkloadProfileList {
	if l == nil {
		return nil
	}
	out := new(VGPUWorkloadProfileList)
	l.DeepCopyInto(out)
	return out
}

func (l *VGPUWorkloadProfileList) DeepCopyInto(out *VGPUWorkloadProfileList) {
	*out = *l
	out.TypeMeta = l.TypeMeta
	l.ListMeta.DeepCopyInto(&out.ListMeta)
	if l.Items != nil {
		out.Items = make([]VGPUWorkloadProfile, len(l.Items))
		for i := range l.Items {
			l.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}
