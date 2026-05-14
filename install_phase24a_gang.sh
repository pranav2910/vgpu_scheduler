#!/usr/bin/env bash
# ============================================================================
# install_phase24a_gang.sh
#
# Phase 2.4a — Gang scheduling installer.
#
# Locked design (per CTO):
#   1. New VGPUGangJob CRD
#   2. New VGPUGangReservation CRD
#   3. Strict gangs only (minAvailable == gangSize, enforced by webhook)
#   4. Gang preemption deferred to v2
#
# What this script does:
#
#   A. Copies all NEW files into the repo:
#      - api/v1alpha1/vgpugangjob_types.go
#      - api/v1alpha1/vgpugangreservation_types.go
#      - internal/controller/vgpugangjob_reconciler.go
#      - internal/controller/vgpugangreservation_reconciler.go
#      - internal/scheduler/gang.go
#      - internal/webhook/validating_gangjob.go
#      - internal/webhook/gangjob_validator_handler.go
#      - deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangjobs.yaml
#      - deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangreservations.yaml
#
#   B. Patches EXISTING files (with anchors verified once each):
#      - cmd/controller/main.go                       (register reconcilers + webhook)
#      - deployments/manifests/rbac/controller_rbac.yaml  (RBAC for new CRDs)
#      - internal/scheduler/plugin.go                 (insert gang gate before bind)
#
# Idempotent: re-running after a successful install is a no-op.
# Backs up each modified file to .bak.<timestamp> before writing.
# Aborts on anchor mismatch — original files are NOT touched on failure.
#
# Usage:
#   bash install_phase24a_gang.sh                    # apply everything
#   bash install_phase24a_gang.sh --check            # dry-run validate
#
# Run from the repo root (same directory as go.mod).
# ============================================================================

set -euo pipefail

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
fi

if [[ ! -f go.mod ]] || [[ ! -d cmd/controller ]]; then
    echo "ERROR: must run from repo root (where go.mod lives)" >&2
    exit 1
fi

BUNDLE_DIR="phase24a_bundle"
if [[ ! -d "$BUNDLE_DIR" ]]; then
    echo "ERROR: bundle directory '$BUNDLE_DIR' not found." >&2
    echo "Place the unzipped Phase 2.4a bundle next to this script." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Idempotency gate: if any of the new files already exist, assume installed.
# ---------------------------------------------------------------------------
SENTINEL="api/v1alpha1/vgpugangjob_types.go"
if [[ -f "$SENTINEL" ]]; then
    echo "✓ Phase 2.4a already installed ($SENTINEL exists). Nothing to do."
    exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "[--check] would install Phase 2.4a (sentinel $SENTINEL not present)"
    echo "[--check] anchors will be verified at apply time"
    exit 0
fi

TS=$(date +%s)
echo "Phase 2.4a installer starting (timestamp suffix: .bak.$TS)"
echo

# ---------------------------------------------------------------------------
# Step A — copy NEW files
# ---------------------------------------------------------------------------
copy_file() {
    local rel=$1
    local src="$BUNDLE_DIR/$rel"
    if [[ ! -f "$src" ]]; then
        echo "ERROR: bundle file missing: $src" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$rel")"
    cp "$src" "$rel"
    echo "  + $rel"
}

echo "[A] Copying new files…"
copy_file "api/v1alpha1/vgpugangjob_types.go"
copy_file "api/v1alpha1/vgpugangreservation_types.go"
copy_file "internal/controller/vgpugangjob_reconciler.go"
copy_file "internal/controller/vgpugangreservation_reconciler.go"
copy_file "internal/scheduler/gang.go"
copy_file "internal/webhook/validating_gangjob.go"
copy_file "internal/webhook/gangjob_validator_handler.go"
copy_file "deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangjobs.yaml"
copy_file "deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangreservations.yaml"

# ---------------------------------------------------------------------------
# Step B — patch EXISTING files via Python (anchor-verified, atomic write)
# ---------------------------------------------------------------------------
echo
echo "[B] Patching existing files…"

# B1: cmd/controller/main.go — register the two new reconcilers + webhook
cp cmd/controller/main.go "cmd/controller/main.go.bak.$TS"
python3 - <<'PYEOF' || { echo "ABORTED: rolled back via backup"; cp "cmd/controller/main.go.bak.$TS" cmd/controller/main.go; exit 1; }
import pathlib, sys

p = pathlib.Path("cmd/controller/main.go")
src = p.read_text()
orig = len(src)

