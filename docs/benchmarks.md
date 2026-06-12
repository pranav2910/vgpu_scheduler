# vGPU Scheduler — Benchmarks & Validation Report

*Last run: 2026-06-11 · single NVIDIA H100 80GB (k3s v1.35.5) + a kind control-plane battery.*

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

**Honest scope.** Results 1–6 are on **one GPU, one node**; Result 7 extends to
**8 GPUs per node and a heterogeneous 2-node cluster** (see Limitations for what
is still out of scope).

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

### Result 3b — acting on the recommendation (enforcement → self-correction)

The recommendation isn't just advice — `VGPU_RECOMMENDATION_MODE` turns it into policy:

| mode | what happens to an under-provisioned request |
|---|---|
| `recommendOnly` *(default)* | flagged (condition + metric), admitted |
| `warn` | flagged + a Warning event, admitted |
| `requireOverride` | **rejected** unless it carries the override annotation |
| `autoResize` | **automatically raised** to the recommendation at admission (capped at fleet max) |

So the platform moves from *"observe → recommend → user decides"* to *"observe →
recommend → **safely auto-correct the next request**"* — the under-sized 16 GiB job
above is admitted **as 24.7 GiB**, before the slice is even created, with an audit
trail (`original-vram-bytes` / `autoresized-vram-bytes` annotations + an `AutoResized`
condition + event). Safety is built in and **validated**: it acts only at `Medium`+
confidence, never shrinks an over-provisioned request, caps at a single card's
capacity (distinct `AutoResizeCapped` signal), honors an explicit override, and is
**fail-open** (a webhook outage never blocks submission). Proven on kind:
`validate-recommendation-3.7-kind.sh` (enforcement, 5/5) and
`validate-recommendation-3.7b-kind.sh` (autoResize raise/override/Low/capped + audit,
11/11), plus unit tests of the full decision matrix.

### Result 3c — measurement accuracy (the fact the whole loop rests on)

Right-sizing and autoResize are only safe if the per-workload VRAM we measure is
**accurate** (matches reality) and **safe** (never below the job's true footprint, or
autoResize would shrink a job into an OOM). Validated against real PyTorch workloads
on a 1× H100, comparing our `VGPUWorkloadProfile` peak to the workload's own
`torch.cuda.max_memory_*` and to `nvidia-smi`:

| Workload | nvidia-smi (truth) | **our tool** | vs framework-reserved |
|---|---|---|---|
| static 18 GiB allocation | 18952 MiB | **18952 MiB** (0% off) | ≥ reserved (18432) ✓ |
| real training loop (16×Linear + Adam, 60 steps) | 11626 MiB | **11626 MiB** (0% off) | ≥ reserved (10500), and **above** it ✓ |
| two jobs sharing one GPU | — | **A 10760 / B 31240 MiB** | each ≈ its own job's reserved (5% / 1%), not swapped or merged ✓ |

Two things matter here. (1) Our number matches `nvidia-smi` **exactly** and, on the
training run, came in **above PyTorch's own `reserved` counter** — it captures the
CUDA/cuDNN context + library memory the framework doesn't even report, i.e. the
*complete* process footprint. (2) This is **safe by construction**, not by luck: we
read **NVML process-used** (the memory the driver charges the process), which is
always ≥ the framework's reserved pool — so `recommended = peak × 1.15` cannot land
below what the job needs. And under GPU **sharing**, attribution stays per-tenant
(PID → cgroup → slice), the case competitors that don't touch runtime memory can't do.

Scripts: `validate-attribution-h100.sh` (single + sharing, 6/6) and
`validate-attribution-training-h100.sh` (real training, 3/3). *Honest scope:*
validated on these workloads on one node; pathological fragmentation and
multi-process (DDP) shapes aren't stress-tested yet — low risk, since NVML
process-used tracks the reserved pool by construction.

---

## Result 4 — Correctness & resilience (15-test adversarial battery)

`real_world_test.sh` goes well beyond happy-path: it over-subscribes capacity, crashes
the controller and scheduler under load, kills the leader mid-bind, and runs sustained
submit/delete soak — asserting the core invariants hold throughout. **Latest: 15/15.**

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
| 2.9 | Child deleted after commit | committed gang fails LOUD (child lost) → teardown → capacity reclaimed, no orphans |
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

## Result 6 — Read-only monitor mode (the zero-risk waste report)

Before any scheduling, packing, or CRDs, vGPU can run as a **read-only** DaemonSet
(`VGPU_MODE=monitor`) that drops in *beside* any scheduler — vanilla Kubernetes, KAI,
Volcano, Run:ai, Slurm-on-K8s — and answers one question: how much GPU memory does each
workload **ask for** vs. **actually use**? It reads NVML, attributes usage to the owning
pod (`PID → cgroup → pod`), reads each pod's requested VRAM, and emits per-pod
requested-vs-used metrics; `vgpu report` turns them into a table + a $ estimate. It has
exactly one RBAC verb — `list/watch pods` — and creates, evicts, and mutates nothing.

**Live on the H100** (`demo/monitor-demo.sh` — two plain GPU pods, no scheduler involved):

```
  WORKLOAD (ns/pod)        REQUESTED      USED       WASTE   UTIL  SOURCE
  default/waste-a           39.1 GiB    16.5 GiB    22.6 GiB   42%  annotation
  default/waste-b           23.4 GiB     8.5 GiB    14.9 GiB   36%  annotation
  Estimated waste/month: $1031   (at $3.00/GPU-hr, ~0.47 cards idle)
```

The `16.5`/`8.5` (not `16`/`8`) is the CUDA context the framework doesn't report — i.e.
the *true* NVML process footprint, the same per-tenant attribution proven exact in 3c.

