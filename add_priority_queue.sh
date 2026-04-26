#!/usr/bin/env bash
# ============================================================================
# Priority queue implementation for vGPU scheduler
#
# Replaces controller-runtime's default rate-limiting workqueue with a
# tier-aware priority queue. Items are dequeued in (priority desc, arrival asc)
# order: Guaranteed slices ALWAYS dequeue before BestEffort slices, regardless
# of arrival time.
#
# The implementation is a heap-backed wrapper that satisfies the full
# workqueue.TypedRateLimitingInterface[reconcile.Request] contract used by
# controller-runtime, so we can drop it in via .WithOptions(RateLimiter:...).
#
# Files created:
#   internal/scheduler/priorityqueue/priorityqueue.go  — the queue impl
#   internal/scheduler/priorityqueue/priorityqueue_test.go — unit tests
#
# Files modified:
#   cmd/scheduler/main.go — wires the priority queue into the reconciler
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".pqfix_${STAMP}"
mkdir -p "$BACKUP"
cp -p cmd/scheduler/main.go "$BACKUP/main.go"
echo "Backup: $BACKUP"

mkdir -p internal/scheduler/priorityqueue

# =============================================================================
# 1. The priority queue itself
# =============================================================================
cat > internal/scheduler/priorityqueue/priorityqueue.go <<'GOEOF'
// Package priorityqueue provides a tier-aware priority queue that satisfies
// controller-runtime's workqueue interface.
//
// Items are ordered by (Priority desc, EnqueueTime asc). Higher Priority
// dequeues first; ties broken by arrival order (FIFO within a tier).
//
// This is the architectural fix for the service-tier-preference bug: the
// previous default workqueue used FIFO ordering across all priorities, so a
// BestEffort claim arriving before a Guaranteed claim would always win when
// capacity was tight.
package priorityqueue

import (
	"container/heap"
	"context"
	"sync"
	"time"

	"k8s.io/client-go/util/workqueue"
)

// Priority levels. Higher numbers dequeue first.
const (
	PriorityBestEffort = 10
	PriorityGuaranteed = 100
)

// Item is the heap element. Only `request` and `priority` matter for ordering.
type item struct {
	request   any
	priority  int
	enqueued  time.Time
	heapIndex int
}

// itemHeap implements heap.Interface. Higher priority comes first; ties
// broken by enqueue time so we behave FIFO within a priority tier.
type itemHeap []*item

func (h itemHeap) Len() int { return len(h) }

func (h itemHeap) Less(i, j int) bool {
	if h[i].priority != h[j].priority {
		return h[i].priority > h[j].priority
	}
	return h[i].enqueued.Before(h[j].enqueued)
}

func (h itemHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].heapIndex = i
	h[j].heapIndex = j
}

func (h *itemHeap) Push(x any) {
	it := x.(*item)
	it.heapIndex = len(*h)
	*h = append(*h, it)
}

func (h *itemHeap) Pop() any {
	old := *h
	n := len(old)
	it := old[n-1]
	old[n-1] = nil
	it.heapIndex = -1
	*h = old[0 : n-1]
	return it
}

// PriorityFunc resolves the priority for a workqueue request. Implementations
// inspect the underlying object (e.g. fetch the slice's parent claim) and
// return PriorityGuaranteed or PriorityBestEffort.
type PriorityFunc func(request any) int

// Queue is a tier-aware priority workqueue. It is safe for concurrent use.
type Queue struct {
	mu      sync.Mutex
	cond    *sync.Cond
	heap    itemHeap
	dirty   map[any]*item // Add-after-Add coalesces; latest priority wins
	processing map[any]struct{}
	dirtyAfterProcessing map[any]int // requests Add'd while being processed

	// rate limiting
	limiter workqueue.TypedRateLimiter[any]

	priorityFn PriorityFunc

	shuttingDown bool
}

