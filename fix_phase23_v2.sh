#!/usr/bin/env bash
# ============================================================================
# Phase 2.3 fix v2: regex-based anchor matching, less brittle.
# Inserts the Preempting handler at the right place in Reconcile().
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".phase23fix2_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/controller/vgpuslice_reconciler.go "$BACKUP/vgpuslice_reconciler.go"
echo "Backup: $BACKUP"

# ============================================================================
# 1. Inject Preempting handler in Reconcile() using regex
# ============================================================================
python3 - <<'PYEOF'
import pathlib, re

p = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
src = p.read_text()

if "Layer 2 Phase 2.3" in src and "grace remaining" in src:
    print("  - Reconcile already has Preempting handler")
    raise SystemExit(0)

# Pattern: match the Get block + reconcileSlice call with flexible whitespace.
# We want to inject between them.
pattern = re.compile(
    r'(if\s+err\s*:=\s*r\.Client\.Get\(ctx,\s*req\.NamespacedName,\s*&slice\);\s*err\s*!=\s*nil\s*\{[^}]*?\bfetching VGPUSlice:[^}]*?\}\s*\n)'
    r'(\s*)(if\s+err\s*:=\s*r\.reconcileSlice\(ctx,\s*&slice\);)',
    re.DOTALL
)

m = pattern.search(src)
if not m:
    print("ERROR: regex did not match Reconcile body")
    print("Showing first 500 chars of Reconcile:")
    rm = re.search(r'func \(r \*VGPUSliceReconciler\) Reconcile[^}]+\}', src, re.DOTALL)
    if rm:
        print(rm.group(0)[:500])
    raise SystemExit(1)

# Indent matches the existing reconcileSlice call's indentation.
indent = m.group(2)

# Build the injection. We use state.SlicePhaseReleased since that's what's
# imported in the file and what the existing logic uses.
injection = (
    m.group(1)
    + "\n"
    + indent + "// Layer 2 Phase 2.3: Preempting phase has its own lifecycle.\n"
    + indent + "// Honour per-Job grace period, then transition to Released so\n"
    + indent + "// existing cleanup runs.\n"
    + indent + 'if string(slice.Status.Phase) == "Preempting" {\n'
    + indent + "\tgrace := 30 * time.Second\n"
    + indent + "\tif slice.Spec.ClaimRef != \"\" {\n"
    + indent + "\t\tvar claim vgpuv1alpha1.VGPUClaim\n"
    + indent + "\t\tif err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {\n"
    + indent + "\t\t\tif claim.Spec.JobRef != \"\" {\n"
    + indent + "\t\t\t\tvar job vgpuv1alpha1.VGPUJob\n"
    + indent + "\t\t\t\tif err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {\n"
    + indent + "\t\t\t\t\tif job.Spec.PreemptionGraceSeconds != nil && *job.Spec.PreemptionGraceSeconds > 0 {\n"
    + indent + "\t\t\t\t\t\tgrace = time.Duration(*job.Spec.PreemptionGraceSeconds) * time.Second\n"
    + indent + "\t\t\t\t\t}\n"
    + indent + "\t\t\t\t}\n"
    + indent + "\t\t\t}\n"
    + indent + "\t\t}\n"
    + indent + "\t}\n"
    + indent + "\tvar since time.Time\n"
    + indent + "\tfor _, c := range slice.Status.Conditions {\n"
    + indent + "\t\tif c.Type == \"Preempting\" {\n"
    + indent + "\t\t\tsince = c.LastTransitionTime.Time\n"
    + indent + "\t\t\tbreak\n"
    + indent + "\t\t}\n"
    + indent + "\t}\n"
    + indent + "\tif since.IsZero() {\n"
    + indent + "\t\tsince = time.Now()\n"
    + indent + "\t}\n"
    + indent + "\telapsed := time.Since(since)\n"
    + indent + "\tif elapsed < grace {\n"
    + indent + "\t\tremaining := grace - elapsed\n"
    + indent + '\t\tlog.Printf("[preempting] %s/%s grace remaining %v", slice.Namespace, slice.Name, remaining.Round(time.Second))\n'
    + indent + "\t\treturn reconcile.Result{RequeueAfter: remaining}, nil\n"
    + indent + "\t}\n"
    + indent + '\tlog.Printf("[preempting] %s/%s grace expired -> Released", slice.Namespace, slice.Name)\n'
    + indent + "\tslice.Status.Phase = state.SlicePhaseReleased\n"
    + indent + "\tif err := r.Client.Status().Update(ctx, &slice); err != nil {\n"
    + indent + "\t\treturn reconcile.Result{}, err\n"
    + indent + "\t}\n"
    + indent + "\treturn reconcile.Result{Requeue: true}, nil\n"
    + indent + "}\n\n"
    + m.group(2) + m.group(3)
)

src = src.replace(m.group(0), injection)
p.write_text(src)
print("  ✓ Reconcile() now handles Preempting phase")
PYEOF

# ============================================================================
# 2. Verify Phase type and adjust the assignment if needed
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

# Now check the state package's SlicePhaseReleased declaration to make sure it's
# the same type as slice.Status.Phase.
state_p = pathlib.Path("internal/state/phases.go")
if state_p.exists():
    sp = state_p.read_text()
    m = re.search(r'SlicePhaseReleased\s*(\w*)\s*=', sp)
    if m:
        print(f"  - state.SlicePhaseReleased declared (matches type: {m.group(1) or 'inferred'})")
PYEOF

# ============================================================================
# 3. Build
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo ""
    echo "go vet failed. Showing the relevant section of vgpuslice_reconciler.go:"
    sed -n '/Layer 2 Phase 2.3/,/^	}/p' internal/controller/vgpuslice_reconciler.go | head -50
    echo ""
    echo "Backup at: $BACKUP"
    exit 1
fi

echo ""
echo "Building..."
go build -o bin/controller ./cmd/controller || { echo "controller build failed"; exit 1; }
go build -o bin/scheduler ./cmd/scheduler || { echo "scheduler build failed"; exit 1; }
echo "  ✓ both built"

# ============================================================================
# 4. Image + deploy
# ============================================================================
TAG="p23fix2$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "scheduler image build failed:"; tail -10 /tmp/build.log; exit 1
}
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ images built ($TAG)"

docker save vgpu-scheduler:$TAG vgpu-controller:$TAG -o /tmp/vgpu-p23fix2.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23fix2.tar > /dev/null

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
echo "=== Controller logs (looking for VGPUSlice reconciler restart) ==="
kubectl logs -n vgpu-system deploy/vgpu-controller --tail=20 | grep -E "Starting Controller"

echo ""
echo "✅ Phase 2.3 complete. Tag: $TAG. Backup: $BACKUP"
