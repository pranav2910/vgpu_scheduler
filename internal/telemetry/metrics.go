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

	// ── GPU hardware truth (Phase 3.1, node agent observation) ────────────
	// Observed per-device GPU state from the node agent's GPUProvider. Keyed by
	// node + device UUID. Observation-only: these never drive scheduler capacity.

	GPUDeviceTotalBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_total_memory_bytes",
		Help: "Observed total VRAM of a physical GPU, in bytes (healthy devices only).",
	}, []string{"node", "device"})

	GPUDeviceUsedBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_used_memory_bytes",
		Help: "Observed active/process-used VRAM of a physical GPU, in bytes (NVML v2 excludes driver-reserved; healthy devices only).",
	}, []string{"node", "device"})

	GPUDeviceFreeBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_free_memory_bytes",
		Help: "Observed allocatable free VRAM of a physical GPU, in bytes (the scheduling-relevant figure; healthy devices only).",
	}, []string{"node", "device"})

	GPUDeviceReservedBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_reserved_memory_bytes",
		Help: "Observed driver/device-reserved VRAM of a physical GPU, in bytes (NVML v2; healthy devices only).",
	}, []string{"node", "device"})

	GPUDeviceHealthy = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_healthy",
		Help: "1 if a physical GPU is healthy/observable, 0 otherwise.",
	}, []string{"node", "device"})

	GPUProviderInfo = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_provider_info",
		Help: "Active GPU provider on a node (1). provider: fake|nvml|degraded.",
	}, []string{"node", "provider"})

	GPUObservationErrors = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_gpu_observation_errors_total",
		Help: "Failed GPU observation cycles (provider unavailable, driver/permission errors).",
	}, []string{"node"})

	GPUCapacityDriftBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_gpu_capacity_drift_bytes",
		Help: "Observed healthy GPU total minus scheduler-assumed capacity, in bytes (negative => hardware shows less than assumed).",
	}, []string{"node"})

	// ── Runtime over-use detection (Phase 3.4a, node agent, observe-only) ─
	// Compares observed GPU process-used VRAM against the VRAM the scheduler
	// granted to bound slices on the node. Detection only — nothing is evicted.

	NodeMemoryOveruseBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_node_memory_overuse_bytes",
		Help: "Observed GPU process-used VRAM minus the VRAM granted to bound slices, clamped at 0 (bytes). Per GPU; slice attribution arrives in 3.4b.",
	}, []string{"node", "gpu_uuid"})

	NodeMemoryViolationActive = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_node_memory_violation_active",
		Help: "1 while a GPU has sustained VRAM over-use beyond what was granted, else 0.",
	}, []string{"node", "gpu_uuid"})

	// Per-slice attribution (Phase 3.4b). Same observe-only semantics, but now
	// naming the slice whose workload exceeded its grant.
	SliceMemoryViolationActive = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_memory_violation_active",
		Help: "1 while a slice's attributed GPU VRAM use sustainably exceeds its grant, else 0.",
	}, []string{"node", "namespace", "slice"})

	SliceMemoryViolationExcessBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_memory_violation_excess_bytes",
		Help: "Attributed GPU VRAM a slice is using beyond its grant, in bytes (0 when within grant).",
	}, []string{"node", "namespace", "slice"})

	SliceMemoryViolationsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_memory_violations_total",
		Help: "Count of times a slice transitioned into a sustained over-use violation, by reason.",
	}, []string{"node", "namespace", "slice", "reason"})

	// ── Runtime soft enforcement (Phase 3.4c, node agent, non-destructive) ─
	// When a slice's over-use persists past a grace period, soft enforcement
	// engages: it labels/annotates the offending pod and records the decision.
	// Still observe-and-warn — nothing is evicted, throttled, or phase-failed.

	MemoryEnforcementMode = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_memory_enforcement_mode",
		Help: "Active runtime enforcement mode on a node: 0=off, 1=softwarn (the 3.4c ceiling; hard modes arrive in 3.4d).",
	}, []string{"node"})

	MemoryEnforcementActive = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_memory_enforcement_active",
		Help: "1 while soft enforcement is engaged on a slice (over-use sustained past the grace period), else 0. Engaged = pod labeled/annotated, never evicted.",
	}, []string{"node", "namespace", "slice"})

	MemoryEnforcementActionsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_memory_enforcement_actions_total",
		Help: "Enforcement actions taken, by mode and action (warn|clear in softwarn; evict in evict mode).",
	}, []string{"node", "namespace", "slice", "mode", "action"})

	// Phase 3.4d: blocked eviction attempts (the safety rails firing). reason:
	// pdb (PodDisruptionBudget would be violated), exempt (workload opted out),
	// ratelimited (per-node eviction budget exhausted).
	MemoryEvictionsBlocked = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_memory_evictions_blocked_total",
		Help: "Eviction attempts blocked by a safety rail, by reason (pdb|exempt|ratelimited).",
	}, []string{"node", "namespace", "slice", "reason"})

	// ── Runtime feedback / behavior profiles (Phase 3.5, controller) ──────
	// Per-workload learned VRAM behavior. Observe-only — surfaced for dashboards
	// and alerting (e.g. under-provisioned workloads), never drives scheduling.

	WorkloadPeakObservedVRAMBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_workload_peak_observed_vram_bytes",
		Help: "Observed peak GPU VRAM use for a workload, in bytes (high-water).",
	}, []string{"namespace", "workload"})

	WorkloadRecommendedVRAMBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_workload_recommended_vram_bytes",
		Help: "Recommended VRAM grant for a workload (peak + headroom), in bytes.",
	}, []string{"namespace", "workload"})

	WorkloadProfileConfidence = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_workload_profile_confidence",
		Help: "Confidence in a workload's recommendation: 0=Low, 1=Medium, 2=High.",
	}, []string{"namespace", "workload"})

	// Phase 3.6: soft feedback-aware scheduling. 1 while a workload's requested
	// VRAM is below its profile's recommendation (at sufficient confidence). A
	// warning only — the request is still admitted and scheduled.
	WorkloadUnderprovisioned = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_workload_underprovisioned",
		Help: "1 while a workload requests less VRAM than its profile recommends (advisory only, non-blocking).",
	}, []string{"namespace", "workload"})

	// ── recommendation enforcement (3.7) ──────────────────────────────────

	// RecommendationMode is set to 1 for the controller's active enforcement mode
	// (recommendOnly|warn|requireOverride) — observability of the configured policy.
	RecommendationMode = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "vgpu_recommendation_mode",
		Help: "Active recommendation-enforcement mode (1 for the configured mode).",
	}, []string{"mode"})

	// RecommendationRejectionsTotal counts VGPUJob CREATE requests the webhook
	// rejected for being under-provisioned (requireOverride, confident profile, no override).
	RecommendationRejectionsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_recommendation_rejections_total",
		Help: "VGPUJob CREATE requests rejected as under-provisioned (requireOverride, no override).",
	}, []string{"namespace"})

	// RecommendationOverridesTotal counts under-provisioned CREATE requests admitted
	// because they carried the override annotation.
	RecommendationOverridesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_recommendation_overrides_total",
		Help: "Under-provisioned VGPUJob CREATE requests admitted via the override annotation.",
	}, []string{"namespace"})

	// RecommendationAutoResizesTotal counts VGPUJob CREATE requests whose VRAM was
	// raised to the recommendation by autoResize (3.7b).
	RecommendationAutoResizesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_recommendation_autoresizes_total",
		Help: "VGPUJob CREATE requests auto-resized up to the profile recommendation.",
	}, []string{"namespace"})

	// RecommendationAutoResizeCappedTotal counts autoResize events that were clamped
	// at fleet max (recommendation exceeded a single card).
	RecommendationAutoResizeCappedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "vgpu_recommendation_autoresize_capped_total",
		Help: "Auto-resizes clamped at fleet max (recommendation exceeded a single GPU).",
	}, []string{"namespace"})

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
		// gpu hardware truth
		GPUDeviceTotalBytes, GPUDeviceUsedBytes, GPUDeviceFreeBytes, GPUDeviceReservedBytes,
		GPUDeviceHealthy, GPUProviderInfo, GPUObservationErrors, GPUCapacityDriftBytes,
		// runtime over-use detection (3.4a node-level, 3.4b per-slice)
		NodeMemoryOveruseBytes, NodeMemoryViolationActive,
		SliceMemoryViolationActive, SliceMemoryViolationExcessBytes, SliceMemoryViolationsTotal,
		// runtime soft enforcement (3.4c) + opt-in eviction (3.4d)
		MemoryEnforcementMode, MemoryEnforcementActive, MemoryEnforcementActionsTotal,
		MemoryEvictionsBlocked,
		// runtime feedback / behavior profiles (3.5) + soft advisory (3.6)
		WorkloadPeakObservedVRAMBytes, WorkloadRecommendedVRAMBytes, WorkloadProfileConfidence,
		WorkloadUnderprovisioned,
		// recommendation enforcement (3.7) + autoResize (3.7b)
		RecommendationMode, RecommendationRejectionsTotal, RecommendationOverridesTotal,
		RecommendationAutoResizesTotal, RecommendationAutoResizeCappedTotal,
		// data plane
		HardwareAllocations, DriftEvents,
	)
}
