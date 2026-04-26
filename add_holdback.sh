#!/usr/bin/env bash
# ============================================================================
# Add a 2-second holdback for BestEffort slices.
#
# Why: the priority queue is correct but never has 2+ items at once because
# scheduling completes in <1 second. Holding BestEffort for 2 seconds gives
# any Guaranteed claim arriving in that window time to enter the queue and
# jump ahead via priority ordering.
#
# Effect: when a BestEffort + Guaranteed compete for capacity within a few
# seconds, Guaranteed wins. After 2s, BestEffort proceeds.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".holdback_${STAMP}"
mkdir -p "$BACKUP"
cp -p cmd/scheduler/main.go "$BACKUP/main.go"
echo "Backup: $BACKUP"

# ============================================================================
# Patch the slice reconciler: insert a holdback check before the Schedule call.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Find the bestEffort block + Schedule call and inject a holdback check
# right before the Schedule call.
old = '''	bestEffort := false
	// Resolve ServiceTier from the parent claim if present. Bug #19.
	if slice.Spec.ClaimRef != "" {
		var claim vgpuv1alpha1.VGPUClaim
		if err := r.client.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
			bestEffort = claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierBestEffort
		}
	}
	_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes, bestEffort)'''

new = '''	bestEffort := false
	// Resolve ServiceTier from the parent claim if present. Bug #19.
	if slice.Spec.ClaimRef != "" {
		var claim vgpuv1alpha1.VGPUClaim
		if err := r.client.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
			bestEffort = claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierBestEffort
		}
	}

	// HOLDBACK: BestEffort slices wait 2 seconds before their first scheduling
	// attempt. This gives any Guaranteed claim arriving in the same window
	// time to enter the priority queue and jump ahead. After 2s have passed
	// since the slice was created, scheduling proceeds normally.
	//
	// Without this, the scheduler is so fast (<1s per claim) that the priority
	// queue never holds 2+ items simultaneously, so priority ordering can't
	// matter. The holdback creates an artificial contention window.
	if bestEffort {
		const holdback = 2 * time.Second
		age := time.Since(slice.CreationTimestamp.Time)
		if age < holdback {
			remaining := holdback - age
			log.Printf("[holdback] BestEffort slice %s/%s waiting %v before scheduling",
				slice.Namespace, slice.Name, remaining.Round(100*time.Millisecond))
			return reconcile.Result{RequeueAfter: remaining}, nil
		}
	}

	_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes, bestEffort)'''

if old not in src:
    print("ERROR: could not find the target code block. Aborting.")
    raise SystemExit(1)

src = src.replace(old, new)
p.write_text(src)
print("  ✓ main.go — BestEffort holdback added")
PYEOF

# ============================================================================
# Build, image, deploy.
# ============================================================================
echo ""
echo "Verifying build..."
go vet ./cmd/scheduler/... || {
    echo "vet failed — restoring"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
}

go build -o bin/scheduler ./cmd/scheduler || {
    echo "build failed — restoring"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
}
echo "  ✓ binary built"

echo ""
echo "Building container image..."
TAG="hb$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ vgpu-scheduler:$TAG"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-hb.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-hb.tar > /dev/null
echo "  ✓ imported into kind"

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]'

# Clean state — wipe stuck claims from previous tests
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1 || true
kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1 || true

sleep 30
echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "✅ Holdback applied. Backup: $BACKUP"
echo ""
echo "Quick test:"
cat <<'TEST'
# 1. Filler — 72 GiB, leaves 8 GiB free
cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: hb-filler, namespace: default }
spec: { requestedVramBytes: 77309411328, serviceTier: Guaranteed }
EOF
sleep 10

# 2. BestEffort first
cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: hb-be, namespace: default }
spec: { requestedVramBytes: 8589934592, serviceTier: BestEffort }
EOF

# 3. Guaranteed within the 2s holdback window
sleep 1
cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: hb-g, namespace: default }
spec: { requestedVramBytes: 8589934592, serviceTier: Guaranteed }
EOF

# 4. Wait for scheduler decisions
sleep 15

echo "=== Final state ==="
kubectl get vgpuclaim
kubectl get vgpuslice

echo ""
echo "=== Scheduler decisions ==="
kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=80 | grep -E "holdback|Scheduling|bound|sufficient" | grep "hb-"
TEST
