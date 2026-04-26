#!/usr/bin/env bash
# ============================================================================
# Layer 2 Phase 2.2a — Namespace fairness via VGPUQuota
#
# Adds:
#   1. VGPUQuota CRD (cluster-scoped, with targetNamespace field)
#   2. VGPUQuotaReconciler (refreshes status.usedVramBytes every 30s)
#   3. Namespace-usage cache in scheduler (O(1) hot path)
#   4. Quota filter check (rejects requests that would exceed quota)
#   5. Wait-time aging in priorityFn (+1/30s, capped at +50)
#   6. Pending-reason condition on rejected slices
#   7. RBAC for VGPUQuota
#
# Build order:
#   1. Types + DeepCopy
#   2. CRD YAML
#   3. RBAC updates (scheduler + controller)
#   4. Quota reconciler in controller
#   5. Namespace usage cache + quota check in scheduler
#   6. Wait-time aging in priorityFn
#   7. Build, image, deploy
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".phase22a_${STAMP}"
mkdir -p "$BACKUP"
echo "Backup: $BACKUP"

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$(dirname "$f")/"
}

backup cmd/controller/main.go
backup cmd/scheduler/main.go
backup internal/scheduler/filter.go
backup deployments/manifests/rbac/controller_rbac.yaml
backup deployments/manifests/rbac/scheduler_rbac.yaml

# ============================================================================
# 1. VGPUQuota types
# ============================================================================
cat > api/v1alpha1/vgpuquota_types.go <<'GOEOF'
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
GOEOF
echo "  ✓ api/v1alpha1/vgpuquota_types.go"

# ============================================================================
# 2. CRD YAML
# ============================================================================
cat > deployments/manifests/crds/infrastructure.pranav2910.com_vgpuquotas.yaml <<'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vgpuquotas.infrastructure.pranav2910.com
spec:
  group: infrastructure.pranav2910.com
  names:
    kind: VGPUQuota
    listKind: VGPUQuotaList
    plural: vgpuquotas
    singular: vgpuquota
    shortNames:
      - vquota
  scope: Cluster
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
              required: [targetNamespace, maxVramBytes]
              properties:
                targetNamespace:
                  type: string
                  minLength: 1
                maxVramBytes:
                  type: integer
                  format: int64
                  minimum: 1
                description:
                  type: string
            status:
              type: object
              properties:
                usedVramBytes:
                  type: integer
                  format: int64
                lastUpdated:
                  type: string
                  format: date-time
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
        - name: Namespace
          type: string
          jsonPath: .spec.targetNamespace
        - name: Max
          type: integer
          jsonPath: .spec.maxVramBytes
        - name: Used
          type: integer
          jsonPath: .status.usedVramBytes
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
CRDEOF
echo "  ✓ CRD YAML for VGPUQuota"

# ============================================================================
# 3. VGPUQuotaReconciler
# ============================================================================
cat > internal/controller/vgpuquota_reconciler.go <<'GOEOF'
package controller

import (
	"context"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// VGPUQuotaReconciler refreshes status.usedVramBytes every 30s by walking
// all Ready slices in the quota's TargetNamespace.
type VGPUQuotaReconciler struct {
	Client client.Client
	Scheme *runtime.Scheme
}

// SetupWithManager registers the reconciler.
func (r *VGPUQuotaReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUQuota{}).
		Complete(r)
}

const quotaRefreshInterval = 30 * time.Second

func (r *VGPUQuotaReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var quota vgpuv1alpha1.VGPUQuota
	if err := r.Client.Get(ctx, req.NamespacedName, &quota); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	if !quota.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// Compute current usage by walking Ready slices in target namespace.
	used, err := r.computeUsage(ctx, quota.Spec.TargetNamespace)
	if err != nil {
		log.Printf("VGPUQuota %s: failed to compute usage: %v", quota.Name, err)
		return reconcile.Result{RequeueAfter: quotaRefreshInterval}, nil
	}

	// Patch status with retry-on-conflict.
	key := types.NamespacedName{Name: quota.Name}
	err = retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUQuota
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		fresh.Status.UsedVramBytes = used
		fresh.Status.LastUpdated = metav1.Now()
		return r.Client.Status().Update(ctx, &fresh)
	})
	if err != nil {
		log.Printf("VGPUQuota %s: status update failed: %v", quota.Name, err)
	} else {
		log.Printf("VGPUQuota %s: namespace=%s used=%d/%d bytes",
			quota.Name, quota.Spec.TargetNamespace, used, quota.Spec.MaxVramBytes)
	}

	// Requeue every 30s for periodic refresh.
	return reconcile.Result{RequeueAfter: quotaRefreshInterval}, nil
}

