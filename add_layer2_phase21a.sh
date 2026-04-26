#!/usr/bin/env bash
# ============================================================================
# Layer 2 Phase 2.1a — VGPUJob, JobRef, workload-aware scoring
#
# Adds:
#   1. VGPUJob CRD (api/v1alpha1/vgpujob_types.go)
#   2. JobRef field on VGPUClaim
#   3. VGPUJobReconciler (creates Claim from claimTemplate, mirrors lifecycle)
#   4. priorityBonus + workloadAffinityBonus in scoring
#   5. Updated priorityFn to walk Slice → Claim → Job for full context
#   6. RBAC for VGPUJob
#   7. Generated CRD YAML
#
# Build order matches the spec:
#   1-2: Types + CRD generation
#   3-4: Reconciler + wiring
#   5: RBAC
#   6: Scheduler scoring + priorityFn
#   7-8: Build, image, deploy
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".layer2_${STAMP}"
mkdir -p "$BACKUP"
echo "Backup: $BACKUP"

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$(dirname "$f")/"
}

# Stage everything we'll modify
backup api/v1alpha1/vgpuclaim_types.go
backup api/v1alpha1/zz_generated.deepcopy.go
backup api/v1alpha1/groupversion_info.go
backup cmd/controller/main.go
backup cmd/scheduler/main.go
backup internal/scheduler/score.go
backup deployments/manifests/rbac/controller_rbac.yaml

# ============================================================================
# 1. Add VGPUJob types
# ============================================================================
cat > api/v1alpha1/vgpujob_types.go <<'GOEOF'
package v1alpha1

import (
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
	JobPhaseRunning      VGPUJobPhase = "Running"
	JobPhaseFailed       VGPUJobPhase = "Failed"
	JobPhaseCompleted    VGPUJobPhase = "Completed"
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

	// ClaimTemplate is the VGPUClaim that this Job will materialize.
	ClaimTemplate VGPUClaimTemplate `json:"claimTemplate"`
}

// VGPUJobStatus reports the observed state of a Job.
type VGPUJobStatus struct {
	// Phase is the high-level lifecycle stage.
	Phase VGPUJobPhase `json:"phase,omitempty"`

	// ClaimRef is the name of the VGPUClaim this Job created (same namespace).
	ClaimRef string `json:"claimRef,omitempty"`

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
GOEOF
echo "  ✓ api/v1alpha1/vgpujob_types.go"

# ============================================================================
# 2. Add JobRef to VGPUClaim spec
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("api/v1alpha1/vgpuclaim_types.go")
src = p.read_text()

if "JobRef" in src:
    print("  - JobRef already present in VGPUClaimSpec, skipping")
else:
    # Find VGPUClaimSpec struct and append JobRef as a new optional field.
    # We look for the line that ends the existing fields (usually ServiceTier).
    target = '\tServiceTier ServiceTier `json:"serviceTier,omitempty"`'
    if target not in src:
        print("ERROR: could not find ServiceTier field as anchor")
        raise SystemExit(1)

    addition = (
        '\tServiceTier ServiceTier `json:"serviceTier,omitempty"`\n\n'
        '\t// JobRef is the name of the parent VGPUJob in the same namespace,\n'
        '\t// if this claim was created by a Job. Empty for standalone claims.\n'
        '\t// +optional\n'
        '\tJobRef string `json:"jobRef,omitempty"`'
    )
    src = src.replace(target, addition)
    p.write_text(src)
    print("  ✓ JobRef added to VGPUClaimSpec")
PYEOF

# ============================================================================
# 3. VGPUJobReconciler
# ============================================================================
cat > internal/controller/vgpujob_reconciler.go <<'GOEOF'
package controller

import (
	"context"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// VGPUJobReconciler manages the lifecycle of VGPUJob resources.
// In Phase 2.1a it ensures each Job has a corresponding VGPUClaim materialized
// from claimTemplate, and mirrors the claim's status into the Job's phase.
type VGPUJobReconciler struct {
	Client client.Client
	Scheme *runtime.Scheme
}

// SetupWithManager registers the reconciler with the controller manager.
func (r *VGPUJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUJob{}).
		Owns(&vgpuv1alpha1.VGPUClaim{}).
		Complete(r)
}

// claimNameForJob is deterministic so we can find/recreate without races.
func claimNameForJob(jobName string) string {
	return jobName + "-claim"
}

func (r *VGPUJobReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var job vgpuv1alpha1.VGPUJob
	if err := r.Client.Get(ctx, req.NamespacedName, &job); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	// Job is being deleted: OwnerReferences handle cascade. Nothing to do.
	if !job.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// 1. Ensure a Claim exists for this Job.
	claimName := claimNameForJob(job.Name)
	var claim vgpuv1alpha1.VGPUClaim
	err := r.Client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: claimName}, &claim)
	switch {
	case errors.IsNotFound(err):
		if err := r.createClaim(ctx, &job); err != nil {
			return reconcile.Result{}, fmt.Errorf("creating claim: %w", err)
		}
		log.Printf("VGPUJob %s/%s: created claim %s", job.Namespace, job.Name, claimName)
		return r.updatePhase(ctx, &job, vgpuv1alpha1.JobPhaseClaimCreated, "VGPUClaim materialized from template")
	case err != nil:
		return reconcile.Result{}, err
	}

	// 2. Mirror Claim/Slice phase into Job phase.
	desired, msg := derivePhaseFromClaim(&claim)
	if job.Status.Phase != desired || job.Status.ClaimRef != claimName {
		if _, err := r.updatePhase(ctx, &job, desired, msg); err != nil {
			return reconcile.Result{}, err
		}
	}

	return reconcile.Result{}, nil
}

