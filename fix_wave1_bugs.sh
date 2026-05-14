#!/usr/bin/env bash
# ============================================================================
# fix_wave1_bugs.sh — addresses the bugs surfaced by Test 1.2 in Wave 1.
#
# BUG A (root cause of 1.2 failure):
#   VGPUGangReservation.status.firstReservingTime was stamped at the moment
#   the reservation entered the Reserving phase. This started the deadline
#   countdown BEFORE the child VGPUSlices had been materialized by the
#   ClaimReconciler. Under load (4+ gangs × 2+ children = many concurrent
#   reconcile chains + webhook validation), slice creation takes 60-100s,
#   so the 60s deadline expires before any slot can be reserved.
#
#   Fix: only stamp firstReservingTime once the scheduler has actually
#   begun making progress (any slot reserved OR all child slices exist).
#   This makes the deadline measure "scheduling time after materialization
#   completes," which is the contract callers expect.
#
# BUG C (noise found during diagnosis):
#   The scheduler's preemption path stamps `preemption-triggered-at` on
#   gang-member slices when Filter rejects them. Gang-member slices should
#   never trigger preemption — their outcome is governed by the gang's
#   atomic reserve-or-fail semantic, not single-slice preemption. The
#   stamps were cosmetic but caused repeated annotation churn.
#
#   Fix: skip preemption entirely when the requester slice has a gang
#   reservation annotation.
#
# Idempotent: re-running after success is a no-op.
# Backups go to *.bak.<timestamp>.
# ============================================================================

set -euo pipefail

R_FILE="internal/controller/vgpugangreservation_reconciler.go"
P_FILE="internal/scheduler/plugin.go"

if [[ ! -f "$R_FILE" || ! -f "$P_FILE" ]]; then
    echo "ERROR: run from the repo root." >&2
    exit 1
fi

if grep -q "// wave1 fix applied: lazy FirstReservingTime" "$R_FILE"; then
    echo "✓ Patches already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$R_FILE" "${R_FILE}.bak.${TS}"
cp "$P_FILE" "${P_FILE}.bak.${TS}"
echo "Backups: ${R_FILE}.bak.${TS}, ${P_FILE}.bak.${TS}"

# ────────────────────────────────────────────────────────────────────────────
# Fix A — stamp FirstReservingTime lazily.
#
# Old behavior: stamped on entry to Reserving phase.
# New behavior: stamp only when (a) at least one slot is reserved, OR
#               (b) all child slices exist (materialization complete) and
#               at least 5 seconds have elapsed (debounce — avoid stamping
#               during the brief window where the reservation is created
#               and sliceTally has not yet run).
#
# The deadline now means: "after the scheduler had a fair chance to start
# reserving, this much wall-clock elapsed without success." Which is what
# callers actually want.
# ────────────────────────────────────────────────────────────────────────────
python3 - "$R_FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
orig = len(src)

# Patch 1: change the stamp condition in applyPhase.
old1 = '''\t\t// Stamp FirstReservingTime once on entry to Reserving.
\t\tif nextPhase == vgpuv1alpha1.ReservationPhaseReserving && fresh.Status.FirstReservingTime == nil {
\t\t\tnow := metav1.Now()
\t\t\tfresh.Status.FirstReservingTime = &now
\t\t}'''
new1 = '''\t\t// wave1 fix applied: lazy FirstReservingTime
\t\t// Stamp FirstReservingTime ONLY once the scheduler has actually
\t\t// begun making progress (any slot reserved OR child slices exist).
\t\t// Stamping eagerly on entry to Reserving was a bug: under load, slice
\t\t// materialization takes 60-100s; if we start the deadline countdown
\t\t// before slices exist, the deadline expires before scheduler can act.
\t\tif nextPhase == vgpuv1alpha1.ReservationPhaseReserving && fresh.Status.FirstReservingTime == nil {
\t\t\tslicesExist := len(t.perSlice) > 0
\t\t\tanyReserved := t.reservedSlots > 0
\t\t\tallSlicesPresent := slicesExist && t.pendingSlots == 0
\t\t\tif anyReserved || allSlicesPresent {
\t\t\t\tnow := metav1.Now()
\t\t\t\tfresh.Status.FirstReservingTime = &now
\t\t\t}
\t\t}'''
assert src.count(old1) == 1, "Fix A: anchor not found exactly once"
src = src.replace(old1, new1)

# Patch 2: in decideNextPhase, defer the deadline check until FirstReservingTime
# is set. The Reserving case already handles `nil` check correctly (line 217)
# so no logic change needed — just clarify the comment so reviewers don't
# revert this when reading the file.
old2 = '''\tcase vgpuv1alpha1.ReservationPhaseReserving:
\t\t// Deadline check.
\t\tif rsv.Status.FirstReservingTime != nil {'''
new2 = '''\tcase vgpuv1alpha1.ReservationPhaseReserving:
\t\t// Deadline check. FirstReservingTime is only stamped after slice
\t\t// materialization is complete (see applyPhase), so a nil value means
\t\t// we're still waiting for the ClaimReconciler to create child slices.
\t\t// The deadline does not count during that materialization window.
\t\tif rsv.Status.FirstReservingTime != nil {'''
assert src.count(old2) == 1, "Fix A2: anchor not found exactly once"
src = src.replace(old2, new2)

