#!/usr/bin/env bash
# ============================================================================
# Layer 2 Phase 2.3 — Preemption
#
# Locked design (from user):
#   - Capacity-only trigger (not quota, not filter)
#   - Victim eligibility: preemptible=true AND priority delta >= 100
#   - Selection: lowest priority -> smallest VRAM -> oldest slice
#   - Graceful 30s timeout (per-Job override, default 30, range 1-3600)
#   - 60s cooldown + 100-priority gap
#   - Intra-namespace only
#   - Observable: victim slice phase becomes "Preempting" with conditions
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".phase23_${STAMP}"
mkdir -p "$BACKUP"
echo "Backup: $BACKUP"

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$(dirname "$f")/"
}

backup api/v1alpha1/vgpuslice_types.go
backup api/v1alpha1/vgpujob_types.go
backup internal/scheduler/plugin.go
backup internal/controller/vgpuslice_reconciler.go
backup cmd/scheduler/main.go
backup deployments/manifests/crds/infrastructure.pranav2910.com_vgpujobs.yaml
backup deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml

# ============================================================================
# 1. Add Preempting phase constant
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("api/v1alpha1/vgpuslice_types.go")
src = p.read_text()

if "PhasePreempting" in src or '"Preempting"' in src:
    print("  - Preempting phase already declared")
else:
    # Add as a top-level constant declaration so we don't depend on existing
    # const-block layout matching exactly.
    addition = '\n\n// PhasePreempting is the slice phase during graceful pre-eviction (Phase 2.3).\nconst PhasePreempting = "Preempting"\n'
    p.write_text(src.rstrip() + addition)
    print("  ✓ PhasePreempting constant added")
PYEOF

# ============================================================================
# 2. Add PreemptionGraceSeconds to VGPUJobSpec
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("api/v1alpha1/vgpujob_types.go")
src = p.read_text()

if "PreemptionGraceSeconds" in src:
    print("  - PreemptionGraceSeconds already in VGPUJobSpec")
else:
    anchor = '''	// Preemptible reserves the right for the scheduler to evict this Job
	// in favour of higher-priority work. Reserved for Phase 2.3; stored
	// but not honoured in Phase 2.1a.
	// +kubebuilder:default=false
	Preemptible bool `json:"preemptible,omitempty"`'''

    if anchor not in src:
        print("ERROR: could not find Preemptible field as anchor")
        raise SystemExit(1)

    addition = anchor + '''

	// PreemptionGraceSeconds is how long a victim slice stays in the
	// Preempting phase before being deleted. Used only when Preemptible=true.
	// Default: 30 seconds. Range: 1-3600 seconds.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=3600
	// +optional
	PreemptionGraceSeconds *int32 `json:"preemptionGraceSeconds,omitempty"`'''

    src = src.replace(anchor, addition)
    p.write_text(src)
    print("  ✓ PreemptionGraceSeconds added to VGPUJobSpec")
PYEOF

# ============================================================================
# 3. Update VGPUJob CRD schema
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("deployments/manifests/crds/infrastructure.pranav2910.com_vgpujobs.yaml")
src = p.read_text()

if "preemptionGraceSeconds" in src:
    print("  - CRD already has preemptionGraceSeconds")
else:
    anchor = """                preemptible:
                  type: boolean
                  default: false"""

    if anchor not in src:
        print("WARNING: could not find preemptible in CRD; skipping schema update")
    else:
        addition = anchor + """
                preemptionGraceSeconds:
                  type: integer
                  minimum: 1
                  maximum: 3600
                  default: 30"""
        src = src.replace(anchor, addition)
        p.write_text(src)
        print("  ✓ preemptionGraceSeconds added to VGPUJob CRD schema")
PYEOF

# ============================================================================
# 4. Update VGPUSlice CRD enum (if present) to allow Preempting phase
# ============================================================================
python3 - <<'PYEOF'
import pathlib, re
p = pathlib.Path("deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml")
src = p.read_text()

m = re.search(r'phase:\s*\n\s+type:\s*string\s*\n\s+enum:\s*\n((?:\s+-\s+\w+\s*\n)+)', src)
if m and "Preempting" not in m.group(0):
    enum_block = m.group(1)
    indent = re.match(r'(\s+)', enum_block).group(1)
    new_enum = enum_block + indent + "- Preempting\n"
    src = src.replace(enum_block, new_enum)
    p.write_text(src)
    print("  ✓ Preempting added to VGPUSlice phase enum")
