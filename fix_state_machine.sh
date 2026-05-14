#!/usr/bin/env bash
# ============================================================================
# fix_state_machine.sh
#
# Fixes the two TestStateMachine_IllegalTransitions failures:
#   - Pending → Releasing  (was incorrectly listed as legal)
#   - Ready   → Released   (was incorrectly listed as legal)
#
# Plus one related hole the test missed:
#   - "" → Releasing  (same root cause as Pending → Releasing)
#
# Why these are bugs:
#
#   Pending → Releasing
#     A slice that never bound has no hardware to release. Going through
#     Releasing leaves it stuck waiting for a NodeAgent transition that
#     never fires (NodeAgent only handles slices it allocated). Result:
#     stuck-in-Releasing forever. This is the "unbound-slice cleanup"
#     limitation already documented in the YC summary's known-issues list.
#
#   Ready → Released
#     Skips the Releasing phase, where the NodeAgent runs CDI teardown.
#     Hardware would stay locked while the API thinks it's free.
#
#   "" → Releasing
#     Same logical hole as Pending → Releasing. Empty/unset phase has no
#     hardware to release.
#
# ─── changes ────────────────────────────────────────────────────────────────
#
#   A. internal/state/transitions.go
#        Remove three illegal entries from legalSliceTransitions.
#
#   B. internal/controller/vgpuslice_reconciler.go
#        After A, the existing handleDelete fallback ("Transition to Releasing
#        skipped") leaves Pending slices with their finalizer attached and
#        no clear path to deletion. Add a direct-finalizer-removal branch
#        for never-bound slices so they tear down cleanly.
#
# Idempotent: re-running after success is a no-op.
# Backups go to *.bak.<timestamp>.
# ============================================================================

set -euo pipefail

T_FILE="internal/state/transitions.go"
R_FILE="internal/controller/vgpuslice_reconciler.go"

if [[ ! -f "$T_FILE" || ! -f "$R_FILE" ]]; then
    echo "ERROR: run from the repo root." >&2
    exit 1
fi

if grep -q "// state-machine fix applied: tightened DAG" "$T_FILE"; then
    echo "✓ Patches already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$T_FILE" "${T_FILE}.bak.${TS}"
cp "$R_FILE" "${R_FILE}.bak.${TS}"
echo "Backups: ${T_FILE}.bak.${TS}, ${R_FILE}.bak.${TS}"

# ────────────────────────────────────────────────────────────────────────────
# Patch A — tighten transitions.go
# ────────────────────────────────────────────────────────────────────────────
python3 - "$T_FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
orig = len(src)

# Patch A1: drop "" → Releasing (only Pending stays legal as initial transition)
old1 = '\t"":                   {SlicePhasePending: true, SlicePhaseReleasing: true},'
new1 = '\t// state-machine fix applied: tightened DAG\n\t"":                   {SlicePhasePending: true},'
assert src.count(old1) == 1, "Patch A1 anchor not found exactly once"
src = src.replace(old1, new1)

# Patch A2: drop Pending → Releasing (Pending slices have nothing to release)
old2 = '\tSlicePhasePending:    {SlicePhaseScheduled: true, SlicePhaseReleasing: true, SlicePhaseFailed: true},'
new2 = '\tSlicePhasePending:    {SlicePhaseScheduled: true, SlicePhaseFailed: true},'
assert src.count(old2) == 1, "Patch A2 anchor not found exactly once"
src = src.replace(old2, new2)

# Patch A3: drop Ready → Released (Ready slices must drain through Releasing)
old3 = '\tSlicePhaseReady:      {SlicePhaseReleasing: true, SlicePhaseReleased: true, SlicePhaseFailed: true},'
new3 = '\tSlicePhaseReady:      {SlicePhaseReleasing: true, SlicePhaseFailed: true},'
assert src.count(old3) == 1, "Patch A3 anchor not found exactly once"
src = src.replace(old3, new3)

assert len(src) != orig, "transitions.go unchanged — patches did not apply"
path.write_text(src)
print(f"  ~ {path} patched ({orig} -> {len(src)} bytes)")
PYEOF

# ────────────────────────────────────────────────────────────────────────────
# Patch B — slice reconciler delete path handles never-bound slices.
#
# Before:  if Pending or empty phase, transition to Releasing fails (DAG now
#          rejects it), the log.Printf swallows the error, currentPhase stays
#          Pending, and the finalizer never gets removed -> stuck object.
#
# After:   if the slice never bound (no AllocationID set), bypass the
#          Releasing phase entirely and remove the finalizer directly.
#          Releasing only applies to slices that had hardware to release.
# ────────────────────────────────────────────────────────────────────────────
python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
orig = len(src)

