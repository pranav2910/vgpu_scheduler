package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// VGPUGangJobPhase tracks the lifecycle of an entire gang. It is intentionally
// distinct from VGPUJobPhase because gang-level transitions ("waiting for the
// last sibling to bind", "rolling back because slot 3 of 4 failed") have no
// per-job analogue.
type VGPUGangJobPhase string

const (
	// GangPhasePending: gang has been admitted but no children created yet.
	GangPhasePending VGPUGangJobPhase = "Pending"

	// GangPhaseMaterializing: child VGPUJobs are being created.
	GangPhaseMaterializing VGPUGangJobPhase = "Materializing"

	// GangPhaseReserving: all children created; reservation in flight.
	GangPhaseReserving VGPUGangJobPhase = "Reserving"

	// GangPhaseRunning: all N child slices bound. Steady state.
	GangPhaseRunning VGPUGangJobPhase = "Running"

	// GangPhaseFailed: reservation could not be satisfied or a child failed
	// after binding. Children are torn down on entry to this state.
	GangPhaseFailed VGPUGangJobPhase = "Failed"

	// GangPhaseCompleted: all children released cleanly.
	GangPhaseCompleted VGPUGangJobPhase = "Completed"
)

// VGPUGangJobSpec is the user-facing intent for an all-or-nothing gang of
// N identical workloads. Strict mode only in v1: the gang either schedules
// all gangSize members or none. Elastic gangs (minAvailable < gangSize) are
// rejected by the validating webhook.
type VGPUGangJobSpec struct {
	// GangSize is the number of identical workloads that must be scheduled
	// together. Range 2-256 — gangs of 1 should use plain VGPUJob.
	// +kubebuilder:validation:Minimum=2
	// +kubebuilder:validation:Maximum=256
	GangSize int32 `json:"gangSize"`

	// MinAvailable is the minimum number of children that must be schedulable
	// for the gang to commit. v1 enforces MinAvailable == GangSize via the
	// validating webhook; the field exists in the API for forward compatibility
	// with elastic gangs in v2.
	// +kubebuilder:validation:Minimum=2
	// +kubebuilder:validation:Maximum=256
	MinAvailable int32 `json:"minAvailable"`

	// ReservationTimeoutSeconds is how long the gang will sit in Reserving
	// before failing back. Default 60s. Capped at 600s so a misconfigured
	// gang can't sit on cluster capacity indefinitely.
	// +kubebuilder:validation:Minimum=10
	// +kubebuilder:validation:Maximum=600
	// +kubebuilder:default=60
	// +optional
	ReservationTimeoutSeconds *int32 `json:"reservationTimeoutSeconds,omitempty"`

	// Priority is the scheduling priority applied to every child Job (0-1000).
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=1000
	// +kubebuilder:default=50
	Priority int32 `json:"priority,omitempty"`

	// WorkloadClass is propagated to every child Job. Defaults to Training
	// (gangs are overwhelmingly distributed-training shaped).
	// +kubebuilder:validation:Enum=Training;Inference;Batch;Interactive
	// +kubebuilder:default=Training
	WorkloadClass WorkloadClass `json:"workloadClass,omitempty"`

	// Preemptible is propagated to every child Job. Note: in v1 a preemptible
	// gang's children can be preempted individually by single-slice preemption.
	// True gang-aware preemption (atomic eviction of an entire victim gang)
	// lands in Phase 2.4b.
	// +kubebuilder:default=false
	Preemptible bool `json:"preemptible,omitempty"`

	// PreemptionGraceSeconds is propagated to every child Job.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=3600
	// +optional
	PreemptionGraceSeconds *int32 `json:"preemptionGraceSeconds,omitempty"`

	// PodTemplate carries the per-child resource shape. Every child uses
	// identical resource asks (gang scheduling assumes homogeneity).
	PodTemplate VGPUGangPodTemplate `json:"podTemplate"`
}

// VGPUGangPodTemplate is the per-child resource template. Mirrors the shape
// of VGPUClaimTemplate so existing claim validation continues to apply.
type VGPUGangPodTemplate struct {
	Spec VGPUClaimSpec `json:"spec"`
}