elif m:
    print("  - VGPUSlice phase enum already includes Preempting")
else:
    print("  - VGPUSlice CRD has no enum constraint on phase (any string accepted)")
PYEOF

# ============================================================================
# 5. Create Preemptor
# ============================================================================
cat > internal/scheduler/preemptor.go <<'GOEOF'
package scheduler

import (
	"context"
	"fmt"
	"log"
	"sort"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	PreemptionCooldown    = 60 * time.Second
	PreemptionPriorityGap = int32(100)
	DefaultGraceSeconds   = int32(30)
)

// PreemptionPlan describes a planned eviction.
type PreemptionPlan struct {
	Requester    *vgpuv1alpha1.VGPUSlice
	Victims      []VictimSelection
	FreedBytes   int64
	NeededBytes  int64
	CreatedAt    time.Time
}

// VictimSelection is one slice marked for eviction in a plan.
type VictimSelection struct {
	Slice          *vgpuv1alpha1.VGPUSlice
	Job            *vgpuv1alpha1.VGPUJob
	Priority       int32
	GraceSeconds   int32
	AllocatedBytes int64
}

// PreemptionInProgressError signals scheduling-failed-due-to-preemption.
// The reconciler should requeue with a delay >= grace period.
type PreemptionInProgressError struct {
	Plan *PreemptionPlan
}

func (e *PreemptionInProgressError) Error() string {
	return fmt.Sprintf("preemption in progress: %d victims, %d bytes",
		len(e.Plan.Victims), e.Plan.FreedBytes)
}

// Preemptor owns preemption state.
type Preemptor struct {
	client client.Client

	mu       sync.Mutex
	cooldown map[string]time.Time // key: namespace/claimName -> until
}

// NewPreemptor constructs a Preemptor.
func NewPreemptor(c client.Client) *Preemptor {
	return &Preemptor{
		client:   c,
		cooldown: make(map[string]time.Time),
	}
}

