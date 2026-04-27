#!/usr/bin/env bash
# ============================================================================
# Phase 2.3 follow-up fix:
#   1. Add DeepCopy() *VGPUJob and DeepCopy() *VGPUQuota (Phase 2.1a/2.2a oversights)
#   2. Add DeepCopy() *VGPUJobList and DeepCopy() *VGPUQuotaList for completeness
#   3. Inject Preempting-phase handler in reconcileSlice() (correct anchor)
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".phase23fix_${STAMP}"
mkdir -p "$BACKUP"
backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$(dirname "$f")/"
}

backup api/v1alpha1/vgpujob_types.go
backup api/v1alpha1/vgpuquota_types.go
backup internal/controller/vgpuslice_reconciler.go
echo "Backup: $BACKUP"

# ============================================================================
# 1. Add DeepCopy() *VGPUJob and DeepCopy() *VGPUJobList
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("api/v1alpha1/vgpujob_types.go")
src = p.read_text()

if "func (j *VGPUJob) DeepCopy() *VGPUJob" in src:
    print("  - VGPUJob.DeepCopy already exists")
else:
    addition = '''

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
'''
    p.write_text(src.rstrip() + addition + "\n")
    print("  ✓ VGPUJob.DeepCopy + VGPUJobList.DeepCopy added")
PYEOF

# ============================================================================
# 2. Add DeepCopy() *VGPUQuota and DeepCopy() *VGPUQuotaList
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("api/v1alpha1/vgpuquota_types.go")
src = p.read_text()

if "func (q *VGPUQuota) DeepCopy() *VGPUQuota" in src:
    print("  - VGPUQuota.DeepCopy already exists")
else:
    addition = '''

// DeepCopy returns a deep copy of VGPUQuota.
func (q *VGPUQuota) DeepCopy() *VGPUQuota {
	if q == nil {
		return nil
	}
	out := new(VGPUQuota)
	q.DeepCopyInto(out)
	return out
}

// DeepCopy returns a deep copy of VGPUQuotaList.
func (l *VGPUQuotaList) DeepCopy() *VGPUQuotaList {
	if l == nil {
		return nil
	}
	out := new(VGPUQuotaList)
	l.DeepCopyInto(out)
	return out
}
'''
    p.write_text(src.rstrip() + addition + "\n")
    print("  ✓ VGPUQuota.DeepCopy + VGPUQuotaList.DeepCopy added")
PYEOF

# ============================================================================
# 3. Inject Preempting handler at top of reconcileSlice()
# ============================================================================
python3 - <<'PYEOF'
import pathlib, re
p = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
src = p.read_text()

if "Layer 2 Phase 2.3" in src and 'Preempting' in src and 'grace remaining' in src:
    print("  - reconcileSlice already handles Preempting")
else:
    # Anchor: top of reconcileSlice's body, just inside the function brace.
    # The current first statement is "if !slice.DeletionTimestamp.IsZero()..."
    # We insert before it so Preempting is checked first.
    anchor = '''func (r *VGPUSliceReconciler) reconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	if !slice.DeletionTimestamp.IsZero() {
		return r.handleDelete(ctx, slice)
	}'''

    if anchor not in src:
        # Try with 4-space indent
        anchor = '''func (r *VGPUSliceReconciler) reconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
    if !slice.DeletionTimestamp.IsZero() {
        return r.handleDelete(ctx, slice)
    }'''

    if anchor not in src:
        print("ERROR: could not find reconcileSlice() body anchor")
        print("Looking for actual start of reconcileSlice:")
        m = re.search(r'func \(r \*VGPUSliceReconciler\) reconcileSlice[^{]+\{[^\n]*\n[^\n]+', src)
        if m:
            print("Found:")
            print(m.group(0))
        raise SystemExit(1)

    # Note: reconcileSlice returns `error`, not `(reconcile.Result, error)`.
    # So we can't return a Result here. Instead, we transition the phase
    # and let the next reconcile cycle pick it up via the existing flow.
    # The grace-period requeue is handled differently: we set the phase
    # to Released only after grace expires, otherwise we just return nil
    # and rely on the caller's RequeueAfter logic. But this reconciler's
    # Reconcile() doesn't currently set RequeueAfter for Preempting.
    #
    # Cleanest approach: handle Preempting in the OUTER Reconcile method
    # so we have access to reconcile.Result. Move our injection there.
    print("  - reconcileSlice handler skipped; using outer Reconcile instead")

# Now inject in Reconcile() instead, where we can return RequeueAfter.
if "Layer 2 Phase 2.3: Preempting" in src:
    print("  - Reconcile() already handles Preempting")
