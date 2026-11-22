package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// VGPUGangReservationPhase tracks the atomic-reserve-or-rollback state machine.
// This is intentionally finer-grained than VGPUGangJobPhase because the
// scheduler has to make hard reserve/bind decisions at this level.
type VGPUGangReservationPhase string

const (
	// ReservationPhasePending: created, scheduler hasn't picked it up yet.
	ReservationPhasePending VGPUGangReservationPhase = "Pending"

	// ReservationPhaseReserving: scheduler is processing child slices.
	// Successful Reserves increment ReservedSlots. Filter failures
	// increment FailedSlots. The reservation transitions out of this phase
	// when ReservedSlots == GangSize OR when timeout elapses OR when the
	// remaining unreserved slots can no longer fit.
	ReservationPhaseReserving VGPUGangReservationPhase = "Reserving"

	// ReservationPhaseReserved: all GangSize child slices are speculatively
	// reserved in the cluster. Scheduler is permitted to start binding
	// (transitioning slices to Allocating) only when this phase is reached.
	ReservationPhaseReserved VGPUGangReservationPhase = "Reserved"

	// ReservationPhaseCommitted: all child slices are bound (Ready phase).
	// The gang is running.
	ReservationPhaseCommitted VGPUGangReservationPhase = "Committed"

	// ReservationPhaseFailed: reservation could not be satisfied. Reconciler
	// drives child-slice teardown and frees cache reservations.
	ReservationPhaseFailed VGPUGangReservationPhase = "Failed"

	// ReservationPhaseReleased: terminal. All child slices released.
	ReservationPhaseReleased VGPUGangReservationPhase = "Released"
)

// VGPUGangReservationSpec captures the contract between the gang reconciler
// and the scheduler. The reconciler creates the reservation; the scheduler
// drives state transitions.
type VGPUGangReservationSpec struct {
	// GangRef is the name of the parent VGPUGangJob (same namespace).
	GangRef string `json:"gangRef"`

	// GangSize is denormalized from the parent for fast scheduler reads
	// without an extra Get on every Reserve attempt.
	// +kubebuilder:validation:Minimum=2
	// +kubebuilder:validation:Maximum=256
	GangSize int32 `json:"gangSize"`

	// ChildClaims is the list of child VGPUClaim names (same namespace) that
	// must be atomically reserved together. Length must equal GangSize at
	// creation time; the gang reconciler doesn't add more later.
	ChildClaims []string `json:"childClaims"`

	// DeadlineSeconds bounds how long the scheduler will sit in Reserving
	// before failing the reservation. Defaults to 60s if unset.
	// +kubebuilder:validation:Minimum=10
	// +kubebuilder:validation:Maximum=600
	// +optional
	DeadlineSeconds *int32 `json:"deadlineSeconds,omitempty"`
}

