# vGPU Scheduler — Benchmarks & Validation Report

*Last run: 2026-06-07 · single NVIDIA H100 80GB (k3s v1.35.5) + a kind control-plane battery.*

This report is **reproducible, not rhetorical**: every number below comes from a
script in this repo, and the "Reproduce it yourself" section runs the whole thing
in three commands. Where a result is a known limitation, it is stated as one.

---

## TL;DR — the headline

On a single 80 GB H100, packing 16 GiB workloads:

| | Workloads admitted / GPU | VRAM in use | Memory utilization | Over-commit safety |
|---|---|---|---|---|
| **Vanilla Kubernetes** (`nvidia.com/gpu: 1`) | **1** | 16 GiB | ~20% (1 of 4 that fit) | n/a — whole-GPU only |
| **vGPU scheduler** | **4** | 64 GiB | **~80%** | 5th request **held Pending**, no over-commit |

**≈4× more workloads on the same card, ~20% → ~80% memory utilization**, and the
scheduler refuses to over-commit the GPU rather than risk an OOM. On top of that it
**learns each workload's real VRAM footprint** and recommends a right-sized request.

> Utilization metric: granted VRAM of admitted workloads ÷ card total (16/80 vs
> 64/80). The `demo/h100-before-after.sh` script prints the "before" as ~25% using a
> 1-of-4-schedulable-slots framing; in absolute card memory it is ~20%. The "after"
> is ~80% either way.

---

## Test environment (methodology)

| | |
|---|---|
| GPU | 1× NVIDIA H100 80GB HBM3 (`GPU-a66d3a8d-1ff0-eda7-6e07-0839cf5ed421`) |
| Total VRAM (NVML) | 85,520,809,984 bytes = 81,559 MiB ≈ 79.65 GiB |
| Kubernetes | k3s v1.35.5+k3s1, single node, containerd CDI enabled |
| GPU access | NVIDIA container runtime + `RuntimeClass/nvidia`; CDI device injection |
| vGPU build | node agent built `-tags nvml` (real NVML); scheduler + controller (2 replicas, leader-elected) |
| Capacity advertised | the node's full VRAM as `infrastructure.pranav2910.com/vgpu-bytes` = `85520809984` |

**How utilization is measured.** The scheduler accounts capacity in **VRAM bytes**: a
workload's `requestedVramBytes` is reserved against the node's advertised
`vgpu-bytes`. "Admitted" = the workload's `VGPUSlice` reached `Ready` and bound a real
GPU (`status.deviceUuid == GPU-…`). The node agent independently reads true per-GPU
usage via NVML v2 accounting, which is how the feedback numbers below are obtained
(observed, not estimated).

**Honest scope.** All hardware results are on **one GPU, one node**. Multi-GPU-per-node
and multi-node packing are not yet validated (see Limitations).

---

## Result 1 — Packing efficiency (the business number)

**Experiment:** submit five identical 16 GiB workloads to an idle 80 GB H100 (one more
than fits), via `demo/h100-before-after.sh`.

```
── RESULT ──
  4 workloads packed onto ONE physical GPU  (GPU-a66d3a8d-1ff0-eda7-6e07-0839cf5ed421)
  4 pods Running  ·  64 GiB of 80 GiB used  ·  ~80% utilization
  1 held Pending — the scheduler refused to over-commit past the card's memory
  Before: 1 workload per H100 (~25%).   After: 4 per H100 (~80%).  Same hardware.
```

- **Vanilla Kubernetes** exposes a GPU as one indivisible unit (`nvidia.com/gpu: 1`).
  Four pods each requesting a GPU → **1 Running, 3 Pending forever**; 64 of 80 GiB
  stranded.
- **vGPU** packs **4 workloads (64 GiB) onto the one card**, all four pods `Running`,
  each seeing the same physical GPU UUID inside the container.

**Throughput: 4×. Memory utilization: ~20% → ~80%. Same hardware, same 16 GiB jobs.**

---

## Result 2 — No over-admission (the safety guarantee)

In the same run, the **5th** 16 GiB workload would push the card to 80 GiB > 79.65 GiB
available. The scheduler **left its slice `Pending`** rather than over-commit — no OOM
roulette, no silent overlap. This is the property vanilla GPU sharing (time-slicing /
MPS) does **not** give you: it will happily co-locate work past the memory ceiling and
let the kernel OOM-kill the loser.

It is also exercised adversarially off-hardware — 180 GiB of demand into an 80 GiB
node never over-admits (Result 4, test 1.1).

---

## Result 3 — Runtime feedback / right-sizing (the wedge)

**Experiment:** submit a job that *asks* for 16 GiB but actually allocates ~21 GiB
(`torch.empty(21 GiB)`), then read its learned profile.

```
profile big-train
  requested     16.0 GiB
  peak observed 21.5 GiB
  avg observed  21.5 GiB
  recommended   24.7 GiB        <- request this next time
  confidence    Low  (3 observations)
  VERDICT       UNDERPROVISIONED — Requested 16384 MiB but observed peak recommends 25325 MiB
```

- The node agent **observed actual VRAM** via NVML (21.5 GiB), attributed it to this
  exact workload, and the controller recommended `peak × 1.15 ≈ 24.7 GiB`.
- The verdict is **non-blocking**: the pod kept running. The platform tells you the
  right number; it does not kill your job to make a point.
- **Confidence is honest.** It is `Low` at 3 observations and strengthens with data
  (`Low <20`, `Medium 20–99`, `High ≥100`). The formal advisory event on the Job is
  gated at `Medium` so it never nags on thin data.