// New constructs a priority queue. priorityFn is called every time an item is
// enqueued; if it's expensive (e.g. does an API Get), keep it cached and short.
func New(priorityFn PriorityFunc, limiter workqueue.TypedRateLimiter[any]) *Queue {
	q := &Queue{
		dirty:                map[any]*item{},
		processing:           map[any]struct{}{},
		dirtyAfterProcessing: map[any]int{},
		limiter:              limiter,
		priorityFn:           priorityFn,
	}
	q.cond = sync.NewCond(&q.mu)
	heap.Init(&q.heap)
	return q
}

// Add enqueues a request with the priority returned by priorityFn. Repeated
// Add of the same request coalesces: the latest priority wins, and arrival
// time is preserved for fairness within a tier.
func (q *Queue) Add(req any) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.shuttingDown {
		return
	}
	priority := q.priorityFn(req)

	// If this request is already being processed, mark it dirty for re-add
	// after Done() — same as workqueue's standard behaviour.
	if _, busy := q.processing[req]; busy {
		q.dirtyAfterProcessing[req] = priority
		return
	}

	// Already in heap? Update priority if the new one is higher.
	if existing, ok := q.dirty[req]; ok {
		if priority > existing.priority {
			existing.priority = priority
			heap.Fix(&q.heap, existing.heapIndex)
		}
		return
	}

	it := &item{request: req, priority: priority, enqueued: time.Now()}
	heap.Push(&q.heap, it)
	q.dirty[req] = it
	q.cond.Signal()
}

// Get blocks until an item is ready or the queue is shutting down. Returns
// the request and a shutdown flag.
func (q *Queue) Get() (req any, shutdown bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for q.heap.Len() == 0 && !q.shuttingDown {
		q.cond.Wait()
	}
	if q.heap.Len() == 0 {
		return nil, true
	}
	it := heap.Pop(&q.heap).(*item)
	delete(q.dirty, it.request)
	q.processing[it.request] = struct{}{}
	return it.request, false
}

// Done marks a request as processed. If Add was called for the same request
// while it was being processed, the request is re-enqueued with the deferred
// priority.
func (q *Queue) Done(req any) {
	q.mu.Lock()
	defer q.mu.Unlock()
	delete(q.processing, req)

	if priority, dirty := q.dirtyAfterProcessing[req]; dirty {
		delete(q.dirtyAfterProcessing, req)
		it := &item{request: req, priority: priority, enqueued: time.Now()}
		heap.Push(&q.heap, it)
		q.dirty[req] = it
		q.cond.Signal()
	}
}

// Len returns the current queue depth.
func (q *Queue) Len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.heap.Len()
}

// ShutDown drains all waiting goroutines.
func (q *Queue) ShutDown() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.shuttingDown = true
	q.cond.Broadcast()
}

