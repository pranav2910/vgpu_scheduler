# Runtime VRAM over-use detection & enforcement (Phase 3.4)

VRAM-slicing only holds if workloads actually stay within the VRAM they were
granted. Phase 3.4 closes that loop — but deliberately, in stages, so nothing is
ever evicted on untrusted accounting:

```
3.4a  detect node-level over-use            ← HERE (observe-only)
3.4b  attribute + mark the slice Violating  (observe-only)
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

## 3.4b — per-slice attribution + mark `Violating` (next)

- Per-process GPU memory via `nvmlDeviceGetComputeRunningProcesses` →
  `(pid, usedMem)`; map `pid → pod` (parse `/proc/<pid>/cgroup`) `→ VGPUSlice`.
- A slice over its grant (sustained) gets a status **Condition**, not a phase
  change — it stays `Ready`:

  ```yaml
  status:
    conditions:
      - type: MemoryViolation
        status: "True"
        reason: ObservedGpuMemoryOveruse
        message: "Observed GPU memory usage exceeded allocated VRAM by 512MiB for 60s"
  ```

  A summary `MemoryViolation` condition is mirrored onto the parent `VGPUJob`.
- Per-slice metrics gain the attribution labels:
  `vgpu_memory_violation_active{node, namespace, slice}`,
  `vgpu_memory_violation_excess_bytes{node, namespace, slice}`,
  `vgpu_memory_violations_total{node, namespace, slice, reason}`.
- A `Warning`/`MemoryViolation` Event is emitted on the slice/pod.

Marking ≠ termination: a violating slice is `Ready + MemoryViolation=True`, never
`Failed`, because 3.4b is still observe-only. The condition is the hook
enforcement (3.4c+) will later act on.
