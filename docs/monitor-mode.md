# Monitor mode — the read-only GPU waste report

The easiest possible first step with vGPU: a **read-only** agent you drop into *any*
cluster that shows how much GPU memory each workload **asks for** vs. how much it
**actually uses** — and what that waste is costing you. No commitment, no risk.

> **Read-only. No scheduling. No pod mutation. No eviction. No CRDs required.**
> **Runs alongside Kubernetes, KAI, Volcano, Run:ai, or Slurm-on-K8s.**
>
> **Honest blast radius:** "read-only" means read-only *to your cluster* — the
> RBAC is list/watch pods, nothing else. The agent pod itself runs `privileged`
> + `hostPID` (required for NVML + PID→pod attribution), like any GPU telemetry
> agent — so treat the container as node-root when you review it.

It does not replace your scheduler. It watches beside it. (When you're ready for the
full platform — packing, right-sizing, autoResize — that's a separate, opt-in step.)

---

## What it does

A DaemonSet (`VGPU_MODE=monitor`) on each GPU node:
1. reads real per-GPU + per-process VRAM via **NVML**,
2. attributes each GPU process to its owning pod (`PID → cgroup → pod`),
3. reads each GPU pod's **requested** VRAM,
4. exports per-pod **requested-vs-used** Prometheus metrics.

`vgpu report` turns those metrics into a table + a $ estimate. That's it — it only
reads.

## Install (one apply)

Build the node-agent image with real GPU support, load it on the cluster, then:

```sh
kubectl apply -f deployments/monitor/monitor.yaml
```

RBAC is intentionally minimal — **list/watch Pods, nothing else.** It has no verbs to
create, delete, evict, or modify anything. (`hostPID` + `privileged` are for read-only
NVML + cgroup attribution.)

## Use it

```sh
vgpu report                              # the waste table (scrapes the monitor agents)
vgpu report --price-per-gpu-hour 3.00    # estimate $ wasted/month
vgpu report -n vgpu-monitor              # if installed in a different namespace
```

Example:

```
Cluster GPU Waste Report  (read-only — no scheduling, no mutation, no eviction)

  WORKLOAD (ns/pod)             REQUESTED         USED        WASTE   UTIL  SOURCE
  default/llama-train             40.0 GiB      16.0 GiB      24.0 GiB    40%  annotation
  default/infer-x                 16.0 GiB       8.0 GiB       8.0 GiB    50%  nvidia_gpu_limit
  default/right-sized             16.0 GiB      15.0 GiB       1.0 GiB    94%  annotation

  GPU memory requested:     72.0 GiB
  GPU memory actually used: 39.0 GiB
  Estimated waste:          33.0 GiB
  Utilization:              54.2%
  Estimated waste/month:    $903   (at $3.00/GPU-hr, ~0.41 cards idle)

  Estimated, not guaranteed savings. Read-only; runs alongside Kubernetes, KAI, Volcano, or Slurm-on-K8s.
```

## How "requested" is detected (`source` label)

| source | how it's read |
|---|---|
| `nvidia_gpu_limit` | `resources.limits["nvidia.com/gpu"]` (whole cards × card size) |
| `annotation` | a GPU-memory annotation (e.g. `gpu-memory`, `run.ai/gpu-memory`); configure with `VGPU_REQUEST_ANNOTATION_KEY` (comma-separated) on the DaemonSet |
| `vgpu_claim` | our own `…/requested-vram-bytes` annotation (when running next to the full vGPU stack) |
| `unknown` | a pod using GPU memory whose request we couldn't determine — shown with its usage, not counted as waste |

A bare-integer annotation is read as **MiB** (the Run:ai/KAI convention); a value with
a unit (`16Gi`) is a Kubernetes quantity.

## Metrics

```
vgpu_monitor_pod_requested_vram_bytes{namespace,pod,node,source}
vgpu_monitor_pod_used_vram_bytes{namespace,pod,node,gpu_uuid}
vgpu_monitor_gpu_total_vram_bytes{node,gpu_uuid}
vgpu_monitor_gpu_used_vram_bytes{node,gpu_uuid}
vgpu_monitor_gpu_free_vram_bytes{node,gpu_uuid}
```

Scrape them with your own Prometheus, or let `vgpu report` pull them for you.

## Validate

- **Report logic (no GPU needed):** `bash scripts/validate-monitor-report.sh` — feeds
  synthetic metrics and checks the join, waste math, price math, and missing-request
  handling (9/9).
- **Live numbers (on a GPU box):** install the DaemonSet, run a few pods (some
  over-asking), and `vgpu report` shows real requested-vs-used. The *accuracy* of the
  underlying measurement is proven in [benchmarks.md](benchmarks.md) (Result 3c).

## Limitations (honest)

- Attribution needs `hostPID` + NVML (real GPU). On the mock (kind) image, usage is
  synthetic.
- "Requested" is `unknown` for pods that express GPU need in a way we don't recognize
  yet — set `VGPU_REQUEST_ANNOTATION_KEY` to teach it your scheduler's annotation.
- The $ figure is an **estimate**, not guaranteed savings — it assumes a flat
  `--price-per-gpu-hour` and counts requested-but-unused memory as idle card fraction.
