#!/usr/bin/env bash
# ============================================================================
# fix_gang_wiring.sh
#
# Implements the three fixes identified by the architectural review:
#
#   Fix #1 — Propagate gang annotations through Job → Claim → Slice.
#            Without this, no slice carries the gang.vgpu.pranav2910.com/*
#            annotations, so every gang-aware code path silently no-ops.
#
#   Fix #2 — Wire up GangBindingGate in the scheduler. Currently the field
#            is never assigned; the gate-check code in plugin.go is dead.
#
#   Fix #3 — Tight requeue for GangDeferredError. Currently any scheduling
#            error retries in 30s; with a 60s reservation deadline that's
#            at most 2 retries before failure. Reduce to 500ms for gang
#            defers so up to 120 retries fit within the deadline.
#
# All three fixes are required together — applying any subset leaves the
# system in a partially-coherent state. The script is atomic: any anchor
# mismatch aborts and rolls back all files.
#
# Idempotent: re-running after a successful apply is a no-op.
# ============================================================================

set -euo pipefail

JOB_FILE="internal/controller/vgpujob_reconciler.go"
CLAIM_FILE="internal/controller/vgpuclaim_reconciler.go"
SCHED_FILE="cmd/scheduler/main.go"
HELPER_FILE="internal/controller/gang_annotations.go"

