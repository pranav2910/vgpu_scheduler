#!/usr/bin/env bash
# ============================================================================
# Add diagnostic logging to the priority queue path so we can see:
#   1. Is priorityFn being called at all?
#   2. What priority does it return for each request?
#   3. What order does Get() dequeue items in?
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".pqdebug_${STAMP}"
mkdir -p "$BACKUP"
cp -p cmd/scheduler/main.go "$BACKUP/main.go"
cp -p internal/scheduler/priorityqueue/priorityqueue.go "$BACKUP/priorityqueue.go"

# 1. Add logging inside priorityqueue.Add and Get.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/priorityqueue/priorityqueue.go")
src = p.read_text()

# Add log import if missing
if '"log"' not in src:
    src = src.replace(
        '"container/heap"\n\t"context"\n\t"sync"\n\t"time"',
        '"container/heap"\n\t"context"\n\t"log"\n\t"sync"\n\t"time"'
    )

# Add log line at the END of Add(), after enqueueing.
src = src.replace(
    "\tit := &item{request: req, priority: priority, enqueued: time.Now()}\n"
    "\theap.Push(&q.heap, it)\n"
    "\tq.dirty[req] = it\n"
    "\tq.cond.Signal()\n"
    "}",
    "\tit := &item{request: req, priority: priority, enqueued: time.Now()}\n"
    "\theap.Push(&q.heap, it)\n"
    "\tq.dirty[req] = it\n"
    "\tq.cond.Signal()\n"
    "\tlog.Printf(\"[priorityqueue] Add  req=%v priority=%d depth=%d\", req, priority, q.heap.Len())\n"
    "}"
)

# Add log line at end of Get() before returning.
src = src.replace(
    "\tit := heap.Pop(&q.heap).(*item)\n"
    "\tdelete(q.dirty, it.request)\n"
    "\tq.processing[it.request] = struct{}{}\n"
    "\treturn it.request, false\n"
    "}",
    "\tit := heap.Pop(&q.heap).(*item)\n"
    "\tdelete(q.dirty, it.request)\n"
    "\tq.processing[it.request] = struct{}{}\n"
    "\tlog.Printf(\"[priorityqueue] Get  req=%v priority=%d remaining=%d\", it.request, it.priority, q.heap.Len())\n"
    "\treturn it.request, false\n"
    "}"
)

p.write_text(src)
print("  ✓ priorityqueue.go — added Add/Get logging")
PYEOF

# 2. Add logging in cmd/scheduler/main.go's makePriorityFunc to confirm tier
#    resolution and report failure modes.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Replace the priorityFn body with a verbose version.
old = '''func makePriorityFunc(c client.Client) func(reconcile.Request) int {
	return func(req reconcile.Request) int {
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()

		var slice vgpuv1alpha1.VGPUSlice
		if err := c.Get(ctx, req.NamespacedName, &slice); err != nil {
			return pq.PriorityBestEffort
		}
		if slice.Spec.ClaimRef == "" {
			return pq.PriorityBestEffort
		}

		var claim vgpuv1alpha1.VGPUClaim
		if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil {
			return pq.PriorityBestEffort
		}
		if claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierGuaranteed {
			return pq.PriorityGuaranteed
		}
		return pq.PriorityBestEffort
	}
}'''

new = '''func makePriorityFunc(c client.Client) func(reconcile.Request) int {
	return func(req reconcile.Request) int {
		// Generous timeout — we want to actually fetch the claim, not
		// punt to BestEffort because of a 200ms budget.
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()

		var slice vgpuv1alpha1.VGPUSlice
		if err := c.Get(ctx, req.NamespacedName, &slice); err != nil {
			log.Printf("[priorityFn] %s/%s: slice Get failed (%v) → BestEffort", req.Namespace, req.Name, err)
			return pq.PriorityBestEffort
		}
		if slice.Spec.ClaimRef == "" {
			log.Printf("[priorityFn] %s/%s: empty ClaimRef → BestEffort", req.Namespace, req.Name)
			return pq.PriorityBestEffort
		}

		var claim vgpuv1alpha1.VGPUClaim
		if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil {
			log.Printf("[priorityFn] %s/%s: claim Get failed (%v) → BestEffort", req.Namespace, req.Name, err)
			return pq.PriorityBestEffort
		}
		if claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierGuaranteed {
			log.Printf("[priorityFn] %s/%s: tier=Guaranteed → priority=%d", req.Namespace, req.Name, pq.PriorityGuaranteed)
			return pq.PriorityGuaranteed
		}
		log.Printf("[priorityFn] %s/%s: tier=BestEffort → priority=%d", req.Namespace, req.Name, pq.PriorityBestEffort)
		return pq.PriorityBestEffort
	}
}'''

src = src.replace(old, new)
p.write_text(src)
print("  ✓ main.go — verbose priorityFn with 2s timeout")
PYEOF

# 3. Build, image, push.
echo ""
echo "Building..."
go vet ./internal/scheduler/priorityqueue/... ./cmd/scheduler/... || {
    echo "vet failed — restoring"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    cp -p "$BACKUP/priorityqueue.go" internal/scheduler/priorityqueue/priorityqueue.go
    exit 1
}
go test ./internal/scheduler/priorityqueue/... || {
    echo "tests failed — restoring"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    cp -p "$BACKUP/priorityqueue.go" internal/scheduler/priorityqueue/priorityqueue.go
    exit 1
}
go build -o bin/scheduler ./cmd/scheduler || exit 1

TAG="pqdbg$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ vgpu-scheduler:$TAG"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-pq-dbg.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-pq-dbg.tar > /dev/null
echo "  ✓ imported"

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]'

# Clean stuck claims
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1 || true
kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1 || true

sleep 30
echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "✅ Diagnostic logging deployed. Now run a single Guaranteed claim:"
echo ""
echo "  cat <<EOF | kubectl apply -f -"
echo "  apiVersion: infrastructure.pranav2910.com/v1alpha1"
echo "  kind: VGPUClaim"
echo "  metadata: { name: dbg, namespace: default }"
echo "  spec: { requestedVramBytes: 4294967296, serviceTier: Guaranteed }"
echo "  EOF"
echo ""
echo "  sleep 10"
echo "  kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=80 | grep -E 'priorityqueue|priorityFn|Scheduling'"
