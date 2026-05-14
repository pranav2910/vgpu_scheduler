#!/usr/bin/env bash
# ============================================================================
# fix_scheduler_gang_rbac.sh
#
# Adds VGPUGangReservation read permissions to the scheduler's ClusterRole.
#
# Symptom: scheduler logs show repeated
#   "vgpugangreservations.infrastructure.pranav2910.com is forbidden:
#    User \"system:serviceaccount:vgpu-system:vgpu-scheduler-sa\"
#    cannot list resource \"vgpugangreservations\" at the cluster scope"
#
# Root cause: the scheduler's GangBindingGate uses controller-runtime's
# typed Client, which reads through an informer cache. The informer
# requires list+watch on every type the client touches. When the gang
# gate was wired (gang-wiring fix), it added VGPUGangReservation reads
# without adding the corresponding RBAC. The failing watch:
#
#   1. blocks the informer factory's WaitForCacheSync()
#   2. which prevents the controller-runtime manager from starting workers
#   3. so NO reconciliation runs at all
#   4. resulting in slices stuck in empty phase forever
#
# Fix: add VGPUGangReservation to the scheduler ClusterRole and re-apply.
#
# Idempotent: re-running after success is a no-op.
# ============================================================================

set -euo pipefail

RBAC_FILE="deployments/manifests/rbac/scheduler_rbac.yaml"

if [[ ! -f "$RBAC_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "vgpugangreservations" "$RBAC_FILE"; then
    echo "✓ RBAC already grants vgpugangreservations. Re-applying to live cluster anyway."
    kubectl apply -f "$RBAC_FILE"
    exit 0
fi

TS=$(date +%s)
cp "$RBAC_FILE" "${RBAC_FILE}.bak.${TS}"
echo "Backup: ${RBAC_FILE}.bak.${TS}"

python3 - "$RBAC_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

# Anchor: the vgpuquotas rule is the last vgpu-resource rule in the existing
# file. We insert vgpugangreservations after it.
old = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuquotas"]
    verbs: ["get", "list", "watch"]
'''
new = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuquotas"]
    verbs: ["get", "list", "watch"]
  # gang-wiring fix: scheduler reads VGPUGangReservation via the gang gate.
  # controller-runtime's typed client requires list+watch for the informer
  # cache; without these the cache sync hangs and no reconciler runs.
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpugangreservations"]
    verbs: ["get", "list", "watch"]
'''
if src.count(old) != 1:
    sys.stderr.write(f"ERROR: anchor not found exactly once (count={src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) > orig, "file did not grow"
p.write_text(src)
print(f"  ~ patched {p} ({orig} -> {len(src)} bytes)")
PYEOF

echo
echo "Applying to cluster..."
kubectl apply -f "$RBAC_FILE"

echo
echo "Restarting scheduler so the failed informer reflector reconnects..."
kubectl rollout restart deployment/vgpu-scheduler -n vgpu-system
kubectl rollout status deployment/vgpu-scheduler -n vgpu-system --timeout=120s

echo
echo "Verifying scheduler can now list reservations (should print empty list, not Forbidden)..."
sleep 3
SCHED_POD=$(kubectl get pods -n vgpu-system -l control-plane=vgpu-scheduler -o jsonpath='{.items[0].metadata.name}')
if kubectl logs -n vgpu-system "$SCHED_POD" --tail=50 | grep -i "forbidden.*vgpugangreservation"; then
    echo "  ✗ scheduler is still seeing Forbidden errors"
    exit 1
else
    echo "  ✓ no more Forbidden errors in fresh logs"
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "✅ Scheduler RBAC fixed."
echo "════════════════════════════════════════════════════════════"
echo
echo "Next:"
echo "  1. Clean up the wedged test namespace:"
echo "     kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "     sleep 5"
echo "     kubectl get vgpuslice -A   # should be 'No resources found'"
echo "  2. Re-run the battery:"
echo "     bash real_world_test.sh"
