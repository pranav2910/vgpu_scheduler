#!/usr/bin/env bash
# ============================================================================
# fix_gangjob_recreation.sh
#
# Root cause of Test 2.2's failure:
#
# When the reservation reconciler's tearDownChildren deletes a child VGPUJob
# (e.g. fail-test-3), the deletion fires a gang-job reconcile (because the
# gang Owns VGPUJob, watching deletions). The gang reconciler's flow:
#
#   1. If gang.DeletionTimestamp is set → return (cascade handles it)
#   2. Else: ensureChildren() — find missing children, create them
#
# But the gang ITSELF is not being deleted — only its reservation and child
# jobs are being cleaned up by tearDownChildren. So the gang reconciler
# sees a missing child and faithfully re-creates it. Which gets deleted
# again. Forever.
#
# Fix: extend the early-return guard. If the reservation exists and is in
# a terminal phase (Failed or Released), don't materialize children. Let
# the cascade complete and the gang reach its own terminal state.
#
# The check is cheap (one Get on the deterministic reservation name) and
# only blocks on terminal-phase reservations, so it's safe for normal
# operation.
# ============================================================================

set -euo pipefail

R_FILE="internal/controller/vgpugangjob_reconciler.go"

if [[ ! -f "$R_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "gang-job-recreation fix applied" "$R_FILE" 2>/dev/null; then
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

old = '''	// Deletion: cascade is handled by OwnerReferences. Nothing to do.
	if !gang.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// 1. Make sure all N child VGPUJobs exist.
	createdNow, totalExisting, err := r.ensureChildren(ctx, &gang)'''

new = '''	// Deletion: cascade is handled by OwnerReferences. Nothing to do.
	if !gang.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// gang-job-recreation fix applied: if the reservation is in a terminal
	// phase (Failed or Released), don't re-create children that the
	// reservation reconciler's tearDownChildren is actively cleaning up.
	// Without this guard, deletion of a child VGPUJob fires a gang reconcile
	// (via Owns watch), ensureChildren sees the missing child, re-creates
	// it, tearDownChildren deletes it again — infinite loop.
	{
		rsvName := reservationNameForGang(gang.Name)
		var rsv vgpuv1alpha1.VGPUGangReservation
		if err := r.Client.Get(ctx, types.NamespacedName{
			Namespace: gang.Namespace, Name: rsvName,
		}, &rsv); err == nil {
			if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseFailed ||
				rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
				log.Printf("VGPUGangJob %s/%s: reservation in terminal phase %s — skipping child materialization",
					gang.Namespace, gang.Name, rsv.Status.Phase)
				// Still mirror status so the gang itself transitions to
				// Failed/Completed. Use updatePhase's existing logic.
				desired := vgpuv1alpha1.GangPhaseFailed
				if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
					desired = vgpuv1alpha1.GangPhaseFailed
				}
				return r.updatePhase(ctx, &gang, desired,
					"reservation terminated; no further child materialization",
					gang.Spec.GangSize, 0)
			}
		}
		// If err is NotFound or other, fall through — normal materialization
		// path will handle creating the reservation as needed.
	}

	// 1. Make sure all N child VGPUJobs exist.
	createdNow, totalExisting, err := r.ensureChildren(ctx, &gang)'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: anchor not found exactly once (count={src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) > orig, "file should have grown"
p.write_text(src)
print(f"  ~ patched {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

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
echo "✅ Gang-job recreation fix applied."
echo "════════════════════════════════════════════════════════════"
echo
echo "What this fixes:"
echo "  - Test 2.2 infinite loop where deleted child VGPUJobs were"
echo "    immediately re-created by the gang reconciler"
echo "  - Failed-gang teardown can finally complete the cascade"
echo
echo "Deploy:"
echo "  make docker-build"
echo "  kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  kubectl rollout restart deployment/vgpu-controller -n vgpu-system"
echo "  kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo
echo "Pre-test cleanup (clean up the stuck state):"
echo "  for s in \$(kubectl get vgpuslice -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do"
echo "      ns=\${s%/*}; name=\${s#*/}"
echo "      kubectl patch vgpuslice \"\$name\" -n \"\$ns\" --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]' 2>/dev/null || true"
echo "  done"
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  sleep 10"
echo
echo "Then:"
echo "  bash real_world_test.sh"
