#!/usr/bin/env bash
# ============================================================================
# Quick fix: add missing "time" import to vgpuclaim_reconciler.go
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

FILE="internal/controller/vgpuclaim_reconciler.go"

if grep -q '"time"' "$FILE"; then
    echo "  - time already imported, weird; check go vet output"
    exit 0
fi

# Use goimports if available — it's the cleanest fix
if command -v goimports >/dev/null 2>&1; then
    echo "Running goimports..."
    goimports -w "$FILE"
    echo "  ✓ goimports added missing imports"
else
    # Manual: append "time" to the import block. Find the closing `)` of
    # imports (the FIRST `)` that follows `import (`).
    python3 - <<'PYEOF'
import pathlib, re

p = pathlib.Path("internal/controller/vgpuclaim_reconciler.go")
src = p.read_text()

# Find import block — match the entire `import ( ... )` even with newlines
m = re.search(r'(import\s*\()([^)]*)(\))', src, re.DOTALL)
if not m:
    print("ERROR: import block not found")
    raise SystemExit(1)

opening = m.group(1)
body = m.group(2)
closing = m.group(3)

if '"time"' in body:
    print("  - time already in imports")
else:
    # Add time as the first stdlib import (alphabetical with context, fmt etc)
    # Easiest: just append to the body before the closing paren
    new_body = body.rstrip() + '\n\t"time"\n'
    src = src[:m.start()] + opening + new_body + closing + src[m.end():]
    p.write_text(src)
    print("  ✓ time import added")
PYEOF
fi

echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo "ERROR: go vet still failing"
    exit 1
fi

echo ""
echo "Building..."
go build -o bin/controller ./cmd/controller || { echo "build failed"; exit 1; }
echo "  ✓ controller builds"

# ============================================================================
# Image + deploy
# ============================================================================
TAG="claimfix2_$(date +%s)"
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ image built ($TAG)"

docker save vgpu-controller:$TAG -o /tmp/vgpu-claimfix2.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-claimfix2.tar > /dev/null

kubectl set image -n vgpu-system deploy/vgpu-controller manager=vgpu-controller:$TAG
kubectl patch deploy -n vgpu-system vgpu-controller --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl delete pod -n vgpu-system -l control-plane=vgpu-controller --wait=false

# Cleanup orphans
sleep 30

for ns in default ml-team-a ml-team-pre team-prod team-research; do
    kubectl get vgpujob,vgpuclaim,vgpuslice -n $ns -o name 2>/dev/null | \
        xargs -I{} kubectl patch {} -n $ns --type=json \
            -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null
done
kubectl get vgpuquota -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
        -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null

kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 30

echo ""
echo "=== Cluster state ==="
kubectl get vgpujob -A
kubectl get vgpuclaim -A
kubectl get vgpuslice -A
kubectl get vgpuquota

echo ""
echo "=== Controller image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-controller \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ Done. Tag: $TAG"