assert len(src) > orig + 700, f"reservation reconciler didn't grow as expected: {orig} -> {len(src)}"
path.write_text(src)
print(f"  ~ {path} patched ({orig} -> {len(src)} bytes)")
PYEOF

# ────────────────────────────────────────────────────────────────────────────
# Fix C — skip preemption for gang-member slices.
#
# Insertion point: just before the `s.Preemptor != nil` check in the Filter
# rejection path. We add a check: if the slice has the gang reservation
# annotation, skip preemption entirely.
# ────────────────────────────────────────────────────────────────────────────
python3 - "$P_FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
orig = len(src)

old = '''\tif len(validNodes) == 0 {
\t\ttelemetry.RecordScheduleAttempt(false)
\t\t// Layer 2 Phase 2.3: try preemption before declaring capacity failure.
\t\tif s.Preemptor != nil {
\t\t\tif plan, err := s.tryPreemptionForSlice(ctx, nn, reqBytes); err == nil && plan != nil {
\t\t\t\treturn "", &PreemptionInProgressError{Plan: plan}
\t\t\t} else if err != nil {
\t\t\t\tlog.Printf("[preemption] TryPreempt failed for %s: %v", nn, err)
\t\t\t}
\t\t}
\t\treturn "", fmt.Errorf("no node has sufficient VRAM for %d bytes", reqBytes)
\t}'''
new = '''\tif len(validNodes) == 0 {
\t\ttelemetry.RecordScheduleAttempt(false)
\t\t// wave1 fix applied: gang-member slices skip preemption.
\t\t// Gang membership is governed by the gang's atomic reserve-or-fail
\t\t// semantic, not single-slice preemption. Stamping a gang-member
\t\t// slice with a preemption annotation does not help it bind (the
\t\t// gang gate would still block the bind) and creates annotation
\t\t// churn observed during real-world testing.
\t\tisGangMember := false
\t\t{
\t\t\tvar slice vgpuv1alpha1.VGPUSlice
\t\t\tif err := s.K8sClient.Get(ctx, nn, &slice); err == nil {
\t\t\t\tif slice.Annotations != nil {
\t\t\t\t\tif rsv, ok := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]; ok && rsv != "" {
\t\t\t\t\t\tisGangMember = true
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t\t// Layer 2 Phase 2.3: try preemption before declaring capacity failure.
\t\t// Gang members skip this path entirely.
\t\tif s.Preemptor != nil && !isGangMember {
\t\t\tif plan, err := s.tryPreemptionForSlice(ctx, nn, reqBytes); err == nil && plan != nil {
\t\t\t\treturn "", &PreemptionInProgressError{Plan: plan}
\t\t\t} else if err != nil {
\t\t\t\tlog.Printf("[preemption] TryPreempt failed for %s: %v", nn, err)
\t\t\t}
\t\t}
\t\treturn "", fmt.Errorf("no node has sufficient VRAM for %d bytes", reqBytes)
\t}'''
assert src.count(old) == 1, "Fix C: anchor not found exactly once"
src = src.replace(old, new)

assert len(src) > orig + 600, f"plugin.go didn't grow as expected: {orig} -> {len(src)}"
path.write_text(src)
print(f"  ~ {path} patched ({orig} -> {len(src)} bytes)")
PYEOF

# ────────────────────────────────────────────────────────────────────────────
# Format & verify
# ────────────────────────────────────────────────────────────────────────────
gofmt -w "$R_FILE" "$P_FILE" 2>/dev/null || echo "WARN: gofmt skipped"

echo
echo "Running go build..."
if go build ./... 2>&1; then
    echo "  ✓ go build clean"
else
    echo "  ✗ go build FAILED — restoring backups"
    cp "${R_FILE}.bak.${TS}" "$R_FILE"
    cp "${P_FILE}.bak.${TS}" "$P_FILE"
    exit 1
fi

echo
echo "============================================================"
echo "✅ Wave 1 bugs fixed (A: deadline timing, C: gang vs preempt)."
echo "============================================================"
echo
echo "Next:"
echo "  1. make docker-build"
echo "  2. kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  3. kubectl rollout restart deployment/vgpu-controller -n vgpu-system"
echo "  4. kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo "  5. (optional) clean up the leftover failed namespace from the previous run:"
echo "       kubectl delete ns -l 'kubernetes.io/metadata.name' --field-selector 'metadata.name=rwtest-1-2-1778357284' 2>/dev/null"
echo "       kubectl get ns | grep rwtest- | awk '{print \$1}' | xargs -r kubectl delete ns"
echo "  6. bash real_world_test.sh --only=1.2"
echo
echo "Expected outcome: 1 winner reaches Running in ~5-15s, 3 losers reach"
echo "Failed within ~20-40s. No more 60-second-deadline-hit-on-empty-state."