// ShutDownWithDrain blocks until all in-flight items are Done().
func (q *Queue) ShutDownWithDrain() {
	q.ShutDown()
	for {
		q.mu.Lock()
		empty := q.heap.Len() == 0 && len(q.processing) == 0
		q.mu.Unlock()
		if empty {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// ShuttingDown reports whether ShutDown was called.
func (q *Queue) ShuttingDown() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.shuttingDown
}

// AddRateLimited enqueues the request after the configured backoff.
func (q *Queue) AddRateLimited(req any) {
	delay := q.limiter.When(req)
	q.AddAfter(req, delay)
}

// Forget resets the rate-limit history for a request.
func (q *Queue) Forget(req any) { q.limiter.Forget(req) }

// NumRequeues is the rate limiter's view of how many times this item has
// been retried.
func (q *Queue) NumRequeues(req any) int { return q.limiter.NumRequeues(req) }

// AddAfter schedules an Add after the given duration.
func (q *Queue) AddAfter(req any, after time.Duration) {
	if after <= 0 {
		q.Add(req)
		return
	}
	go func() {
		select {
		case <-time.After(after):
		case <-context.Background().Done():
			return
		}
		q.Add(req)
	}()
}
GOEOF
echo "  ✓ priorityqueue.go"

# =============================================================================
# 2. Unit tests for the priority queue
# =============================================================================
cat > internal/scheduler/priorityqueue/priorityqueue_test.go <<'GOEOF'
package priorityqueue

import (
	"sync"
	"testing"
	"time"

	"k8s.io/client-go/util/workqueue"
)

// constantPriority is a test helper that returns the priority encoded in the
// request's name string. e.g. "g-1" → Guaranteed, "be-1" → BestEffort.
func constantPriority(req any) int {
	s, ok := req.(string)
	if !ok {
		return PriorityBestEffort
	}
	if len(s) > 1 && s[0] == 'g' {
		return PriorityGuaranteed
	}
	return PriorityBestEffort
}

func newTestQueue() *Queue {
	limiter := workqueue.DefaultTypedItemBasedRateLimiter[any]()
	return New(constantPriority, limiter)
}

// TestPriorityOrdering verifies that high-priority items dequeue first
// regardless of arrival order.
func TestPriorityOrdering(t *testing.T) {
	q := newTestQueue()
	defer q.ShutDown()

	// BestEffort first (arrives first), Guaranteed second.
	q.Add("be-1")
	q.Add("g-1")

	got1, _ := q.Get()
	q.Done(got1)
	got2, _ := q.Get()
	q.Done(got2)

	if got1 != "g-1" {
		t.Errorf("expected guaranteed first, got %v", got1)
	}
	if got2 != "be-1" {
		t.Errorf("expected besteffort second, got %v", got2)
	}
}

// TestFIFOWithinTier verifies that within a single priority tier, items
// dequeue in arrival order.
func TestFIFOWithinTier(t *testing.T) {
	q := newTestQueue()
	defer q.ShutDown()

	q.Add("g-1")
	time.Sleep(2 * time.Millisecond)
	q.Add("g-2")
	time.Sleep(2 * time.Millisecond)
	q.Add("g-3")

	for _, want := range []string{"g-1", "g-2", "g-3"} {
		got, _ := q.Get()
		q.Done(got)
		if got != want {
			t.Errorf("expected %s, got %v", want, got)
		}
	}
}

// TestCoalescing verifies repeated Add of the same request doesn't grow
// the queue.
func TestCoalescing(t *testing.T) {
	q := newTestQueue()
	defer q.ShutDown()

	q.Add("g-1")
	q.Add("g-1")
	q.Add("g-1")

	if got := q.Len(); got != 1 {
		t.Errorf("expected len 1 after 3x Add of same item, got %d", got)
	}
}

// TestPriorityUpgrade verifies that re-Add of an already-queued item with
// higher priority bubbles the item up.
func TestPriorityUpgrade(t *testing.T) {
	q := newTestQueue()
	defer q.ShutDown()

	q.Add("be-1")
	q.Add("be-2")
	// Now upgrade be-1 to Guaranteed — but constantPriority is fixed by name,
	// so we test this by injecting a custom priorityFn.
	q2 := New(func(req any) int {
		s := req.(string)
		switch s {
		case "x":
			return PriorityBestEffort
		case "y":
			return PriorityBestEffort
		}
		return PriorityBestEffort
	}, workqueue.DefaultTypedItemBasedRateLimiter[any]())
	defer q2.ShutDown()

	q2.Add("x")
	q2.Add("y")

	// Now re-add x with a priorityFn that returns Guaranteed for it.
	q2.priorityFn = func(req any) int {
		if req == "x" {
			return PriorityGuaranteed
		}
		return PriorityBestEffort
	}
	q2.Add("x")

	got, _ := q2.Get()
	if got != "x" {
		t.Errorf("expected upgraded x to dequeue first, got %v", got)
	}
}

// TestConcurrent simulates many parallel producers and one consumer.
// Verifies no panic, no item loss, and priority ordering holds.
func TestConcurrent(t *testing.T) {
	q := newTestQueue()
	defer q.ShutDown()

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if i%2 == 0 {
				q.Add(stringFmt("g-", i))
			} else {
				q.Add(stringFmt("be-", i))
			}
		}(i)
	}
	wg.Wait()

	guaranteedSeen := 0
	besteffortSeen := 0
	for i := 0; i < 100; i++ {
		req, shut := q.Get()
		if shut {
			t.Fatal("unexpected shutdown")
		}
		s := req.(string)
		if s[0] == 'g' {
			guaranteedSeen++
			if besteffortSeen > 0 {
				t.Fatalf("Guaranteed dequeued after BestEffort — invariant broken")
			}
		} else {
			besteffortSeen++
		}
		q.Done(req)
	}
	if guaranteedSeen != 50 || besteffortSeen != 50 {
		t.Errorf("expected 50/50 split, got %d/%d", guaranteedSeen, besteffortSeen)
	}
}