old = '''func (r *VGPUSliceReconciler) handleDelete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
\tlog.Printf("Deletion triggered for Slice %s", slice.Name)

\tcurrentPhase := string(slice.Status.Phase)

\tif currentPhase != state.SlicePhaseReleasing && currentPhase != state.SlicePhaseReleased {
\t\treturn PatchSliceStatus(ctx, r.Client, slice, func() {
\t\t\t// Round-3 fix: swallowing DAG violations silently hid bugs. If the
\t\t\t// transition is illegal at this point (e.g. already Released), we
\t\t\t// log it and skip the patch; controller-runtime will requeue.
\t\t\tif err := state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "", "Deletion requested"); err != nil {
\t\t\t\tlog.Printf("Transition to Releasing skipped: %v", err)
\t\t\t}
\t\t})
\t}'''

new = '''func (r *VGPUSliceReconciler) handleDelete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
\tlog.Printf("Deletion triggered for Slice %s", slice.Name)

\tcurrentPhase := string(slice.Status.Phase)

\t// Never-bound slices: no hardware was allocated, so there is nothing for
\t// the NodeAgent to release. Bypass the Releasing phase entirely and remove
\t// the finalizer directly. Without this branch, tightening the DAG (which
\t// now rejects Pending->Releasing) leaves Pending slices stuck during
\t// deletion because the transition fails and the finalizer never lifts.
\tneverBound := slice.Status.AllocationID == "" &&
\t\t(currentPhase == state.SlicePhasePending || currentPhase == "")
\tif neverBound {
\t\tlog.Printf("Slice %s never bound; removing finalizer directly", slice.Name)
\t\tkey := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
\t\treturn retry.RetryOnConflict(retry.DefaultRetry, func() error {
\t\t\tvar fresh vgpuv1alpha1.VGPUSlice
\t\t\tif err := r.Client.Get(ctx, key, &fresh); err != nil {
\t\t\t\treturn err
\t\t\t}
\t\t\tif !RemoveFinalizer(&fresh, SliceFinalizerName) {
\t\t\t\treturn nil
\t\t\t}
\t\t\treturn r.Client.Update(ctx, &fresh)
\t\t})
\t}

\tif currentPhase != state.SlicePhaseReleasing && currentPhase != state.SlicePhaseReleased {
\t\treturn PatchSliceStatus(ctx, r.Client, slice, func() {
\t\t\t// Round-3 fix: swallowing DAG violations silently hid bugs. If the
\t\t\t// transition is illegal at this point (e.g. already Released), we
\t\t\t// log it and skip the patch; controller-runtime will requeue.
\t\t\tif err := state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "", "Deletion requested"); err != nil {
\t\t\t\tlog.Printf("Transition to Releasing skipped: %v", err)
\t\t\t}
\t\t})
\t}'''

assert src.count(old) == 1, "Patch B anchor not found exactly once"
src = src.replace(old, new)

assert len(src) > orig + 800, f"reconciler didn't grow as expected: {orig} -> {len(src)}"
path.write_text(src)
print(f"  ~ {path} patched ({orig} -> {len(src)} bytes)")
PYEOF

# ────────────────────────────────────────────────────────────────────────────
# Format & verify
# ────────────────────────────────────────────────────────────────────────────
gofmt -w "$T_FILE" "$R_FILE" 2>/dev/null || echo "WARN: gofmt skipped (not on PATH)"

echo
echo "Running go build..."
if go build ./... 2>&1; then
    echo "  ✓ go build clean"
else
    echo "  ✗ go build FAILED — restoring backups"
    cp "${T_FILE}.bak.${TS}" "$T_FILE"
    cp "${R_FILE}.bak.${TS}" "$R_FILE"
    exit 1
fi

echo
echo "Running go test on the failing test specifically..."
if go test -run TestStateMachine_IllegalTransitions ./test/integration/... 2>&1; then
    echo "  ✓ TestStateMachine_IllegalTransitions PASSES"
else
    echo "  ✗ Test still fails. Backups at ${T_FILE}.bak.${TS} and ${R_FILE}.bak.${TS}"
    exit 1
fi

echo
echo "============================================================"
echo "✅ State-machine bugs fixed."
echo "============================================================"
echo
echo "Next: bash rollout_phase24a.sh --start-at=4"
echo "(test phase should pass; pipeline continues)"
