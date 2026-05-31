# GPU hardware truth (Phase 3.1 — NVML scaffolding)

This phase moves the node agent from "trusts the advertised capacity" toward
"observes real GPUs." It is **observation only** — it discovers GPUs and
reports their VRAM and health, and surfaces drift between what the hardware
shows and what the scheduler assumes. It does **not** enforce limits, create
MIG partitions, evict processes, or write the node's advertised capacity.

The ladder is: **discover → observe → compare (drift) → [enforce later]**.
Phase 3.1 delivers the first three. Enforcement is explicitly future work.

## Architecture

`internal/nodeagent/gpu/` — a read-only `GPUProvider`, selected at build time:

| File | Build | Role |
|---|---|---|
| `provider.go` | always | `GPUProvider` interface, `GPUDevice`, `Inventory`, drift math, degraded provider |
| `fake_provider.go` | `!nvml` (default) | deterministic synthetic GPUs, env-configurable |
| `nvml_provider.go` | `nvml` | real GPUs via `go-nvml`; the **only** place the observation path touches the driver |
| `collector.go` | always | periodic observation loop → `Inventory` + metrics + drift |

```go
type GPUProvider interface {
    Name() string
    ListDevices(ctx) ([]GPUDevice, error)
    GetDevice(ctx, uuid) (*GPUDevice, error)
    Shutdown() error
}
type GPUDevice struct {
    UUID, Name string
    Index int
    TotalMemoryBytes, UsedMemoryBytes, FreeMemoryBytes int64
    Healthy bool
    Error   string
}
```

The build tag is the single source of truth for "is real hardware present"
(`gpu.RealBuild`): the default build uses the fake provider **and** the mock
allocator; `-tags nvml` uses the real provider **and** the real allocator.

```sh
go build ./...                       # default: fake provider, no go-nvml linked for discovery
go build -tags nvml ./cmd/nodeagent  # real-hardware build (g5)
```

## What it observes

Per device, every 30s: total / used / free VRAM and health. Aggregated to the
node (healthy devices only). The node agent exposes metrics on `:8083/metrics`:

| Metric | Labels | Meaning |
|---|---|---|
| `vgpu_gpu_total_memory_bytes` | node, device | observed total VRAM (healthy only) |
| `vgpu_gpu_used_memory_bytes` | node, device | observed used VRAM |
| `vgpu_gpu_free_memory_bytes` | node, device | observed free VRAM |
| `vgpu_gpu_healthy` | node, device | 1 healthy / 0 not |
| `vgpu_gpu_provider_info` | node, provider | active provider: fake \| nvml \| degraded |
| `vgpu_gpu_observation_errors_total` | node | failed observation cycles |
| `vgpu_gpu_capacity_drift_bytes` | node | observed healthy-total − scheduler-assumed (negative = hardware shows less) |

**Drift** is the bridge to the scheduler's view. The scheduler exposes
`vgpu_node_capacity_bytes`; hardware truth is `sum(vgpu_gpu_total_memory_bytes)`.
The agent also emits `vgpu_gpu_capacity_drift_bytes` directly when
`VGPU_EXPECTED_VRAM_BYTES` is set (no Node read / extra RBAC). PromQL:

```promql
sum by (node) (vgpu_gpu_total_memory_bytes) - max by (node) (vgpu_node_capacity_bytes)
```

A negative drift is the dangerous direction: real hardware has **less** VRAM
than the scheduler assumes, so the scheduler could over-admit relative to
hardware. Phase 3.1 makes this visible; acting on it is a later phase.

## Failure behavior (fail-safe)

Observation failures degrade visibly; they never crash the agent or touch
scheduler state.

| Failure | Behavior |
|---|---|
| NVML library/driver absent, permission denied | `NewProvider` errors → wrapped in a degraded provider; `provider_info{provider="degraded"}`, every cycle increments `observation_errors_total`; capacity untouched |
| Whole-node query fails mid-run | snapshot marked stale (last-known retained), `observation_errors_total++` |
| A single GPU falls off the bus | that device → `healthy=0`, memory zeroed; other GPUs keep reporting |

## Fake provider (default / kind)

Configured by env so the kind agent models the cluster's advertised capacity:

| Env | Default | Meaning |
|---|---|---|
| `VGPU_FAKE_GPU_COUNT` | 1 | number of fake GPUs |
| `VGPU_FAKE_GPU_MEM_BYTES` | 80 GiB | total VRAM per fake GPU |
| `VGPU_FAKE_GPU_USED_BYTES` | 0 | used VRAM per fake GPU |
| `VGPU_FAKE_FAIL` | unset | if truthy, observations fail (exercise degraded mode) |
| `VGPU_FAKE_UNHEALTHY_IDX` | none | mark one device index unhealthy |

The kind daemonset sets `VGPU_FAKE_GPU_MEM_BYTES` and `VGPU_EXPECTED_VRAM_BYTES`
to 80 GiB, so observed truth matches scheduler-assumed capacity (drift = 0).

## Real-GPU validation runbook (g5)

Run this on real hardware; CI/kind stays on the fake provider.

1. **Provision** a GPU node (e.g. AWS `g5.xlarge`, NVIDIA A10G, 24 GiB).
   Install the NVIDIA driver + container toolkit; confirm `nvidia-smi` works.
2. **Build** the real image:
   ```sh
   go build -tags nvml ./cmd/nodeagent
   # or: docker build with the nvml tag, base image carrying libnvidia-ml.so.1
   ```
3. **Deploy** to the GPU node. Logs should show:
   `[gpu] observation collector started: provider=nvml ...`
4. **Verify truth** against `nvidia-smi`:
   ```sh
   kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/<agent-pod>:8083/proxy/metrics" \
     | grep '^vgpu_gpu_'
   # vgpu_gpu_total_memory_bytes ≈ nvidia-smi --query-gpu=memory.total --format=csv,nounits,nounits (×1024²)
   ```
   Start a CUDA process and confirm `used`/`free` track it.
5. **Failure drills** (each must keep the agent up, capacity untouched):
   - Revoke device access / stop the driver → `vgpu_gpu_healthy 0`,
     `provider_info{provider="degraded"}`, `observation_errors_total` climbing.
   - On a multi-GPU node, take one GPU offline → only that device's
     `vgpu_gpu_healthy` drops to 0; others keep reporting.
6. **Drift**: set `VGPU_EXPECTED_VRAM_BYTES` to the node's advertised
   `vgpu-bytes`; confirm `vgpu_gpu_capacity_drift_bytes` ≈ 0 when they match,
   and goes negative if you under-provision the advertised capacity.
7. **Regression**: confirm the default build still runs on kind with
   `provider=fake` and all chaos tests stay green.

## Non-goals (reaffirmed)

No runtime memory enforcement, no MIG creation/partitioning, no GPU-process
eviction, no hard isolation, no intra-node multi-GPU topology, no writing the
node's advertised capacity. Those are later phases.
