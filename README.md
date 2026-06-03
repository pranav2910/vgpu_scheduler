# vGPU Scheduler

An open-source Kubernetes scheduler and control plane that slices GPUs by **VRAM
bytes** and provides **atomic gang scheduling under contention** — multiple
workloads share a GPU's memory safely, and multi-worker jobs are admitted
all-or-nothing.

It is not a wrapper around time-slicing or MPS: it adds VRAM-aware bin-packing,
a reserve-or-rollback gang admission gate, preemption, namespace quota,
soft topology placement, HA failover, and Prometheus observability — and each of
those is tested **in composition**, under adversarial load, not just in isolation.

## Components

| Component | Role |
|---|---|
| **Scheduler** | VRAM-aware Filter/Score/Reserve/Bind/Confirm; gang admission gate; preemption; quota; in-memory VRAM cache. Leader-elected, 2 replicas. |
| **Controller** | Reconciles the CRDs (`VGPUGangJob` → `VGPUGangReservation` + child `VGPUJob`/`VGPUClaim`/`VGPUSlice`); admission webhook. Leader-elected, 2 replicas. |
| **Node agent** | Per-node DaemonSet: hardware allocation, CDI, drift healing, and GPU hardware-truth observation (NVML behind a build tag; fake provider by default). |

## Validated guarantees

The scheduler is exercised by a **14-test battery** (`real_world_test.sh`) that
goes well beyond happy-path unit tests — it crashes processes, kills the leader
under load, over-subscribes capacity, and runs sustained submit/delete cycles,
asserting the core invariants hold throughout.

Coverage:

- **No over-admission** under heavy over-subscription (180 GiB of demand into 80)
- **Atomic gang scheduling** — gangs commit all-or-nothing
- **Liveness under contention** — serialized admission packs the cluster; no fragmentation deadlock
- **Anti-starvation** — an un-assemblable gang backs off and never blocks feasible ones
- **Quota + gang composition** — an over-quota gang is held out *whole* (gang-atomic quota)
- **Preemption** with bounded, deduplicated, atomic eviction
- **HA failover** — leader killed mid-flight (even under contention): no over-admission, no duplicate binds, clean `leader_active` transfer, warm-up before Ready
- **No capacity leak** across sustained scheduling cycles
- **Topology** soft zone preference, with an auditable placement condition

**Latest result: 14/14 green** (Wave 1 correctness, Wave 2 chaos, Wave 3
adversarial). The Wave 3 adversarial suite found and closed a real
gang-vs-quota composition bug — the kind of cross-subsystem defect that only
surfaces under combined load.

### Runtime VRAM accounting — hardware-validated (NVIDIA A10)

The runtime chain is validated end-to-end against **real NVML + Linux cgroups +
the Kubernetes Eviction API** on an A10 (`scripts/a10-bootstrap.sh` +
`validate-runtime-3.4-a10.sh` `13/13`, `validate-runtime-3.4d-a10.sh` `5/5`,
`validate-runtime-3.5-a10.sh` `8/8`), not just mocks:

- **Hardware truth** — per-GPU VRAM read via NVML v2 accounting (process-used vs
  driver-reserved separated), matching `nvidia-smi`
- **Over-use detection** — a node flags GPU memory use beyond the VRAM granted to
  its bound slices (hysteresis; no flapping)
- **Per-slice attribution** — the over-using workload is traced to the exact
  `VGPUSlice` (GPU PID → `/proc` cgroup → claim-ref → slice) using host-PID NVML
- **Soft enforcement (non-destructive, default)** — the offending **pod** is
  labeled + annotated with the violation and an enforcement deadline, the
  slice/job carry a `MemoryEnforcement` condition, events fire — and the pod
  keeps **running**. Nothing is evicted, throttled, or phase-failed.
- **Opt-in eviction** — set `VGPU_ENFORCEMENT_MODE=evict` and a pod that stays
  over-budget past the deadline is evicted via the **PDB-respecting Eviction API**
  (rate-limited per node; never a raw delete). Pods/namespaces labeled
  `…/enforcement-exempt=true` are spared — proven on hardware: victim evicted,
  exempt pod left Running.
- **Feedback loop (3.5/3.6)** — the node agent's NVML observations accumulate into
  a per-workload `VGPUWorkloadProfile` (peak/avg, incident counts), the controller
  recommends a right-sized grant (`peak × 1.15`) with a confidence grade, and an
  under-provisioned request gets a **non-blocking** `Underprovisioned` advisory.
  Validated end-to-end on the A10 (`validate-runtime-3.5-a10.sh`): real peak →
  `recommended > requested` at `High` confidence → advisory fires, pod still running.

The A10 runs also surfaced two real bugs unit tests structurally couldn't — a
cached-vs-direct client read in pod stamping, and a controller/slice ordering race
— both caught and fixed on hardware.

## Quick start (kind)

```sh
# One-command, idempotent local cluster (kind + cert-manager + CRDs + deploys)
scripts/setup-kind-cluster.sh

# Run the validation battery
bash real_world_test.sh            # full battery
bash real_world_test.sh --only=3   # just the Wave 3 adversarial group
```

The default build uses mock GPU capacity, so it needs no real hardware. For real
GPUs, build the node agent with `-tags nvml` (see GPU docs below).

## Observability

Scheduler `:8081/metrics`, controller `:8080/metrics`, node agent `:8083/metrics`
(controller-runtime registry). Capacity, slice lifecycle, gang admission,
preemption, topology, scheduler health, and observed GPU truth are all exported.
See [docs/metrics.md](docs/metrics.md).

## Documentation

- [docs/gang-scheduling.md](docs/gang-scheduling.md) — gang guarantees, serialized admission, tunables, limits
- [docs/ha-failover.md](docs/ha-failover.md) — active/standby model, readiness semantics, failover invariants
- [docs/metrics.md](docs/metrics.md) — Prometheus metrics reference + sample scrape config
- [docs/gpu-hardware-truth.md](docs/gpu-hardware-truth.md) — NVML observation scaffolding + g5 validation runbook
- [docs/runtime-enforcement.md](docs/runtime-enforcement.md) — staged over-use detection → attribution → soft enforcement → opt-in eviction (3.4a–d), tunables, A10 E2E
- [docs/runtime-feedback.md](docs/runtime-feedback.md) — GPU behavior profiles: learn peak usage → recommend right-sized grants (3.5) → non-blocking under-provisioning advisory (3.6)

## Status & roadmap

Done and validated: single-slice lifecycle · gang scheduling (atomic,
live under contention) · preemption · quota (gang-atomic) · soft topology ·
observability · HA failover · GPU hardware-truth **observation** · runtime
over-use **detection → attribution → soft enforcement → opt-in eviction**
(3.4a–d, hardware-validated on an A10; default non-destructive `softwarn`) ·
**runtime feedback engine** — per-workload GPU behavior profiles that learn peak
usage and recommend right-sized grants (3.5) · **soft feedback-aware scheduling**
— a non-blocking advisory when a request is below its profile's recommendation
(3.6). 3.5/3.6 are observe-and-recommend only, hardware-validated on an A10.

Next frontier: 3.7 **enforcing the recommendation** (block / auto-right-size
under-provisioned requests). MIG-backed hard partitioning (3.4e), federation, and
a managed SaaS layer are deferred.