// VGPUGangReservationStatus reports observed reserve-or-rollback state. This
// is the kubectl-observable surface that delivers the "every scheduling
// decision is explainable" wedge.
type VGPUGangReservationStatus struct {
	Phase VGPUGangReservationPhase `json:"phase,omitempty"`

	// ReservedSlots is the count of child claims for which the scheduler has
	// successfully completed Reserve (cache speculative-locked, slice in
	// Scheduled phase). Transitions Reserving → Reserved when this equals
	// Spec.GangSize.
	ReservedSlots int32 `json:"reservedSlots,omitempty"`

	// FailedSlots is the count of child claims that hit a hard scheduling
	// failure (no node has capacity, quota exceeded, etc.). When this is
	// non-zero on transition to Reserved, the reservation goes Failed instead.
	FailedSlots int32 `json:"failedSlots,omitempty"`

	// CommittedSlots is the count of child slices that have transitioned to
	// Ready. When this equals GangSize, phase becomes Committed.
	CommittedSlots int32 `json:"committedSlots,omitempty"`

	// PerSliceState is a compact, kubectl-friendly map from child claim name
	// to its current scheduling status ("Pending", "Reserved", "Bound",
	// "FailedNoCapacity", etc.). This is the diagnostic field operators read
	// when asking "why is my distributed job pending?"
	PerSliceState map[string]string `json:"perSliceState,omitempty"`

	// FirstReservingTime is when the reservation first entered Reserving.
	// Used by the scheduler to enforce DeadlineSeconds.
	FirstReservingTime *metav1.Time `json:"firstReservingTime,omitempty"`

	// FailureReason is human-readable text explaining a Failed transition.
	// e.g. "no node has capacity for slot 4 (claim training-3)".
	FailureReason string `json:"failureReason,omitempty"`

	Message string `json:"message,omitempty"`

	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Gang",type=string,JSONPath=`.spec.gangRef`
// +kubebuilder:printcolumn:name="Size",type=integer,JSONPath=`.spec.gangSize`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Reserved",type=integer,JSONPath=`.status.reservedSlots`
// +kubebuilder:printcolumn:name="Failed",type=integer,JSONPath=`.status.failedSlots`
// +kubebuilder:printcolumn:name="Committed",type=integer,JSONPath=`.status.committedSlots`
// +kubebuilder:printcolumn:name="Reason",type=string,JSONPath=`.status.failureReason`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type VGPUGangReservation struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUGangReservationSpec   `json:"spec,omitempty"`
	Status VGPUGangReservationStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type VGPUGangReservationList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUGangReservation `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUGangReservation{}, &VGPUGangReservationList{})
}

// ─────────────────────────── deep-copy plumbing ──────────────────────────────

func (r *VGPUGangReservation) DeepCopyObject() runtime.Object {
	if r == nil {
		return nil
	}
	out := new(VGPUGangReservation)
	r.DeepCopyInto(out)
	return out
}

func (l *VGPUGangReservationList) DeepCopyObject() runtime.Object {
	if l == nil {
		return nil
	}
	out := new(VGPUGangReservationList)
	l.DeepCopyInto(out)
	return out
}

func (r *VGPUGangReservation) DeepCopyInto(out *VGPUGangReservation) {
	*out = *r
	out.TypeMeta = r.TypeMeta
	r.ObjectMeta.DeepCopyInto(&out.ObjectMeta)

	out.Spec = r.Spec
	if r.Spec.ChildClaims != nil {
		out.Spec.ChildClaims = make([]string, len(r.Spec.ChildClaims))
		copy(out.Spec.ChildClaims, r.Spec.ChildClaims)
	}
	if r.Spec.DeadlineSeconds != nil {
		val := *r.Spec.DeadlineSeconds
		out.Spec.DeadlineSeconds = &val
	}

	out.Status = r.Status
	if r.Status.PerSliceState != nil {
		out.Status.PerSliceState = make(map[string]string, len(r.Status.PerSliceState))
		for k, v := range r.Status.PerSliceState {
			out.Status.PerSliceState[k] = v
		}
	}
	if r.Status.FirstReservingTime != nil {
		t := *r.Status.FirstReservingTime
		out.Status.FirstReservingTime = &t
	}
	if r.Status.Conditions != nil {
		out.Status.Conditions = make([]metav1.Condition, len(r.Status.Conditions))
		for i := range r.Status.Conditions {
			r.Status.Conditions[i].DeepCopyInto(&out.Status.Conditions[i])
		}
	}
}

func (l *VGPUGangReservationList) DeepCopyInto(out *VGPUGangReservationList) {
	*out = *l
	out.TypeMeta = l.TypeMeta
	l.ListMeta.DeepCopyInto(&out.ListMeta)
	if l.Items != nil {
		out.Items = make([]VGPUGangReservation, len(l.Items))
		for i := range l.Items {
			l.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (r *VGPUGangReservation) DeepCopy() *VGPUGangReservation {
	if r == nil {
		return nil
	}
	out := new(VGPUGangReservation)
	r.DeepCopyInto(out)
	return out
}

func (l *VGPUGangReservationList) DeepCopy() *VGPUGangReservationList {
	if l == nil {
		return nil
	}
	out := new(VGPUGangReservationList)
	l.DeepCopyInto(out)
	return out
}

// ─────────────────────────── helpers ─────────────────────────────────────────

// AnnotationReservationRef is stamped on each child VGPUSlice so the scheduler
// can walk slice → reservation in O(1) without a List call.
const AnnotationReservationRef = "gang.vgpu.pranav2910.com/reservation"

// AnnotationGangRef is stamped on each child VGPUClaim/VGPUSlice with the
// parent gang's name. Faster lookup than walking labels for the gang
// reconciler when iterating over children.
const AnnotationGangRef = "gang.vgpu.pranav2910.com/gang"

// AnnotationGangPriority is stamped on each child VGPUClaim/VGPUSlice with the
// parent gang's scheduling priority (as a decimal string). The scheduler's
// gang admission gate reads it to order which gang may hold capacity when the
// serialized admission slot is free (priority desc → age asc → name asc), so
// priority can influence gang admission without a CRD lookup on the hot path.
const AnnotationGangPriority = "gang.vgpu.pranav2910.com/priority"

// IsTerminalReservationPhase returns true if no further state transitions
// are valid from the given phase.
func IsTerminalReservationPhase(p VGPUGangReservationPhase) bool {
	return p == ReservationPhaseReleased || p == ReservationPhaseFailed
}
