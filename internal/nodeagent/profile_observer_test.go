package nodeagent

import (
	"context"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func sliceStatus(t *testing.T, c client.Client, name string) vgpuv1alpha1.VGPUSliceStatus {
	t.Helper()
	var s vgpuv1alpha1.VGPUSlice
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: name}, &s); err != nil {
		t.Fatal(err)
	}
	return s.Status
}

// The node agent must record observed usage onto the slice status (the data the
// controller aggregates into a VGPUWorkloadProfile) — flushed promptly on a new
// peak. Runs with enforcement off: learning is independent of enforcement.
func TestObserveProfile_FlushesStatsOnPeakGrowth(t *testing.T) {
	d, c := fixture(t, 12*giB) // 12 GiB attributed to slice-1
	if err := d.detectOnce(context.Background()); err != nil {
		t.Fatalf("detectOnce: %v", err)
	}
	st := sliceStatus(t, c, "slice-1")
	if st.PeakObservedVRAMBytes != 12*giB {
		t.Fatalf("peakObserved=%d want 12Gi (flushed on first peak growth)", st.PeakObservedVRAMBytes)
	}
	if st.ObservedVRAMBytes != 12*giB {
		t.Fatalf("observed=%d want 12Gi", st.ObservedVRAMBytes)
	}
	if st.Observations < 1 {
		t.Fatalf("observations=%d want >=1", st.Observations)
	}
}

// A sustained over-use onset must be counted on the slice status (the input to
// the workload's violation/eviction history) once the stats flush.
func TestObserveProfile_CountsViolationAfterFlush(t *testing.T) {
	d, c := fixture(t, 12*giB) // 12 over a 10 GiB grant → violates after the streak
	clock := time.Unix(1_700_000_000, 0)
	d.now = func() time.Time { return clock }
	ctx := context.Background()

	for i := 0; i < sliceOveruseStreakThreshold; i++ {
		if err := d.detectOnce(ctx); err != nil {
			t.Fatalf("detectOnce: %v", err)
		}
	}
	// Advance past the flush interval; the next cycle flushes the accumulated
	// counters (peak already flushed on cycle 1, so only the interval triggers it).
	clock = clock.Add(profileFlushInterval + time.Second)
	if err := d.detectOnce(ctx); err != nil {
		t.Fatalf("detectOnce: %v", err)
	}

	st := sliceStatus(t, c, "slice-1")
	if st.ViolationCount < 1 {
		t.Fatalf("violationCount=%d want >=1 after onset + flush", st.ViolationCount)
	}
	if st.PeakObservedVRAMBytes != 12*giB {
		t.Fatalf("peakObserved=%d want 12Gi", st.PeakObservedVRAMBytes)
	}
	if st.Observations < int64(sliceOveruseStreakThreshold) {
		t.Fatalf("observations=%d want >=%d", st.Observations, sliceOveruseStreakThreshold)
	}
}
