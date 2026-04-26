#!/usr/bin/env bash
# ============================================================================
# Repair controller_rbac.yaml after the bad Layer 2 append.
#
# What went wrong: previous patch did "append at end of file" but the file
# has TWO documents (ClusterRole + ClusterRoleBinding). Append went after
# the binding's `subjects:` array, so kubectl thought the new rules were
# additional ServiceAccount subjects.
#
# Fix: remove any malformed lines, then inject the vgpujobs rules into the
# ClusterRole's `rules:` array (in the first YAML document).
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FILE="deployments/manifests/rbac/controller_rbac.yaml"
[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found"; exit 1; }

cp -p "$FILE" "${FILE}.broken_$(date +%s)"

python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("deployments/manifests/rbac/controller_rbac.yaml")
src = p.read_text()

# Step 1: Strip everything after the ClusterRoleBinding's subjects block
# that was incorrectly appended. We do this by truncating at the first
# malformed line (any line at indent 2 that says "- apiGroups:" AFTER
# the subjects block has started).

lines = src.splitlines(keepends=True)
in_binding = False
in_subjects = False
seen_first_subject = False
truncate_at = None

for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped == "---":
        in_binding = True
        in_subjects = False
        seen_first_subject = False
        continue
    if not in_binding:
        continue
    if stripped.startswith("subjects:"):
        in_subjects = True
        continue
    if in_subjects:
        # First valid subject is "- kind: ServiceAccount"
        if stripped.startswith("- kind:"):
            seen_first_subject = True
            continue
        # Lines belonging to the first subject (name:, namespace:) are indented further
        if seen_first_subject and (stripped.startswith("name:") or stripped.startswith("namespace:")):
            continue
        # Anything else after we've seen the first subject = malformed append
        if seen_first_subject and stripped.startswith("- apiGroups:"):
            truncate_at = i
            break
        # Also catch the case where the malformed lines come before any valid subject
        if not seen_first_subject and stripped.startswith("- apiGroups:"):
            truncate_at = i
            break

if truncate_at is not None:
    lines = lines[:truncate_at]
    print(f"  Truncating malformed append at line {truncate_at + 1}")

# Step 2: Make sure the file ends properly. The ServiceAccount subject block
# should be the last thing in the file.
src = "".join(lines).rstrip() + "\n"

# Step 3: Inject vgpujobs rules into the ClusterRole's rules: section.
# We insert before the existing "- apiGroups: \"\"\n    resources: [\"events\"]"
# rule, which is a stable anchor.

if "vgpujobs" in src:
    print("  - vgpujobs rules already present in ClusterRole")
else:
    anchor = '''  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]'''
    addition = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs/finalizers"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]'''

    if anchor not in src:
        print("ERROR: could not find events rule as anchor — manual edit needed")
        raise SystemExit(1)

    src = src.replace(anchor, addition)
    print("  ✓ vgpujobs rules added to ClusterRole")

p.write_text(src)
PYEOF

# Validate the YAML
echo ""
echo "Validating YAML..."
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('$FILE')))
assert len(docs) == 2, f'Expected 2 docs, got {len(docs)}'
assert docs[0]['kind'] == 'ClusterRole', f\"First doc should be ClusterRole, got {docs[0]['kind']}\"
assert docs[1]['kind'] == 'ClusterRoleBinding', f\"Second doc should be ClusterRoleBinding, got {docs[1]['kind']}\"
# Verify vgpujobs is in rules
rules = docs[0]['rules']
assert any('vgpujobs' in (r.get('resources') or []) for r in rules), 'vgpujobs rule missing'
# Verify subjects is correctly structured
subjects = docs[1]['subjects']
assert all('kind' in s for s in subjects), f'Malformed subjects: {subjects}'
print('  ✓ YAML structure verified')
print(f'  ✓ ClusterRole has {len(rules)} rules')
print(f'  ✓ ClusterRoleBinding has {len(subjects)} subject(s)')
"

echo ""
echo "Applying RBAC..."
kubectl apply -f "$FILE"

echo ""
echo "Restarting controller to pick up new RBAC..."
kubectl rollout restart -n vgpu-system deploy/vgpu-controller

sleep 30
echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "Controller logs (last 20 lines, looking for any RBAC errors):"
kubectl logs -n vgpu-system deploy/vgpu-controller --tail=20

echo ""
echo "✅ RBAC fix applied. Verify VGPUJob is reachable:"
kubectl get vgpujobs -A 2>&1 | head -5

echo ""
echo "Now run the test scenario from the original Layer 2 script."
