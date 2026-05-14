#!/usr/bin/env bash
# ============================================================================
# fix_controller_security.sh
#
# Fixes the controller crash:
#   "controller manager crashed: open /tmp/k8s-webhook-server/serving-certs/
#    tls.crt: permission denied"
#
# Root cause:
#   The controller's distroless base runs as UID 65532. The webhook-cert
#   Secret is mounted with defaultMode 0440 — but without an `fsGroup`
#   in the pod's securityContext, the file's group is `root` (gid 0).
#   So the file is rw-r----- root:root and UID 65532 can't read it.
#
# Fix:
#   Add a pod-level securityContext with fsGroup: 65532. Kubernetes will
#   chgrp the mounted Secret to that gid, and the existing 0440 mode lets
#   the container read it.
#
# Side-benefit: silences the PodSecurity "restricted" warnings that have
# been firing on every kubectl apply by setting all the required fields
# at the same time.
#
# Idempotent: re-running after success is a no-op.
# Backups go to *.bak.<timestamp>.
# ============================================================================

set -euo pipefail

CTRL_FILE="deployments/manifests/controller_deployment.yaml"
SCHED_FILE="deployments/manifests/scheduler_deployment.yaml"

if [[ ! -f "$CTRL_FILE" ]]; then
    echo "ERROR: run from repo root." >&2
    exit 1
fi

if grep -q "fsGroup: 65532" "$CTRL_FILE"; then
    echo "✓ Patches already applied. Nothing to do."
    exit 0
fi

TS=$(date +%s)
cp "$CTRL_FILE" "${CTRL_FILE}.bak.${TS}"
[[ -f "$SCHED_FILE" ]] && cp "$SCHED_FILE" "${SCHED_FILE}.bak.${TS}"
echo "Backups: ${CTRL_FILE}.bak.${TS}$([[ -f "$SCHED_FILE" ]] && echo ", ${SCHED_FILE}.bak.${TS}")"

# ────────────────────────────────────────────────────────────────────────────
# Patch the controller deployment.
#
# Insert pod-level securityContext (with fsGroup) before serviceAccountName,
# and container-level securityContext (capabilities, allowPrivEscalation,
# readOnlyRootFilesystem) before resources.
# ────────────────────────────────────────────────────────────────────────────
python3 - "$CTRL_FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
orig = len(src)

# Pod-level securityContext insertion. Anchor: the line `      serviceAccountName: vgpu-controller-sa`.
# We insert ABOVE it so the block sits between `spec:` and serviceAccountName.
old1 = "      serviceAccountName: vgpu-controller-sa\n"
new1 = (
    "      securityContext:\n"
    "        runAsNonRoot: true\n"
    "        runAsUser: 65532\n"
    "        runAsGroup: 65532\n"
    "        fsGroup: 65532\n"
    "        seccompProfile:\n"
    "          type: RuntimeDefault\n"
    "      serviceAccountName: vgpu-controller-sa\n"
)
assert src.count(old1) == 1, "Patch 1: serviceAccountName anchor not found exactly once"
src = src.replace(old1, new1)

# Container-level securityContext. Anchor: the `imagePullPolicy: IfNotPresent`
# line. Insert securityContext block AFTER it, BEFORE ports.
old2 = (
    "          image: vgpu-controller:latest\n"
    "          imagePullPolicy: IfNotPresent\n"
    "          ports:\n"
)
new2 = (
    "          image: vgpu-controller:latest\n"
    "          imagePullPolicy: IfNotPresent\n"
    "          securityContext:\n"
    "            allowPrivilegeEscalation: false\n"
    "            readOnlyRootFilesystem: true\n"
    "            capabilities:\n"
    "              drop: [\"ALL\"]\n"
    "          ports:\n"
)
assert src.count(old2) == 1, "Patch 2: imagePullPolicy anchor not found exactly once"
src = src.replace(old2, new2)

assert len(src) > orig + 350, f"controller deployment didn't grow as expected: {orig} -> {len(src)}"
path.write_text(src)
print(f"  ~ {path} patched ({orig} -> {len(src)} bytes)")
PYEOF

# ────────────────────────────────────────────────────────────────────────────
# Patch the scheduler deployment too — silences the same PodSecurity warning
# even though the scheduler isn't crashing. No secret to read so fsGroup
# isn't strictly needed, but consistency + warning-free apply is worth it.
# ────────────────────────────────────────────────────────────────────────────
if [[ -f "$SCHED_FILE" ]]; then
    python3 - "$SCHED_FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
orig = len(src)

# Insert pod-level securityContext before serviceAccountName.
old1 = "      serviceAccountName: vgpu-scheduler-sa\n"
new1 = (
    "      securityContext:\n"
    "        runAsNonRoot: true\n"
    "        runAsUser: 65532\n"
    "        runAsGroup: 65532\n"
    "        fsGroup: 65532\n"
    "        seccompProfile:\n"
    "          type: RuntimeDefault\n"
    "      serviceAccountName: vgpu-scheduler-sa\n"
)
assert src.count(old1) == 1, "Sched patch 1: serviceAccountName anchor not found exactly once"
src = src.replace(old1, new1)

# Container-level securityContext. Anchor: the imagePullPolicy line.
old2 = (
    "        image: vgpu-scheduler:latest\n"
    "        imagePullPolicy: IfNotPresent\n"
    "        resources:\n"
)
new2 = (
    "        image: vgpu-scheduler:latest\n"
    "        imagePullPolicy: IfNotPresent\n"
    "        securityContext:\n"
    "          allowPrivilegeEscalation: false\n"
    "          readOnlyRootFilesystem: true\n"
    "          capabilities:\n"
    "            drop: [\"ALL\"]\n"
    "        resources:\n"
)
assert src.count(old2) == 1, "Sched patch 2: imagePullPolicy anchor not found exactly once"
src = src.replace(old2, new2)

path.write_text(src)
print(f"  ~ {path} patched ({orig} -> {len(src)} bytes)")
PYEOF
fi

# ────────────────────────────────────────────────────────────────────────────
# Apply
# ────────────────────────────────────────────────────────────────────────────
echo
echo "Applying updated controller deployment..."
kubectl apply -f "$CTRL_FILE"
[[ -f "$SCHED_FILE" ]] && kubectl apply -f "$SCHED_FILE"

echo
echo "Waiting for controller rollout..."
if kubectl rollout status -n vgpu-system deployment/vgpu-controller --timeout=120s; then
    echo "  ✓ controller rolled out cleanly"
else
    echo "  ✗ rollout still failing — check pod logs:"
    echo "    kubectl get pods -n vgpu-system"
    echo "    kubectl logs -n vgpu-system <pod-name>"
    exit 1
fi

[[ -f "$SCHED_FILE" ]] && kubectl rollout status -n vgpu-system deployment/vgpu-scheduler --timeout=120s

echo
echo "============================================================"
echo "✅ controller security context fixed."
echo "============================================================"
echo
echo "Verify the new pod is running and healthy:"
echo "  kubectl get pods -n vgpu-system"
echo "  kubectl logs -n vgpu-system deployment/vgpu-controller --tail=30"
echo
echo "Then re-run the full Wave 1 battery:"
echo "  bash real_world_test.sh"