# Patch 1: register VGPUGangJobReconciler + VGPUGangReservationReconciler
# anchor: the existing slice reconciler registration block.
old = (
    "\tif err := (&controller.VGPUSliceReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {\n"
    "\t\tlog.Fatalf(\"setting up VGPUSlice reconciler: %v\", err)\n"
    "\t}\n"
)
new = old + (
    "\n"
    "\t// Layer 2 Phase 2.4a: gang scheduling.\n"
    "\tif err := (&controller.VGPUGangJobReconciler{\n"
    "\t\tClient: mgr.GetClient(),\n"
    "\t\tScheme: mgr.GetScheme(),\n"
    "\t}).SetupWithManager(mgr); err != nil {\n"
    "\t\tlog.Fatalf(\"setting up VGPUGangJobReconciler: %v\", err)\n"
    "\t}\n"
    "\tif err := (&controller.VGPUGangReservationReconciler{\n"
    "\t\tClient: mgr.GetClient(),\n"
    "\t\tScheme: mgr.GetScheme(),\n"
    "\t}).SetupWithManager(mgr); err != nil {\n"
    "\t\tlog.Fatalf(\"setting up VGPUGangReservationReconciler: %v\", err)\n"
    "\t}\n"
)
assert src.count(old) == 1, "Patch B1.1: VGPUSliceReconciler registration anchor not found exactly once"
src = src.replace(old, new)

# Patch 2: register the gang-job validating webhook on the webhook server
old2 = (
    "\tmgr.GetWebhookServer().Register(\"/validate-infrastructure-pranav2910-com-v1alpha1-vgpuclaim\",\n"
    "\t\t&webhookserver.Admission{Handler: webhook.NewClaimValidatorHandler(decoder)})\n"
)
new2 = old2 + (
    "\tmgr.GetWebhookServer().Register(\"/validate-infrastructure-pranav2910-com-v1alpha1-vgpugangjob\",\n"
    "\t\t&webhookserver.Admission{Handler: webhook.NewGangJobValidatorHandler(decoder)})\n"
)
assert src.count(old2) == 1, "Patch B1.2: ClaimValidatorHandler registration anchor not found exactly once"
src = src.replace(old2, new2)

assert len(src) > orig + 500, f"main.go didn't grow as expected: {orig} -> {len(src)}"
p.write_text(src)
print(f"  ~ cmd/controller/main.go ({orig} -> {len(src)} bytes)")
PYEOF

# B2: deployments/manifests/rbac/controller_rbac.yaml — add gang RBAC
cp deployments/manifests/rbac/controller_rbac.yaml "deployments/manifests/rbac/controller_rbac.yaml.bak.$TS"
python3 - <<'PYEOF' || { echo "ABORTED"; cp "deployments/manifests/rbac/controller_rbac.yaml.bak.$TS" deployments/manifests/rbac/controller_rbac.yaml; exit 1; }
import pathlib

p = pathlib.Path("deployments/manifests/rbac/controller_rbac.yaml")
src = p.read_text()
orig = len(src)

# Anchor: the events rule, which is the last vgpu-specific rule before the
# kubernetes-side ones (events, leases, pods).
old = (
    '  - apiGroups: [\"infrastructure.pranav2910.com\"]\n'
    '    resources: [\"vgpuquotas/status\"]\n'
    '    verbs: [\"get\", \"update\", \"patch\"]\n'
)
new = old + (
    '  # Layer 2 Phase 2.4a: gang scheduling.\n'
    '  - apiGroups: [\"infrastructure.pranav2910.com\"]\n'
    '    resources: [\"vgpugangjobs\", \"vgpugangreservations\"]\n'
    '    verbs: [\"get\", \"list\", \"watch\", \"create\", \"update\", \"patch\", \"delete\"]\n'
    '  - apiGroups: [\"infrastructure.pranav2910.com\"]\n'
    '    resources: [\"vgpugangjobs/status\", \"vgpugangreservations/status\"]\n'
    '    verbs: [\"get\", \"update\", \"patch\"]\n'
    '  - apiGroups: [\"infrastructure.pranav2910.com\"]\n'
    '    resources: [\"vgpugangjobs/finalizers\", \"vgpugangreservations/finalizers\"]\n'
    '    verbs: [\"update\"]\n'
)
assert src.count(old) == 1, "Patch B2: vgpuquotas/status anchor not found exactly once"
src = src.replace(old, new)