// TryPreempt attempts to free neededBytes of capacity by evicting eligible
// lower-priority victims in the requester's namespace.
//
// Returns:
//   - (*PreemptionPlan, nil) if a viable plan was found and victims marked
//   - (nil, nil) if no plan possible (no eligible victims, gap too small, etc)
//   - (nil, err) on infrastructure failure
func (p *Preemptor) TryPreempt(
	ctx context.Context,
	requester *vgpuv1alpha1.VGPUSlice,
	requesterPriority int32,
	requesterClaim *vgpuv1alpha1.VGPUClaim,
	neededBytes int64,
) (*PreemptionPlan, error) {

	// 1. Cooldown on requester's claim.
	if requesterClaim != nil {
		key := requester.Namespace + "/" + requesterClaim.Name
		p.mu.Lock()
		if until, ok := p.cooldown[key]; ok && time.Now().Before(until) {
			p.mu.Unlock()
			log.Printf("[preemptor] %s/%s in cooldown until %v",
				requester.Namespace, requester.Name, until.Format(time.RFC3339))
			return nil, nil
		}
		p.mu.Unlock()
	}

	// 2. List slices in requester's namespace.
	var slices vgpuv1alpha1.VGPUSliceList
	if err := p.client.List(ctx, &slices, client.InNamespace(requester.Namespace)); err != nil {
		return nil, fmt.Errorf("listing slices: %w", err)
	}

	// 3. Build candidate list: Ready, preemptible, big-enough priority gap.
	candidates := make([]VictimSelection, 0)
	for i := range slices.Items {
		s := &slices.Items[i]

		if s.Name == requester.Name {
			continue
		}
		if s.Status.Phase != "Ready" {
			continue
		}
		if s.Status.AllocatedBytes <= 0 {
			continue
		}
		if s.Spec.ClaimRef == "" {
			continue
		}

		var claim vgpuv1alpha1.VGPUClaim
		if err := p.client.Get(ctx, client.ObjectKey{Namespace: s.Namespace, Name: s.Spec.ClaimRef}, &claim); err != nil {
			continue
		}
		if claim.Spec.JobRef == "" {
			continue
		}

		var job vgpuv1alpha1.VGPUJob
		if err := p.client.Get(ctx, client.ObjectKey{Namespace: s.Namespace, Name: claim.Spec.JobRef}, &job); err != nil {
			continue
		}

		if !job.Spec.Preemptible {
			continue
		}
		if requesterPriority-job.Spec.Priority < PreemptionPriorityGap {
			continue
		}

		// Per-victim cooldown.
		victimKey := s.Namespace + "/" + claim.Name
		p.mu.Lock()
		if until, ok := p.cooldown[victimKey]; ok && time.Now().Before(until) {
			p.mu.Unlock()
			continue
		}
		p.mu.Unlock()

		grace := DefaultGraceSeconds
		if job.Spec.PreemptionGraceSeconds != nil {
			grace = *job.Spec.PreemptionGraceSeconds
		}

		candidates = append(candidates, VictimSelection{
			Slice:          s.DeepCopy(),
			Job:            job.DeepCopy(),
			Priority:       job.Spec.Priority,
			GraceSeconds:   grace,
			AllocatedBytes: s.Status.AllocatedBytes,
		})
	}

	if len(candidates) == 0 {
		log.Printf("[preemptor] no eligible victims in %s for %s (priority=%d)",
			requester.Namespace, requester.Name, requesterPriority)
		return nil, nil
	}

	// 4. Sort: lowest priority -> smallest VRAM -> oldest.
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].Priority != candidates[j].Priority {
			return candidates[i].Priority < candidates[j].Priority
		}
		if candidates[i].AllocatedBytes != candidates[j].AllocatedBytes {
			return candidates[i].AllocatedBytes < candidates[j].AllocatedBytes
		}
		return candidates[i].Slice.CreationTimestamp.Before(&candidates[j].Slice.CreationTimestamp)
	})

	// 5. Greedy selection: take victims until enough capacity freed.
	plan := &PreemptionPlan{
		Requester:   requester.DeepCopy(),
		Victims:     []VictimSelection{},
		NeededBytes: neededBytes,
		CreatedAt:   time.Now(),
	}
	for _, c := range candidates {
		plan.Victims = append(plan.Victims, c)
		plan.FreedBytes += c.AllocatedBytes
		if plan.FreedBytes >= neededBytes {
			break
		}
	}

	if plan.FreedBytes < neededBytes {
		log.Printf("[preemptor] insufficient eligible capacity in %s: needed=%d freeable=%d",
			requester.Namespace, neededBytes, plan.FreedBytes)
		return nil, nil
	}

	// 6. Mark victims as Preempting.
	if err := p.markVictimsPreempting(ctx, plan); err != nil {
		return nil, fmt.Errorf("marking victims: %w", err)
	}

	// 7. Cooldown each victim's claim.
	p.mu.Lock()
	until := time.Now().Add(PreemptionCooldown)
	for _, v := range plan.Victims {
		p.cooldown[v.Slice.Namespace+"/"+v.Job.Name+"-claim"] = until
	}
	p.mu.Unlock()

	log.Printf("[preemptor] PLAN: requester=%s/%s priority=%d victims=%d freed=%d/%d bytes",
		requester.Namespace, requester.Name, requesterPriority,
		len(plan.Victims), plan.FreedBytes, neededBytes)

	return plan, nil
}

func (p *Preemptor) markVictimsPreempting(ctx context.Context, plan *PreemptionPlan) error {
	for i := range plan.Victims {
		v := &plan.Victims[i]
		key := client.ObjectKey{Namespace: v.Slice.Namespace, Name: v.Slice.Name}

		err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var fresh vgpuv1alpha1.VGPUSlice
			if err := p.client.Get(ctx, key, &fresh); err != nil {
				return err
			}
			if fresh.Status.Phase != "Ready" {
				return nil // someone else moved it; abort silently
			}

			fresh.Status.Phase = "Preempting"

			cond := metav1.Condition{
				Type:               "Preempting",
				Status:             metav1.ConditionTrue,
				Reason:             "HigherPriorityWorkload",
				Message: fmt.Sprintf("Preempted by %s/%s; grace=%ds",
					plan.Requester.Namespace, plan.Requester.Name, v.GraceSeconds),
				LastTransitionTime: metav1.Now(),
			}
			fresh.Status.Conditions = upsertCondition(fresh.Status.Conditions, cond)

			return p.client.Status().Update(ctx, &fresh)
		})
		if err != nil {
			log.Printf("[preemptor] failed to mark victim %s/%s: %v",
				v.Slice.Namespace, v.Slice.Name, err)
			return err
		}
	}
	return nil
}