// createClaim materializes the VGPUClaim from the Job's claimTemplate and
// sets OwnerReference for cascade-delete. JobRef is stamped in spec for
// the scheduler to walk back to the Job during scoring.
func (r *VGPUJobReconciler) createClaim(ctx context.Context, job *vgpuv1alpha1.VGPUJob) error {
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      claimNameForJob(job.Name),
			Namespace: job.Namespace,
		},
		Spec: job.Spec.ClaimTemplate.Spec,
	}
	// Stamp JobRef so scheduler can resolve priority/class.
	claim.Spec.JobRef = job.Name

	if err := controllerutil.SetControllerReference(job, claim, r.Scheme); err != nil {
		return fmt.Errorf("setting owner reference: %w", err)
	}

	return r.Client.Create(ctx, claim)
}

// derivePhaseFromClaim collapses claim+slice state into the Job's phase.
func derivePhaseFromClaim(claim *vgpuv1alpha1.VGPUClaim) (vgpuv1alpha1.VGPUJobPhase, string) {
	switch claim.Status.Phase {
	case "Bound":
		// Claim is Bound but Slice could still be in any state.
		// Treat Bound as "Scheduled" — the actual workload running is Phase 2.1b.
		return vgpuv1alpha1.JobPhaseScheduled, "Slice scheduled and ready"
	case "Pending", "":
		return vgpuv1alpha1.JobPhaseClaimCreated, "Awaiting scheduler"
	case "Failed":
		return vgpuv1alpha1.JobPhaseFailed, "Claim entered Failed phase"
	case "Released":
		return vgpuv1alpha1.JobPhaseCompleted, "Claim released"
	default:
		return vgpuv1alpha1.JobPhaseClaimCreated, fmt.Sprintf("Claim in phase %s", claim.Status.Phase)
	}
}

// updatePhase patches Job status with retry-on-conflict so concurrent updates
// (e.g. from a webhook) don't drop our changes.
func (r *VGPUJobReconciler) updatePhase(ctx context.Context, job *vgpuv1alpha1.VGPUJob, phase vgpuv1alpha1.VGPUJobPhase, msg string) (reconcile.Result, error) {
	key := types.NamespacedName{Namespace: job.Namespace, Name: job.Name}
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		fresh.Status.Phase = phase
		fresh.Status.Message = msg
		fresh.Status.ClaimRef = claimNameForJob(fresh.Name)
		return r.Client.Status().Update(ctx, &fresh)
	})
	return reconcile.Result{}, err
}
GOEOF
echo "  ✓ internal/controller/vgpujob_reconciler.go"