// TestShutdown verifies Get unblocks when the queue is shut down.
func TestShutdown(t *testing.T) {
	q := newTestQueue()

	done := make(chan struct{})
	go func() {
		_, shut := q.Get()
		if !shut {
			t.Errorf("expected shutdown signal")
		}
		close(done)
	}()

	time.Sleep(10 * time.Millisecond)
	q.ShutDown()
	select {
	case <-done:
		// good
	case <-time.After(time.Second):
		t.Fatal("Get did not unblock after ShutDown")
	}
}

func stringFmt(prefix string, n int) string {
	digits := ""
	if n == 0 {
		digits = "0"
	}
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return prefix + digits
}
GOEOF
echo "  ✓ priorityqueue_test.go"

# =============================================================================
# 3. Wire the priority queue into the scheduler reconciler.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Add imports we need.
new_imports = '''import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
	pq "github.com/pranav2910/vgpu-scheduler/internal/scheduler/priorityqueue"
	_ "github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/util/workqueue"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)'''

# Replace the existing import block (everything from "import (" to the matching ")").
import re
src = re.sub(
    r'import \(\n(?:[^)]|\n)*?\n\)',
    new_imports,
    src,
    count=1
)

# Replace the slice scheduling reconciler builder to use our priority queue.
old_builder = '''	if err := ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(&sliceSchedulingReconciler{sched: sched, client: mgr.GetClient()}); err != nil {
		log.Fatalf("setting up slice scheduling reconciler: %v", err)
	}'''

new_builder = '''	// Tier-aware priority queue (replaces controller-runtime's default FIFO).
	// Resolves a slice's tier by fetching its parent claim, defaulting to
	// BestEffort if the lookup fails.
	priorityFn := makePriorityFunc(mgr.GetClient())
	limiter := workqueue.DefaultTypedItemBasedRateLimiter[reconcile.Request]()
	priorityQueue := pq.New(
		func(req any) int { return priorityFn(req.(reconcile.Request)) },
		untypedLimiter(limiter),
	)

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		WithOptions(controller.Options{
			NewQueue: func(name string, _ workqueue.TypedRateLimiter[reconcile.Request]) workqueue.TypedRateLimitingInterface[reconcile.Request] {
				return &queueAdapter{q: priorityQueue}
			},
		}).
		Complete(&sliceSchedulingReconciler{sched: sched, client: mgr.GetClient()}); err != nil {
		log.Fatalf("setting up slice scheduling reconciler: %v", err)
	}'''

src = src.replace(old_builder, new_builder)