func upsertCondition(conds []metav1.Condition, c metav1.Condition) []metav1.Condition {
	for i := range conds {
		if conds[i].Type == c.Type {
			conds[i] = c
			return conds
		}
	}
	return append(conds, c)
}

// CleanupCooldown prunes stale cooldown entries.
func (p *Preemptor) CleanupCooldown() {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	for k, until := range p.cooldown {
		if now.After(until) {
			delete(p.cooldown, k)
		}
	}
}
GOEOF
echo "  ✓ internal/scheduler/preemptor.go"

# ============================================================================
# 6. Add Preemptor field + setter on SliceScheduler
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

if "Preemptor *Preemptor" in src:
    print("  - Preemptor already a field on SliceScheduler")
else:
    old = "QuotaChecker *QuotaChecker"
    new = "QuotaChecker *QuotaChecker\n\tPreemptor    *Preemptor"
    if old not in src:
        print("ERROR: QuotaChecker anchor not found in struct")
        raise SystemExit(1)
    src = src.replace(old, new)

    setter = '''

// SetPreemptor wires preemption into the scheduler.
func (s *SliceScheduler) SetPreemptor(p *Preemptor) {
	s.Preemptor = p
}
'''
    src = src.rstrip() + setter
    p.write_text(src)
    print("  ✓ Preemptor field + SetPreemptor on SliceScheduler")
PYEOF

# ============================================================================
# 7. Hook preemption into Schedule() on capacity failure
# ============================================================================
python3 - <<'PYEOF'
import pathlib, re
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

if "PreemptionInProgressError{" in src or "tryPreemptionForSlice" in src:
    print("  - preemption already wired into Schedule()")
else:
    # Find capacity-failure return.
    pattern = re.compile(
        r'(return\s+"",\s*fmt\.Errorf\("no node has sufficient VRAM for %d bytes",\s*reqBytes\))',
    )
    m = pattern.search(src)
    if not m:
        pattern2 = re.compile(r'(return\s+"",\s*[^\n]*"no node has sufficient VRAM[^"]*"[^)]*\))')
        m = pattern2.search(src)

    if not m:
        print("WARNING: could not find capacity-failure return; preemption NOT wired")
        print("Manual integration needed: invoke s.Preemptor.TryPreempt before returning the error.")
    else:
        anchor = m.group(1)
        replacement = '''// Layer 2 Phase 2.3: try preemption before declaring capacity failure.
		if s.Preemptor != nil {
			if plan, err := s.tryPreemptionForSlice(ctx, nn, reqBytes); err == nil && plan != nil {
				return "", &PreemptionInProgressError{Plan: plan}
			} else if err != nil {
				log.Printf("[preemption] TryPreempt failed for %s: %v", nn, err)
			}
		}
		''' + anchor

        src = src.replace(anchor, replacement)

        helper = '''

// tryPreemptionForSlice resolves the requester's priority and invokes the
// Preemptor. The Preemptor handles eligibility + victim selection + marking.
func (s *SliceScheduler) tryPreemptionForSlice(ctx context.Context, nn types.NamespacedName, neededBytes int64) (*PreemptionPlan, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &slice); err != nil {
		return nil, err
	}

	var requesterPriority int32 = 50
	var claim vgpuv1alpha1.VGPUClaim
	if slice.Spec.ClaimRef != "" {
		if err := s.K8sClient.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
			if claim.Spec.JobRef != "" {
				var job vgpuv1alpha1.VGPUJob
				if err := s.K8sClient.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
					requesterPriority = job.Spec.Priority
				}
			}
		}
	}

	return s.Preemptor.TryPreempt(ctx, &slice, requesterPriority, &claim, neededBytes)
}
'''
        src = src.rstrip() + helper
        p.write_text(src)
        print("  ✓ preemption wired into Schedule()")
PYEOF

# ============================================================================
# 8. Slice reconciler: handle Preempting phase with grace timeout
# ============================================================================
python3 - <<'PYEOF'
import pathlib, re
p = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
src = p.read_text()