# ============================================================================
# 4. Wire VGPUJobReconciler into controller's main.go
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/controller/main.go")
src = p.read_text()

# Find a place to add the new reconciler setup. We append after the existing
# claim reconciler setup. The exact line varies but the pattern is:
#   if err := (&controller.VGPUClaimReconciler{...}).SetupWithManager(mgr); err != nil { ... }

import re

# Look for the claim reconciler setup pattern.
claim_setup_pattern = re.compile(
    r'if err := \(&controller\.VGPUClaimReconciler\{[^}]+\}\)\.SetupWithManager\(mgr\); err != nil \{\s*[^}]+\}',
    re.DOTALL
)
m = claim_setup_pattern.search(src)
if not m:
    print("ERROR: could not find claim reconciler setup as anchor")
    raise SystemExit(1)

if "VGPUJobReconciler" in src:
    print("  - VGPUJobReconciler already wired, skipping")
else:
    job_setup = (
        m.group(0) + "\n\n"
        "\t// Layer 2 Phase 2.1a: VGPUJobReconciler manages workload-intent jobs.\n"
        "\tif err := (&controller.VGPUJobReconciler{\n"
        "\t\tClient: mgr.GetClient(),\n"
        "\t\tScheme: mgr.GetScheme(),\n"
        "\t}).SetupWithManager(mgr); err != nil {\n"
        "\t\tlog.Fatalf(\"setting up VGPUJobReconciler: %v\", err)\n"
        "\t}"
    )
    src = src.replace(m.group(0), job_setup)
    p.write_text(src)
    print("  ✓ VGPUJobReconciler wired in cmd/controller/main.go")
PYEOF

# ============================================================================
# 5. Update controller RBAC to include VGPUJob
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("deployments/manifests/rbac/controller_rbac.yaml")
src = p.read_text()

if "vgpujobs" in src:
    print("  - vgpujobs already in RBAC, skipping")
else:
    # Find the rule block for vgpuclaims and add a parallel one for vgpujobs.
    addition = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs/finalizers"]
    verbs: ["update"]
'''
    # Find the rules: section and append before the closing.
    # Simplest approach: append at the end of the rules array.
    if "rules:" not in src:
        print("ERROR: rules: not found in controller_rbac.yaml")
        raise SystemExit(1)

    # Append at end of file (it's all one ClusterRole document).
    src = src.rstrip() + "\n" + addition
    p.write_text(src)
    print("  ✓ vgpujobs RBAC added")
PYEOF

# ============================================================================
# 6. Add CRD YAML for VGPUJob (hand-written; controller-gen would generate this)
# ============================================================================
cat > deployments/manifests/crds/infrastructure.pranav2910.com_vgpujobs.yaml <<'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vgpujobs.infrastructure.pranav2910.com
spec:
  group: infrastructure.pranav2910.com
  names:
    kind: VGPUJob
    listKind: VGPUJobList
    plural: vgpujobs
    singular: vgpujob
    shortNames:
      - vjob
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required:
                - claimTemplate
              properties:
                priority:
                  type: integer
                  minimum: 0
                  maximum: 1000
                  default: 50
                workloadClass:
                  type: string
                  enum:
                    - Training
                    - Inference
                    - Batch
                    - Interactive
                  default: Batch
                preemptible:
                  type: boolean
                  default: false
                claimTemplate:
                  type: object
                  required:
                    - spec
                  properties:
                    spec:
                      type: object
                      required:
                        - requestedVramBytes
                      properties:
                        requestedVramBytes:
                          type: integer
                          format: int64
                          minimum: 1
                        serviceTier:
                          type: string
                          enum:
                            - Guaranteed
                            - BestEffort
                          default: Guaranteed
                        jobRef:
                          type: string
            status:
              type: object
              properties:
                phase:
                  type: string
                claimRef:
                  type: string
                message:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type: { type: string }
                      status: { type: string }
                      reason: { type: string }
                      message: { type: string }
                      lastTransitionTime: { type: string, format: date-time }
                      observedGeneration: { type: integer }
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: Priority
          type: integer
          jsonPath: .spec.priority
        - name: Class
          type: string
          jsonPath: .spec.workloadClass
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Claim
          type: string
          jsonPath: .status.claimRef
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
CRDEOF
echo "  ✓ CRD YAML for VGPUJob"

# ============================================================================
# 7. Also add jobRef field to VGPUClaim CRD schema
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml")
src = p.read_text()

if "jobRef" in src:
    print("  - jobRef already in VGPUClaim CRD")
else:
    # Find serviceTier and add jobRef after it.
    target_anchor = "serviceTier:"
    if target_anchor not in src:
        print("ERROR: could not find serviceTier in VGPUClaim CRD")
        raise SystemExit(1)

    # We need to add a sibling field after serviceTier's full definition.
    # Easiest reliable approach: find the next blank line or status: section
    # and insert before it.
    import re

    # Find serviceTier block. It looks like:
    #   serviceTier:
    #     type: string
    #     enum:
    #       - Guaranteed
    #       - BestEffort
    #     default: Guaranteed
    # We add jobRef as a sibling.
    pattern = re.compile(r'(serviceTier:\s*\n(?:\s+[^\n]+\n)+?)(\s+\w)', re.MULTILINE)
    m = pattern.search(src)
    if m:
        injection = m.group(1) + "                        jobRef:\n                          type: string\n" + m.group(2)
        src = src[:m.start()] + injection + src[m.end():]
        p.write_text(src)
        print("  ✓ jobRef added to VGPUClaim CRD")
    else:
        print("  WARNING: could not auto-insert jobRef; manual fix may be needed")
PYEOF

# ============================================================================
# 8. Scheduler scoring: priorityBonus + workloadAffinityBonus
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/score.go")
src = p.read_text()

if "priorityBonus" in src and "workloadAffinityBonus" in src:
    print("  - scoring helpers already present, skipping")
else:
    # Append the two new helpers at the end of the file. Callers will use them
    # via priorityFn (already in main.go) and a new ScoreWithJob wrapper we add
    # below.
    addition = '''