// VGPUGangJobStatus reports observed state of the gang.
type VGPUGangJobStatus struct {
	Phase VGPUGangJobPhase `json:"phase,omitempty"`

	// ReservationRef is the name of the VGPUGangReservation tracking
	// atomic-reserve state for this gang.
	ReservationRef string `json:"reservationRef,omitempty"`

	// ChildrenCreated is the number of child VGPUJobs successfully created
	// by the reconciler so far. Should equal Spec.GangSize once
	// Phase == Reserving or later.
	ChildrenCreated int32 `json:"childrenCreated,omitempty"`

	// ChildrenRunning is the number of child VGPUJobs whose underlying slice
	// is in phase Ready. When this equals Spec.GangSize the gang is Running.
	ChildrenRunning int32 `json:"childrenRunning,omitempty"`

	Message string `json:"message,omitempty"`

	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Size",type=integer,JSONPath=`.spec.gangSize`
// +kubebuilder:printcolumn:name="Class",type=string,JSONPath=`.spec.workloadClass`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Running",type=integer,JSONPath=`.status.childrenRunning`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type VGPUGangJob struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUGangJobSpec   `json:"spec,omitempty"`
	Status VGPUGangJobStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type VGPUGangJobList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUGangJob `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUGangJob{}, &VGPUGangJobList{})
}

// ─────────────────────────── deep-copy plumbing ──────────────────────────────

func (g *VGPUGangJob) DeepCopyObject() runtime.Object {
	if g == nil {
		return nil
	}
	out := new(VGPUGangJob)
	g.DeepCopyInto(out)
	return out
}

func (l *VGPUGangJobList) DeepCopyObject() runtime.Object {
	if l == nil {
		return nil
	}
	out := new(VGPUGangJobList)
	l.DeepCopyInto(out)
	return out
}

func (g *VGPUGangJob) DeepCopyInto(out *VGPUGangJob) {
	*out = *g
	out.TypeMeta = g.TypeMeta
	g.ObjectMeta.DeepCopyInto(&out.ObjectMeta)

	out.Spec = g.Spec
	out.Spec.PodTemplate.Spec = g.Spec.PodTemplate.Spec
	if g.Spec.ReservationTimeoutSeconds != nil {
		val := *g.Spec.ReservationTimeoutSeconds
		out.Spec.ReservationTimeoutSeconds = &val
	}
	if g.Spec.PreemptionGraceSeconds != nil {
		val := *g.Spec.PreemptionGraceSeconds
		out.Spec.PreemptionGraceSeconds = &val
	}

	out.Status = g.Status
	if g.Status.Conditions != nil {
		out.Status.Conditions = make([]metav1.Condition, len(g.Status.Conditions))
		for i := range g.Status.Conditions {
			g.Status.Conditions[i].DeepCopyInto(&out.Status.Conditions[i])
		}
	}
}

func (l *VGPUGangJobList) DeepCopyInto(out *VGPUGangJobList) {
	*out = *l
	out.TypeMeta = l.TypeMeta
	l.ListMeta.DeepCopyInto(&out.ListMeta)
	if l.Items != nil {
		out.Items = make([]VGPUGangJob, len(l.Items))
		for i := range l.Items {
			l.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (g *VGPUGangJob) DeepCopy() *VGPUGangJob {
	if g == nil {
		return nil
	}
	out := new(VGPUGangJob)
	g.DeepCopyInto(out)
	return out
}

func (l *VGPUGangJobList) DeepCopy() *VGPUGangJobList {
	if l == nil {
		return nil
	}
	out := new(VGPUGangJobList)
	l.DeepCopyInto(out)
	return out
}

// ─────────────────────────── helpers ─────────────────────────────────────────

// LabelGangParent is stamped on every child VGPUJob so the gang reconciler
// can find its children by label selector. Also used by the scheduler's gang
// detection helper to route slices through the gang path.
const LabelGangParent = "gang.vgpu.pranav2910.com/parent"

// LabelGangIndex is stamped on every child VGPUJob with its 0-based index in
// the gang. Useful for stable identity ("rank 3 of 8") in distributed-training
// frameworks.
const LabelGangIndex = "gang.vgpu.pranav2910.com/index"
