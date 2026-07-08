# vGPU Scheduler

An open-source Kubernetes scheduler and control plane that slices GPUs by **VRAM
bytes** and provides **atomic gang scheduling under contention** — multiple
workloads share a GPU's memory safely, and multi-worker jobs are admitted
all-or-nothing.

It is not a wrapper around time-slicing or MPS: it adds VRAM-aware bin-packing,
a reserve-or-rollback gang admission gate, preemption, namespace quota,
soft topology placement, HA failover, and Prometheus observability — and each of
those is tested **in composition**, under adversarial load, not just in isolation.

On top of scheduling sits a hardware-validated **runtime-intelligence stack**:
detect VRAM over-use → attribute it to the exact workload → warn → opt-in evict →
**learn each workload's real footprint and recommend a right-sized grant**.

**→ [docs/one-pager.md](docs/one-pager.md)** is the 2-minute business brief (problem · proof · who it's for).
**→ [DEMO.md](DEMO.md)** walks the whole thing end to end (kind, then one real GPU).
**→ [docs/architecture.md](docs/architecture.md)** is the one-page system map.

## Install

```sh
# The vgpu CLI — one file, no repo, no build (all an ML engineer ever installs):
curl -sSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu \
  -o /usr/local/bin/vgpu && chmod +x /usr/local/bin/vgpu
```

Everything else — read-only **waste monitor**, full platform on a **GPU node**,
**multi-node** cluster, local **kind** dev — is one page with five copy-paste
paths: **[docs/INSTALL.md](docs/INSTALL.md)**.

## Components

| Component | Role |
|---|---|
| **Scheduler** | VRAM-aware Filter/Score/Reserve/Bind/Confirm; gang admission gate; preemption; quota; in-memory VRAM cache. Leader-elected, 2 replicas. |
| **Controller** | Reconciles the CRDs (`VGPUGangJob` → `VGPUGangReservation` + child `VGPUJob`/`VGPUClaim`/`VGPUSlice`); admission webhook. Leader-elected, 2 replicas. |
| **Node agent** | Per-node DaemonSet: hardware allocation, CDI, drift detection (checkpoint pruning), and GPU hardware-truth observation (NVML behind a build tag; fake provider by default). |

## Validated guarantees

The scheduler is exercised by a **15-test battery** (`real_world_test.sh`) that
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

**Latest result: 15/15 green** (Wave 1 correctness, Wave 2 chaos, Wave 3
adversarial). The Wave 3 adversarial suite found and closed a real
gang-vs-quota composition bug — the kind of cross-subsystem defect that only
surfaces under combined load.

### Runtime + data plane — hardware-validated (NVIDIA A10 and H100)

The full chain is validated end-to-end against **real NVML + Linux cgroups +
containerd CDI + the Kubernetes Eviction API** on actual GPUs (`scripts/a10-bootstrap.sh`
+ `validate-alloc-a10.sh` `11/11`, `validate-runtime-3.4-a10.sh` `13/13`,
`validate-runtime-3.4d-a10.sh` `5/5`, `validate-runtime-3.5-a10.sh` `8/8` — the
3.4/3.5/alloc suites all green on a 1× H100), not just mocks:

- **Full submit flow (v0.8) — the whole product in one command** — on an H100,
  `scripts/h100-control-plane.sh` brings up the entire control plane (scheduler +
  controller + admission webhooks + node agent), and **`vgpu submit --vram 16Gi`**
  then runs a workload on a shared GPU with **zero manual wiring**: the controller
  auto-creates the Claim+Slice, the scheduler places it, the node agent binds a
  real GPU, the mutating webhook auto-injects it, and the pod runs
  (`validate-submit-flow-h100.sh` `14/14`). This is the complete ML-engineer
  experience, end to end on real hardware.
- **Data plane (allocate → CDI → inject)** — a slice is bound to a real GPU UUID
  via NVML, the node agent writes a CDI spec, and a pod referencing it gets the
  GPU: `nvidia-smi` works *inside the pod* and its GPU UUID matches the slice's
  `deviceUuid`. Proven on an H100 (`validate-alloc-a10.sh` 11/11) — a workload
  actually runs on a shared GPU.
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

The hardware runs surfaced several real bugs unit tests structurally couldn't —
a cached-vs-direct client read in pod stamping, a controller/slice ordering race,
a CDI device-name mismatch, and malformed pod YAML from the CLI — all caught and
fixed on hardware.

## Local dev quick start (kind, no GPU)

For contributors — installing on real clusters is [docs/INSTALL.md](docs/INSTALL.md).

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

- [docs/INSTALL.md](docs/INSTALL.md) — **start here**: the install map — five copy-paste paths (CLI · monitor · single GPU node · multi-node · kind) on one page
- [docs/PILOT.md](docs/PILOT.md) — **pilot in 15 minutes**: install the read-only monitor, see your waste number, tell us if it matches your suspicion
- [docs/monitor-mode.md](docs/monitor-mode.md) — **start here, zero-risk**: a read-only GPU **waste report** (`vgpu report`) you drop in beside *any* scheduler (KAI/Volcano/vanilla) — no scheduling, no mutation, no CRDs
- [docs/QUICKSTART.md](docs/QUICKSTART.md) — **for ML engineers, in 5 minutes**: install the CLI, run a workload on a shared GPU, right-size it (copy-paste)
- [docs/USER-GUIDE.md](docs/USER-GUIDE.md) — **for ML engineers**: the full manual — `vgpu submit / status / profile`, right-sizing, gang jobs, troubleshooting
- [docs/INSTALL-H100.md](docs/INSTALL-H100.md) — **for platform/admins**: from-scratch control-plane install on a real GPU node (clone → `h100-control-plane.sh` → validate), with the before/after packing proof
- [docs/INSTALL-MULTINODE.md](docs/INSTALL-MULTINODE.md) — **multi-node + multi-GPU**: join several GPU boxes into one cluster (WireGuard flannel) and validate spread / cross-node gangs / node loss (`validate-multinode.sh`), plus the multi-GPU-per-node validator (`validate-multigpu-a100.sh`)
- [docs/benchmarks.md](docs/benchmarks.md) — **the numbers**: 4× packing / ~80% utilization / no over-commit / right-sizing on a 1× H100, the 15-test battery, and how to reproduce it all
- [docs/one-pager.md](docs/one-pager.md) — **the 2-minute brief**: problem → solution → proof → differentiator → honest limits → who it's for (also linked at the top)
- [docs/customer-discovery.md](docs/customer-discovery.md) — **for founders**: a Mom-Test call guide for talking to GPU/ML platform teams (problem-first, no pitching)
- [DEMO.md](DEMO.md) — end-to-end walkthrough: control plane on kind, then runtime intelligence on a real GPU
- [docs/architecture.md](docs/architecture.md) — one-page system map: CRDs, components, the runtime stack, the safety philosophy
- [docs/gang-scheduling.md](docs/gang-scheduling.md) — gang guarantees, serialized admission, tunables, limits
- [docs/ha-failover.md](docs/ha-failover.md) — active/standby model, readiness semantics, failover invariants
- [docs/metrics.md](docs/metrics.md) — Prometheus metrics reference + sample scrape config
- [docs/gpu-hardware-truth.md](docs/gpu-hardware-truth.md) — NVML observation scaffolding + g5 validation runbook
- [docs/runtime-enforcement.md](docs/runtime-enforcement.md) — staged over-use detection → attribution → soft enforcement → opt-in eviction (3.4a–d), tunables, A10 E2E
- [docs/runtime-feedback.md](docs/runtime-feedback.md) — GPU behavior profiles: learn peak usage → recommend right-sized grants (3.5) → non-blocking under-provisioning advisory (3.6)
- [docs/recommendation-policy.md](docs/recommendation-policy.md) — recommendation enforcement (3.7a): `recommendOnly` / `warn` / `requireOverride` modes, the override annotation, safety gates, and the `vgpu --override` flow

## Status & roadmap

Done and validated: single-slice lifecycle · gang scheduling (atomic,
live under contention) · preemption · quota (gang-atomic) · soft topology ·
observability · HA failover · GPU hardware-truth **observation** · runtime
over-use **detection → attribution → soft enforcement → opt-in eviction**
(3.4a–d) · **runtime feedback engine** that learns peak usage and recommends
right-sized grants (3.5) · **soft feedback-aware scheduling** (3.6) · and the
**full submit flow** — one `vgpu submit` materializes the Job→Claim→Slice, the
scheduler places it, the node agent binds a real GPU, and the mutating webhook
injects it so the pod runs (v0.8) · **recommendation enforcement** — an
under-provisioned request can be required to carry an explicit override (3.7a).
All hardware-validated on an A10, a 1× H100, an **8× V100 node** (per-card
best-fit packing, fail-loud fragmentation, per-card pod isolation) and a
**heterogeneous 2-node cluster** (cross-node spread + gang atomicity, live
node-loss — v0.14); defaults stay non-destructive (`softwarn`, `recommendOnly`).

**Recommendation enforcement (3.7a/b)** is done: `VGPU_RECOMMENDATION_MODE` =
`recommendOnly` (default) · `warn` · `requireOverride` · **`autoResize`**.
`requireOverride` rejects an under-provisioned request unless overridden;
`autoResize` instead **raises** it to the recommendation at CREATE (mutating
webhook, capped at fleet max, fully audited via `AutoResized` condition + event,
never shrinks). Both act only at **Medium+** confidence, honor the
`…/override-recommendation` annotation, and are **fail-open**
(see [docs/recommendation-policy.md](docs/recommendation-policy.md)). Next frontier:
a hard `block` mode and **auto-shrink** of over-provisioned requests. True per-process VRAM isolation today is
soft (record + evict); **MIG-backed hard partitioning** (3.4e), per-card scheduler
awareness (the node agent owns per-card fit today, failing loud on fragmentation),
cluster-scale validation, federation, and a managed SaaS layer are deferred.

## License

Licensed under the [Apache License 2.0](LICENSE).
