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
	"log"
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
	log.Printf("[priorityqueue] Add  req=%v priority=%d depth=%d", req, priority, q.heap.Len())
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
	log.Printf("[priorityqueue] Get  req=%v priority=%d remaining=%d", it.request, it.priority, q.heap.Len())
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
