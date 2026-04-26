package integration

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
)

func TestThunderingHerd_Concurrency(t *testing.T) {
	// 1. Set up an 80 GiB node.
	cache := scheduler.NewVRAMCache()
	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	const nodeName = "h100-worker-1"
	const nodeCapacityGiB = int64(80)
	const requestGiB = int64(8)
	const expectedSuccesses = int(nodeCapacityGiB / requestGiB) // 10

	cache.UpdateNodeCapacity(nodeName, nodeCapacityGiB) // fixed: UpdateNodeCapacity added in FIX 8

	// 2. Fire 100 concurrent workloads each requesting 8 GiB. Only 10 can succeed.
	var wg sync.WaitGroup
	var successCount int32
	workers := 100

	fmt.Printf("Firing %d concurrent AI workloads...\n", workers)

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			sliceUID := fmt.Sprintf("slice-%d", id)

			// Reserve returns (*ReservationTx, error) — fixed: was used as single error return.
			_, err := reserver.Reserve(sliceUID, nodeName, requestGiB*1024*1024*1024)
			if err == nil {
				atomic.AddInt32(&successCount, 1) // fixed: atomic instead of mutex
			}
		}(i)
	}
	wg.Wait()

	// 3. Verify exactly 10 successes.
	got := int(successCount)
	if got != expectedSuccesses {
		t.Fatalf("Concurrency failure: expected %d successes, got %d — thundering herd broke the lock",
			expectedSuccesses, got)
	}

	// 4. Verify the node is truly full.
	fits, _, _ := cache.CanFit(nodeName, 1) // fixed: was capturing only 2 of 3 return values
	if fits {
		t.Fatal("Math failure: node should be full but CanFit returned true")
	}

	fmt.Printf("PASS: %d workloads fired, exactly %d succeeded, %d safely rejected.\n",
		workers, got, workers-got)
}
