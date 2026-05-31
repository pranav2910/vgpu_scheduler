package telemetry

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// All metrics register with controller-runtime's global registry, which the
// manager already exposes at the configured metrics bind address (scheduler:
// :8081/metrics, controller: its own /metrics). Both binaries import this
// package, so each exposes the metrics its code paths actually touch.
//
// Naming follows Prometheus conventions: _total suffix on counters, _bytes /
// _seconds unit suffixes, base units (bytes, seconds). Gauges that represent a
// live inventory (slices by phase) are refreshed by a periodic collector in
// the scheduler rather than maintained incrementally.

var (
	// ── Capacity ──────────────────────────────────────────────────────────
	// Where the GPU memory is going, per node and per namespace.

	NodeCapacityBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_node_capacity_bytes",
		Help: "Total physical VRAM capacity of a node, in bytes.",
	}, []string{"node"})

	NodeReservedBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_node_reserved_bytes",
		Help: "VRAM speculatively reserved (assumed, not yet allocated) on a node, in bytes.",
	}, []string{"node"})

	NodeAllocatedBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_node_allocated_bytes",
		Help: "VRAM allocated to bound slices on a node, in bytes.",
	}, []string{"node"})

	NodeFreeBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_node_free_bytes",
		Help: "VRAM available on a node after allocations and reservations, in bytes.",
	}, []string{"node"})

	NamespaceAllocatedBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_namespace_allocated_bytes",
		Help: "VRAM allocated to all slices in a namespace, in bytes.",
	}, []string{"namespace"})

	NamespaceQuotaBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_namespace_quota_bytes",
		Help: "Configured VGPUQuota maxVramBytes for a namespace, in bytes.",
	}, []string{"namespace"})

	// ── Slice lifecycle ───────────────────────────────────────────────────

	SlicesByPhase = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_slices_total",
		Help: "Current number of VGPUSlices by phase (refreshed periodically).",
	}, []string{"phase"})

	SliceScheduleAttempts = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_slice_schedule_attempts_total",
		Help: "Slice scheduling attempts by result and reason.",
	}, []string{"result", "reason"}) // result: success|deferred|wait|rejected|error

	SliceScheduleLatency = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    "vgpu_slice_schedule_latency_seconds",
		Help:    "Wall-clock duration of a single Schedule() cycle, in seconds.",
		Buckets: []float64{.0005, .001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5},
	})

	SliceReady = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_slice_ready_total",
		Help: "Total slices observed transitioning to Ready.",
	})

	SliceFailed = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_slice_failed_total",
		Help: "Total slices observed transitioning to Failed, by reason.",
	}, []string{"reason"})

	// ── Gang scheduling (core claim) ──────────────────────────────────────

	GangAttempts = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_gang_attempts_total",
		Help: "Gang reservations reaching a terminal outcome, by result.",
	}, []string{"result"}) // result: committed|failed

	GangAdmissionDecisions = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_gang_admission_decisions_total",
		Help: "Gang gate decisions, by decision.",
	}, []string{"decision"}) // decision: admitted|deferred|wait|rejected

	GangQuorumWait = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    "vgpu_gang_quorum_wait_seconds",
		Help:    "Time from a gang cohort first being observed to reaching quorum, in seconds.",
		Buckets: []float64{.1, .5, 1, 2, 5, 10, 20, 30, 60, 120},
	})

	GangRollbacks = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_gang_rollbacks_total",
		Help: "Gang reservations torn down (rolled back), by reason.",
	}, []string{"reason"})

	GangAdmissionBackoffs = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_gang_admission_backoffs_total",
		Help: "Times a stalled gang was backed off and yielded the admission slot.",
	})

	GangAdmissionSlotHeld = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "vgpu_gang_admission_slot_held",
		Help: "1 while a gang holds the serialized admission slot, 0 when free.",
	})

	// ── Preemption ────────────────────────────────────────────────────────

	Preemptions = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_preemptions_total",
		Help: "Preemption plans produced, by result.",
	}, []string{"result"}) // result: planned

	PreemptionVictims = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_preemption_victims_total",
		Help: "Total victim slices marked for eviction across all preemption plans.",
	})

	PreemptionFreedBytes = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_preemption_freed_bytes_total",
		Help: "Total VRAM (bytes) freed by preemption plans.",
	})

	PreemptionGrace = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    "vgpu_preemption_grace_seconds",
		Help:    "Per-victim grace period granted before eviction, in seconds.",
		Buckets: []float64{1, 5, 10, 15, 30, 60, 120, 300, 600, 3600},
	})

	PreemptionBlocked = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_preemption_blocked_total",
		Help: "Preemption attempts that produced no plan, by reason.",
	}, []string{"reason"}) // reason: cooldown|no_victims|insufficient_capacity|ownership_lost

	// ── Topology (Phase 2.5) ──────────────────────────────────────────────

	TopologyPreferenceHits = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_topology_preference_hits_total",
		Help: "Slices placed in their preferred topology zone.",
	})

	TopologyPreferenceMisses = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_topology_preference_misses_total",
		Help: "Slices that expressed a zone preference but were placed elsewhere.",
	})

	TopologySelectedZone = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_topology_selected_zone_total",
		Help: "Slices bound, by the topology zone they landed in.",
	}, []string{"zone"})

	// ── Scheduler health ──────────────────────────────────────────────────

	CacheWarmupComplete = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "vgpu_scheduler_cache_warmup_complete",
		Help: "1 once the cache warm-up (re-accounting bound slices) has completed.",
	})

	CacheWarmupDuration = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "vgpu_scheduler_cache_warmup_duration_seconds",
		Help: "Duration of the startup cache warm-up, in seconds.",
	})

	QueueDepth = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "vgpu_scheduler_queue_depth",
		Help: "Current depth of the scheduler's priority work queue.",
	})

	ReconcileErrors = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_scheduler_reconcile_errors_total",
		Help: "Slice reconcile cycles that ended in a backoff-worthy error.",
	})

	LeaderActive = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "vgpu_scheduler_leader_active",
		Help: "1 if this scheduler instance holds leadership and is actively scheduling.",
	})

	ReservationsActive = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "vgpu_scheduler_reservations_active",
		Help: "Number of speculative cache reservations currently held in memory.",
	})

	// ── Data plane (node agent) ───────────────────────────────────────────

	HardwareAllocations = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_allocations_total",
		Help: "Physical hardware allocations performed by the node agent, by status.",
	}, []string{"node", "status"})

	DriftEvents = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "vgpu_drift_events_total",
		Help: "Times the self-healing engine detected state drift.",
	})
)

func init() {
	metrics.Registry.MustRegister(
		// capacity
		NodeCapacityBytes, NodeReservedBytes, NodeAllocatedBytes, NodeFreeBytes,
		NamespaceAllocatedBytes, NamespaceQuotaBytes,
		// slice lifecycle
		SlicesByPhase, SliceScheduleAttempts, SliceScheduleLatency, SliceReady, SliceFailed,
		// gang
		GangAttempts, GangAdmissionDecisions, GangQuorumWait, GangRollbacks,
		GangAdmissionBackoffs, GangAdmissionSlotHeld,
		// preemption
		Preemptions, PreemptionVictims, PreemptionFreedBytes, PreemptionGrace, PreemptionBlocked,
		// topology
		TopologyPreferenceHits, TopologyPreferenceMisses, TopologySelectedZone,
		// scheduler health
		CacheWarmupComplete, CacheWarmupDuration, QueueDepth, ReconcileErrors,
		LeaderActive, ReservationsActive,
		// data plane
		HardwareAllocations, DriftEvents,
	)
}