else:
    # Anchor: the line right after the Get block in Reconcile, before reconcileSlice
    outer_anchor = '''	if err := r.Client.Get(ctx, req.NamespacedName, &slice); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUSlice: %w", err)
	}
	if err := r.reconcileSlice(ctx, &slice); err != nil {
		return reconcile.Result{}, err
	}'''

    if outer_anchor not in src:
        print("ERROR: could not find Reconcile body anchor")
        raise SystemExit(1)

    injection = '''	if err := r.Client.Get(ctx, req.NamespacedName, &slice); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUSlice: %w", err)
	}

	// Layer 2 Phase 2.3: Preempting phase has its own lifecycle independent
	// of the normal reconcile path. Honour the per-Job grace period, then
	// transition to Released so existing cleanup runs.
	if string(slice.Status.Phase) == "Preempting" {
		grace := 30 * time.Second
		if slice.Spec.ClaimRef != "" {
			var claim vgpuv1alpha1.VGPUClaim
			if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
				if claim.Spec.JobRef != "" {
					var job vgpuv1alpha1.VGPUJob
					if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
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
		slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Released")
		if err := r.Client.Status().Update(ctx, &slice); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{Requeue: true}, nil
	}

	if err := r.reconcileSlice(ctx, &slice); err != nil {
		return reconcile.Result{}, err
	}'''

    src = src.replace(outer_anchor, injection)

    # Ensure imports include log and time and types
    needed_imports = ['"log"', '"time"', '"k8s.io/apimachinery/pkg/types"']
    missing = [imp for imp in needed_imports if imp not in src]
    if missing:
        # Find import block
        import_match = re.search(r'(import\s*\(\s*\n)([^)]+)(\))', src)
        if import_match:
            existing = import_match.group(2)
            for imp in missing:
                if imp not in existing:
                    existing += "\t" + imp + "\n"
            new_block = import_match.group(1) + existing + import_match.group(3)
            src = src[:import_match.start()] + new_block + src[import_match.end():]

    p.write_text(src)
    print("  ✓ Reconcile() handles Preempting with grace timer")
PYEOF

# ============================================================================
# 4. Verify VGPUSlicePhase type alias exists. If reconciler uses string casts,
#    we need to know the actual phase type.
# ============================================================================
python3 - <<'PYEOF'
import pathlib, re
p = pathlib.Path("api/v1alpha1/vgpuslice_types.go")
src = p.read_text()

# What's the type of slice.Status.Phase?
phase_match = re.search(r'Phase\s+(\w+)\s+`json:"phase', src)
if phase_match:
    phase_type = phase_match.group(1)
    print(f"  - Slice Phase type: {phase_type}")
    if phase_type == "string":
        # Then we don't need the cast in Reconcile.
        rec = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
        rec_src = rec.read_text()
        rec_src = rec_src.replace(
            'slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Released")',
            'slice.Status.Phase = "Released"'
        )
        rec.write_text(rec_src)
        print("  ✓ Adjusted: Phase is plain string, removed cast")
    else:
        # Use the actual type for the assignment
        rec = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
        rec_src = rec.read_text()
        rec_src = rec_src.replace(
            'slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Released")',
            f'slice.Status.Phase = vgpuv1alpha1.{phase_type}("Released")'
        )
        rec.write_text(rec_src)
        print(f"  ✓ Adjusted: Phase is {phase_type}, used correct cast")
PYEOF

# ============================================================================
# 5. Verify build
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo ""
    echo "ERROR: go vet still failing. Backup at: $BACKUP"
    exit 1
fi

echo ""
echo "Building binaries..."
go build -o bin/controller ./cmd/controller || { echo "controller build failed"; exit 1; }
go build -o bin/scheduler ./cmd/scheduler || { echo "scheduler build failed"; exit 1; }
echo "  ✓ both built"

# ============================================================================
# 6. Build and deploy images
# ============================================================================
TAG="p23fix$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "scheduler image build failed:"; tail -10 /tmp/build.log; exit 1
}
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ images built ($TAG)"

docker save vgpu-scheduler:$TAG vgpu-controller:$TAG -o /tmp/vgpu-p23fix.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23fix.tar > /dev/null

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
echo "=== Controller image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-controller \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "=== Controller logs ==="
kubectl logs -n vgpu-system deploy/vgpu-controller --tail=20 | grep -E "Starting Controller|Starting EventSource"

echo ""
echo "✅ Phase 2.3 fix applied. Tag: $TAG. Backup: $BACKUP"
