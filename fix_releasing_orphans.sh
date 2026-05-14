#!/usr/bin/env bash
# ============================================================================
# fix_releasing_orphans.sh
#
# Fixes the "orphan finalizer" symptom on every test run, and the failure
# of Test 2.2.
#
# Root cause: slices in `Releasing` phase that never reached `Ready`
# (i.e. `Status.AllocationID == ""`) have no way to advance to `Released`.
# The NodeAgent normally drives `Releasing → Released`, but the NodeAgent
# only knows about slices it has allocated hardware for. A slice that was
# bound (Scheduled) but failed to allocate, OR was force-deleted before
# the NodeAgent observed it, has no AllocationID and is invisible to the
# NodeAgent. It sits in Releasing forever with its finalizer.
#
# Two sub-symptoms:
#
#   1. Every Test 1.1 / 1.2 run leaves "orphan finalizer" warnings (the
#      namespace stays in Terminating for > 60s because slices won't go).
#      These are losing gangs' slices — they were bound briefly, then the
#      reservation's tearDownChildren deleted them. With no AllocationID
#      they sit in Releasing.
#
#   2. Test 2.2 FAILS outright because child slices in Releasing phase
#      hold their parent claims, which hold the parent jobs, which hold
#      the namespace open.
#
# Fix: extend the slice reconciler's "neverBound" fast-path to also catch
# slices in Releasing phase that have no AllocationID. They cannot have
# released hardware they never allocated, so removing the finalizer is
# safe and correct.
#
# Net change: 2-line update to the `neverBound` condition.
#
# Idempotent: re-running after success is a no-op.
# ============================================================================

set -euo pipefail

S_FILE="internal/controller/vgpuslice_reconciler.go"

if [[ ! -f "$S_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "// releasing-orphan fix applied" "$S_FILE" 2>/dev/null; then
    echo "✓ Patch already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$S_FILE" "${S_FILE}.bak.${TS}"
echo "Backup: ${S_FILE}.bak.${TS}"

restore() { cp "${S_FILE}.bak.${TS}" "$S_FILE"; }
trap 'restore; echo "ABORTED — file restored"' ERR

python3 - "$S_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

old = '''	// Never-bound slices: no hardware was allocated, so there is nothing for
	// the NodeAgent to release. Bypass the Releasing phase entirely and remove
	// the finalizer directly. Without this branch, tightening the DAG (which
	// now rejects Pending->Releasing) leaves Pending slices stuck during
	// deletion because the transition fails and the finalizer never lifts.
	neverBound := slice.Status.AllocationID == "" &&
		(currentPhase == state.SlicePhasePending || currentPhase == "")'''

new = '''	// releasing-orphan fix applied: extended "neverBound" to also catch
	// slices stuck in Releasing/Scheduled phases with no AllocationID.
	// These slices were bound (assigned a nodeName) but the NodeAgent
	// never allocated hardware for them — either because the gang failed
	// at deadline and tearDown deleted the slice before NodeAgent
	// processed it, or because something else interrupted the bind →
	// allocate transition. The NodeAgent doesn't know about these slices,
	// so it never advances Releasing → Released. Without this fix, every
	// failed-gang test run leaks slices that hold finalizers forever.
	//
	// Safe to remove the finalizer directly: no hardware was allocated
	// (AllocationID == ""), so there is nothing for the NodeAgent to free.
	neverBound := slice.Status.AllocationID == "" &&
		(currentPhase == state.SlicePhasePending ||
			currentPhase == "" ||
			currentPhase == state.SlicePhaseReleasing ||
			currentPhase == state.SlicePhaseScheduled)'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: anchor not found exactly once (count={src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) > orig, "file should have grown"
p.write_text(src)
print(f"  ~ patched {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

gofmt -w "$S_FILE" 2>/dev/null || true

trap - ERR
if go build ./...; then
    echo "  ✓ go build clean"
else
    echo "  ✗ go build FAILED — restoring"
    restore
    exit 1
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "✅ Releasing-orphan fix applied."
echo "════════════════════════════════════════════════════════════"
echo
echo "What this fixes:"
echo "  - 'orphan finalizer' warnings on Test 1.1 / 1.2 runs"
echo "  - Test 2.2 failed-gang teardown leaves slices in Releasing forever"
echo "  - Namespaces staying in Terminating state after tests"
echo
echo "Deploy:"
echo "  make docker-build"
echo "  kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  kubectl rollout restart deployment/vgpu-controller -n vgpu-system"
echo "  kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo
echo "Note: only the controller needs rebuilding."
echo
echo "Pre-test cleanup (necessary because previous runs leaked stuck slices):"
echo "  for s in \$(kubectl get vgpuslice -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do"
echo "      ns=\${s%/*}; name=\${s#*/}"
echo "      kubectl patch vgpuslice \"\$name\" -n \"\$ns\" --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]' 2>/dev/null || true"
echo "  done"
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  sleep 10"
echo "  kubectl get vgpuslice -A   # 'No resources found'"
echo
echo "Then test:"
echo "  bash real_world_test.sh"
