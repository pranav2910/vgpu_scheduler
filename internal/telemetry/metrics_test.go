package telemetry

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// TestMetrics_HelpersIncrement is the Phase 3.2 smoke test: it exercises a
// representative helper from each metric category and asserts the underlying
// series moved by the expected amount.
func TestMetrics_HelpersIncrement(t *testing.T) {
	// Slice lifecycle: schedule-attempt counter.
	before := testutil.ToFloat64(SliceScheduleAttempts.WithLabelValues("success", ""))
	RecordScheduleResult("success", "")
	if got := testutil.ToFloat64(SliceScheduleAttempts.WithLabelValues("success", "")); got != before+1 {
		t.Fatalf("schedule attempts: got %v, want %v", got, before+1)
	}

	// Capacity: per-node gauges set absolutely.
	RecordNodeVRAM("smoke-node", 100, 20, 30, 50)
	if got := testutil.ToFloat64(NodeFreeBytes.WithLabelValues("smoke-node")); got != 50 {
		t.Fatalf("node free bytes: got %v, want 50", got)
	}
	if got := testutil.ToFloat64(NodeReservedBytes.WithLabelValues("smoke-node")); got != 20 {
		t.Fatalf("node reserved bytes: got %v, want 20", got)
	}

	// Topology: hit + selected-zone.
	hits := testutil.ToFloat64(TopologyPreferenceHits)
	zone := testutil.ToFloat64(TopologySelectedZone.WithLabelValues("nvlink-a"))
	RecordTopologyPlacement("nvlink-a", true)
	if got := testutil.ToFloat64(TopologyPreferenceHits); got != hits+1 {
		t.Fatalf("topology hits: got %v, want %v", got, hits+1)
	}
	if got := testutil.ToFloat64(TopologySelectedZone.WithLabelValues("nvlink-a")); got != zone+1 {
		t.Fatalf("topology selected zone: got %v, want %v", got, zone+1)
	}

	// Preemption: plan bundles several counters + a histogram.
	victims := testutil.ToFloat64(PreemptionVictims)
	freed := testutil.ToFloat64(PreemptionFreedBytes)
	RecordPreemptionPlan(3, 1024, []int32{30, 30, 60})
	if got := testutil.ToFloat64(PreemptionVictims); got != victims+3 {
		t.Fatalf("preemption victims: got %v, want %v", got, victims+3)
	}
	if got := testutil.ToFloat64(PreemptionFreedBytes); got != freed+1024 {
		t.Fatalf("preemption freed bytes: got %v, want %v", got, freed+1024)
	}
}

// TestMetrics_RegisteredForExposition verifies the metrics are registered with
// the controller-runtime registry that the manager serves at /metrics, so the
// instrumentation actually reaches a scrape.
func TestMetrics_RegisteredForExposition(t *testing.T) {
	// Touch a few series so they appear in the gather output.
	RecordScheduleResult("success", "")
	RecordNodeVRAM("smoke-node", 100, 20, 30, 50)
	GangAdmissionSlotHeld.Set(1)

	for _, name := range []string{
		"vgpu_slice_schedule_attempts_total",
		"vgpu_node_free_bytes",
		"vgpu_gang_admission_slot_held",
	} {
		n, err := testutil.GatherAndCount(metrics.Registry, name)
		if err != nil {
			t.Fatalf("gathering %s: %v", name, err)
		}
		if n == 0 {
			t.Fatalf("metric %s not registered/exposed", name)
		}
	}
}
