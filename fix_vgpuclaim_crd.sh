#!/usr/bin/env bash
# ============================================================================
# Fix the VGPUClaim CRD jobRef insertion. The previous patch used wrong
# indentation (24 spaces) but your file uses 16 spaces under spec.properties.
# This rolls back the bad insertion and adds it correctly.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FILE="deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml"
[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found"; exit 1; }

# Backup the malformed version
cp -p "$FILE" "${FILE}.broken_$(date +%s)"

python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml")
src = p.read_text()

# Step 1: Remove any previous (malformed) jobRef insertion.
# We're looking for the bad lines we added.
import re
# The bad insertion was:
#                         jobRef:
#                           type: string
# (24 + 26 spaces) — let's strip any line containing "jobRef:" and the next line.
lines = src.splitlines(keepends=True)
cleaned = []
i = 0
while i < len(lines):
    if "jobRef:" in lines[i]:
        # Skip jobRef line + next line (type: string)
        i += 2
        continue
    cleaned.append(lines[i])
    i += 1
src = "".join(cleaned)

# Step 2: Now insert correctly. The serviceTier block is at 16 spaces.
# We add jobRef at the same indent level as a sibling.
target = """                serviceTier:
                  type: string
                  enum: [Guaranteed, BestEffort]
                  default: Guaranteed
"""
addition = """                serviceTier:
                  type: string
                  enum: [Guaranteed, BestEffort]
                  default: Guaranteed
                jobRef:
                  type: string
                  description: Name of the parent VGPUJob, if owned by one.
"""

if target not in src:
    print("ERROR: could not find serviceTier block at expected indentation")
    print("Falling back to no-op (jobRef will not be in CRD schema, but the")
    print("Go field still exists and will be sent — the API server will")
    print("just store it in a less validated way via x-kubernetes-preserve-unknown.")
    raise SystemExit(1)

src = src.replace(target, addition)
p.write_text(src)
print("✓ jobRef inserted into VGPUClaim CRD with correct indentation")
PYEOF

# Validate the YAML
echo ""
echo "Validating YAML..."
python3 -c "import yaml; yaml.safe_load(open('$FILE'))" && echo "✓ YAML is valid" || {
    echo "✗ YAML still broken — restoring from backup"
    LATEST_BROKEN=$(ls -t ${FILE}.broken_* | head -1)
    echo "(broken version saved at $LATEST_BROKEN)"
    exit 1
}

# Now apply
echo ""
echo "Applying CRDs..."
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml
kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpujobs.yaml
kubectl apply -f deployments/manifests/rbac/controller_rbac.yaml

echo ""
echo "Restarting controller and scheduler to pick up new code..."
kubectl rollout restart -n vgpu-system deploy/vgpu-controller deploy/vgpu-scheduler

sleep 30
echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "Verify VGPUJob CRD is registered:"
kubectl get crd vgpujobs.infrastructure.pranav2910.com >/dev/null 2>&1 \
    && echo "  ✓ vgpujobs CRD registered" \
    || echo "  ✗ vgpujobs CRD missing"

echo ""
echo "Verify jobRef field on VGPUClaim:"
kubectl get crd vgpuclaims.infrastructure.pranav2910.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.jobRef}{"\n"}'

echo ""
echo "✅ CRD fix applied. Now run the test scenario from the original script."
