#!/usr/bin/env bash
# ============================================================================
# install_wave2_fixes.sh
#
# Consolidated fix for the 6 bugs surfaced by Test 1.1 in real-world testing:
#
#   Bug 1 — No slice-watch trigger.
#   Bug 2 — Failed-phase short-circuit was permanent.
#   Bug 3 — Cascade-delete used Background propagation (returns before done).
#   Bug 4 — applyPhase ran BEFORE tearDownChildren, freezing stale tally.
#   Bug 5 — Tally couldn't distinguish brand-new from re-created slices.
#   Bug 6 — Slices whose gang failed were left in Pending, jamming scheduler.
#
# Strategy: rewrite vgpugangreservation_reconciler.go from scratch (too many
# changes for surgical patches), surgically patch the scheduler's slice
# reconciler for Bug 6.
#
# Idempotent: re-running after success is a no-op.
# Backups: both modified files saved to *.bak.<timestamp>.
# ============================================================================

set -euo pipefail

R_FILE="internal/controller/vgpugangreservation_reconciler.go"
S_FILE="cmd/scheduler/main.go"
BUNDLE_FILE="vgpugangreservation_reconciler.go"

if [[ ! -f "$R_FILE" || ! -f "$S_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if [[ ! -f "$BUNDLE_FILE" ]]; then
    echo "ERROR: replacement file '$BUNDLE_FILE' not found in current directory." >&2
    echo "Place the new vgpugangreservation_reconciler.go next to this script." >&2
    exit 1
fi

# Idempotency check
if grep -q "// Bug 1 fix: watch child slices" "$R_FILE" 2>/dev/null; then
    echo "✓ Wave 2 patches already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$R_FILE" "${R_FILE}.bak.${TS}"
cp "$S_FILE" "${S_FILE}.bak.${TS}"
echo "Backups: ${R_FILE}.bak.${TS}, ${S_FILE}.bak.${TS}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — wholesale replace the reservation reconciler.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[1/3] Replacing reservation reconciler..."
cp "$BUNDLE_FILE" "$R_FILE"
echo "  ~ wrote $R_FILE ($(wc -c < "$R_FILE") bytes)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — patch scheduler reconciler for Bug 6: gang-failed slices get
# transitioned to Failed phase immediately, unjamming the priority queue.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[2/3] Patching scheduler reconciler for Bug 6..."
python3 - "$S_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

# Anchor: the line just before the bestEffort block. We insert the gang-fail
# check between "if slice.Spec.NodeName != ...; return ...;" and "bestEffort := false".
old = '''\tif slice.Spec.NodeName != "" {
\t\treturn reconcile.Result{}, nil
\t}

\tbestEffort := false'''

new = '''\tif slice.Spec.NodeName != "" {
\t\treturn reconcile.Result{}, nil
\t}

\t// Bug 6 fix: if this slice belongs to a gang whose reservation has Failed,
\t// transition the slice to Failed phase immediately. Without this the slice
\t// stays in Pending forever; the priority queue keeps re-enqueueing it; the
\t// gang gate keeps rejecting it; capacity is held by ghost slices.
\tif slice.Annotations != nil {
\t\tif rsvName, ok := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]; ok && rsvName != "" {
\t\t\tvar rsv vgpuv1alpha1.VGPUGangReservation
\t\t\tif err := r.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: rsvName}, &rsv); err == nil {
\t\t\t\tif rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseFailed ||
\t\t\t\t\trsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
\t\t\t\t\tlog.Printf("[scheduler] Slice %s/%s belongs to dead gang reservation %s — marking Failed",
\t\t\t\t\t\tslice.Namespace, slice.Name, rsvName)
\t\t\t\t\tslice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Failed")
\t\t\t\t\tslice.Status.LastError = "gang reservation failed; this slot was orphaned"
\t\t\t\t\tif err := r.client.Status().Update(ctx, &slice); err != nil {
\t\t\t\t\t\treturn reconcile.Result{RequeueAfter: 5 * time.Second}, nil
\t\t\t\t\t}
\t\t\t\t\treturn reconcile.Result{}, nil
\t\t\t\t}
\t\t\t}
\t\t}
\t}

\tbestEffort := false'''

if src.count(old) != 1:
    print(f"ERROR: anchor not found exactly once (found {src.count(old)})", file=sys.stderr)
    sys.exit(1)
src = src.replace(old, new)

assert len(src) > orig + 1000, f"file didn't grow as expected: {orig} -> {len(src)}"
p.write_text(src)
print(f"  ~ patched {p} ({orig} -> {len(src)} bytes)")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — gofmt + go build verification
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[3/3] Running gofmt and go build..."

gofmt -w "$R_FILE" "$S_FILE" 2>/dev/null || echo "  WARN: gofmt skipped"

if go build ./...; then
    echo "  ✓ go build clean"
else
    echo "  ✗ go build FAILED — restoring backups"
    cp "${R_FILE}.bak.${TS}" "$R_FILE"
    cp "${S_FILE}.bak.${TS}" "$S_FILE"
    exit 1
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "✅ Wave 2 fixes applied to source."
echo "════════════════════════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1. make docker-build"
echo "  2. kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  3. kind load docker-image vgpu-scheduler:latest  --name vgpu-test"
echo "  4. kubectl rollout restart deployment/vgpu-controller deployment/vgpu-scheduler -n vgpu-system"
echo "  5. kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo "  6. # Clean any leftover from previous test runs:"
echo "     kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force"
echo "     kubectl get vgpuslice -A     # should report 'No resources found'"
echo "  7. bash real_world_test.sh    # full battery (1.1, 1.2, 2.1, 2.2)"
echo
echo "If 1.1 still fails, paste diagnostics WITH --skip-cleanup so we can post-mortem."
