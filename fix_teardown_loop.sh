#!/usr/bin/env bash
# ============================================================================
# fix_teardown_loop.sh
#
# Fixes the self-reinforcing teardown loop in vgpugangreservation_reconciler.go
# uncovered by Test 1.1.
#
# Root cause:
#   tallyChildSlices counts a claim/slice with DeletionTimestamp set as
#   failedSlots. But DeletionTimestamp is set BY tearDownChildren during
#   normal cascade-delete. So the loop is:
#
#     1. Slot-reserve fails → genuine slice in Failed phase
#     2. tally sees failedSlots=1 → decideNextPhase returns Failed
#     3. Reconcile's transition path runs tearDownChildren
#     4. tearDownChildren sets DeletionTimestamp on every child via
#        foreground-propagation Delete
#     5. Next reconcile: tally sees DeletionTimestamps on 4 claims
#        → reports failedSlots=4 → "slot failure: 4 slot(s) could not be
#        scheduled" → tearDown again → forever
#
#   And separately, applyPhase returns the not-found error when a reservation
#   is deleted out from under the reconciler (e.g. by parent gang cascade),
#   triggering controller-runtime workqueue exponential backoff. Multiple
#   failed gangs in the same run cause the workqueue to back off into the
#   minutes-range, so subsequent reservations sit unprocessed.
#
# Fix A — separate "teardown progress" from "scheduling failure":
#   - schedulingFailedSlots only counts slices in Failed phase (genuine fail)
#   - tearingDownSlots counts DeletionTimestamps (cascade progress, not fail)
#   - decideNextPhase only triggers Failed transition for schedulingFailedSlots
#
# Fix B — swallow not-found in applyPhase:
#   - errors.IsNotFound(err) returns nil (the object was deleted; that's fine)
#
# Fix C — same for the not-found path in continueTeardown:
#   - applyPhase failures with not-found don't propagate
#
# Idempotent: re-running after success is a no-op.
# ============================================================================

set -euo pipefail

R_FILE="internal/controller/vgpugangreservation_reconciler.go"