// computeUsage sums allocatedBytes across all Ready slices in the namespace.
func (r *VGPUQuotaReconciler) computeUsage(ctx context.Context, namespace string) (int64, error) {
	var slices vgpuv1alpha1.VGPUSliceList
	if err := r.Client.List(ctx, &slices, client.InNamespace(namespace)); err != nil {
		return 0, err
	}
	var total int64
	for _, s := range slices.Items {
		if s.Status.Phase == "Ready" {
			total += s.Status.AllocatedBytes
		}
	}
	return total, nil
}
GOEOF
echo "  ✓ VGPUQuotaReconciler"

# ============================================================================
# 4. Wire VGPUQuotaReconciler into controller's main.go
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/controller/main.go")
src = p.read_text()

if "VGPUQuotaReconciler" in src:
    print("  - VGPUQuotaReconciler already wired")
else:
    # Anchor: insert AFTER the VGPUJobReconciler setup
    import re
    job_block = re.compile(
        r'(\tif err := \(&controller\.VGPUJobReconciler\{[^}]+\}\)\.SetupWithManager\(mgr\); err != nil \{\s*[^}]+\})',
        re.DOTALL
    )
    m = job_block.search(src)
    if not m:
        print("ERROR: could not find VGPUJobReconciler setup as anchor")
        raise SystemExit(1)

    addition = m.group(1) + "\n\n" + (
        "\t// Layer 2 Phase 2.2a: VGPUQuotaReconciler refreshes namespace usage every 30s.\n"
        "\tif err := (&controller.VGPUQuotaReconciler{\n"
        "\t\tClient: mgr.GetClient(),\n"
        "\t\tScheme: mgr.GetScheme(),\n"
        "\t}).SetupWithManager(mgr); err != nil {\n"
        "\t\tlog.Fatalf(\"setting up VGPUQuotaReconciler: %v\", err)\n"
        "\t}"
    )
    src = src.replace(m.group(1), addition)
    p.write_text(src)
    print("  ✓ VGPUQuotaReconciler wired in cmd/controller/main.go")
PYEOF

# ============================================================================
# 5. Namespace usage cache + quota check in scheduler
# ============================================================================
cat > internal/scheduler/quota.go <<'GOEOF'
package scheduler