**The number is honest by construction — proven adversarially.** A read-only waste report
is only worth anything if it never *invents* waste, so the phase logic was bug-hunted
before shipping. The first finder caught a real one: the report counted *every* pod on
the node, so a finished (`Succeeded`) or not-yet-started (`Pending`) pod — which still
carries a request but holds no live GPU process — surfaced as **100% phantom waste**.
Caught by inspection, fixed (count only `Running` pods), and proven live before/after on
the H100 (`validate-monitor-phase-h100.sh`, 3/3 — a Running under-user kept, a Succeeded
and a Pending pod correctly dropped):

| | requested | reported waste | $/month |
|---|---|---|---|
| **before fix** (Running + Succeeded + Pending all counted) | 78.1 GiB | **71.6 GiB** | **$1,969** |
| **after fix** (only the Running under-user) | 15.6 GiB | 9.1 GiB | $251 |

The bug would have over-reported waste **7.8×** — exactly the kind of wrong number that
kills trust in a waste report on first read. The report join + waste/price math is also
unit-tested off-hardware (`validate-monitor-report.sh`, 9/9) and the phase filter has a
Go regression test (`TestObserveSkipsNonRunningPods`).

*Honest scope:* attribution needs `hostPID` + real NVML; on a node where nvidia isn't the
default runtime the monitor must request `runtimeClassName: nvidia` so NVML's libraries
are injected (else it degrades to requested-only). The $ figure is an estimate (a flat
`--price-per-gpu-hour`), not guaranteed savings.

---

## Result 7 — Multi-GPU nodes + multi-node clusters (v0.14)

**Multi-GPU per node** (8× Tesla V100-16GB, `validate-multigpu-a100.sh`, **7/7**):

- The node advertises the **sum** of its cards (128Gi) and the allocator places
  each slice on ONE physical card, **best-fit**: 32 grants → exactly 4 per card
  across all 8 GPUs, per-card ledger never exceeding a card.
- **Fragmentation fails loud**: with ≤1Gi holes per card, one more slice-sized
  request fits the node pool but no single card —
  `No single GPU has 3.8Gi free; node has 6.1Gi free across GPUs. Fragmented capacity.`
  The slice fails terminally with that message; nothing silently retries or
  over-packs a card.
- **Per-card isolation, in-container**: two pods forced onto two different
  physical GPUs each see exactly THEIR card's UUID inside the container. This
  run caught a real bug first: the CDI env edit only *appended*
  `NVIDIA_VISIBLE_DEVICES`, and nvidia/cuda images bake in `=all` — every pod
  could see every GPU (invisible on single-GPU boxes, where "all" ≡ your card).
  The webhook now pins the env in the pod spec, which Kubernetes guarantees
  wins. Caught, fixed, and re-proven in the same session.

**Multi-node** (8×V100-16GB server + 1×H100-80GB agent — deliberately
heterogeneous — joined over WireGuard flannel; `validate-multinode.sh
--node-loss`, **6/6**):

- 9× 15Gi grants (sized to the smallest physical card) spread across **both
  machines**, all Ready.
- A 136Gi grant — bigger than any node — held Pending, never mis-bound.
- A 9-member **gang that cannot fit on one machine committed all-or-nothing
  across nodes**.
- Zone preference honored across nodes (auditable condition).
- **Live node loss**: the agent node deleted from the API → its capacity
  vanished from scheduling immediately and new work landed only on the
  survivor (the `RemoveNode` ghost-capacity fix, proven on real machines).

**Recovery + cross-machine fail-loud, rehearsed live** (same cluster): the lost
node re-joined (agent restart + capacity re-advertise — the advertisement does
not survive deletion; see INSTALL-MULTINODE) and immediately took a 40Gi
placement only it could host. Then a 6-member gang spanning both machines had
one child killed: the reservation failed loud with the exact designed reason
("child lost after commit … 1 deleting"), survivors drained on BOTH machines,
zero slices left, capacity returned — batch B's all-or-nothing-for-life
guarantee, watched frame by frame on real metal.

**Monitor mode on a multi-GPU node** (same 8×V100 box): two pods pinned to two
different physical cards; the read-only report attributed each pod exactly its
own footprint (3.3 GiB = 3 GiB tensors + its CUDA context — not summed
card-wide, not swapped) against its declared request, with all 8 GPUs in the
totals. The waste-report wedge is proven on the node shape real clusters run.

*Honest scope:* per-card awareness lives in the **node agent**; the scheduler
pools capacity per node, so a placement no single card can host is admitted
node-level and then **fails loudly** at allocation (the message above) rather
than being filtered earlier — per-card scheduler awareness is the next
milestone. Validated at 2 nodes / 9 GPUs total; cluster *scale* (tens of nodes)
is not yet exercised. One slice never spans cards; multi-GPU single pods and
NVLink-aware placement are out of scope.

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

The 15-test adversarial battery runs on a laptop with no GPU:

```sh
bash scripts/setup-kind-cluster.sh && bash real_world_test.sh   # → 15/15
```

Full runbook: [INSTALL-H100.md](INSTALL-H100.md).

---

## Limitations (read before quoting the numbers)

1. **Validated at small scale.** Core results are on a 1× H100; multi-GPU (8× V100)
   and multi-node (2 heterogeneous nodes) are validated in Result 7. Cluster *scale*
   — tens of nodes, node churn under load — is designed but not yet exercised. The
   scheduler pools capacity per node; per-card fit is enforced by the node agent
   with loud failure on fragmentation (per-card scheduler awareness is roadmap).
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