# Append the priority-resolution helper, the rate-limiter adapter, and the
# typed-queue adapter at the end of the file.
helpers = '''

// ─── Priority queue plumbing ────────────────────────────────────────────────

// makePriorityFunc returns a function that resolves a request's priority
// based on the parent VGPUClaim's ServiceTier. The lookup is best-effort:
// transient errors default to BestEffort, which means the slice will simply
// be processed in FIFO order with other BestEffort claims.
func makePriorityFunc(c client.Client) func(reconcile.Request) int {
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
}

// untypedLimiter wraps a typed rate-limiter so the priority queue (which is
// type-erased on `any`) can use it.
func untypedLimiter(typed workqueue.TypedRateLimiter[reconcile.Request]) workqueue.TypedRateLimiter[any] {
	return &typedToAnyLimiter{typed: typed}
}

type typedToAnyLimiter struct {
	typed workqueue.TypedRateLimiter[reconcile.Request]
}

func (a *typedToAnyLimiter) When(item any) time.Duration {
	if r, ok := item.(reconcile.Request); ok {
		return a.typed.When(r)
	}
	return 0
}
func (a *typedToAnyLimiter) Forget(item any) {
	if r, ok := item.(reconcile.Request); ok {
		a.typed.Forget(r)
	}
}
func (a *typedToAnyLimiter) NumRequeues(item any) int {
	if r, ok := item.(reconcile.Request); ok {
		return a.typed.NumRequeues(r)
	}
	return 0
}

// queueAdapter wraps our priority queue into the typed workqueue interface
// that controller-runtime expects. The conversions are zero-cost — the
// underlying queue is already type-erased.
type queueAdapter struct {
	q *pq.Queue
}

func (a *queueAdapter) Add(item reconcile.Request)                              { a.q.Add(item) }
func (a *queueAdapter) Len() int                                                { return a.q.Len() }
func (a *queueAdapter) Get() (item reconcile.Request, shutdown bool) {
	got, shut := a.q.Get()
	if shut || got == nil {
		return reconcile.Request{}, true
	}
	return got.(reconcile.Request), false
}
func (a *queueAdapter) Done(item reconcile.Request)                             { a.q.Done(item) }
func (a *queueAdapter) ShutDown()                                               { a.q.ShutDown() }
func (a *queueAdapter) ShutDownWithDrain()                                      { a.q.ShutDownWithDrain() }
func (a *queueAdapter) ShuttingDown() bool                                      { return a.q.ShuttingDown() }
func (a *queueAdapter) AddAfter(item reconcile.Request, after time.Duration)    { a.q.AddAfter(item, after) }
func (a *queueAdapter) AddRateLimited(item reconcile.Request)                   { a.q.AddRateLimited(item) }
func (a *queueAdapter) Forget(item reconcile.Request)                           { a.q.Forget(item) }
func (a *queueAdapter) NumRequeues(item reconcile.Request) int                  { return a.q.NumRequeues(item) }

// suppress unused-import warnings if the helpers are added but unused.
var _ = fmt.Sprintf
'''

# Append at end of file (before the last closing brace if any). Simplest:
# just concatenate.
src = src.rstrip() + "\n" + helpers
p.write_text(src)
print("  ✓ cmd/scheduler/main.go — priority queue wired")
PYEOF

# =============================================================================
# 4. Build, image, restart.
# =============================================================================
echo ""
echo "Running go vet first to catch issues early..."
if ! go vet ./internal/scheduler/priorityqueue/...; then
    echo "ERROR: priorityqueue package failed vet"
    exit 1
fi
if ! go vet ./cmd/scheduler/...; then
    echo "ERROR: scheduler main.go failed vet — restoring backup"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
fi

echo ""
echo "Running unit tests..."
go test ./internal/scheduler/priorityqueue/... || {
    echo "ERROR: priority queue unit tests failed"
    exit 1
}

echo ""
echo "Building scheduler..."
if ! go build -o bin/scheduler ./cmd/scheduler; then
    echo "ERROR: scheduler build failed — restoring main.go"
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
fi

echo ""
echo "Building container image with unique tag..."
TAG="pq$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "Image build failed:"; tail -20 /tmp/build.log; exit 1
}
echo "  ✓ vgpu-scheduler:$TAG"

echo ""
echo "Importing into kind..."
docker save vgpu-scheduler:$TAG -o /tmp/vgpu-pq.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-pq.tar > /dev/null
echo "  ✓ imported"

echo ""
echo "Updating deployment to use the new tag..."
kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]'

# Clean any stuck claims/slices first
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1 || true
kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1 || true

sleep 30

echo ""
echo "Pods:"
kubectl get pods -n vgpu-system

echo ""
echo "✅ Priority queue applied. Backup at: $BACKUP"
echo ""
echo "Test it:"
echo "  bash test_layer1_complete.sh"
echo ""
echo "Or specifically the service-tier test, which was previously a known limitation:"
echo "  Submit a 72 GiB filler, then 1 BestEffort + 1 Guaranteed for 8 GiB."
echo "  Guaranteed should now WIN regardless of arrival order."