if "Layer 2 Phase 2.3" in src and "Preempting" in src:
    print("  - slice reconciler already handles Preempting")
else:
    # Find the slice Get block to inject right after.
    get_match = re.search(
        r'(if err := r\.client\.Get\(ctx, req\.NamespacedName, &slice\); err != nil \{[^}]+\})',
        src
    )
    if not get_match:
        print("WARNING: could not find slice Get block in reconciler; manual integration needed")
    else:
        anchor = get_match.group(1)
        injection = anchor + '''

	// Layer 2 Phase 2.3: handle Preempting phase with graceful drain.
	if slice.Status.Phase == "Preempting" {
		grace := 30 * time.Second
		if slice.Spec.ClaimRef != "" {
			var claim vgpuv1alpha1.VGPUClaim
			if err := r.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
				if claim.Spec.JobRef != "" {
					var job vgpuv1alpha1.VGPUJob
					if err := r.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
						if job.Spec.PreemptionGraceSeconds != nil && *job.Spec.PreemptionGraceSeconds > 0 {
							grace = time.Duration(*job.Spec.PreemptionGraceSeconds) * time.Second
						}
					}
				}
			}
		}

		var since time.Time
		for _, c := range slice.Status.Conditions {
			if c.Type == "Preempting" {
				since = c.LastTransitionTime.Time
				break
			}
		}
		if since.IsZero() {
			since = time.Now()
		}

		elapsed := time.Since(since)
		if elapsed < grace {
			remaining := grace - elapsed
			log.Printf("[preempting] %s/%s grace remaining %v", slice.Namespace, slice.Name, remaining.Round(time.Second))
			return reconcile.Result{RequeueAfter: remaining}, nil
		}

		log.Printf("[preempting] %s/%s grace expired -> Released", slice.Namespace, slice.Name)
		slice.Status.Phase = "Released"
		if err := r.client.Status().Update(ctx, &slice); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{Requeue: true}, nil
	}
'''
        src = src.replace(anchor, injection)
        p.write_text(src)
        print("  ✓ slice reconciler handles Preempting with grace timeout")
PYEOF

# ============================================================================
# 9. Construct Preemptor in cmd/scheduler/main.go
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

if "scheduler.NewPreemptor" in src:
    print("  - Preemptor already constructed")
else:
    anchor = "sched.SetQuotaChecker(scheduler.NewQuotaChecker(mgr.GetClient()))"
    if anchor not in src:
        print("WARNING: SetQuotaChecker anchor not found in main.go; manual wiring needed")
    else:
        addition = anchor + '''

	// Layer 2 Phase 2.3: wire preemption.
	sched.SetPreemptor(scheduler.NewPreemptor(mgr.GetClient()))'''
        src = src.replace(anchor, addition)
        p.write_text(src)
        print("  ✓ Preemptor wired in cmd/scheduler/main.go")
PYEOF

# ============================================================================
# 10. Build
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo ""
    echo "ERROR: go vet failed"
    echo "Backup at: $BACKUP — restore with:"
    echo "  cp -rp $BACKUP/* ."
    exit 1
fi

echo ""
echo "Building binaries..."
go build -o bin/controller ./cmd/controller || { echo "controller build failed"; exit 1; }
go build -o bin/scheduler ./cmd/scheduler || { echo "scheduler build failed"; exit 1; }
echo "  ✓ both built"

echo ""
echo "Building images..."
TAG="p23_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "scheduler image build failed:"; tail -10 /tmp/build.log; exit 1
}
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ images built ($TAG)"

docker save vgpu-scheduler:$TAG vgpu-controller:$TAG -o /tmp/vgpu-p23.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23.tar > /dev/null
echo "  ✓ imported into kind"

# Apply CRDs
echo ""
echo "Applying CRD updates..."
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpujobs.yaml
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml

# Update deployments
kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl set image -n vgpu-system deploy/vgpu-controller manager=vgpu-controller:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl patch deploy -n vgpu-system vgpu-controller --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null

kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false
kubectl delete pod -n vgpu-system -l control-plane=vgpu-controller --wait=false

# Clean state
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuquota -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 30

echo ""
echo "=== Pods ==="
kubectl get pods -n vgpu-system

echo ""
echo "=== Scheduler image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ Phase 2.3 applied. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Test plan in next message."