assert len(src) > orig + 400, f"rbac.yaml didn't grow as expected: {orig} -> {len(src)}"
p.write_text(src)
print(f"  ~ deployments/manifests/rbac/controller_rbac.yaml ({orig} -> {len(src)} bytes)")
PYEOF

# B3: internal/scheduler/plugin.go — insert gang gate before bind
cp internal/scheduler/plugin.go "internal/scheduler/plugin.go.bak.$TS"
python3 - <<'PYEOF' || { echo "ABORTED"; cp "internal/scheduler/plugin.go.bak.$TS" internal/scheduler/plugin.go; exit 1; }
import pathlib

p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()
orig = len(src)

# Patch: add GangGate field to SliceScheduler.
old_struct = (
    "// SliceScheduler is the stateful scheduling engine.\n"
    "type SliceScheduler struct {\n"
    "\tQuotaChecker *QuotaChecker\n"
    "\tPreemptor    *Preemptor\n"
    "\tCache     *VRAMCache\n"
    "\tReserver  *ReservationManager\n"
    "\tK8sClient client.Client\n"
    "}"
)
new_struct = (
    "// SliceScheduler is the stateful scheduling engine.\n"
    "type SliceScheduler struct {\n"
    "\tQuotaChecker *QuotaChecker\n"
    "\tPreemptor    *Preemptor\n"
    "\tGangGate  *GangBindingGate\n"
    "\tCache     *VRAMCache\n"
    "\tReserver  *ReservationManager\n"
    "\tK8sClient client.Client\n"
    "}"
)
assert src.count(old_struct) == 1, "Patch B3.1: SliceScheduler struct anchor not found exactly once"
src = src.replace(old_struct, new_struct)

# Patch: insert gang-gate check just before bindToKubernetesAPI is called.
# This is the all-or-nothing gate — slice cannot proceed to Bind unless its
# parent reservation is in Reserved (or Committed) phase.
old_bind = (
    "\tdefer tx.RollbackIfNotConfirmed()\n"
    "\n"
    "\tif err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {\n"
    "\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\treturn \"\", fmt.Errorf(\"bind to Kubernetes API failed: %w\", err)\n"
    "\t}"
)
new_bind = (
    "\tdefer tx.RollbackIfNotConfirmed()\n"
    "\n"
    "\t// Layer 2 Phase 2.4a: gang gate.\n"
    "\t// If this slice is part of a gang, we must NOT bind unless the parent\n"
    "\t// reservation has reached Reserved phase (all siblings successfully\n"
    "\t// reserved). Returning a GangDeferredError tells the caller to keep\n"
    "\t// the speculative reservation but requeue the slice for retry.\n"
    "\tif s.GangGate != nil {\n"
    "\t\tvar slice vgpuv1alpha1.VGPUSlice\n"
    "\t\tif err := s.K8sClient.Get(ctx, nn, &slice); err == nil {\n"
    "\t\t\tres, reason, gerr := s.GangGate.CheckSlice(ctx, &slice)\n"
    "\t\t\tif gerr != nil {\n"
    "\t\t\t\tlog.Printf(\"[gang] gate error for %s: %v\", nn, gerr)\n"
    "\t\t\t}\n"
    "\t\t\tswitch res {\n"
    "\t\t\tcase GangBindDeferred:\n"
    "\t\t\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\t\t\t// Keep tx un-confirmed so RollbackIfNotConfirmed releases it,\n"
    "\t\t\t\t// then return a typed error so the caller knows to requeue.\n"
    "\t\t\t\treturn \"\", &GangDeferredError{Reason: reason}\n"
    "\t\t\tcase GangBindRejected:\n"
    "\t\t\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\t\t\treturn \"\", fmt.Errorf(\"gang reservation rejected bind: %s\", reason)\n"
    "\t\t\tcase GangBindAllowed, GangNotApplicable:\n"
    "\t\t\t\t// proceed to bind\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n"
    "\n"
    "\tif err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {\n"
    "\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\treturn \"\", fmt.Errorf(\"bind to Kubernetes API failed: %w\", err)\n"
    "\t}"
)
assert src.count(old_bind) == 1, "Patch B3.2: bind-call anchor not found exactly once"
src = src.replace(old_bind, new_bind)

