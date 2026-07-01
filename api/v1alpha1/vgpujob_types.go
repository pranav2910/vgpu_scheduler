package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// WorkloadClass categorizes a workload so the scheduler can apply class-aware
// scoring. The categories are intentionally small for Phase 2.1a; they exist
// primarily so policy can hang off them in later phases.
type WorkloadClass string

const (
	WorkloadClassTraining    WorkloadClass = "Training"
	WorkloadClassInference   WorkloadClass = "Inference"
	WorkloadClassBatch       WorkloadClass = "Batch"
	WorkloadClassInteractive WorkloadClass = "Interactive"
)

// VGPUJobPhase mirrors the lifecycle of the underlying claim/slice but
// adds Job-level states (Pending, Failed, Completed) that don't exist
// at the slice level.
type VGPUJobPhase string

const (
	JobPhasePending      VGPUJobPhase = "Pending"
	JobPhaseClaimCreated VGPUJobPhase = "ClaimCreated"
	JobPhaseScheduled    VGPUJobPhase = "Scheduled"
	// JobPhasePodCreating: the slice is allocated and the controller has created
	// (or is creating) the workload Pod from podTemplate. Only reachable when
	// podTemplate is set.
	JobPhasePodCreating VGPUJobPhase = "PodCreating"
	JobPhaseRunning     VGPUJobPhase = "Running"
	// JobPhaseSucceeded: the workload Pod ran to completion (exit 0). Distinct
	// from Completed (which tracks claim release).
	JobPhaseSucceeded VGPUJobPhase = "Succeeded"
	JobPhaseFailed    VGPUJobPhase = "Failed"
	JobPhaseCompleted VGPUJobPhase = "Completed"
)

// VGPUClaimTemplate is the embedded spec used by VGPUJob to materialize a
// VGPUClaim. We reuse the existing VGPUClaimSpec verbatim so existing claim
// validation rules continue to apply.
type VGPUClaimTemplate struct {
	Spec VGPUClaimSpec `json:"spec"`
}

// VGPUJobSpec describes a workload's intent. The actual GPU demand is
// expressed via claimTemplate (which materializes into a VGPUClaim).
type VGPUJobSpec struct {
	// Priority controls scheduling order between competing Jobs. Higher
	// values are scheduled first. Range is 0-1000; default 50.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=1000
	// +kubebuilder:default=50
	Priority int32 `json:"priority,omitempty"`

	// WorkloadClass is a hint about workload character so the scheduler
	// can apply class-aware scoring. Defaults to Batch.
	// +kubebuilder:validation:Enum=Training;Inference;Batch;Interactive
	// +kubebuilder:default=Batch
	WorkloadClass WorkloadClass `json:"workloadClass,omitempty"`

	// Preemptible reserves the right for the scheduler to evict this Job
	// in favour of higher-priority work. Reserved for Phase 2.3; stored
	// but not honoured in Phase 2.1a.
	// +kubebuilder:default=false
	Preemptible bool `json:"preemptible,omitempty"`

	// PreemptionGraceSeconds is how long a victim slice stays in the
	// Preempting phase before being deleted. Used only when Preemptible=true.
	// Default: 30 seconds. Range: 1-3600 seconds.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=3600
	// +optional
	PreemptionGraceSeconds *int32 `json:"preemptionGraceSeconds,omitempty"`

	// ClaimTemplate is the VGPUClaim that this Job will materialize.
	ClaimTemplate VGPUClaimTemplate `json:"claimTemplate"`

	// PodTemplate, when set, makes the VGPUJob OWN its workload Pod: once the
	// claim's slice is allocated, the controller creates a Pod from this template
	// — stamping the claim-ref label+annotation the mutating webhook keys on, and
	// an OwnerReference for cascade-delete — then mirrors the Pod's phase into the
	// Job status. This is what makes `kubectl apply -f vgpujob.yaml` ALONE run a
	// workload on a shared GPU (fully declarative).
	//
	// When omitted, the Job is a pure resource request (claim+slice only) and the
	// caller creates the Pod — the original, back-compatible behavior. We use the
	// native corev1.PodTemplateSpec so any Kubernetes-native tooling and the §17
	// framework integrations work unchanged.
	// +optional
	PodTemplate *corev1.PodTemplateSpec `json:"podTemplate,omitempty"`
}