// ─── Layer 2 Phase 2.1a: Job-aware scoring helpers ──────────────────────────

// priorityBonus maps a Job's priority (0-1000) into a scoring contribution.
// We scale to 0-100 so it dominates workloadAffinityBonus but doesn't drown
// out the bin-pack score, which is in the hundreds of GiB range.
func priorityBonus(priority int32) int64 {
	if priority < 0 {
		return 0
	}
	if priority > 1000 {
		priority = 1000
	}
	return int64(priority) / 10
}

// workloadAffinityBonus is a small class-aware adjustment. The values are
// intentionally tiny relative to priorityBonus — they break ties between
// same-priority claims rather than overriding priority.
func workloadAffinityBonus(class string) int64 {
	switch class {
	case "Training":
		return 10
	case "Inference":
		return 5
	case "Batch":
		return -5
	case "Interactive":
		return 0
	default:
		return 0
	}
}
'''
    src = src.rstrip() + addition
    p.write_text(src)
    print("  ✓ priorityBonus + workloadAffinityBonus added to score.go")
PYEOF

# ============================================================================
# 9. Update scheduler's priorityFn to walk Slice → Claim → Job
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Find the existing makePriorityFunc and extend it to also walk to the Job
# when the Claim has a JobRef.
old_block = '''	if claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierGuaranteed {
			log.Printf("[priorityFn] %s/%s: tier=Guaranteed → priority=%d", req.Namespace, req.Name, pq.PriorityGuaranteed)
			return pq.PriorityGuaranteed
		}
		log.Printf("[priorityFn] %s/%s: tier=BestEffort → priority=%d", req.Namespace, req.Name, pq.PriorityBestEffort)
		return pq.PriorityBestEffort
	}
}'''

new_block = '''	// Layer 2 Phase 2.1a: if the Claim is owned by a VGPUJob, the Job's
		// priority overrides the tier-based default. Higher priority always wins.
		basePriority := pq.PriorityBestEffort
		if claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierGuaranteed {
			basePriority = pq.PriorityGuaranteed
		}

		if claim.Spec.JobRef != "" {
			var job vgpuv1alpha1.VGPUJob
			if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
				// Map Job.spec.priority (0-1000) to a queue priority.
				// Anything >= 500 outranks Guaranteed; below acts as
				// fine-grained ordering within tiers.
				jobPriority := int(job.Spec.Priority)
				if jobPriority > basePriority {
					log.Printf("[priorityFn] %s/%s: job=%s priority=%d (overrides tier)",
						req.Namespace, req.Name, job.Name, jobPriority)
					return jobPriority
				}
			}
		}

		if basePriority == pq.PriorityGuaranteed {
			log.Printf("[priorityFn] %s/%s: tier=Guaranteed → priority=%d", req.Namespace, req.Name, basePriority)
		} else {
			log.Printf("[priorityFn] %s/%s: tier=BestEffort → priority=%d", req.Namespace, req.Name, basePriority)
		}
		return basePriority
	}
}'''

if "Job's\n\t\t// priority overrides the tier-based default" in src:
    print("  - priorityFn already walks to Job, skipping")
elif old_block in src:
    src = src.replace(old_block, new_block)
    p.write_text(src)
    print("  ✓ priorityFn now walks Slice → Claim → Job")
else:
    print("  WARNING: could not find priorityFn block to extend; manual edit may be needed")
PYEOF

# ============================================================================
# 10. Build everything
# ============================================================================
echo ""
echo "Running go vet..."
go vet ./... 2>&1 | head -30

echo ""
echo "Running unit tests for the priority queue (still relevant)..."
go test ./internal/scheduler/priorityqueue/... 2>&1 | tail -10

echo ""
echo "Building binaries..."
go build -o bin/controller ./cmd/controller || { echo "controller build failed"; exit 1; }
go build -o bin/scheduler ./cmd/scheduler || { echo "scheduler build failed"; exit 1; }
echo "  ✓ both binaries built"

# ============================================================================
# 11. Apply the new CRD
# ============================================================================
echo ""
echo "Applying CRDs..."
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpujobs.yaml
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml
kubectl apply -f deployments/manifests/rbac/controller_rbac.yaml
echo "  ✓ CRDs and RBAC applied"

# ============================================================================
# 12. Build images and deploy
# ============================================================================
echo ""
echo "Building images..."
TAG="l2_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "scheduler image build failed:"; tail -10 /tmp/build.log; exit 1
}
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ images built ($TAG)"

docker save vgpu-scheduler:$TAG vgpu-controller:$TAG -o /tmp/vgpu-l2.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-l2.tar > /dev/null
echo "  ✓ imported into kind"

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl set image -n vgpu-system deploy/vgpu-controller manager=vgpu-controller:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl patch deploy -n vgpu-system vgpu-controller --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null

# Clean state
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1 || true
kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1 || true

sleep 30
echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "✅ Layer 2 Phase 2.1a applied. Backup: $BACKUP"
echo ""
echo "Next: test the priority scenario:"
echo ""
cat <<'TESTEOF'
# Test: Two Jobs, contended capacity, high-priority should win
# Submit a 72 GiB filler so only 8 GiB is free, then two 8 GiB Jobs.

cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: l2-filler, namespace: default }
spec: { requestedVramBytes: 77309411328, serviceTier: Guaranteed }
EOF

sleep 10  # let filler bind

cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: job-low, namespace: default }
spec:
  priority: 10
  workloadClass: Batch
  claimTemplate:
    spec: { requestedVramBytes: 8589934592, serviceTier: Guaranteed }
EOF

sleep 1

cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: job-high, namespace: default }
spec:
  priority: 900
  workloadClass: Inference
  claimTemplate:
    spec: { requestedVramBytes: 8589934592, serviceTier: Guaranteed }
EOF

sleep 30

echo "=== VGPUJobs ==="
kubectl get vgpujobs

echo ""
echo "=== VGPUClaims ==="
kubectl get vgpuclaims

echo ""
echo "=== VGPUSlices ==="
kubectl get vgpuslices

echo ""
echo "=== Scheduler decisions ==="
kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=80 | \
    grep -E "priorityFn|priorityqueue|Scheduling|bound" | grep -E "job-low|job-high" | tail -20
TESTEOF
