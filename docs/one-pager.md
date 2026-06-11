# vGPU Scheduler — one-page brief

> **On a single NVIDIA H100, we ran 4× more workloads than vanilla Kubernetes** by
> letting ML engineers request GPU **memory in GiB** instead of whole GPUs —
> lifting memory utilization from **~25% to ~80%**, refusing to over-commit the
> card, and **automatically right-sizing** future requests from observed usage.

An open-source, Kubernetes-native GPU scheduler with a runtime feedback loop.

---

### 1. Problem
GPUs are the most expensive, scarcest resource in AI — and most of every GPU is
wasted. Kubernetes allocates GPUs at **whole-card granularity** (`nvidia.com/gpu: 1`):
a job that needs 16 GiB takes an entire 80 GB H100 and strands the other ~75%.
Teams over-buy GPUs to work around a packing problem.

### 2. Solution
Request GPU **memory** (`--vram 16Gi`), not a whole card. The platform packs many
workloads onto one GPU, watches real VRAM use via NVIDIA NVML, attributes it to the
exact workload, enforces budgets, and **learns each workload's true footprint** to
right-size the next request. One command — `vgpu submit --vram 16Gi …` — runs a
workload on a shared GPU end to end.

Not ready to change your scheduler? **Start read-only.** A monitor DaemonSet drops in
beside whatever you run today (KAI, Volcano, vanilla Kubernetes, Slurm-on-K8s) and
reports how much GPU memory each workload **asks for vs. actually uses** — no
scheduling, no mutation, no CRDs, one RBAC verb. It's the zero-risk way to see the
waste before adopting anything.

### 3. Proof (single H100, reproducible from the repo in 3 commands)
- **4 workloads on one 80 GB H100** where vanilla Kubernetes runs **1** → **~25% → ~80%** memory utilization.
- The **5th is safely held** — the scheduler refuses to over-commit the card (no OOM roulette).
- **Right-sizing works**: a job that asked for 16 GiB but used 21.5 GiB was recommended 24.7 GiB; in `autoResize` mode the request is corrected **before scheduling**, audited.
- **Hardened**: a 15-test adversarial battery (over-subscription, leader-kill-mid-bind, gang atomicity, child-loss, soak) passes **15/15**; data-plane + runtime suites pass on real A10 + H100.
- **Zero-risk entry point works**: the read-only monitor, live on an H100, flagged two jobs over-asking by ~37 GiB (~$1,000/mo) beside the stock scheduler — and its waste math was adversarially bug-hunted, catching a 7.8× over-report (finished/pending pods counted as waste) and fixing it *before* shipping.

  *Evidence + methodology: [benchmarks.md](benchmarks.md).*

### 4. Differentiator
A runtime-aware loop nobody in open source closes:
**schedule → observe → attribute → enforce → learn → autoResize.**
MIG and time-slicing hand you a fixed slice and *no idea whether it was the right
size*. We pack by bytes **and get smarter about packing** — the platform becomes
self-correcting.

### 5. Honest limits
- **Validated on one H100 node today.** Multi-GPU-per-node and multi-node packing are designed, not yet proven.
- **Soft GPU sharing with runtime governance** (observe → warn → opt-in evict → right-size), **not** hardware partitioning. **MIG-backed hard isolation is future work.**
- Open-source and early; pre-revenue, starting customer discovery.

### 6. Who it's for
ML platform / infrastructure teams running GPUs on Kubernetes who own GPU **cost and
utilization** — AI startups, university and research labs, GPU cluster admins — and
the ML engineers who just want to ask for `16Gi` instead of fighting over whole
cards. Sweet spot: teams with their own GPU clusters who want better utilization
**without buying Run:ai or locking into a single vendor**.

### 7. Open-source core vs. commercial
- **Open-source (now):** the scheduler, VRAM bin-packing + gang/quota/preemption, runtime governance (detect → attribute → enforce), the feedback/right-size/autoResize loop, the `vgpu` CLI, Prometheus metrics.
- **Commercial (later):** a dashboard, multi-tenant policy & quota hierarchy, multi-cluster/federation, MIG hard isolation, framework integrations (Ray / PyTorch / vLLM / Kubeflow), and enterprise support / SSO / audit.

---

*Apache-2.0 · github.com/pranav2910/vgpu_scheduler · latest: v0.13 (correctness hardening, 24 fixes) · runbook: [INSTALL-H100.md](INSTALL-H100.md) · try it: `docs/USER-GUIDE.md`*