// VGPUJobStatus reports the observed state of a Job.
type VGPUJobStatus struct {
	// Phase is the high-level lifecycle stage.
	Phase VGPUJobPhase `json:"phase,omitempty"`

	// ClaimRef is the name of the VGPUClaim this Job created (same namespace).
	ClaimRef string `json:"claimRef,omitempty"`

	// PodRef is the name of the workload Pod the controller created from
	// podTemplate. Empty when the Job is a pure resource request (no podTemplate).
	PodRef string `json:"podRef,omitempty"`

	// NodeName is the node the slice (and therefore the workload Pod) landed on.
	NodeName string `json:"nodeName,omitempty"`

	// DeviceUUID is the physical GPU UUID the slice bound — the same card the
	// Pod's container sees via the injected CDI device.
	DeviceUUID string `json:"deviceUuid,omitempty"`

	// Message is a human-readable explanation of the current phase.
	Message string `json:"message,omitempty"`

	// Conditions follow the standard Kubernetes condition pattern.
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Priority",type=integer,JSONPath=`.spec.priority`
// +kubebuilder:printcolumn:name="Class",type=string,JSONPath=`.spec.workloadClass`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Claim",type=string,JSONPath=`.status.claimRef`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type VGPUJob struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUJobSpec   `json:"spec,omitempty"`
	Status VGPUJobStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type VGPUJobList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUJob `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUJob{}, &VGPUJobList{})
}

// DeepCopyObject is needed for runtime.Object — generated implementations
// follow controller-gen conventions but we hand-write the minimum required.
func (j *VGPUJob) DeepCopyObject() runtime.Object {
	if j == nil {
		return nil
	}
	out := new(VGPUJob)
	j.DeepCopyInto(out)
	return out
}

func (l *VGPUJobList) DeepCopyObject() runtime.Object {
	if l == nil {
		return nil
	}
	out := new(VGPUJobList)
	l.DeepCopyInto(out)
	return out
}

func (j *VGPUJob) DeepCopyInto(out *VGPUJob) {
	*out = *j
	out.TypeMeta = j.TypeMeta
	j.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = j.Spec
	out.Spec.ClaimTemplate.Spec = j.Spec.ClaimTemplate.Spec
	if j.Spec.PreemptionGraceSeconds != nil {
		v := *j.Spec.PreemptionGraceSeconds
		out.Spec.PreemptionGraceSeconds = &v
	}
	if j.Spec.PodTemplate != nil {
		out.Spec.PodTemplate = j.Spec.PodTemplate.DeepCopy()
	}
	out.Status = j.Status
	if j.Status.Conditions != nil {
		out.Status.Conditions = make([]metav1.Condition, len(j.Status.Conditions))
		for i := range j.Status.Conditions {
			j.Status.Conditions[i].DeepCopyInto(&out.Status.Conditions[i])
		}
	}
}

func (l *VGPUJobList) DeepCopyInto(out *VGPUJobList) {
	*out = *l
	out.TypeMeta = l.TypeMeta
	l.ListMeta.DeepCopyInto(&out.ListMeta)
	if l.Items != nil {
		out.Items = make([]VGPUJob, len(l.Items))
		for i := range l.Items {
			l.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

// DeepCopy returns a deep copy of VGPUJob.
func (j *VGPUJob) DeepCopy() *VGPUJob {
	if j == nil {
		return nil
	}
	out := new(VGPUJob)
	j.DeepCopyInto(out)
	return out
}

// DeepCopy returns a deep copy of VGPUJobList.
func (l *VGPUJobList) DeepCopy() *VGPUJobList {
	if l == nil {
		return nil
	}
	out := new(VGPUJobList)
	l.DeepCopyInto(out)
	return out
}
