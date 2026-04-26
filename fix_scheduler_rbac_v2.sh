#!/usr/bin/env bash
# ============================================================================
# Fix scheduler RBAC: add vgpuclaims and vgpujobs read access (in case either
# is missing), and apply the priorityFn logging patch that didn't make it
# through last time.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".rbacfix2_${STAMP}"
mkdir -p "$BACKUP"
cp -p deployments/manifests/rbac/scheduler_rbac.yaml "$BACKUP/scheduler_rbac.yaml"
cp -p cmd/scheduler/main.go "$BACKUP/main.go"
echo "Backup: $BACKUP"

# ============================================================================
# 1. Inject vgpuclaims + vgpujobs rules into the scheduler ClusterRole.
#    Anchor: the existing "vgpuslices" rule, which we know exists.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("deployments/manifests/rbac/scheduler_rbac.yaml")
src = p.read_text()

# Anchor on the vgpuslices rule. Insert vgpuclaims (read) AND vgpujobs (read)
# right after it. Read access is enough — the scheduler doesn't write to claims
# or jobs; the controller does that.
anchor = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuslices"]
    verbs: ["get", "list", "watch", "patch", "update"]'''

if anchor not in src:
    print("ERROR: could not find vgpuslices rule")
    raise SystemExit(1)

addition = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuslices"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs"]
    verbs: ["get", "list", "watch"]'''

# Avoid double-inserting if we re-run.
if "vgpujobs" in src:
    print("  - vgpujobs already in scheduler RBAC")
else:
    src = src.replace(anchor, addition)
    p.write_text(src)
    print("  ✓ vgpuclaims + vgpujobs rules added to scheduler RBAC")
PYEOF

# Validate YAML
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('deployments/manifests/rbac/scheduler_rbac.yaml')))
assert len(docs) == 2, f'Expected 2 YAML docs, got {len(docs)}'
assert docs[0]['kind'] == 'ClusterRole'
assert docs[1]['kind'] == 'ClusterRoleBinding'
rules = docs[0]['rules']
resource_lists = [r.get('resources', []) for r in rules]
flat = [item for sub in resource_lists for item in sub]
assert 'vgpujobs' in flat, f'vgpujobs missing from rules: {flat}'
assert 'vgpuclaims' in flat, f'vgpuclaims missing from rules: {flat}'
print(f'  ✓ YAML valid: {len(rules)} rules, includes vgpujobs and vgpuclaims')
"

# ============================================================================
# 2. Apply the priorityFn logging patch (so silent Get failures stop hiding).
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Check if the patch already landed last time
if "but Job Get failed" in src:
    print("  - priorityFn logging patch already present")
else:
    old = '''		if claim.Spec.JobRef != "" {
			var job vgpuv1alpha1.VGPUJob
			if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
				// Map Job.spec.priority (0-1000) to a queue priority.
				// Anything >= 500 outranks Guaranteed; below acts as
				// fine-grained ordering within tiers.
				jobPriority := int(job.Spec.Priority)
				if jobPriority > basePriority {
					log.Printf("[priorityFn] %s/%s: job=%s priority=%d (overrides tier)",
						req.Namespace, req.Name, job.Name, jobPriority)
					return jobPriority
				}
			}
		}'''

    new = '''		if claim.Spec.JobRef != "" {
			var job vgpuv1alpha1.VGPUJob
			if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err != nil {
				log.Printf("[priorityFn] %s/%s: jobRef=%s but Job Get failed: %v — falling back to tier",
					req.Namespace, req.Name, claim.Spec.JobRef, err)
			} else {
				// Map Job.spec.priority (0-1000) to a queue priority.
				// Anything >= 500 outranks Guaranteed; below acts as
				// fine-grained ordering within tiers.
				jobPriority := int(job.Spec.Priority)
				log.Printf("[priorityFn] %s/%s: jobRef=%s job.priority=%d basePriority=%d",
					req.Namespace, req.Name, claim.Spec.JobRef, jobPriority, basePriority)
				if jobPriority > basePriority {
					log.Printf("[priorityFn] %s/%s: job=%s priority=%d (overrides tier)",
						req.Namespace, req.Name, job.Name, jobPriority)
					return jobPriority
				}
			}
		}'''

    if old not in src:
        print("ERROR: could not find priorityFn block (may have been edited)")
        raise SystemExit(1)

    src = src.replace(old, new)
    p.write_text(src)
    print("  ✓ priorityFn now logs Job Get failures + resolved priorities")
PYEOF

# ============================================================================
# 3. Build, image, deploy.
# ============================================================================
echo ""
echo "Building scheduler..."
go build -o bin/scheduler ./cmd/scheduler || {
    echo "build failed — restoring"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
}

TAG="rbac2_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ vgpu-scheduler:$TAG"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-rbac2.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-rbac2.tar > /dev/null
echo "  ✓ imported into kind"

# Apply the RBAC
echo ""
echo "Applying RBAC..."
kubectl apply -f deployments/manifests/rbac/scheduler_rbac.yaml

# Update scheduler deployment with new image
kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null

# Force fresh scheduler pod
kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false

# Cleanup state
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null

sleep 30
echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "Scheduler image:"
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "RBAC includes vgpujobs:"
kubectl get clusterrole vgpu-scheduler-role -o yaml | grep -B 1 -A 2 vgpujobs

echo ""
echo "Cluster state (should be empty):"
kubectl get vgpujob -A
kubectl get vgpuclaim -A
kubectl get vgpuslice -A

echo ""
echo "✅ Fix applied. Re-run the Layer 2 test."
