#!/usr/bin/env bash
# ============================================================================
# fix_test_2_2_timing.sh
#
# Test 2.2 currently snapshots child-object counts 10 seconds after the
# reservation reaches Failed phase, then asserts they're all zero.
#
# The cascade delete via foreground propagation takes longer than 10s in
# practice (we observed ~12s in the most recent run). The reservation
# reconciler correctly drives teardown: it transitions Failed -> Released
# after verifying all children are gone. We just need to wait for that.
#
# Fix: replace the fixed sleep with a poll-and-wait loop that exits early
# when cleanup completes, with a generous 60s ceiling.
# ============================================================================

set -euo pipefail

T_FILE="real_world_test.sh"

if [[ ! -f "$T_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "test-2-2-timing fix applied" "$T_FILE" 2>/dev/null; then
    echo "✓ Patch already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$T_FILE" "${T_FILE}.bak.${TS}"
echo "Backup: ${T_FILE}.bak.${TS}"

python3 - "$T_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

old = '''    # Wait for the reconciler's teardown to complete
    sleep 10

    local final_committed; final_committed=$(committed_bytes)
    local remaining_slices remaining_claims remaining_jobs
    remaining_slices=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null | wc -l)
    remaining_claims=$(kubectl get vgpuclaim -n "$ns" --no-headers 2>/dev/null | wc -l)
    remaining_jobs=$(kubectl get vgpujob -n "$ns" --no-headers 2>/dev/null | wc -l)'''

new = '''    # test-2-2-timing fix applied: poll for teardown completion instead of
    # fixed sleep. The reservation reconciler drives cascade-delete via
    # foreground propagation, which can take 10-20s. It transitions
    # Failed -> Released once all children are confirmed gone.
    local final_committed remaining_slices remaining_claims remaining_jobs
    local waited=0
    while [[ $waited -lt 60 ]]; do
        remaining_slices=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        remaining_claims=$(kubectl get vgpuclaim -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        remaining_jobs=$(kubectl get vgpujob -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$remaining_slices" == "0" && "$remaining_claims" == "0" && "$remaining_jobs" == "0" ]]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    final_committed=$(committed_bytes)'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: anchor not found exactly once (count={src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) > orig, "file should have grown"
p.write_text(src)
print(f"  ~ patched {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

echo
echo "Patch applied. Now re-run the battery:"
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  sleep 5"
echo "  bash real_world_test.sh"
