package telemetry

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	// Scheduler Metrics
	ScheduleAttempts = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "vgpu_scheduler_attempts_total",
			Help: "Total number of attempts to schedule a vGPU slice",
		},
		[]string{"result"}, // "success" or "error"
	)

	ActiveReservations = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "vgpu_scheduler_reservations_active",
			Help: "Number of speculative locks currently held in memory",
		},
	)

	// Capacity Metrics
	NodeTotalVRAM = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "vgpu_node_total_vram_bytes",
			Help: "Total physical VRAM capacity per node",
		},
		[]string{"node"},
	)

	NodeFreeVRAM = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "vgpu_node_free_vram_bytes",
			Help: "Available VRAM capacity per node after allocations and reservations",
		},
		[]string{"node"},
	)

	// Data Plane Metrics
	HardwareAllocations = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "vgpu_allocations_total",
			Help: "Total number of physical hardware allocations performed",
		},
		[]string{"node", "status"}, // status: "success", "failed"
	)

	DriftEvents = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "vgpu_drift_events_total",
			Help: "Total number of times the self-healing engine detected state drift",
		},
	)
)

func init() {
	// Register custom metrics with the global controller-runtime registry
	metrics.Registry.MustRegister(
		ScheduleAttempts,
		ActiveReservations,
		NodeTotalVRAM,
		NodeFreeVRAM,
		HardwareAllocations,
		DriftEvents,
	)
}