if [[ ! -f "$JOB_FILE" || ! -f "$CLAIM_FILE" || ! -f "$SCHED_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "// gang-wiring fix applied" "$JOB_FILE" 2>/dev/null; then
    echo "✓ Patches already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$JOB_FILE" "${JOB_FILE}.bak.${TS}"
cp "$CLAIM_FILE" "${CLAIM_FILE}.bak.${TS}"
cp "$SCHED_FILE" "${SCHED_FILE}.bak.${TS}"
echo "Backups: *.bak.${TS}"

restore() {
    cp "${JOB_FILE}.bak.${TS}" "$JOB_FILE"
    cp "${CLAIM_FILE}.bak.${TS}" "$CLAIM_FILE"
    cp "${SCHED_FILE}.bak.${TS}" "$SCHED_FILE"
    rm -f "$HELPER_FILE"
}
trap 'restore; echo "ABORTED — files restored from backup."' ERR

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — create the annotation-filter helper
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[1/5] Creating annotation propagation helper..."
cat > "$HELPER_FILE" <<'EOF'
package controller

import "strings"

// gangAnnotationPrefix matches all annotations the gang scheduling feature
// stamps on its objects (gang reference, reservation reference, gang index,
// etc.). We propagate exactly these from Job → Claim → Slice; no other
// annotations cross object boundaries (avoids leaking kubectl bookkeeping,
// last-applied-config, etc. into derived objects).
const gangAnnotationPrefix = "gang.vgpu.pranav2910.com/"

// FilterGangAnnotations returns a new map containing only the gang-related
// annotations from src. Returns nil if there are no gang annotations to
// propagate, so the caller can omit the Annotations field entirely on
// derived objects rather than carrying an empty map.
func FilterGangAnnotations(src map[string]string) map[string]string {
	if len(src) == 0 {
		return nil
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		if strings.HasPrefix(k, gangAnnotationPrefix) {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
EOF
echo "  ~ wrote $HELPER_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Fix #1a: VGPUJobReconciler.createClaim copies gang annotations
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[2/5] Patching VGPUJobReconciler.createClaim..."
python3 - "$JOB_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

old = '''func (r *VGPUJobReconciler) createClaim(ctx context.Context, job *vgpuv1alpha1.VGPUJob) error {
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      claimNameForJob(job.Name),
			Namespace: job.Namespace,
		},
		Spec: job.Spec.ClaimTemplate.Spec,
	}'''

new = '''// gang-wiring fix applied: propagate gang annotations from Job to Claim.
func (r *VGPUJobReconciler) createClaim(ctx context.Context, job *vgpuv1alpha1.VGPUJob) error {
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:        claimNameForJob(job.Name),
			Namespace:   job.Namespace,
			Annotations: FilterGangAnnotations(job.Annotations),
		},
		Spec: job.Spec.ClaimTemplate.Spec,
	}'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: createClaim anchor not found exactly once (found {src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) > orig, "file did not grow"
p.write_text(src)
print(f"  ~ {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Fix #1b: VGPUClaimReconciler.ensureSliceExists copies annotations
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[3/5] Patching VGPUClaimReconciler.ensureSliceExists..."
python3 - "$CLAIM_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

old = '''	truePtr := true
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:      sliceName,
			Namespace: claim.Namespace,
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion:         vgpuv1alpha1.GroupVersion.String(),
					Kind:               "VGPUClaim",
					Name:               claim.Name,
					UID:                claim.UID,
					Controller:         &truePtr,
					BlockOwnerDeletion: &truePtr,
				},
			},
		},
		Spec: vgpuv1alpha1.VGPUSliceSpec{
			ClaimRef:           claim.Name,
			RequestedVRAMBytes: claim.Spec.RequestedVRAMBytes,
		},
	}'''

new = '''	truePtr := true
	// gang-wiring fix applied: propagate gang annotations from Claim to Slice.
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:        sliceName,
			Namespace:   claim.Namespace,
			Annotations: FilterGangAnnotations(claim.Annotations),
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion:         vgpuv1alpha1.GroupVersion.String(),
					Kind:               "VGPUClaim",
					Name:               claim.Name,
					UID:                claim.UID,
					Controller:         &truePtr,
					BlockOwnerDeletion: &truePtr,
				},
			},
		},
		Spec: vgpuv1alpha1.VGPUSliceSpec{
			ClaimRef:           claim.Name,
			RequestedVRAMBytes: claim.Spec.RequestedVRAMBytes,
		},
	}'''

if src.count(old) != 1:
    sys.stderr.write(f"ERROR: ensureSliceExists anchor not found exactly once (found {src.count(old)})\n")
    sys.exit(1)
src = src.replace(old, new)
assert len(src) > orig, "file did not grow"
p.write_text(src)
print(f"  ~ {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Fix #2: wire GangBindingGate in scheduler main
#                + Fix #3: typed-error check for fast gang-deferred retry
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[4/5] Wiring GangGate + tightening deferred-bind requeue..."
python3 - "$SCHED_FILE" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = len(src)

# Patch 4a: add "errors" import. Anchor: the existing context import.
old_imports = '''import (
	"context"
	"fmt"
	"log"
	"os"
	"time"
'''
new_imports = '''import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"time"
'''
if src.count(old_imports) != 1:
    sys.stderr.write(f"ERROR: imports anchor not found ({src.count(old_imports)})\n")
    sys.exit(1)
src = src.replace(old_imports, new_imports)

# Patch 4b: wire the GangBindingGate. Anchor is the SetPreemptor block.
old_wire = '''	// Layer 2 Phase 2.3: wire preemption.
	sched.SetPreemptor(scheduler.NewPreemptor(mgr.GetClient()))
'''
new_wire = '''	// Layer 2 Phase 2.3: wire preemption.
	sched.SetPreemptor(scheduler.NewPreemptor(mgr.GetClient()))

	// gang-wiring fix applied: wire the GangBindingGate so Schedule()
	// actually consults gang state before binding.
	sched.GangGate = scheduler.NewGangBindingGate(mgr.GetClient())
'''
if src.count(old_wire) != 1:
    sys.stderr.write(f"ERROR: wire anchor not found ({src.count(old_wire)})\n")
    sys.exit(1)
src = src.replace(old_wire, new_wire)

# Patch 4c: typed-error check on the Schedule() error path so a gang defer
# requeues fast (500ms) instead of waiting 30s.
old_err = '''	_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes, bestEffort)
	if err != nil {
		// Bug F fix: requeue instead of silently dropping the slice.
		log.Printf("Scheduling failed for Slice %s/%s: %v — will retry in 30s",
			slice.Namespace, slice.Name, err)
		return reconcile.Result{RequeueAfter: 30 * time.Second}, nil
	}'''

new_err = '''	_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes, bestEffort)
	if err != nil {
		// gang-wiring fix applied: a gang member that hit "deferred" is
		// waiting for siblings to reach Reserved. Retry quickly (500ms)
		// so up to ~120 retries fit within the 60s reservation deadline.
		// Other errors keep the existing 30s backoff.
		var gd *scheduler.GangDeferredError
		if errors.As(err, &gd) {
			return reconcile.Result{RequeueAfter: 500 * time.Millisecond}, nil
		}
		log.Printf("Scheduling failed for Slice %s/%s: %v — will retry in 30s",
			slice.Namespace, slice.Name, err)
		return reconcile.Result{RequeueAfter: 30 * time.Second}, nil
	}'''

if src.count(old_err) != 1:
    sys.stderr.write(f"ERROR: schedule-error anchor not found ({src.count(old_err)})\n")
    sys.exit(1)
src = src.replace(old_err, new_err)

assert len(src) > orig, "file did not grow"
p.write_text(src)
print(f"  ~ {p.name} ({orig} -> {len(src)} bytes)")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — gofmt + go build verification
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "[5/5] Running gofmt and go build..."

gofmt -w "$JOB_FILE" "$CLAIM_FILE" "$SCHED_FILE" "$HELPER_FILE" 2>/dev/null || echo "  WARN: gofmt skipped"

# Disable trap for the build check (we want a clean error message, not auto-restore)
trap - ERR

if go build ./...; then
    echo "  ✓ go build clean"
else
    echo "  ✗ go build FAILED — restoring backups"
    restore
    exit 1
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "✅ Gang scheduling wiring fixed."
echo "════════════════════════════════════════════════════════════"
echo
echo "Three independent defects addressed:"
echo "  1. Job → Claim annotation propagation (gang membership preserved)"
echo "  2. Claim → Slice annotation propagation (slice knows its gang)"
echo "  3. GangBindingGate now wired into scheduler"
echo "  4. GangDeferredError now triggers 500ms retry (was 30s)"
echo
echo "Next steps to deploy:"
echo "  1. make docker-build"
echo "  2. kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  3. kind load docker-image vgpu-scheduler:latest  --name vgpu-test"
echo "  4. kubectl rollout restart deployment/vgpu-controller deployment/vgpu-scheduler -n vgpu-system"
echo "  5. kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s"
echo "  6. kubectl rollout status deployment/vgpu-scheduler  -n vgpu-system --timeout=120s"
echo
echo "Smoke verification (NEW pod should see gang annotations on slices):"
echo "  kubectl create namespace gang-verify"
echo "  cat <<EOF | kubectl apply -f -"
echo "  apiVersion: infrastructure.pranav2910.com/v1alpha1"
echo "  kind: VGPUGangJob"
echo "  metadata: { name: t, namespace: gang-verify }"
echo "  spec:"
echo "    gangSize: 2"
echo "    minAvailable: 2"
echo "    podTemplate:"
echo "      spec: { requestedVramBytes: 10737418240 }"
echo "  EOF"
echo "  sleep 8"
echo "  kubectl get vgpuslice -n gang-verify -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.metadata.annotations}{\"\\n\"}{end}'"
echo
echo "  Expected: each slice prints with gang.vgpu.pranav2910.com/* annotations."
echo "  If annotations are still empty, the fix did not deploy correctly."
echo
echo "Then run the full battery:"
echo "  kubectl delete ns gang-verify"
echo "  kubectl get ns -o name | grep rwtest- | xargs -r kubectl delete --grace-period=0 --force 2>/dev/null"
echo "  bash real_world_test.sh"
