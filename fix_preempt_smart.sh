#!/usr/bin/env bash
# ============================================================================
# Phase 2.3 — over-eviction fix v2
#
# Bug v1 (fixed by previous patch): concurrent reconciles created multiple
# PLANs, each over-evicting independently. Dedup annotation fixed that.
#
# Bug v2 (this fix): even within a single PLAN, the greedy selector
# overshoots when the smallest victim is below the need but combined with
# the next victim exceeds it.
#
# Example: need 20 GiB, candidates [15GiB, 20GiB, 20GiB, 20GiB].
# Old behavior: pick 15 (insufficient) + 20 (sufficient) = 35 GiB freed = OVERSHOOT
# Fix: prefer the smallest *single* victim that covers the need (20 GiB alone).
#      Only accumulate when no single victim is big enough.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".preempt2_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/scheduler/preemptor.go "$BACKUP/preemptor.go"
echo "Backup: $BACKUP"

# ============================================================================
# Replace the greedy selector with a smarter algorithm.
# ============================================================================
python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/scheduler/preemptor.go")
src = p.read_text()

if "smallest single victim that covers" in src:
    print("  - smarter selector already present")
    raise SystemExit(0)

# Anchor: the existing greedy loop
old = '''	// 5. Greedy selection: take victims until enough capacity freed.
	plan := &PreemptionPlan{
		Requester:   requester.DeepCopy(),
		Victims:     []VictimSelection{},
		NeededBytes: neededBytes,
		CreatedAt:   time.Now(),
	}
	for _, c := range candidates {
		plan.Victims = append(plan.Victims, c)
		plan.FreedBytes += c.AllocatedBytes
		if plan.FreedBytes >= neededBytes {
			break
		}
	}'''

new = '''	// 5. Selection algorithm — minimize eviction damage.
	//
	// Strategy:
	//   1. Look for the smallest single victim whose AllocatedBytes alone
	//      covers neededBytes. This minimizes both bytes-freed and
	//      number-of-victims when one victim is enough.
	//   2. If no single victim suffices, accumulate from the candidate list
	//      (already sorted: lowest priority -> smallest VRAM -> oldest).
	plan := &PreemptionPlan{
		Requester:   requester.DeepCopy(),
		Victims:     []VictimSelection{},
		NeededBytes: neededBytes,
		CreatedAt:   time.Now(),
	}

	// Phase 1: find the smallest single victim that covers the need.
	// Iterate in size-ascending order to find the smallest one >= neededBytes.
	// Build a size-sorted view of candidates without disturbing the original
	// priority/age order (used as fallback in Phase 2).
	bySize := make([]VictimSelection, len(candidates))
	copy(bySize, candidates)
	sort.SliceStable(bySize, func(i, j int) bool {
		return bySize[i].AllocatedBytes < bySize[j].AllocatedBytes
	})

	var single *VictimSelection
	for i := range bySize {
		if bySize[i].AllocatedBytes >= neededBytes {
			single = &bySize[i]
			break
		}
	}
	if single != nil {
		plan.Victims = []VictimSelection{*single}
		plan.FreedBytes = single.AllocatedBytes
	} else {
		// Phase 2: no single victim big enough — accumulate.
		// Use the original (priority-sorted) order so we still evict
		// lowest-priority/smallest/oldest first.
		for _, c := range candidates {
			plan.Victims = append(plan.Victims, c)
			plan.FreedBytes += c.AllocatedBytes
			if plan.FreedBytes >= neededBytes {
				break
			}
		}
	}'''

if old not in src:
    print("ERROR: could not find greedy selector block to replace")
    raise SystemExit(1)

src = src.replace(old, new)
p.write_text(src)
print("  ✓ smart selector installed (single-victim preferred when sufficient)")
PYEOF

# ============================================================================
# Build + deploy
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo "ERROR: go vet failed. Backup at: $BACKUP"
    exit 1
fi

echo ""
echo "Building scheduler..."
go build -o bin/scheduler ./cmd/scheduler || {
    echo "build failed — restoring"
    cp -p "$BACKUP/preemptor.go" internal/scheduler/preemptor.go
    exit 1
}
echo "  ✓ scheduler builds"

TAG="p23smart_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ image built ($TAG)"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-p23smart.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23smart.tar > /dev/null

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false

# Restart controller too to clear any stale state
kubectl delete pod -n vgpu-system -l control-plane=vgpu-controller --wait=false

# Cleanup
for ns in default ml-team-a ml-team-pre team-prod team-research; do
    kubectl get vgpujob,vgpuclaim,vgpuslice -n $ns -o name 2>/dev/null | \
        xargs -I{} kubectl patch {} -n $ns --type=json \
            -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null
done
kubectl get vgpuquota -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
        -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null

kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 45

# Final force-strip
for ns in default ml-team-a ml-team-pre team-prod team-research; do
    kubectl get vgpujob,vgpuclaim,vgpuslice -n $ns -o name 2>/dev/null | \
        xargs -I{} kubectl patch {} -n $ns --type=json \
            -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null
done
sleep 15

echo ""
echo "=== Resources (should be empty) ==="
kubectl get vgpujob -A
kubectl get vgpuclaim -A
kubectl get vgpuslice -A
kubectl get vgpuquota

echo ""
echo "=== Pods ==="
kubectl get pods -n vgpu-system

echo ""
echo "=== Scheduler image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ Smart selector installed. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Next: run stress_test_realworld.sh once cluster is confirmed clean."
