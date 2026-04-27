#!/usr/bin/env bash
# ============================================================================
# Phase 2.3 fix v3 — line-based injection (no fragile regex)
# Inserts Preempting handler in Reconcile() between the Get-error block and
# the reconcileSlice call.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".phase23fix3_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/controller/vgpuslice_reconciler.go "$BACKUP/vgpuslice_reconciler.go"
echo "Backup: $BACKUP"

# ============================================================================
# Inject Preempting handler line-by-line, treating the file as a sequence
# of lines instead of trying to regex-match across braces.
# ============================================================================
python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
src = p.read_text()

# Already injected?
if "Layer 2 Phase 2.3" in src and "grace remaining" in src:
    print("  - Reconcile already has Preempting handler")
    raise SystemExit(0)

lines = src.splitlines(keepends=True)

# Find the line that calls reconcileSlice, then walk backward to find the
# end of the Get-error block, and inject right before reconcileSlice.
target_idx = None
for i, line in enumerate(lines):
    if "r.reconcileSlice(ctx, &slice)" in line:
        target_idx = i
        break

if target_idx is None:
    print("ERROR: could not find r.reconcileSlice(ctx, &slice) line")
    raise SystemExit(1)

print(f"  - Found reconcileSlice call at line {target_idx + 1}")

# Detect the indentation of the target line (tabs vs spaces).
target_line = lines[target_idx]
leading = ""
for ch in target_line:
    if ch in " \t":
        leading += ch
    else:
        break

# Build the injection, using detected indentation. This is a single string
# we'll insert *before* the target line.
indent = leading
inj = []
inj.append(indent + "// Layer 2 Phase 2.3: Preempting phase has its own lifecycle.\n")
inj.append(indent + "// Honour per-Job grace period (default 30s, configurable up to 3600s),\n")
inj.append(indent + "// then transition to Released so existing cleanup runs.\n")
inj.append(indent + 'if string(slice.Status.Phase) == "Preempting" {\n')
inj.append(indent + "\tgrace := 30 * time.Second\n")
inj.append(indent + "\tif slice.Spec.ClaimRef != \"\" {\n")
inj.append(indent + "\t\tvar claim vgpuv1alpha1.VGPUClaim\n")
inj.append(indent + "\t\tif err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {\n")
inj.append(indent + "\t\t\tif claim.Spec.JobRef != \"\" {\n")
inj.append(indent + "\t\t\t\tvar job vgpuv1alpha1.VGPUJob\n")
inj.append(indent + "\t\t\t\tif err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {\n")
inj.append(indent + "\t\t\t\t\tif job.Spec.PreemptionGraceSeconds != nil && *job.Spec.PreemptionGraceSeconds > 0 {\n")
inj.append(indent + "\t\t\t\t\t\tgrace = time.Duration(*job.Spec.PreemptionGraceSeconds) * time.Second\n")
inj.append(indent + "\t\t\t\t\t}\n")
inj.append(indent + "\t\t\t\t}\n")
inj.append(indent + "\t\t\t}\n")
inj.append(indent + "\t\t}\n")
inj.append(indent + "\t}\n")
inj.append(indent + "\tvar since time.Time\n")
inj.append(indent + "\tfor _, c := range slice.Status.Conditions {\n")
inj.append(indent + "\t\tif c.Type == \"Preempting\" {\n")
inj.append(indent + "\t\t\tsince = c.LastTransitionTime.Time\n")
inj.append(indent + "\t\t\tbreak\n")
inj.append(indent + "\t\t}\n")
inj.append(indent + "\t}\n")
inj.append(indent + "\tif since.IsZero() {\n")
inj.append(indent + "\t\tsince = time.Now()\n")
inj.append(indent + "\t}\n")
inj.append(indent + "\telapsed := time.Since(since)\n")
inj.append(indent + "\tif elapsed < grace {\n")
inj.append(indent + "\t\tremaining := grace - elapsed\n")
inj.append(indent + '\t\tlog.Printf("[preempting] %s/%s grace remaining %v", slice.Namespace, slice.Name, remaining.Round(time.Second))\n')
inj.append(indent + "\t\treturn reconcile.Result{RequeueAfter: remaining}, nil\n")
inj.append(indent + "\t}\n")
inj.append(indent + '\tlog.Printf("[preempting] %s/%s grace expired -> Released", slice.Namespace, slice.Name)\n')
inj.append(indent + "\tslice.Status.Phase = state.SlicePhaseReleased\n")
inj.append(indent + "\tif err := r.Client.Status().Update(ctx, &slice); err != nil {\n")
inj.append(indent + "\t\treturn reconcile.Result{}, err\n")
inj.append(indent + "\t}\n")
inj.append(indent + "\treturn reconcile.Result{Requeue: true}, nil\n")
inj.append(indent + "}\n")
inj.append("\n")  # blank line after the block

# Insert the injection just before the reconcileSlice line.
new_lines = lines[:target_idx] + inj + lines[target_idx:]
p.write_text("".join(new_lines))
print(f"  ✓ Injected {len(inj)} lines of Preempting handler before line {target_idx + 1}")
PYEOF

# ============================================================================
# Verify build
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo ""
    echo "go vet failed. Showing the injection site (search for 'Layer 2 Phase 2.3'):"
    grep -n "Layer 2 Phase 2.3" -A 60 internal/controller/vgpuslice_reconciler.go | head -80
    echo ""
    echo "Backup at: $BACKUP"
    exit 1
fi

echo ""
echo "Building..."
go build -o bin/controller ./cmd/controller || {
    echo "controller build failed — restoring"
    cp -p "$BACKUP/vgpuslice_reconciler.go" internal/controller/vgpuslice_reconciler.go
    exit 1
}
go build -o bin/scheduler ./cmd/scheduler || {
    echo "scheduler build failed"
    exit 1
}
echo "  ✓ both built"

# ============================================================================
# Image + deploy
# ============================================================================
TAG="p23fix3_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "scheduler image build failed:"; tail -10 /tmp/build.log; exit 1
}
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ images built ($TAG)"

docker save vgpu-scheduler:$TAG vgpu-controller:$TAG -o /tmp/vgpu-p23fix3.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23fix3.tar > /dev/null

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
kubectl logs -n vgpu-system deploy/vgpu-controller --tail=20 | grep -E "Starting Controller"

echo ""
echo "✅ Phase 2.3 wiring complete. Tag: $TAG. Backup: $BACKUP"