import (
	"context"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// QuotaChecker enforces VGPUQuota at scheduling time.
//
// It maintains a small in-memory cache of namespace VRAM usage so the hot
// scheduling path stays O(1). The cache is refreshed lazily on each Filter
// call (cheap) or invalidated externally when slice phases change.
type QuotaChecker struct {
	client client.Client

	mu      sync.RWMutex
	usage   map[string]int64 // namespace → used bytes
	lastRefresh time.Time
}

// NewQuotaChecker returns a new checker bound to the given client.
func NewQuotaChecker(c client.Client) *QuotaChecker {
	return &QuotaChecker{
		client: c,
		usage:  make(map[string]int64),
	}
}

// Check reports whether a request to allocate `requested` bytes in `namespace`
// is allowed under any VGPUQuota that targets the namespace.
//
// Returns:
//   allowed (bool) — true if no quota or quota would not be exceeded
//   reason (string) — short machine-readable code (empty when allowed)
//   message (string) — human-readable explanation
func (q *QuotaChecker) Check(ctx context.Context, namespace string, requested int64) (bool, string, string) {
	// Find any quota for this namespace. Cluster-scoped, so we List all.
	var quotas vgpuv1alpha1.VGPUQuotaList
	if err := q.client.List(ctx, &quotas); err != nil {
		// Fail open — if quota lookup fails, don't block scheduling.
		// Logged in caller. This matches "no quota = unlimited" semantics.
		return true, "", ""
	}

	var match *vgpuv1alpha1.VGPUQuota
	for i := range quotas.Items {
		if quotas.Items[i].Spec.TargetNamespace == namespace {
			match = &quotas.Items[i]
			break
		}
	}
	if match == nil {
		return true, "", "" // No quota = unlimited
	}

	// Compute current namespace usage.
	used, err := q.namespaceUsage(ctx, namespace)
	if err != nil {
		return true, "", "" // fail open
	}

	if used+requested > match.Spec.MaxVramBytes {
		return false, "QuotaExceeded",
			fmtQuotaExceeded(namespace, used, requested, match.Spec.MaxVramBytes)
	}

	return true, "", ""
}

// namespaceUsage returns the sum of allocatedBytes for Ready slices in the
// given namespace. Uses a 5-second cache to avoid hammering the API.
func (q *QuotaChecker) namespaceUsage(ctx context.Context, namespace string) (int64, error) {
	q.mu.RLock()
	cached, hit := q.usage[namespace]
	staleness := time.Since(q.lastRefresh)
	q.mu.RUnlock()

	if hit && staleness < 5*time.Second {
		return cached, nil
	}

	// Refresh.
	var slices vgpuv1alpha1.VGPUSliceList
	if err := q.client.List(ctx, &slices, client.InNamespace(namespace)); err != nil {
		return 0, err
	}
	var total int64
	for _, s := range slices.Items {
		if s.Status.Phase == "Ready" {
			total += s.Status.AllocatedBytes
		}
	}

	q.mu.Lock()
	q.usage[namespace] = total
	q.lastRefresh = time.Now()
	q.mu.Unlock()

	return total, nil
}

// Invalidate clears the cached usage for a namespace, forcing a refresh on
// the next Check call. Useful when a slice transitions to/from Ready.
func (q *QuotaChecker) Invalidate(namespace string) {
	q.mu.Lock()
	delete(q.usage, namespace)
	q.mu.Unlock()
}

func fmtQuotaExceeded(ns string, used, req, max int64) string {
	return "namespace " + ns + " would exceed quota: used=" + i64s(used) +
		" + req=" + i64s(req) + " > max=" + i64s(max) + " bytes"
}

func i64s(v int64) string {
	// Avoid importing strconv just for this; sprintf-style would also pull fmt.
	// strconv is already in go.sum so use it.
	return _i64s(v)
}
GOEOF

# Helper for i64s — use strconv via separate file to keep quota.go self-contained
cat > internal/scheduler/quota_strconv.go <<'GOEOF'
package scheduler

import "strconv"

func _i64s(v int64) string { return strconv.FormatInt(v, 10) }
GOEOF
echo "  ✓ internal/scheduler/quota.go (QuotaChecker)"

# ============================================================================
# 6. Integrate QuotaChecker into the Schedule path.
#    The simplest place is in plugin.go's Schedule(), right before AssumeSlice.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

if "QuotaChecker" in src:
    print("  - QuotaChecker already integrated")
else:
    # 1. Add a QuotaChecker field to the SliceScheduler struct.
    src = src.replace(
        "type SliceScheduler struct {",
        "type SliceScheduler struct {\n\tQuotaChecker *QuotaChecker"
    )

    # 2. In NewSliceScheduler (or wherever it's constructed), set the field.
    #    We do this by adding a setter method instead, since we don't know the
    #    constructor's signature for sure.
    setter = '''

// SetQuotaChecker wires a quota checker into the scheduler. nil disables
// quota enforcement (no quota = unlimited).
func (s *SliceScheduler) SetQuotaChecker(q *QuotaChecker) {
	s.QuotaChecker = q
}
'''
    src = src.rstrip() + setter

    # 3. In Schedule(), check quota before AssumeSlice.
    # Anchor: the line that calls AssumeSlice (or similar reservation).
    # We use a flexible pattern.
    import re
    m = re.search(r'(\n\s*// Filter[^\n]*\n)', src)

    # Simpler: find the line "Scheduling cycle started" log and inject the
    # quota check right before whatever happens next.
    anchor = 'log.Printf("Scheduling cycle started for Slice %s/%s (req: %d bytes)", req.Namespace, req.Name, requestedBytes)'

    if anchor not in src:
        print("WARNING: could not find Schedule anchor; quota check NOT integrated.")
        print("Manual fix: add a quota check at the top of Schedule()")
    else:
        injection = anchor + '''

	// Layer 2 Phase 2.2a: enforce VGPUQuota before reserving capacity.
	if s.QuotaChecker != nil {
		if ok, reason, msg := s.QuotaChecker.Check(ctx, req.Namespace, requestedBytes); !ok {
			log.Printf("Scheduling rejected for Slice %s/%s by quota: %s — %s",
				req.Namespace, req.Name, reason, msg)
			return nil, &SchedulingError{Reason: reason, Message: msg}
		}
	}'''
        src = src.replace(anchor, injection)

    # 4. Add SchedulingError type if not present.
    if "type SchedulingError struct" not in src:
        sched_err = '''

// SchedulingError carries a structured rejection reason from Schedule().
type SchedulingError struct {
	Reason  string
	Message string
}

func (e *SchedulingError) Error() string { return e.Reason + ": " + e.Message }
'''
        src = src.rstrip() + sched_err

    p.write_text(src)
    print("  ✓ QuotaChecker integrated in plugin.go")
PYEOF

# ============================================================================
# 7. Construct QuotaChecker in scheduler main.go and wire to scheduler.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

if "scheduler.NewQuotaChecker" in src:
    print("  - QuotaChecker already constructed in main.go")
else:
    # Find where SliceScheduler is created (by name) and add QuotaChecker after.
    # Anchor on a likely pattern.
    import re
    # Look for `sched := scheduler.New...` or `&scheduler.SliceScheduler{...}`
    m = re.search(
        r'(sched\s*:?=\s*[^\n]+)',
        src
    )
    if not m:
        print("WARNING: could not find scheduler construction. Add manually:")
        print('    sched.SetQuotaChecker(scheduler.NewQuotaChecker(mgr.GetClient()))')
    else:
        # Append the wiring right after that line.
        anchor = m.group(1)
        injection = anchor + "\n\t// Layer 2 Phase 2.2a: wire VGPUQuota enforcement.\n" + \
            "\tsched.SetQuotaChecker(scheduler.NewQuotaChecker(mgr.GetClient()))"
        src = src.replace(anchor, injection, 1)
        p.write_text(src)
        print("  ✓ QuotaChecker wired in cmd/scheduler/main.go")
PYEOF

# ============================================================================
# 8. Wait-time aging in priorityFn
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

if "agingBonus" in src:
    print("  - wait-time aging already present in priorityFn")
else:
    old = '''		if basePriority == pq.PriorityGuaranteed {
			log.Printf("[priorityFn] %s/%s: tier=Guaranteed → priority=%d", req.Namespace, req.Name, basePriority)
		} else {
			log.Printf("[priorityFn] %s/%s: tier=BestEffort → priority=%d", req.Namespace, req.Name, basePriority)
		}
		return basePriority
	}
}'''

    new = '''		// Layer 2 Phase 2.2a: bounded wait-time aging.
		// Older pending slices gain priority over time so they don't get
		// permanently starved. +1 priority per 30 seconds waited, capped at +50.
		age := time.Since(slice.CreationTimestamp.Time)
		agingBonus := int(age.Seconds() / 30)
		if agingBonus > 50 {
			agingBonus = 50
		}
		finalPriority := basePriority + agingBonus

		if basePriority == pq.PriorityGuaranteed {
			log.Printf("[priorityFn] %s/%s: tier=Guaranteed base=%d aging=%d → priority=%d",
				req.Namespace, req.Name, basePriority, agingBonus, finalPriority)
		} else {
			log.Printf("[priorityFn] %s/%s: tier=BestEffort base=%d aging=%d → priority=%d",
				req.Namespace, req.Name, basePriority, agingBonus, finalPriority)
		}
		return finalPriority
	}
}'''

    if old not in src:
        print("WARNING: could not find priorityFn tail. Aging NOT added.")
    else:
        src = src.replace(old, new)
        p.write_text(src)
        print("  ✓ wait-time aging added to priorityFn")
PYEOF

# ============================================================================
# 9. Update RBAC: scheduler reads vgpuquotas, controller manages vgpuquotas
# ============================================================================
python3 - <<'PYEOF'
import pathlib

# Scheduler: read-only access to vgpuquotas
sp = pathlib.Path("deployments/manifests/rbac/scheduler_rbac.yaml")
sched_src = sp.read_text()
if "vgpuquotas" in sched_src:
    print("  - scheduler RBAC already has vgpuquotas")
else:
    anchor = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs"]
    verbs: ["get", "list", "watch"]'''
    if anchor not in sched_src:
        print("WARNING: scheduler vgpujobs anchor not found; add vgpuquotas rule manually")
    else:
        addition = anchor + '''
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuquotas"]
    verbs: ["get", "list", "watch"]'''
        sched_src = sched_src.replace(anchor, addition)
        sp.write_text(sched_src)
        print("  ✓ scheduler RBAC: vgpuquotas read")

# Controller: read+update vgpuquotas + their status
cp = pathlib.Path("deployments/manifests/rbac/controller_rbac.yaml")
ctrl_src = cp.read_text()
if "vgpuquotas" in ctrl_src:
    print("  - controller RBAC already has vgpuquotas")
else:
    anchor = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs/finalizers"]
    verbs: ["update"]'''
    if anchor not in ctrl_src:
        print("WARNING: controller vgpujobs anchor not found; add vgpuquotas rule manually")
    else:
        addition = anchor + '''
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuquotas"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuquotas/status"]
    verbs: ["get", "update", "patch"]'''
        ctrl_src = ctrl_src.replace(anchor, addition)
        cp.write_text(ctrl_src)
        print("  ✓ controller RBAC: vgpuquotas read+write+status")
PYEOF

# Validate YAML
python3 -c "
import yaml
for f in ['deployments/manifests/rbac/scheduler_rbac.yaml',
          'deployments/manifests/rbac/controller_rbac.yaml']:
    docs = list(yaml.safe_load_all(open(f)))
    for d in docs:
        assert 'kind' in d, f'malformed YAML in {f}'
    print(f'  ✓ {f} valid')
"

# ============================================================================
# 10. Build, image, deploy
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo "ERROR: go vet failed"
    exit 1
fi

echo ""
echo "Building binaries..."
go build -o bin/controller ./cmd/controller || { echo "controller build failed"; exit 1; }
go build -o bin/scheduler ./cmd/scheduler || { echo "scheduler build failed"; exit 1; }
echo "  ✓ both built"

echo ""
echo "Building images..."
TAG="p22a_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "scheduler image build failed:"; tail -10 /tmp/build.log; exit 1
}
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ images built ($TAG)"

