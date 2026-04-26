package telemetry

// RecordScheduleAttempt logs the outcome of the bin-packing algorithm.
func RecordScheduleAttempt(success bool) {
	if success {
		ScheduleAttempts.WithLabelValues("success").Inc()
	} else {
		ScheduleAttempts.WithLabelValues("error").Inc()
	}
}

// RecordNodeCapacity updates the real-time VRAM gauges for a specific node.
func RecordNodeCapacity(nodeName string, total, free int64) {
	NodeTotalVRAM.WithLabelValues(nodeName).Set(float64(total))
	NodeFreeVRAM.WithLabelValues(nodeName).Set(float64(free))
}

// RecordHardwareAllocation tracks the physical success rate of the NodeAgent.
func RecordHardwareAllocation(nodeName string, success bool) {
	if success {
		HardwareAllocations.WithLabelValues(nodeName, "success").Inc()
	} else {
		HardwareAllocations.WithLabelValues(nodeName, "failed").Inc()
	}
}

// RecordDrift increments the self-healing anomaly counter.
func RecordDrift() {
	DriftEvents.Inc()
}
