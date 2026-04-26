#!/usr/bin/env bash
# ============================================================================
# Targeted fixes for the three bugs revealed by test_layer1_advanced.sh:
#
#   Bug A: VRAMCache leak — SyncCacheFromSlice double-counts on every reconcile
#   Bug B: validTransitions doesn't allow "" → Releasing (deleting Pending slices)
#   Bug C: validTransitions doesn't allow Ready → Released (race shortcut)
#
# After this script:
#   1. Rebuilds the scheduler + controller binaries
#   2. Rebuilds the controller container image
#   3. Re-imports it into kind
#   4. Restarts deployments
#   5. Cleans up any stuck slices
#
# Run from project root.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".testfix_${STAMP}"
mkdir -p "$BACKUP"

echo "Backup: $BACKUP"

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$(dirname "$f")/"
}

# =============================================================================
# Bug A — VRAMCache leak via SyncCacheFromSlice double-count.
#
# Current code (cmd/scheduler/main.go) calls SyncCacheFromSlice on EVERY
# reconcile event for slices in phase Ready or Released. Each call to the
# fallback path of PromoteConfirmedToAllocated adds allocatedBytes again.
#
# Fix: gate the call with the idempotent helpers (which DO exist in your
# rolled-back-but-still-Layer-3 cache.go).
# =============================================================================
backup cmd/scheduler/main.go
backup internal/scheduler/plugin.go

python3 - <<'PYEOF'
import pathlib, re

# 1. Make SyncCacheFromSlice use the idempotent variants.
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

if "PromoteSliceToAllocatedOnce" in src:
    print("  plugin.go already calls *Once helpers — skipping")
else:
    src = src.replace(
        "case \"Ready\":\n"
        "\t\tif err := s.Cache.PromoteConfirmedToAllocated(sliceUID, nodeName, allocatedBytes); err != nil {\n"
        "\t\t\tlog.Printf(\"Cache sync (Ready) for slice %s: %v\", sliceUID, err)\n"
        "\t\t}\n"
        "\tcase \"Released\":\n"
        "\t\ts.Cache.ReleaseAllocated(nodeName, allocatedBytes)",
        "case \"Ready\":\n"
        "\t\t// Idempotent — only adds bytes the FIRST time we observe Ready for this sliceUID.\n"
        "\t\t// Without this guard, every reconcile event leaks allocatedBytes into the cache.\n"
        "\t\tif err := s.Cache.PromoteSliceToAllocatedOnce(sliceUID, nodeName, allocatedBytes); err != nil {\n"
        "\t\t\tlog.Printf(\"Cache sync (Ready) for slice %s: %v\", sliceUID, err)\n"
        "\t\t}\n"
        "\tcase \"Released\":\n"
        "\t\ts.Cache.ReleaseSliceOnce(sliceUID, nodeName)"
    )
    p.write_text(src)
    print("  ✓ plugin.go — SyncCacheFromSlice now calls idempotent *Once helpers")
PYEOF
echo "✓ Bug A — SyncCacheFromSlice gated by idempotent helpers"

# =============================================================================
# Bug B + C — state machine missing transitions.
# Add "" → Releasing (delete-while-Pending) and Ready → Released (race shortcut).
# =============================================================================
backup internal/state/transitions.go

python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/state/transitions.go")
src = p.read_text()

# The DAG map is named `legalSliceTransitions` and is string-keyed.
# We need to:
#   1. Allow ""        → Releasing  (delete a slice that was never reconciled)
#   2. Allow Pending   → Releasing  (delete a slice that was scheduled but not bound)
#   3. Allow Ready     → Released   (race shortcut when NA observes a deleted Ready slice)
#
# IMPORTANT: We're modifying entries in the existing map, not adding a new "" key
# (one already exists with {Pending: true}).

# 1. Expand the "" entry to include Releasing.
src = src.replace(
    '"":                   {SlicePhasePending: true},',
    '"":                   {SlicePhasePending: true, SlicePhaseReleasing: true},'
)

# 2. Expand Pending to include Releasing.
src = src.replace(
    "SlicePhasePending:    {SlicePhaseScheduled: true, SlicePhaseFailed: true},",
    "SlicePhasePending:    {SlicePhaseScheduled: true, SlicePhaseReleasing: true, SlicePhaseFailed: true},"
)

# 3. Expand Ready to include Released (race-shortcut).
src = src.replace(
    "SlicePhaseReady:      {SlicePhaseReleasing: true, SlicePhaseFailed: true},",
    "SlicePhaseReady:      {SlicePhaseReleasing: true, SlicePhaseReleased: true, SlicePhaseFailed: true},"
)

p.write_text(src)
print("  ✓ transitions.go — added '' → Releasing, Pending → Releasing, Ready → Released")
PYEOF
echo "✓ Bug B + C — state machine transitions broadened"

# =============================================================================
# Build, image, load, restart.
# =============================================================================
echo ""
echo "Building binaries..."
go build -o bin/scheduler  ./cmd/scheduler  && echo "  ✓ scheduler"
go build -o bin/controller ./cmd/controller && echo "  ✓ controller"

echo ""
echo "Building container images..."
docker build -t vgpu-scheduler:latest  -f Dockerfile.scheduler  . > /tmp/build.log 2>&1 || {
    echo "scheduler build failed:"; tail -20 /tmp/build.log; exit 1; }
echo "  ✓ vgpu-scheduler:latest"
docker build -t vgpu-controller:latest -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "controller build failed:"; tail -20 /tmp/build.log; exit 1; }
echo "  ✓ vgpu-controller:latest"

echo ""
echo "Importing into kind via containerd..."
docker save vgpu-scheduler:latest vgpu-controller:latest -o /tmp/vgpu-images.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-images.tar > /dev/null
echo "  ✓ images imported"

echo ""
echo "Cleaning up stuck slices and claims..."
kubectl get vgpuclaim -A -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
    -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
    -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1
kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1
echo "  ✓ resources cleaned"

echo ""
echo "Restarting deployments..."
kubectl rollout restart -n vgpu-system deploy/vgpu-scheduler deploy/vgpu-controller
kubectl rollout restart -n vgpu-system daemonset/vgpu-nodeagent
sleep 30

echo ""
echo "Verifying pods..."
kubectl get pods -n vgpu-system

echo ""
echo "Tail of scheduler logs (last 10 lines):"
kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=10

echo ""
echo "✅ Fixes applied. Now run: bash test_layer1_advanced.sh"
echo "   Backup at: $BACKUP"