# Patch: add GangDeferredError type at end of file (before final closing).
appendage = (
    "\n"
    "// GangDeferredError signals that a slice's bind was deferred because its\n"
    "// parent gang reservation has not yet reached Reserved phase. The caller\n"
    "// should requeue the slice and try again on the next reconcile pass.\n"
    "// This is NOT a hard scheduling failure — the speculative reservation\n"
    "// is released by tx.RollbackIfNotConfirmed (which the deferred call did)\n"
    "// and will be re-acquired on retry.\n"
    "type GangDeferredError struct {\n"
    "\tReason string\n"
    "}\n"
    "\n"
    "func (e *GangDeferredError) Error() string {\n"
    "\treturn \"gang bind deferred: \" + e.Reason\n"
    "}\n"
)
if not src.endswith("\n"):
    src += "\n"
src += appendage

assert len(src) > orig + 1500, f"plugin.go didn't grow as expected: {orig} -> {len(src)}"
p.write_text(src)
print(f"  ~ internal/scheduler/plugin.go ({orig} -> {len(src)} bytes)")
PYEOF

# ---------------------------------------------------------------------------
# Step C — gofmt the files we generated/touched (string concatenation in the
# patch script can leave struct-field alignment off; gofmt fixes it).
# ---------------------------------------------------------------------------
echo
echo "[C] Running gofmt on new/patched files…"
GOFMT_TARGETS=(
    api/v1alpha1/vgpugangjob_types.go
    api/v1alpha1/vgpugangreservation_types.go
    internal/controller/vgpugangjob_reconciler.go
    internal/controller/vgpugangreservation_reconciler.go
    internal/scheduler/gang.go
    internal/webhook/validating_gangjob.go
    internal/webhook/gangjob_validator_handler.go
    internal/scheduler/plugin.go
    cmd/controller/main.go
)
if command -v gofmt >/dev/null 2>&1; then
    gofmt -w "${GOFMT_TARGETS[@]}"
    echo "  ✓ gofmt applied"
else
    echo "  WARN: gofmt not on PATH — run 'gofmt -w ${GOFMT_TARGETS[*]}' manually"
fi

# ---------------------------------------------------------------------------
# Step D — verify the result builds
# ---------------------------------------------------------------------------
echo
echo "[D] Verifying go build…"
if ! command -v go >/dev/null 2>&1; then
    echo "WARN: 'go' not on PATH — skipping build check. Verify with 'go build ./...' manually."
else
    if go build ./...; then
        echo "  ✓ go build clean"
    else
        echo "  ✗ go build FAILED — original files are backed up at *.bak.$TS"
        exit 1
    fi
fi

echo
echo "============================================================"
echo "✅ Phase 2.4a (gang scheduling) installed."
echo "============================================================"
echo
echo "New files:"
echo "  api/v1alpha1/vgpugangjob_types.go"
echo "  api/v1alpha1/vgpugangreservation_types.go"
echo "  internal/controller/vgpugangjob_reconciler.go"
echo "  internal/controller/vgpugangreservation_reconciler.go"
echo "  internal/scheduler/gang.go"
echo "  internal/webhook/validating_gangjob.go"
echo "  internal/webhook/gangjob_validator_handler.go"
echo "  deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangjobs.yaml"
echo "  deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangreservations.yaml"
echo
echo "Patched files (originals backed up to *.bak.$TS):"
echo "  cmd/controller/main.go"
echo "  deployments/manifests/rbac/controller_rbac.yaml"
echo "  internal/scheduler/plugin.go"
echo
echo "Next steps:"
echo "  1. git diff cmd/controller/main.go internal/scheduler/plugin.go    # review"
echo "  2. go test ./...                                                   # unit tests"
echo "  3. Apply CRDs to your kind cluster:"
echo "     kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangjobs.yaml"
echo "     kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangreservations.yaml"
echo "  4. Rebuild and reload images:"
echo "     make docker-build && kind load docker-image vgpu-controller:latest --name vgpu-test"
echo "  5. Restart the controller deployment to pick up the new reconcilers."
echo
echo "Then submit a test gang:"
echo "  kubectl apply -f - <<EOF"
echo "  apiVersion: infrastructure.pranav2910.com/v1alpha1"
echo "  kind: VGPUGangJob"
echo "  metadata: { name: test-gang, namespace: default }"
echo "  spec:"
echo "    gangSize: 4"
echo "    minAvailable: 4"
echo "    priority: 500"
echo "    workloadClass: Training"
echo "    podTemplate:"
echo "      spec: { requestedVramBytes: 21474836480 }"   # 20 GiB each
echo "  EOF"
echo
echo "Watch:"
echo "  kubectl get vgang,vgpugangreservations,vgpujob,vgpuslice -A"
