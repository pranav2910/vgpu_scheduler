# Architecture

vGPU Scheduler slices a physical GPU by **VRAM bytes** and runs many workloads on
it safely — with atomic gang scheduling, quota, preemption, runtime over-use
enforcement, and a feedback loop that learns each workload's real footprint.
This is the one-page map; each subsystem has its own deep-dive doc (linked below).

## The object model (CRDs)

Everything is declarative Kubernetes state. The user expresses *intent*; the
control plane materializes *placement* and *hardware*:

```
VGPUGangJob ─┐  (a multi-worker job: "N workers, each needs G bytes, all-or-nothing")
             │
             ▼  controller expands
   VGPUGangReservation ──► N × VGPUJob ──► VGPUClaim ──► VGPUSlice
                              (intent)      (demand)     (placement + hardware)
                                                              │
   VGPUQuota (per-namespace VRAM ceiling) ─── gates ──────────┤
   VGPUWorkloadProfile (learned behavior) ─── advises ────────┘
```

- **VGPUJob** — a workload's intent (priority, class, a `claimTemplate`).
- **VGPUClaim** — a concrete VRAM demand (`requestedVramBytes`, service tier).
- **VGPUSlice** — the unit the scheduler places and the node agent backs with
  real hardware. Carries `nodeName` (set at bind) and the runtime stats the
  feedback loop accumulates.
- **VGPUGangJob / VGPUGangReservation** — gang scheduling: a reservation holds
  capacity for the *whole* cohort so it commits all-or-nothing.
- **VGPUQuota** — a namespace VRAM ceiling, enforced gang-atomically.
- **VGPUWorkloadProfile** — Phase 3.5 learned behavior (peak/avg, incident
  counts, recommended grant, confidence). Observe-only.

## The three components

| Component | Owns | Notes |
|---|---|---|
| **Scheduler** | placement: Filter → Score → Reserve → Bind → Confirm, the gang admission gate, preemption, quota checks, an in-memory VRAM cache | leader-elected, 2 replicas; warm-up re-accounts bound slices before scheduling |
| **Controller** | the CRD lifecycle (gang → reservation → job → claim → slice), the admission webhooks, and the Phase 3.5/3.6 feedback aggregation + advisory | leader-elected, 2 replicas; webhooks optional (`VGPU_DISABLE_WEBHOOKS`) |
| **Node agent** | per-node DaemonSet: hardware allocation (CDI), drift detection (checkpoint pruning), NVML observation, and the Phase 3.4 runtime over-use detection + enforcement | `hostPID` for PID→pod attribution; real NVML behind a build tag, fake by default |

## Scheduling: serialized gang admission

The core correctness claim is **atomic gang scheduling under contention**. A
naive "reserve per-pod" scheme deadlocks or over-admits when several gangs
compete. Instead a single **serialized admission slot** lets one gang hold
capacity at a time (ordered priority → age → name, sticky, with backoff/timeout
anti-starvation), so a cohort either reserves its full width or yields the slot
intact — no partial commits, no fragmentation deadlock. Quota is checked
*gang-atomically* (the whole cohort weighed against the ceiling), so a partial
gang can't sneak past a namespace limit. See [gang-scheduling.md](gang-scheduling.md).

## Runtime intelligence (Phase 3.4 → 3.6)

VRAM slicing only holds if workloads stay within their grant — and gets smarter
if the system learns what they actually need. This is built in deliberate,
observe-first stages, each hardware-validated on an A10:

```
3.4a detect over-use  →  3.4b attribute to the exact slice  →  3.4c soft-warn the pod
   →  3.4d opt-in evict (PDB-respecting, rate-limited, exemptable)
3.5 learn a per-workload profile  →  recommend a right-sized grant
   →  3.6 non-blocking advisory when a request is under-provisioned
```

Attribution chain (node agent): `GPU process (NVML) → PID → /proc/<pid>/cgroup →
pod → claim-ref → VGPUSlice`. The feedback loop flows the other way: node agents
record per-slice stats on `VGPUSlice.status`; the controller (single writer)
aggregates them per workload into a `VGPUWorkloadProfile`. See
[runtime-enforcement.md](runtime-enforcement.md) and
[runtime-feedback.md](runtime-feedback.md).

## Design philosophy: observe-first, staged trust

Every layer that *acts* is gated behind a layer that only *observes*, proven
first. Hardware truth never overrides scheduler accounting (it's surfaced as
drift). Enforcement defaults to non-destructive `softwarn`; eviction is an
explicit opt-in with PDB-respect, rate limiting, and exemptions. The feedback
loop recommends but never blocks (3.5/3.6). Destructive or blocking behavior is
always one deliberate flag away — never the default.

## Operational properties

- **HA**: leader election on scheduler + controller; readiness tied to cache
  warm-up so a cold replica never schedules. See [ha-failover.md](ha-failover.md).
- **Recovery**: finalizers + drift detection prune checkpoints whose slices are
  gone after crashes. Detection-and-prune only — full hardware re-inspection and
  automatic re-heal are roadmap, not shipped.
- **Observability**: Prometheus metrics across capacity, gang admission,
  preemption, GPU truth, enforcement, and feedback. See [metrics.md](metrics.md).
- **Validation**: a 15-test adversarial battery (`real_world_test.sh`) on kind,
  plus the `validate-runtime-*-a10.sh` hardware suites. See [DEMO.md](../DEMO.md).
