#!/usr/bin/env bash
# ============================================================================
# Two-part fix:
#   1. Scheduler RBAC: add VGPUJob read access so priorityFn can fetch jobs
#   2. priorityFn: log when the Job Get fails so silent failures stop hiding
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".rbacfix_${STAMP}"
mkdir -p "$BACKUP"

cp -p deployments/manifests/rbac/scheduler_rbac.yaml "$BACKUP/scheduler_rbac.yaml" 2>/dev/null || \
    echo "WARNING: scheduler_rbac.yaml not found; will look for it"
cp -p cmd/scheduler/main.go "$BACKUP/main.go"

# ============================================================================
# 1. Find the scheduler RBAC file and add vgpujobs.
# ============================================================================

# Find the scheduler ClusterRole — it might be in a few places
SCHED_RBAC=""
for f in deployments/manifests/rbac/scheduler_rbac.yaml \
         deployments/manifests/scheduler/rbac.yaml \
         deployments/manifests/scheduler_rbac.yaml; do
    if [[ -f "$f" ]] && grep -q "vgpu-scheduler-role\|kind: ClusterRole" "$f" 2>/dev/null; then
        SCHED_RBAC="$f"
        break
    fi
done

if [[ -z "$SCHED_RBAC" ]]; then
    echo "ERROR: could not find scheduler RBAC file"
    echo "Looking for any file with 'vgpu-scheduler-role':"
    grep -rl "vgpu-scheduler-role" deployments/ 2>/dev/null
    exit 1
fi

echo "Found scheduler RBAC: $SCHED_RBAC"

python3 - <<PYEOF
import pathlib
p = pathlib.Path("$SCHED_RBAC")
src = p.read_text()

if "vgpujobs" in src:
    print("  - vgpujobs already in scheduler RBAC")
else:
    # Find the line with vgpuclaims and add a parallel rule for vgpujobs.
    # The scheduler only needs read access (get/list/watch) since priorityFn
    # only does Get and the reconciler doesn't manage VGPUJob lifecycle.
    target = '''  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuclaims"]
    verbs: ["get", "list", "watch"]'''

    if target not in src:
        # Try a more flexible match
        import re
        m = re.search(r'(\s*-\s*apiGroups:\s*\["infrastructure\.pranav2910\.com"\]\s*\n\s*resources:\s*\["vgpuclaims"\]\s*\n\s*verbs:\s*\[[^\]]+\])', src)
        if not m:
            print("ERROR: could not find vgpuclaims rule as anchor")
            print("Manual fix: add this rule to the scheduler ClusterRole:")
            print('  - apiGroups: ["infrastructure.pranav2910.com"]')
            print('    resources: ["vgpujobs"]')
            print('    verbs: ["get", "list", "watch"]')
            raise SystemExit(1)
        target = m.group(1)

    addition = target + '''
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpujobs"]
    verbs: ["get", "list", "watch"]'''

    src = src.replace(target, addition)
    p.write_text(src)
    print("  ✓ vgpujobs read access added to scheduler RBAC")
PYEOF

# ============================================================================
# 2. Add visibility to priorityFn: log when the Job Get fails.
# ============================================================================

python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

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
    print("ERROR: could not find priorityFn block — manual fix needed")
    raise SystemExit(1)

src = src.replace(old, new)
p.write_text(src)
print("  ✓ priorityFn now logs Job Get failures and resolved priority")
PYEOF

# ============================================================================
# 3. Build, image, deploy.
# ============================================================================
echo ""
echo "Building scheduler binary..."
go build -o bin/scheduler ./cmd/scheduler || {
    echo "build failed — restoring main.go"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
}

TAG="rbac$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ vgpu-scheduler:$TAG"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-rbac.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-rbac.tar > /dev/null
echo "  ✓ imported into kind"

# Apply the RBAC change
echo ""
echo "Applying scheduler RBAC..."
kubectl apply -f "$SCHED_RBAC"

# Update scheduler deployment
kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null

kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false

# Cleanup state from previous test
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
echo "Scheduler image now running:"
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "Scheduler RBAC includes vgpujobs:"
kubectl get clusterrole vgpu-scheduler-role -o yaml | grep -A 1 vgpujobs | head -6

echo ""
echo "Cluster state (should be empty):"
kubectl get vgpujob -A
kubectl get vgpuclaim -A
kubectl get vgpuslice -A

echo ""
echo "✅ Fix applied. Re-run the Layer 2 test now."
