#!/usr/bin/env bash
# ============================================================================
# fix_first_reserving_time.sh
#
# Fixes the remaining issue from Test 1.1 with Option B installed:
# losing gangs (g3/g4/g5 in the 5-gang/2-fits scenario) sit in Reserving
# forever because their FirstReservingTime is never stamped, so the 60s
# deadline never fires, so they never transition to Failed.
#
# Root cause: applyPhase's lazy-stamping condition was added in Wave 1 fix A
# to avoid premature deadlines while slices were still materializing. But
# with Option B, slice materialization completes within seconds, and the
# original concern is no longer warranted. Losing gangs whose slices stay
# in Pending/empty phase (because cluster is full) never satisfy
// `anyReserved` or `allObserved`, so FirstReservingTime stays nil forever.
#
# Fix: stamp FirstReservingTime unconditionally on first transition into
# Reserving. The deadline countdown starts immediately; gangs that can't
# reach quorum within deadline_seconds get cleanly marked Failed.
#
# Safe with Option B because:
#   1. Slice materialization (claim → slice) happens in <2 seconds typically
#   2. Even losing gangs DO get their slices created — they just can't pass
#      Filter due to capacity. That's a real scheduling failure deserving of
#      timely Failed transition.
#   3. The default deadline of 60s is generous for normal materialization
#      AND meaningful for capacity-bound failures.
#
# Idempotent: re-running after success is a no-op.
# ============================================================================

set -euo pipefail

R_FILE="internal/controller/vgpugangreservation_reconciler.go"

if [[ ! -f "$R_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "// firstReservingTime fix applied" "$R_FILE" 2>/dev/null; then
    echo "✓ Patch already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$R_FILE" "${R_FILE}.bak.${TS}"
echo "Backup: ${R_FILE}.bak.${TS}"

restore() { cp "${R_FILE}.bak.${TS}" "$R_FILE"; }
trap 'restore; echo "ABORTED — file restored"' ERR

python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

# Replace the lazy-stamping block with unconditional stamping.
old = '''		// Lazy FirstReservingTime: stamp only when materialization is done
		// (any slot reserved OR every claim has a slice).
		if nextPhase == vgpuv1alpha1.ReservationPhaseReserving && fresh.Status.FirstReservingTime == nil {
			slicesExist := len(t.perSlice) > 0
			anyReserved := t.reservedSlots > 0
			// Bug 5 partial fix: any non-pending observation counts as
			// "materialization done" — we observed something concrete about
			// every claim, so deadline can start.
			allObserved := slicesExist && (t.pendingSlots+t.missingSlots == 0)
			if anyReserved || allObserved {
				now := metav1.Now()
				fresh.Status.FirstReservingTime = &now
			}
		}'''

new = '''		// firstReservingTime fix applied: stamp unconditionally on first
		// transition into Reserving. With Option B (hold-the-reservation
		// gang gate) deployed, slice materialization is fast (<2s), so the
		// original lazy-stamping concern from Wave 1 fix A is no longer
		// warranted. Losing gangs whose slices stay in Pending/empty phase
		// (because the cluster is full) need the deadline to fire so they
		// can be cleanly marked Failed; otherwise they sit forever.
		if nextPhase == vgpuv1alpha1.ReservationPhaseReserving && fresh.Status.FirstReservingTime == nil {
			now := metav1.Now()
			fresh.Status.FirstReservingTime = &now
		}'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: anchor not found exactly once (count={src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) < orig, "file should have shrunk"
p.write_text(src)
print(f"  ~ patched {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

# gofmt check
gofmt -w "$R_FILE" 2>/dev/null || true

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
echo "✅ firstReservingTime stamping fix applied."
echo "════════════════════════════════════════════════════════════"
echo
echo "Deploy:"
echo "  make docker-build"
echo "  kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  kubectl rollout restart deployment/vgpu-controller -n vgpu-system"
echo "  kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo
echo "Note: only the controller image needs to be rebuilt + reloaded —"
echo "the change is purely in the controller's reservation reconciler."
echo
echo "Test:"
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  sleep 5"
echo "  bash real_world_test.sh"
