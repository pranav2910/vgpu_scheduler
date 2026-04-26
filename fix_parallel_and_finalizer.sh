#!/usr/bin/env bash
# ============================================================================
# Two more targeted fixes:
#   Bug 1: UpdateNode zeroes AllocatedVRAMBytes on every node-watch event,
#          which lets parallel allocations exceed capacity.
#   Bug 2: handleClaimDelete doesn't reliably remove the claim finalizer
#          when the slice is already gone — wrap Update in retry-on-conflict.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".cachefix_${STAMP}"
mkdir -p "$BACKUP"

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$(dirname "$f")/"
}

backup internal/scheduler/cache.go
backup internal/controller/vgpuclaim_reconciler.go

# ============================================================================
# Bug 1 — UpdateNode must NOT clobber AllocatedVRAMBytes the scheduler tracked
# from confirmed reservations. The K8s API tells us nothing useful about
# vGPU consumption (no extended-resource accounting on extended resources),
# so AllocatedVRAMBytes is authoritative ONLY in the scheduler's cache.
#
# Fix: when the API reports allocatedBytes==0, ignore it. Only update
# AllocatedVRAMBytes if the API genuinely tells us something larger.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/cache.go")
src = p.read_text()

src = src.replace(
    "\tnode.TotalVRAMBytes = totalBytes\n"
    "\tnode.AllocatedVRAMBytes = allocatedBytes\n"
    "\t// Do NOT touch ReservedVRAMBytes — it is managed by AssumeSlice /\n"
    "\t// RollbackAssumedSlice / PromoteConfirmedToAllocated and must survive node\n"
    "\t// watch events.\n"
    "\tc.recalculateFreeVRAM(node)\n"
    "}",
    "\tnode.TotalVRAMBytes = totalBytes\n"
    "\t// Bug fix (parallel allocation): the API server does not track vGPU\n"
    "\t// consumption (no kubelet bookkeeping for our extended resource), so a\n"
    "\t// naive UpdateNode call from the node-watch reconciler reports\n"
    "\t// allocatedBytes=0 even when slices are Ready. Trusting that value\n"
    "\t// resets the cache's view of consumed capacity and lets parallel\n"
    "\t// allocations exceed the node's actual size.\n"
    "\t//\n"
    "\t// The scheduler's own cache (driven by PromoteSliceToAllocatedOnce /\n"
    "\t// ReleaseSliceOnce) is the authoritative source. Only honor a higher\n"
    "\t// allocatedBytes from the API (e.g. on initial seed for a node that\n"
    "\t// already has workloads from a previous scheduler instance).\n"
    "\tif allocatedBytes > node.AllocatedVRAMBytes {\n"
    "\t\tnode.AllocatedVRAMBytes = allocatedBytes\n"
    "\t}\n"
    "\t// Do NOT touch ReservedVRAMBytes — it is managed by AssumeSlice /\n"
    "\t// RollbackAssumedSlice / PromoteConfirmedToAllocated and must survive\n"
    "\t// node watch events.\n"
    "\tc.recalculateFreeVRAM(node)\n"
    "}"
)
p.write_text(src)
print("  ✓ cache.go — UpdateNode preserves cache-tracked allocations")
PYEOF

# ============================================================================
# Bug 2 — handleClaimDelete uses Update without retry-on-conflict, and
# returns nil after a failed Update so the reconciler never retries.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/controller/vgpuclaim_reconciler.go")
src = p.read_text()

# Add retry import if missing.
if '"k8s.io/client-go/util/retry"' not in src:
    src = src.replace(
        '"k8s.io/apimachinery/pkg/api/errors"',
        '"k8s.io/apimachinery/pkg/api/errors"\n\t"k8s.io/client-go/util/retry"',
        1
    )

# Replace the finalizer-removal tail with retry-on-conflict + fresh Get each attempt.
src = src.replace(
    "\t// Slice gone — safe to remove the claim's finalizer.\n"
    "\tif RemoveFinalizer(claim, ClaimFinalizerName) {\n"
    "\t\treturn r.Client.Update(ctx, claim)\n"
    "\t}\n"
    "\treturn nil\n"
    "}",
    "\t// Slice gone — safe to remove the claim's finalizer.\n"
    "\t// retry-on-conflict: the claim may have been mutated by another\n"
    "\t// controller (status sync, kubectl edits, etc.) between our cached\n"
    "\t// read and the Update. A fresh Get each attempt avoids stale\n"
    "\t// resourceVersion conflicts.\n"
    "\tkey := types.NamespacedName{Namespace: claim.Namespace, Name: claim.Name}\n"
    "\treturn retry.RetryOnConflict(retry.DefaultRetry, func() error {\n"
    "\t\tvar fresh vgpuv1alpha1.VGPUClaim\n"
    "\t\tif err := r.Client.Get(ctx, key, &fresh); err != nil {\n"
    "\t\t\tif errors.IsNotFound(err) {\n"
    "\t\t\t\treturn nil // already gone\n"
    "\t\t\t}\n"
    "\t\t\treturn err\n"
    "\t\t}\n"
    "\t\tif !RemoveFinalizer(&fresh, ClaimFinalizerName) {\n"
    "\t\t\treturn nil // finalizer already removed\n"
    "\t\t}\n"
    "\t\treturn r.Client.Update(ctx, &fresh)\n"
    "\t})\n"
    "}"
)
p.write_text(src)
print("  ✓ vgpuclaim_reconciler.go — finalizer removal wrapped in RetryOnConflict")
PYEOF

# ============================================================================
# Build, image, restart.
# ============================================================================
echo ""
echo "Building binaries..."
go build -o bin/scheduler  ./cmd/scheduler  && echo "  ✓ scheduler"
go build -o bin/controller ./cmd/controller && echo "  ✓ controller"

echo ""
echo "Building container images..."
docker build -t vgpu-scheduler:latest  -f Dockerfile.scheduler  . > /tmp/build.log 2>&1 \
    && echo "  ✓ vgpu-scheduler:latest" \
    || { echo "scheduler build failed:"; tail -20 /tmp/build.log; exit 1; }
docker build -t vgpu-controller:latest -f Dockerfile.controller . > /tmp/build.log 2>&1 \
    && echo "  ✓ vgpu-controller:latest" \
    || { echo "controller build failed:"; tail -20 /tmp/build.log; exit 1; }

echo ""
echo "Importing into kind..."
docker save vgpu-scheduler:latest vgpu-controller:latest -o /tmp/vgpu-images.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-images.tar > /dev/null
echo "  ✓ images imported"

echo ""
echo "Cleaning stale resources..."
kubectl get vgpuclaim -A -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
    -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
    -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1
kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1
sleep 5

echo ""
echo "Restarting pods..."
kubectl rollout restart -n vgpu-system deploy/vgpu-scheduler deploy/vgpu-controller >/dev/null
sleep 30

echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "✅ Fixes applied. Backup: $BACKUP"
echo ""
echo "To verify:"
echo "  bash test_layer1_advanced.sh 2>&1 | tee test_results_v3.txt"
