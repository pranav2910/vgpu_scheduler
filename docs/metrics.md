# Metrics reference

The scheduler and controller export Prometheus metrics via controller-runtime's
metrics server:

| Component | Endpoint |
|---|---|
| Scheduler | `:8081/metrics` |
| Controller | `:8080/metrics` |
| Node agent | data-plane counters (`vgpu_allocations_total`, `vgpu_drift_events_total`) |

All metric definitions live in [internal/telemetry/metrics.go](../internal/telemetry/metrics.go).
Both binaries register with the shared controller-runtime registry, so each
exposes the series its code paths touch. Counters use the `_total` suffix;
byte/second units are in base units. Inventory gauges (slices by phase,
namespace allocated/quota, queue depth) are refreshed every 15s by a collector
goroutine in the scheduler; everything else updates inline at the decision
point.

## Capacity — "where is the GPU memory going?"

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_node_capacity_bytes` | gauge | `node` | Total physical VRAM on the node. |
| `vgpu_node_reserved_bytes` | gauge | `node` | Speculatively reserved (assumed, not yet bound). |
| `vgpu_node_allocated_bytes` | gauge | `node` | Allocated to bound slices. |
| `vgpu_node_free_bytes` | gauge | `node` | `capacity − reserved − allocated`. |
| `vgpu_namespace_allocated_bytes` | gauge | `namespace` | VRAM allocated to all slices in the namespace. |
| `vgpu_namespace_quota_bytes` | gauge | `namespace` | Configured `VGPUQuota.maxVramBytes`. |

## Slice lifecycle — "is single-slice scheduling healthy?"

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_slices_total` | gauge | `phase` | Current slice count by phase. |
| `vgpu_slice_schedule_attempts_total` | counter | `result`, `reason` | Attempts. `result`: success, deferred, wait, rejected, error. |
| `vgpu_slice_schedule_latency_seconds` | histogram | — | Duration of one `Schedule()` cycle. |
| `vgpu_slice_ready_total` | counter | — | Slices observed transitioning to Ready. |
| `vgpu_slice_failed_total` | counter | `reason` | Slices observed transitioning to Failed. |

## Gang scheduling — the core claim

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_gang_attempts_total` | counter | `result` | Gang reservations reaching a terminal outcome: committed, failed. |
| `vgpu_gang_admission_decisions_total` | counter | `decision` | Gate decisions: admitted, deferred, wait, rejected. |
| `vgpu_gang_quorum_wait_seconds` | histogram | — | Time from first observing a cohort to it reaching quorum. |
| `vgpu_gang_rollbacks_total` | counter | `reason` | Gangs torn down: deadline, insufficient_capacity, other. |
| `vgpu_gang_admission_backoffs_total` | counter | — | Times a stalled gang yielded the admission slot. |
| `vgpu_gang_admission_slot_held` | gauge | — | 1 while a gang holds the serialized admission slot, else 0. |

A rising `decisions_total{decision="wait"}` with a flat `attempts_total` means
gangs are queued behind the admission slot — expected under contention. A
climbing `admission_backoffs_total` means a gang repeatedly can't assemble (too
big for free capacity). See [gang-scheduling.md](gang-scheduling.md).

## Preemption — "is eviction controlled, not chaotic?"

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_preemptions_total` | counter | `result` | Plans produced (`planned`). |
| `vgpu_preemption_victims_total` | counter | — | Victim slices marked across all plans. |
| `vgpu_preemption_freed_bytes_total` | counter | — | VRAM freed by plans. |
| `vgpu_preemption_grace_seconds` | histogram | — | Per-victim grace before eviction. |
| `vgpu_preemption_blocked_total` | counter | `reason` | No-plan outcomes: cooldown, no_victims, insufficient_capacity, ownership_lost. |

## Topology (Phase 2.5)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_topology_preference_hits_total` | counter | — | Slices placed in their preferred zone. |
| `vgpu_topology_preference_misses_total` | counter | — | Expressed a zone preference, placed elsewhere. |
| `vgpu_topology_selected_zone_total` | counter | `zone` | Slices bound, by zone they landed in. |

## Scheduler health — for HA and restart debugging

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_scheduler_cache_warmup_complete` | gauge | — | 1 once startup re-accounting finished. |
| `vgpu_scheduler_cache_warmup_duration_seconds` | gauge | — | How long warm-up took. |
| `vgpu_scheduler_queue_depth` | gauge | — | Depth of the priority work queue. |
| `vgpu_scheduler_reconcile_errors_total` | counter | — | Reconcile cycles ending in a backoff error. |
| `vgpu_scheduler_leader_active` | gauge | — | 1 if this instance holds leadership and is scheduling. |
| `vgpu_scheduler_reservations_active` | gauge | — | Speculative cache reservations held in memory. |

## Data plane (node agent)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `vgpu_allocations_total` | counter | `node`, `status` | Physical hardware allocations, success/failed. |
| `vgpu_drift_events_total` | counter | — | State-drift detections by the self-healing engine. |

## Sample Prometheus scrape config

Static-target form (port-forward or in-cluster IPs):

```yaml
scrape_configs:
  - job_name: vgpu-scheduler
    static_configs:
      - targets: ["vgpu-scheduler.vgpu-system.svc:8081"]
  - job_name: vgpu-controller
    static_configs:
      - targets: ["vgpu-controller.vgpu-system.svc:8080"]
```

Kubernetes pod-discovery form (Prometheus running in-cluster):

```yaml
scrape_configs:
  - job_name: vgpu-system
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: ["vgpu-system"]
    relabel_configs:
      # Keep scheduler (:8081) and controller (:8080) pods.
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: "vgpu-(scheduler|controller)"
        action: keep
```

Quick local check:

```sh
kubectl -n vgpu-system port-forward deploy/vgpu-scheduler 8081:8081 &
curl -s localhost:8081/metrics | grep '^vgpu_'
```

> A Grafana dashboard is intentionally deferred (Phase 3.2 ships metrics +
> exposition only). These series are named and labelled so dashboards and alerts
> can be built directly on top of them.