if [[ ! -f "$R_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "// teardown-loop fix applied" "$R_FILE" 2>/dev/null; then
    echo "✓ Patches already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$R_FILE" "${R_FILE}.bak.${TS}"
echo "Backup: ${R_FILE}.bak.${TS}"

restore() {
    cp "${R_FILE}.bak.${TS}" "$R_FILE"
}
trap 'restore; echo "ABORTED — file restored"' ERR

# ─────────────────────────────────────────────────────────────────────────────
# Patch 1 — sliceTally: add schedulingFailedSlots and tearingDownSlots
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[1/4] Splitting failedSlots into schedulingFailedSlots + tearingDownSlots..."
python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

# Find the sliceTally struct and replace failedSlots semantics
old = '''type sliceTally struct {
	reservedSlots  int32
	committedSlots int32
	failedSlots    int32
	pendingSlots   int32
	missingSlots   int32 // slice never created OR claim torn down
	perSlice       map[string]string
}'''

new = '''// teardown-loop fix applied: split "failure" into two distinct concepts.
//
// schedulingFailedSlots: slice in Failed phase — a genuine scheduling failure
//                        that should drive transition to ReservationPhaseFailed.
//
// tearingDownSlots:      claim/slice has DeletionTimestamp set OR slice is in
//                        Releasing/Released/Preempting phase. This is normal
//                        cascade-delete progress, NOT a new failure signal.
//                        Counting these as failures triggered an infinite
//                        teardown loop because tearDownChildren itself sets
//                        DeletionTimestamps.
//
// failedSlots:           preserved for backward-compatible status reporting,
//                        equals schedulingFailedSlots (the value users care
//                        about) so kubectl output remains meaningful.
type sliceTally struct {
	reservedSlots         int32
	committedSlots        int32
	failedSlots           int32 // = schedulingFailedSlots, for status
	schedulingFailedSlots int32
	tearingDownSlots      int32
	pendingSlots          int32
	missingSlots          int32 // slice never created OR claim torn down
	perSlice              map[string]string
}'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: sliceTally anchor not found exactly once (count={src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
p.write_text(src)
print(f"  ~ {p.name}: tally struct expanded")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Patch 2 — tallyChildSlices: classify DeletionTimestamps as tearingDown,
# not failed.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[2/4] Reclassifying DeletionTimestamps as teardown progress..."
python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# Sub-patch 2a — claim DeletionTimestamp
old1 = '''		// Bug 6 partial fix: if the claim is being deleted, count as failed.
		if !claim.DeletionTimestamp.IsZero() {
			t.failedSlots++
			t.perSlice[claimName] = "ClaimDeleting"
			continue
		}'''
new1 = '''		// teardown-loop fix applied: a claim with DeletionTimestamp is
		// cascade-delete in progress, not a new scheduling failure.
		if !claim.DeletionTimestamp.IsZero() {
			t.tearingDownSlots++
			t.perSlice[claimName] = "ClaimDeleting"
			continue
		}'''
if src.count(old1) != 1:
    sys.stderr.write(f"ERROR: claim deletion anchor not found ({src.count(old1)})\n")
    sys.exit(1)
src = src.replace(old1, new1)

# Sub-patch 2b — slice DeletionTimestamp
old2 = '''		// If the slice is being deleted, count as failed.
		if !slice.DeletionTimestamp.IsZero() {
			t.failedSlots++
			t.perSlice[claimName] = "SliceDeleting"
			continue
		}'''
new2 = '''		// teardown-loop fix applied: a slice with DeletionTimestamp is
		// cascade-delete in progress, not a new scheduling failure.
		if !slice.DeletionTimestamp.IsZero() {
			t.tearingDownSlots++
			t.perSlice[claimName] = "SliceDeleting"
			continue
		}'''
if src.count(old2) != 1:
    sys.stderr.write(f"ERROR: slice deletion anchor not found ({src.count(old2)})\n")
    sys.exit(1)
src = src.replace(old2, new2)

# Sub-patch 2c — slice in Failed phase = real scheduling failure
old3 = '''		case "Failed":
			t.failedSlots++
			t.perSlice[claimName] = "Failed"'''
new3 = '''		case "Failed":
			// teardown-loop fix applied: actual Failed phase IS a real
			// scheduling failure — counted under schedulingFailedSlots.
			t.schedulingFailedSlots++
			t.perSlice[claimName] = "Failed"'''
if src.count(old3) != 1:
    sys.stderr.write(f"ERROR: Failed phase anchor not found ({src.count(old3)})\n")
    sys.exit(1)
src = src.replace(old3, new3)

# Sub-patch 2d — Releasing/Released/Preempting = teardown progress, not failure
old4 = '''		case "Releasing", "Released", "Preempting":
			t.failedSlots++
			t.perSlice[claimName] = "Releasing"'''
new4 = '''		case "Releasing", "Released", "Preempting":
			// teardown-loop fix applied: these are teardown phases.
			t.tearingDownSlots++
			t.perSlice[claimName] = "Releasing"'''
if src.count(old4) != 1:
    sys.stderr.write(f"ERROR: Releasing phase anchor not found ({src.count(old4)})\n")
    sys.exit(1)
src = src.replace(old4, new4)

p.write_text(src)
print(f"  ~ {p.name}: 4 sub-patches applied")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Patch 3 — sync failedSlots = schedulingFailedSlots; update decideNextPhase
# to use the schedulingFailedSlots field.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[3/4] Wiring decideNextPhase to use schedulingFailedSlots..."
python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# The dispatch in decideNextPhase used t.failedSlots. Switch to schedulingFailedSlots.
old1 = '''	// Hard failures (slot in Failed/Releasing phase, claim being deleted, etc).
	if t.failedSlots > 0 {
		return vgpuv1alpha1.ReservationPhaseFailed,
			fmt.Sprintf("slot failure: %d slot(s) could not be scheduled", t.failedSlots),
			0
	}'''
new1 = '''	// Hard failures: only genuine scheduling failures (slice in Failed
	// phase) drive the transition to Failed. Teardown progress
	// (DeletionTimestamps, Releasing slices) does NOT — that's expected
	// state during cascade-delete and would otherwise loop the reconciler.
	if t.schedulingFailedSlots > 0 {
		return vgpuv1alpha1.ReservationPhaseFailed,
			fmt.Sprintf("slot failure: %d slot(s) could not be scheduled", t.schedulingFailedSlots),
			0
	}'''
if src.count(old1) != 1:
    sys.stderr.write(f"ERROR: decideNextPhase failedSlots anchor not found ({src.count(old1)})\n")
    sys.exit(1)
src = src.replace(old1, new1)

# In tallyChildSlices, set t.failedSlots = t.schedulingFailedSlots for status.
# Find the end of tallyChildSlices (the 'return t, nil' at the end).
old2 = '''		default:
			t.pendingSlots++
			t.perSlice[claimName] = string(slice.Status.Phase)
		}
	}
	return t, nil
}'''
new2 = '''		default:
			t.pendingSlots++
			t.perSlice[claimName] = string(slice.Status.Phase)
		}
	}
	// teardown-loop fix applied: keep failedSlots in sync with the genuine-
	// failure count for backward-compatible kubectl status output.
	t.failedSlots = t.schedulingFailedSlots
	return t, nil
}'''
if src.count(old2) != 1:
    sys.stderr.write(f"ERROR: tallyChildSlices end anchor not found ({src.count(old2)})\n")
    sys.exit(1)
src = src.replace(old2, new2)

p.write_text(src)
print(f"  ~ {p.name}: state machine + status sync applied")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Patch 4 — applyPhase returns nil on NotFound (the object was deleted, fine)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[4/4] Swallowing not-found errors in applyPhase..."
python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# applyPhase wraps the Get+Update in a retry.RetryOnConflict. The Get can
# fail with not-found if cascade-delete just removed the reservation.
# That's fine; treat it as a no-op.
old = '''	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUGangReservation
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}'''
new = '''	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUGangReservation
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			// teardown-loop fix applied: if the reservation was deleted
			// (cascade from parent gang), there's nothing to update.
			// Returning the error here would trigger workqueue exponential
			// backoff and starve unrelated reservations.
			if errors.IsNotFound(err) {
				return nil
			}
			return err
		}'''
if src.count(old) != 1:
    sys.stderr.write(f"ERROR: applyPhase Get anchor not found ({src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)

# Also: in Reconcile, applying a phase to a NotFound reservation should not
# bubble up. Check if there's a wrapping fmt.Errorf("applying phase: %w").
# After Patch 4 above, applyPhase no longer returns NotFound errors, so this
# is defense-in-depth — but ensure the wrap doesn't accidentally re-introduce
# the issue.
old2 = '''	// 5. Apply the transition.
	if err := r.applyPhase(ctx, &rsv, nextPhase, reason, tally); err != nil {
		return reconcile.Result{}, fmt.Errorf("applying phase: %w", err)
	}'''
new2 = '''	// 5. Apply the transition.
	if err := r.applyPhase(ctx, &rsv, nextPhase, reason, tally); err != nil {
		// teardown-loop fix applied: not-found means cascade-delete reaped
		// the reservation while we were processing it. That's fine; just
		// stop reconciling rather than triggering workqueue backoff.
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("applying phase: %w", err)
	}'''
if src.count(old2) != 1:
    sys.stderr.write(f"ERROR: Reconcile applyPhase anchor not found ({src.count(old2)})\n")
    sys.exit(1)
src = src.replace(old2, new2)

p.write_text(src)
print(f"  ~ {p.name}: not-found swallowed in applyPhase")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Verify build
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "Running gofmt + go build..."
gofmt -w "$R_FILE" 2>/dev/null || echo "  WARN: gofmt skipped"

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
echo "✅ Teardown loop fix applied."
echo "════════════════════════════════════════════════════════════"
echo
echo "What changed:"
echo "  - sliceTally now distinguishes scheduling-failed from teardown-progress"
echo "  - decideNextPhase only fails on genuine scheduling failures"
echo "  - applyPhase swallows not-found (no more workqueue backoff cascade)"
echo
echo "Deploy and test:"
echo "  make docker-build"
echo "  kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  kubectl rollout restart deployment/vgpu-controller -n vgpu-system"
echo "  kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  sleep 5"
echo "  kubectl get vgpuslice -A   # 'No resources found'"
echo "  bash real_world_test.sh"
