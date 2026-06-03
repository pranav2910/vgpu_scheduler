# Runtime VRAM over-use detection & enforcement (Phase 3.4)

VRAM-slicing only holds if workloads actually stay within the VRAM they were
granted. Phase 3.4 closes that loop — but deliberately, in stages, so nothing is
ever evicted on untrusted accounting:

```
3.4a  detect node-level over-use            ✅ observe-only
3.4b  attribute + mark the slice Violating  ✅ observe-and-mark only ← HERE
3.4c  soft enforcement (warn / annotate)
3.4d  hard enforcement (evict / throttle)
3.4e  MIG-backed hard partitioning
```

Everything through 3.4b is **observe-and-mark only**: it makes over-use visible
and auditable (metrics, Kubernetes Events, CRD status) but never touches a
running workload. Enforcement (3.4c+) stays gated behind this being trusted.

## 3.4a — node-level over-use detection (current)

The node agent's observation loop gains a detector. Each cycle, per healthy GPU:

- `granted` = Σ `RequestedVRAMBytes` of slices bound to this node and active
  (nodeName set, phase not Pending/Released/Failed). One GPU per node, so the
  node's grants are that GPU's budget.
- `actual` = the GPU's observed **process-used** VRAM (NVML v2 — excludes
  driver `reserved`; this is why the v2 split mattered).
- `overuse = max(0, actual − granted)`.

A GPU is flagged **only** when `overuse` exceeds a tolerance for several
consecutive cycles (hysteresis — no flapping on transient allocation spikes).

### Surfaced as

| Channel | What |
|---|---|
| Metric | `vgpu_node_memory_overuse_bytes{node, gpu_uuid}` — current over-budget bytes |
| Metric | `vgpu_node_memory_violation_active{node, gpu_uuid}` — 1 while sustained |
| Event | `Warning` / `MemoryViolation` on the **Node**: *"Observed GPU … memory usage exceeded granted VRAM by X MiB for ~Ys (observe-only)"* |

So an operator sees it three ways: Prometheus (alerting), `kubectl get events`
(Kubernetes-native), and the gauge (dashboards) — without any workload impact.

### Tunables (`internal/nodeagent/violation.go`)

| Constant | Default | Meaning |
|---|---|---|
| `overuseToleranceBytes` | 256 MiB | slack before over-budget counts (absorbs noise) |
| `overuseStreakThreshold` | 3 cycles | consecutive over-budget cycles before flagging |
| detector interval | 30s | how often detection runs |

### Explicitly NOT done in 3.4a

No eviction, no throttling, no CRD changes to slices, no per-slice attribution.
A node-level flag says *that* a node is over-subscribed in reality, not yet
*which* workload — that's 3.4b.

## 3.4b — per-slice attribution + mark `Violating` (current)

Now over-use is attributed to the *exact slice* and marked Kubernetes-natively.

**Attribution chain** (no new CRD field — reuses existing contracts):

```
GPU process (NVML) → PID → pod (/proc/<pid>/cgroup) → claim-ref annotation → VGPUSlice (matching ClaimRef)
```

- `nvmlDeviceGetComputeRunningProcesses` / `GetGraphicsRunningProcesses` →
  `(host pid, usedMem)` per GPU.
- `pid → pod UID` by parsing `/proc/<pid>/cgroup` (cgroup v1/v2, systemd &
  cgroupfs drivers). Requires `hostPID: true` so NVML's host PIDs are readable.
- `pod → slice`: the pod carries `infrastructure.pranav2910.com/claim-ref`
  (stamped by the mutating webhook); the slice's `spec.claimRef` matches it.
- Each process's VRAM is summed onto its slice and compared to the slice's grant
  (same tolerance + hysteresis as 3.4a).

**Marking** — a sustained over-use gets a status **Condition**, *not* a phase
change (the slice stays `Ready`):

```yaml
status:
  conditions:
    - type: MemoryViolation
      status: "True"
      reason: ObservedGpuMemoryOveruse
      message: "Observed GPU memory usage exceeded allocated VRAM by 512 MiB for ~90s (observe-only, no eviction)"
```

A summary `MemoryViolation` condition (reason `ChildSliceViolation`) is mirrored
onto the parent `VGPUJob`. Per-slice metrics gain attribution labels —
`vgpu_memory_violation_active{node,namespace,slice}`,
`vgpu_memory_violation_excess_bytes{node,namespace,slice}`,
`vgpu_memory_violations_total{node,namespace,slice,reason}` — and a
`Warning`/`MemoryViolation` Event is emitted on the slice. So an operator sees
the offending slice via `kubectl describe vgpuslice`, `kubectl get events`, and
Prometheus.

Marking ≠ termination: a violating slice is `Ready + MemoryViolation=True`, never
`Failed`. The condition is the hook enforcement (3.4c+) will later act on.

**Deployment**: the NVML node agent (`nodeagent_daemonset_nvml.yaml`) sets
`hostPID: true`; RBAC grants `pods:list` + `vgpuclaims/vgpujobs:get` +
`vgpujobs/status`. The default (fake) build has no real GPU processes, so it
attributes nothing — no false positives on kind.

**Validation**: the full attribution + marking logic is unit-tested
deterministically (synthetic `/proc` cgroups, fake pods/slices, stub provider).
The two hardware-only reads — real `/proc/<pid>/cgroup` and NVML process
listing — get their E2E proof on a real GPU node (an A10 run with live CUDA
processes).
