package telemetry

// This file holds the small helper functions that bundle a few metric
// operations together. Single-metric updates are done inline at the call site
// using the exported metric vars in metrics.go.

// ── Capacity ─────────────────────────────────────────────────────────────────

// RecordNodeVRAM sets all four per-node capacity gauges from a cache snapshot.
func RecordNodeVRAM(node string, capacity, reserved, allocated, free int64) {
	NodeCapacityBytes.WithLabelValues(node).Set(float64(capacity))
	NodeReservedBytes.WithLabelValues(node).Set(float64(reserved))
	NodeAllocatedBytes.WithLabelValues(node).Set(float64(allocated))
	NodeFreeBytes.WithLabelValues(node).Set(float64(free))
}

// ── Slice lifecycle ──────────────────────────────────────────────────────────

// RecordScheduleResult increments the slice scheduling attempt counter. result
// is one of success|deferred|wait|rejected|error; reason is a short, bounded
// label (avoid high-cardinality values like names).
func RecordScheduleResult(result, reason string) {
	SliceScheduleAttempts.WithLabelValues(result, reason).Inc()
}

// ── Topology ─────────────────────────────────────────────────────────────────

// RecordTopologyPlacement records, for a slice that expressed a zone
// preference, whether it landed in that zone and which zone it actually got.
func RecordTopologyPlacement(placedZone string, honored bool) {
	if honored {
		TopologyPreferenceHits.Inc()
	} else {
		TopologyPreferenceMisses.Inc()
	}
	if placedZone != "" {
		TopologySelectedZone.WithLabelValues(placedZone).Inc()
	}
}

// ── Preemption ───────────────────────────────────────────────────────────────

// RecordPreemptionPlan records a successful preemption plan: one plan, its
// victim count, the bytes it frees, and each victim's grace period.
func RecordPreemptionPlan(victims int, freedBytes int64, graceSeconds []int32) {
	Preemptions.WithLabelValues("planned").Inc()
	PreemptionVictims.Add(float64(victims))
	PreemptionFreedBytes.Add(float64(freedBytes))
	for _, g := range graceSeconds {
		PreemptionGrace.Observe(float64(g))
	}
}

// ── Data plane (node agent) ──────────────────────────────────────────────────

// RecordHardwareAllocation tracks the node agent's physical allocation outcome.
func RecordHardwareAllocation(nodeName string, success bool) {
	status := "failed"
	if success {
		status = "success"
	}
	HardwareAllocations.WithLabelValues(nodeName, status).Inc()
}

// RecordDrift increments the self-healing anomaly counter.
func RecordDrift() {
	DriftEvents.Inc()
}