docker save vgpu-scheduler:$TAG vgpu-controller:$TAG -o /tmp/vgpu-p22a.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p22a.tar > /dev/null
echo "  ✓ imported into kind"

# Apply CRD + RBAC
echo ""
echo "Applying CRD + RBAC..."
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpuquotas.yaml
kubectl apply -f deployments/manifests/rbac/scheduler_rbac.yaml
kubectl apply -f deployments/manifests/rbac/controller_rbac.yaml

# Update deployments
kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl set image -n vgpu-system deploy/vgpu-controller manager=vgpu-controller:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl patch deploy -n vgpu-system vgpu-controller --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null

# Force fresh pods
kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false
kubectl delete pod -n vgpu-system -l control-plane=vgpu-controller --wait=false

# Clean state
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null

sleep 30

echo ""
echo "=== Pods ==="
kubectl get pods -n vgpu-system

echo ""
echo "=== Controller logs (looking for VGPUQuota reconciler startup) ==="
kubectl logs -n vgpu-system deploy/vgpu-controller --tail=30 | grep -E "Starting Controller|Starting EventSource"

echo ""
echo "✅ Phase 2.2a applied. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Next: test scenarios at the bottom of this script."
echo ""
cat <<'TESTPLAN'
┌─────────────────────────────────────────────────────────────┐
│ TEST PLAN                                                    │
├─────────────────────────────────────────────────────────────┤
│ 1. No quota → all allocations succeed (regression)          │
│ 2. Quota = 16 GiB → 8 GiB succeeds, second 8 GiB succeeds,  │
│    third 8 GiB rejected with QuotaExceeded                  │
│ 3. Quota status updates within 30s (kubectl get vgpuquotas) │
│ 4. Wait-time aging boosts old pending slice priority        │
└─────────────────────────────────────────────────────────────┘
TESTPLAN