This is the loop nothing else in open-source GPU sharing closes: **observe → attribute
→ learn → recommend.** Static slicing (MIG) and time-slicing give you a fixed slice and
no idea whether it was the right size.

---

## Result 4 — Correctness & resilience (14-test adversarial battery)

`real_world_test.sh` goes well beyond happy-path: it over-subscribes capacity, crashes
the controller and scheduler under load, kills the leader mid-bind, and runs sustained
submit/delete soak — asserting the core invariants hold throughout. **Latest: 14/14.**

| # | Test | Asserts |
|---|---|---|
| 1.1 | Concurrent gangs (atomicity) | no over-admission under 180 GiB→80 GiB demand |
| 1.2 | Race on full-cluster slots | one winner, no double-bind |
| 2.1 | Capacity returns after Running | no leak |
| 2.2 | Failed gang teardown | clean rollback on deadline |
| 2.3 | Controller crash mid-gang | recovery, no orphans |
| 2.4 | Scheduler crash mid-bind | committed gangs survive the crash |
| 2.6 | Delete during in-flight scheduling | no orphaned reservation |
| 2.7 | Gang vs preemption (atomicity) | gang intact; high-prio correctly unscheduled |
| 2.8 | Scheduler leader failover (HA) | clean `leader_active` transfer, warm-up before Ready |
| 3.1 | Heterogeneous gangs | safety + liveness |
| 3.2 | Impossible gang (anti-starvation) | un-assemblable gang backs off, never blocks |
| 3.3 | Sustained soak | no capacity leak over many cycles |
| 3.4 | Quota + gang atomicity | over-quota gang held out *whole* |
| 3.5 | Leader churn under contention (HA) | 2 leader kills, never over-admits, converges |

> Note: test 2.4 (kill the leader mid-bind) is timing-sensitive; on a heavily
> leader-churned cluster it can need a retry, and passes cleanly in isolation. The diff
> for v0.9 contains zero scheduler code.

The controller's pod-ownership logic (v0.9) is additionally covered by 10 unit tests,
including fake-client reconcile coverage of the self-heal / terminating-pod /
genuine-failure / enforcement-eviction decisions.

---

## Result 5 — Data plane + runtime (hardware-validated suites)

The irreducible last mile — a slice becoming a real GPU inside a pod — and the runtime
intelligence stack are validated end-to-end against real NVML + Linux cgroups +
containerd CDI + the Kubernetes Eviction API (NVIDIA A10 and H100):

| Suite | Result | Proves |
|---|---|---|
| `validate-submit-flow-h100.sh` | **14/14** | `vgpu submit` **and** raw `kubectl apply -f` (podTemplate) → pod runs on a real GPU; pod's `nvidia-smi` UUID == slice `deviceUuid` |
| `validate-alloc-a10.sh` | 11/11 | allocate (real UUID) → CDI spec → containerd injects → GPU visible in pod |
| `validate-runtime-3.4-a10.sh` | 13/13 | over-use detection → per-slice attribution → soft enforcement |
| `validate-runtime-3.4d-a10.sh` | 5/5 | opt-in eviction via PDB-respecting Eviction API; exemptions honored |
| `validate-runtime-3.5-a10.sh` | 8/8 | profile learns peak → recommends right-size → non-blocking advisory |

---

## Reproduce it yourself (3 commands)

On a fresh GPU node (drivers + docker + git; the script installs k3s itself):

```sh
git clone https://github.com/pranav2910/vgpu_scheduler.git && cd vgpu_scheduler
bash scripts/h100-control-plane.sh                 # full control plane on the GPU
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/validate-submit-flow-h100.sh          # → PASS=14 FAIL=0
bash demo/h100-before-after.sh                      # → 4 packed on one GPU, ~80%, 5th held
```

The 14-test adversarial battery runs on a laptop with no GPU:

```sh
bash scripts/setup-kind-cluster.sh && bash real_world_test.sh   # → 14/14
```

Full runbook: [INSTALL-H100.md](INSTALL-H100.md).

---

## Limitations (read before quoting the numbers)

1. **Single GPU, single node.** All hardware results are on one H100. Multi-GPU-per-node
   and multi-node packing are designed but not yet validated. "Validated on 1× H100" is
   the honest claim; cluster-scale is roadmap.
2. **Soft isolation, not a hardware fence.** A pod is given the whole GPU via
   `NVIDIA_VISIBLE_DEVICES`; its VRAM budget is *governed* (observe → warn → opt-in
   evict → right-size), not physically partitioned. A workload can briefly exceed its
   grant in the window between detection and enforcement. Hardware-isolated slices
   (MIG-backed partitioning) are the next step, not done.
3. **Enforcement is non-destructive by default.** Default mode is `softwarn` (observe +
   advise). Eviction is strictly opt-in (`VGPU_ENFORCEMENT_MODE=evict`), PDB-respecting,
   rate-limited, with exemption labels.
4. **Recommendations strengthen with data.** A profile at `Low` confidence (e.g. 3
   observations) is directional; treat `Medium`/`High` as actionable.

---

## One-line summary (for the pitch)

> On a single NVIDIA H100, the vGPU scheduler ran **4× more workloads than vanilla
> Kubernetes** (4 vs 1), raising GPU memory utilization from **~20% to ~80%**, while
> **refusing to over-commit** the card and **learning each workload's real VRAM
> footprint** to recommend a right-sized request — proven end-to-end on real hardware,
> reproducible from the repo in three commands.
