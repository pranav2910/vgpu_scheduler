package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// VGPUQuotaSpec defines a namespace-level VRAM quota.
//
// The quota is cluster-scoped (an admin concern, not a tenant-managed
// resource), but applies to a specific namespace via TargetNamespace.
//
// Phase 2.2a semantics:
//   - If a quota exists for a namespace, requests that would push usage above
//     MaxVramBytes are rejected at scheduling time.
//   - If no quota exists, requests proceed unrestricted ("no quota = unlimited").
//   - Already-running slices are NOT evicted if the quota is lowered later.
//     Eviction is a preemption concern (Phase 2.3).
type VGPUQuotaSpec struct {
	// TargetNamespace is the namespace this quota applies to.
	// +kubebuilder:validation:Required
	TargetNamespace string `json:"targetNamespace"`

	// MaxVramBytes is the maximum aggregate VRAM (in bytes) that all VGPUSlices
	// in TargetNamespace are allowed to consume simultaneously.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	MaxVramBytes int64 `json:"maxVramBytes"`

	// Description is a human-readable note for admins.
	Description string `json:"description,omitempty"`
}

// VGPUQuotaStatus reports observed usage against the quota.
type VGPUQuotaStatus struct {
	// UsedVramBytes is the sum of allocatedBytes across all Ready slices
	// in TargetNamespace, refreshed periodically by the QuotaReconciler.
	UsedVramBytes int64 `json:"usedVramBytes,omitempty"`

	// LastUpdated is when the QuotaReconciler last refreshed UsedVramBytes.
	LastUpdated metav1.Time `json:"lastUpdated,omitempty"`

	// Conditions follow the standard Kubernetes condition pattern.
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Namespace",type=string,JSONPath=`.spec.targetNamespace`
// +kubebuilder:printcolumn:name="Max",type=integer,JSONPath=`.spec.maxVramBytes`
// +kubebuilder:printcolumn:name="Used",type=integer,JSONPath=`.status.usedVramBytes`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type VGPUQuota struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUQuotaSpec   `json:"spec,omitempty"`
	Status VGPUQuotaStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type VGPUQuotaList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUQuota `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUQuota{}, &VGPUQuotaList{})
}

func (q *VGPUQuota) DeepCopyObject() runtime.Object {
	if q == nil {
		return nil
	}
	out := new(VGPUQuota)
	q.DeepCopyInto(out)
	return out
}

func (l *VGPUQuotaList) DeepCopyObject() runtime.Object {
	if l == nil {
		return nil
	}
	out := new(VGPUQuotaList)
	l.DeepCopyInto(out)
	return out
}

func (q *VGPUQuota) DeepCopyInto(out *VGPUQuota) {
	*out = *q
	out.TypeMeta = q.TypeMeta
	q.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = q.Spec
	out.Status.UsedVramBytes = q.Status.UsedVramBytes
	q.Status.LastUpdated.DeepCopyInto(&out.Status.LastUpdated)
	if q.Status.Conditions != nil {
		out.Status.Conditions = make([]metav1.Condition, len(q.Status.Conditions))
		for i := range q.Status.Conditions {
			q.Status.Conditions[i].DeepCopyInto(&out.Status.Conditions[i])
		}
	}
}

func (l *VGPUQuotaList) DeepCopyInto(out *VGPUQuotaList) {
	*out = *l
	out.TypeMeta = l.TypeMeta
	l.ListMeta.DeepCopyInto(&out.ListMeta)
	if l.Items != nil {
		out.Items = make([]VGPUQuota, len(l.Items))
		for i := range l.Items {
			l.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}
