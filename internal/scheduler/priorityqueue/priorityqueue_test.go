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
