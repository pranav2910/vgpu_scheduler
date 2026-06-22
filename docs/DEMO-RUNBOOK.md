# vGPU Scheduler — Complete Demo & Run Runbook

The single end-to-end guide: **every feature, the exact command to run it by hand,
and the output it prints.** Flowcharts are ASCII so they render in a terminal.

Everything here is real and grounded in the repo — the commands are the same ones
used in CI and on hardware. Where a feature needs a real GPU, it's marked
**[GPU]**; everything else runs on a laptop with **[kind]** (mock GPU, no driver).

---

## 0. What you will prove (feature → claim map)

| # | Feature | Claim it backs | Track |
|---|---|---|---|
| 0 | **Monitor mode** — read-only waste report | "You're wasting GPU money; install zero-risk and see it" | [kind] or [GPU] |
| 1 | **Byte-granular packing** | "1 GPU does the work of 4" | [kind] |
| 2 | **Atomic gang scheduling** | "Multi-worker jobs commit all-or-nothing" | [kind] |
| 3 | **Gang-atomic quota** | "An over-quota gang is held out *whole*" | [kind] |
| 4 | **Preemption** | "Bounded, deduplicated, atomic eviction" | [kind] |
| 5 | **HA failover** | "Leader killed mid-flight: no over-admission" | [kind] |
| 6 | **15-test adversarial battery** | "Invariants hold under chaos, in composition" | [kind] |
| 7 | **Observability** | "Prometheus metrics for every subsystem" | [kind] |
| 8 | **Full submit flow** | "One command runs a workload on a shared GPU" | [GPU] |
| 9 | **Data plane (CDI inject)** | "`nvidia-smi` works inside the pod; UUID matches the slice" | [GPU] |
| 10 | **Over-use detect → attribute → warn** | "We trace VRAM abuse to the exact workload" | [GPU] |
| 11 | **Opt-in eviction (+ exempt)** | "Sustained over-budget pods evicted via the Eviction API" | [GPU] |
| 12 | **Learn → recommend → advise** | "We learn the real footprint and right-size it" | [GPU] |
| 13 | **Recommendation enforcement** | "requireOverride / autoResize correct bad requests" | [GPU] or [kind] |

---

## 1. Prerequisites

```
[kind track]  docker · kind · kubectl · go (1.22+)        — laptop, no GPU
[GPU track]   a Linux box with 1 NVIDIA GPU + driver      — e.g. Lambda 1×A10 / H100
              (the bootstrap script installs k3s + the NVIDIA runtime for you)
```

Clone and enter the repo:

```sh
git clone https://github.com/pranav2910/vgpu_scheduler && cd vgpu_scheduler
```

---

## 2. Architecture at a glance

```
                        ┌─────────────────────────────────────────────┐
                        │                KUBERNETES API                │
                        └─────────────────────────────────────────────┘
                            ▲                ▲                 ▲
            watch/patch     │                │                 │
        ┌───────────────────┘     ┌──────────┘      ┌──────────┘
        │                         │                 │
 ┌──────────────┐        ┌─────────────────┐   ┌────────────────────────────┐
 │  SCHEDULER   │        │   CONTROLLER    │   │   NODE AGENT (DaemonSet)    │
 │ 2 replicas,  │        │  2 replicas,    │   │  one per GPU node           │
 │ leader-elect │        │  leader-elect   │   │                             │
 │              │        │                 │   │  • allocate real GPU (NVML) │
 │ Filter→Score │        │ reconcile CRDs  │   │  • write CDI spec           │
 │ →Reserve→Bind│        │ admission       │   │  • observe VRAM (NVML)      │
 │ →Confirm     │        │ webhooks        │   │  • attribute PID→pod        │
 │ gang gate    │        │ Job→Claim→Slice │   │  • enforce (warn/evict)     │
 │ preemption   │        │ →Pod            │   │  • drift reconcile          │
 │ VRAM cache   │        │                 │   │                             │
 └──────────────┘        └─────────────────┘   └────────────────────────────┘
   :8081/metrics           :8080/metrics            :8083/metrics

 Build tags:  default = FAKE GPU provider (kind/CI, no driver)
              -tags nvml = REAL NVML via CGO (real GPU nodes)
```

**The CRD chain (the data model):**

```
  VGPUGangJob ──────────────► VGPUGangReservation   (gang admission slot)
      │  (one per gang)              │
      │                             reserves N slots all-or-nothing
      ▼  (fans out to N children)
  VGPUJob ──► VGPUClaim ──► VGPUSlice ──► Pod
   (intent)   (the ask)    (the grant)   (your container, GPU injected)

  Side CRDs:  VGPUQuota  (per-namespace cap, gang-atomic)
              VGPUWorkloadProfile  (learned peak/avg → recommendation)
```

**Request lifecycle — who does what when you `vgpu submit`:**

```
  you ──vgpu submit──► VGPUJob
                          │  controller materializes
                          ▼
                       VGPUClaim ──► scheduler runs Filter/Score/Reserve/Bind
                          │                         │ picks node + reserves VRAM
                          ▼                         ▼
                       VGPUSlice (Pending→Scheduled→Allocating→Ready)
                          │  node agent binds real GPU UUID + writes CDI
                          ▼
                       controller creates Pod  ──► mutating webhook injects GPU
                          │                                       │
                          ▼                                       ▼
                       Pod Running  ◄───────────────  nvidia-smi works inside
```

**The slice phase DAG (state machine):**

```
  "" ──► Pending ──► Scheduled ──► Allocating ──► Ready ──► Releasing ──► Released
   │        │            │             │            │           ▲
   └────────┴────────────┴─────────────┴────────────┴───────────┘
        teardown (→ Releasing) is legal from EVERY pre-Ready state
        (node loss / fast churn can delete a slice at any instant)
                          │
                          ▼
                       Failed   (any state → Failed on hard error)
```

---

## 3. Which track should I run?

```
                    ┌───────────────────────────────┐
                    │   Do you have a real NVIDIA    │
                    │   GPU box to test on?          │
                    └───────────────────────────────┘
                       │ no                    │ yes
                       ▼                       ▼
            ┌────────────────────┐   ┌────────────────────────────┐
            │ Want to see the    │   │ Want the FULL story         │
            │ SCHEDULING proof?  │   │ (slice → run → learn)?      │
            └────────────────────┘   └────────────────────────────┘
                  │                          │
                  ▼                          ▼
        TRACK A (kind, §5)           TRACK B (real GPU, §6)
        + TRACK 0 monitor (§4)       + TRACK A still works for scheduling

   Just want the 60-second "we save money" hook with zero risk?  →  TRACK 0 (§4)
```

---

## 4. TRACK 0 — Monitor mode (the zero-risk wedge)  [kind] or [GPU]

**The claim:** *"Install a read-only agent, change nothing, and see exactly how much
GPU memory each workload wastes — and what it costs."* No scheduler swap, no CRDs,
no mutation, no eviction. Runs **beside** any scheduler (KAI/Volcano/vanilla/Slurm).

```
  ┌──────────────┐   reads NVML    ┌─────────────┐   PID→cgroup→pod   ┌──────────┐
  │  GPU on node │ ──────────────► │ monitor DS  │ ─────────────────► │ per-pod  │
  │ (real VRAM)  │                 │ VGPU_MODE=  │   reads requested  │ req-vs-  │
  └──────────────┘                 │  monitor    │ ◄───── pods ────── │ used     │
                                   └─────────────┘                    └──────────┘
                                          │  exports vgpu_monitor_* metrics
                                          ▼
                                   `vgpu report`  →  the waste table + $/month
```

### Run it

```sh
# (real GPU) bootstrap a node, then install the read-only DaemonSet:
bash scripts/a10-bootstrap.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f deployments/monitor/monitor.yaml      # RBAC = list/watch pods ONLY

# create a couple of PLAIN GPU pods that over-ask and under-use (no scheduler involved):
bash demo/monitor-demo.sh                               # --keep to leave them running

# or, anytime, just print the report:
scripts/vgpu report --price-per-gpu-hour 3.00
```

### Output it shows

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
```

> **Honesty note:** the monitor pod runs `privileged + hostPID` for NVML/cgroup
> reads. It is *read-only to your cluster* (one K8s verb: list/watch pods), but it
> is node-root — say "read-only to your cluster, privileged for NVML," not
> "can't touch anything." The `$` figure is an estimate, not guaranteed savings.

---

## 5. TRACK A — Control plane on kind (scheduling proof)  [kind]

### 5.0 One-command bring-up

```sh
scripts/setup-kind-cluster.sh        # kind 'vgpu-test' + cert-manager + CRDs + all 3 components
                                     #   --skip-build  reuse loaded images
                                     #   --recreate    delete + recreate the cluster
kubectl get pods -n vgpu-system      # scheduler, controller, node agent → Running
```

This creates a kind cluster advertising **one 80 GiB mock GPU**
(`infrastructure.pranav2910.com/vgpu-bytes = 85899345920`). No driver needed.

```
  setup-kind-cluster.sh
     │
     ├─ pre-flight (docker/kind/kubectl present, daemon up)
     ├─ create kind cluster 'vgpu-test'
     ├─ build + load 3 images (scheduler/controller/nodeagent)
     ├─ install cert-manager v1.15.3   (webhook certs)
     ├─ apply CRDs  → wait Established
     ├─ advertise 80 GiB mock GPU capacity on the node
     └─ deploy scheduler + controller + node agent → Running
```

### 5.1 Feature 1 — Byte-granular packing (the headline: 1 GPU = 4×)

**The before/after that makes the value obvious.**

```sh
kubectl apply -f demo/00-demo-namespace.yaml
NODE=$(kubectl get nodes -o name | head -1 | sed 's|node/||')

# BEFORE — make the node a stock 1-GPU box, ask for 4 whole GPUs:
kubectl patch node "$NODE" --subresource=status --type=merge \
  -p '{"status":{"capacity":{"nvidia.com/gpu":"1"},"allocatable":{"nvidia.com/gpu":"1"}}}'
kubectl apply -f demo/03-before-plain-gpu-pods.yaml
kubectl get pods -n vgpu-demo -l group=plain-gpu -o wide
```
```
  →  exactly 1 Running, 3 Pending.   THE PAIN.
     "FailedScheduling … Insufficient nvidia.com/gpu" — 75% of the card stranded.
```
```sh
# AFTER — remove the whole-GPU resource, submit the same 4 as VGPUJobs (16 GiB each):
kubectl delete -f demo/03-before-plain-gpu-pods.yaml
kubectl patch node "$NODE" --subresource=status --type=merge \
  -p '{"status":{"capacity":{"nvidia.com/gpu":"0"},"allocatable":{"nvidia.com/gpu":"0"}}}'
kubectl apply -f demo/04-after-vgpujobs-packed.yaml
kubectl get vgpujobs,vgpuslices -n vgpu-demo -o wide
```
```
  →  all 4 jobs Running, 4 slices ALL on one node.
     4 × 16 GiB = 64 GiB on one 80 GiB GPU.  Same hardware, 4× the work.
```
```sh
# Prove it in the metrics:
kubectl -n vgpu-system port-forward deploy/vgpu-scheduler 8081:8081 >/dev/null 2>&1 &
curl -s localhost:8081/metrics | grep vgpu_node_free_bytes
  #   → free VRAM dropped ~80 GiB → ~16 GiB.
```

### 5.2 Feature 2 — Atomic gang scheduling

**The claim:** a multi-worker job commits **all-or-nothing**.

```sh
kubectl apply -f demo/02-vgpugangjob-allreduce.yaml      # 4 ranks × 12 GiB = 48 GiB
kubectl get vgpugangjob ddp-allreduce -n vgpu-demo -o wide   # Running climbs 0→4 atomically
kubectl get vgpugangreservations -n vgpu-demo               # one reservation gates the whole gang
```

Watch the all-or-nothing rollback (ask for more than fits):

```sh
# edit gangSize/minAvailable to 8 (8×12 = 96 GiB > 80) and re-apply:
kubectl get vgpugangreservations -n vgpu-demo -w
  #   → sits in 'Reserving', then rolls back cleanly within reservationTimeoutSeconds.
  #     No deadlock, no stranded half-gang.
```

```
  gang admission (reserve-or-rollback):
     all N slots free?  ──yes──►  commit all N slices  ──►  Running
          │ no
          ▼
     hold what's free, wait ──► timeout? ──► release ALL ──► retry later
                                            (never a half-gang)
```

### 5.3 Features 3–6 — Quota, preemption, HA, the battery (one command)

The adversarial battery exercises these **in composition** (not isolation): it
crashes processes, kills the leader under load, over-subscribes capacity, and runs
sustained submit/delete cycles.

```sh
bash real_world_test.sh              # full 15-test battery
bash real_world_test.sh --only=3     # just the Wave 3 adversarial group
```
```
  →  15/15 green
     ✓ No over-admission (180 GiB demand into 80)
     ✓ Atomic gang scheduling (all-or-nothing under contention)
     ✓ Liveness (serialized admission packs; no fragmentation deadlock)
     ✓ Quota + gang composition (over-quota gang held out WHOLE)
     ✓ Preemption (bounded, deduplicated, atomic eviction)
     ✓ HA failover (leader killed mid-flight: no over-admission, no dup binds)
     ✓ No capacity leak across sustained cycles
     ✓ Topology soft zone preference (auditable placement condition)
```

### 5.4 Feature 7 — Observability

```sh
kubectl -n vgpu-system port-forward deploy/vgpu-scheduler 8081:8081 &
curl -s localhost:8081/metrics | grep -E 'vgpu_gang_admission|vgpu_node_free|leader_active'
```
Scheduler `:8081`, controller `:8080`, node agent `:8083`. See `docs/metrics.md`.

### 5.5 The `vgpu` CLI (the ML-engineer experience)

```sh
scripts/vgpu submit --name llama --vram 16Gi --image busybox:1.36 --command 'sleep 3600'
scripts/vgpu status  llama        # Job → Claim → Slice → Pod, one line each
scripts/vgpu profile llama        # requested vs recommended vs peak (after it runs a bit)
```
`vgpu status` output:
```
workload llama  (ns=default, requested 16.0 GiB)
  Job    Running      VGPUJob/llama
  Claim  Bound        VGPUClaim/llama-claim  bound=llama-claim-slice
  Slice  Ready        VGPUSlice/llama-claim-slice  node=vgpu-test-control-plane  alloc=alloc-...
  Pod    Running      Pod/llama-workload
```

---

## 6. TRACK B — Real GPU: the runtime intelligence  [GPU]

The half a laptop can't show: a workload **actually runs** on a sliced GPU, and the
system **observes → enforces → learns → right-sizes** it.

```sh
# Full control plane on a GPU node (scheduler + controller + webhooks + NVML node agent):
bash scripts/h100-control-plane.sh           # or a10-bootstrap.sh for a 1×A10
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### 6.1 Feature 8 — Full submit flow (the whole product in one command)

```sh
scripts/vgpu submit --name infer --vram 16Gi \
  --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime \
  --command 'python serve.py' --runtime-class nvidia
scripts/vgpu status infer
```
```
  →  controller auto-creates Claim+Slice, scheduler places it, node agent binds a
     REAL GPU, the mutating webhook injects it, the pod runs. Zero manual wiring.
     (validate-submit-flow-h100.sh → 8/8)
```

### 6.2 Feature 9 — Data plane (allocate → CDI → inject)

```sh
kubectl exec infer-workload -- nvidia-smi          # GPU visible INSIDE the pod
# the pod's GPU UUID == the slice's .status.deviceUuid
kubectl get vgpuslice infer-claim-slice -o jsonpath='{.status.deviceUuid}'; echo
```

### 6.3 Feature 10 — Over-use detect → attribute → soft-warn (non-destructive default)

```sh
bash scripts/validate-runtime-3.4-a10.sh           # 13/13
```
```
  3.4a  node flags over-use      vgpu_node_memory_violation_active = 1
  3.4b  attributed to the slice  MemoryViolation=True (mirrored to the job + Event)
  3.4c  POD labeled+annotated with an enforcement deadline, MemoryEnforcement=True
        — and the pod KEEPS RUNNING.  Nothing evicted/throttled/failed.  (default)
```
```
  observe (NVML) ──► over budget? ──► attribute  ──► label pod + condition + Event
   per-GPU VRAM        hysteresis      GPU PID →        (soft: pod stays Running)
                       no flapping     cgroup → slice
```

### 6.4 Feature 11 — Opt-in eviction (+ exempt)

```sh
kubectl set env deploy/vgpu-nodeagent -n vgpu-system VGPU_ENFORCEMENT_MODE=evict
bash scripts/validate-runtime-3.4d-a10.sh          # 5/5
```
```
  ✓ victim pod evicted via the PDB-respecting Eviction API (rate-limited; never raw delete)
  ✓ Warning/MemoryEnforcementEvicted event + actions_total{action="evict"}
  ✓ a pod/ns labeled  …/enforcement-exempt=true  over-using identically stays Running
```

### 6.5 Feature 12 — Learn → recommend → advise (the feedback loop)

```sh
bash scripts/validate-runtime-3.5-a10.sh           # 8/8
scripts/vgpu profile infer
```
```
profile infer  (ns=default)
  requested     16.0 GiB
  peak observed 21.5 GiB
  recommended   24.7 GiB   <- request this next time   (= peak × 1.15, exactly)
  confidence    High  (120 observations)
  VERDICT       UNDERPROVISIONED — you asked 16, you actually need ~25
```
The under-provisioned request gets a **non-blocking** `Underprovisioned=True`
advisory; the pod keeps running. The advisory NEVER blocks.

```
  NVML samples ──► VGPUWorkloadProfile ──► recommend (peak×1.15, confidence-graded)
   per workload      peak / avg / count       │
                                              ▼
                                    Underprovisioned advisory (non-blocking)
```

### 6.6 Feature 13 — Recommendation enforcement (correct bad requests)

Four modes via `VGPU_RECOMMENDATION_MODE` (default `recommendOnly`):

```
  recommendOnly  (default)  just records the recommendation
  warn                      fires the advisory, admits anyway
  requireOverride           REJECTS an under-provisioned request unless overridden
  autoResize                RAISES the request to the recommendation at admission
```

```sh
# requireOverride: an undersized submit is rejected with an actionable hint —
kubectl set env deploy/vgpu-controller -n vgpu-system VGPU_RECOMMENDATION_MODE=requireOverride
scripts/vgpu submit --name infer --vram 8Gi --image my-model:latest --runtime-class nvidia
  #   → rejected: "raise --vram to the recommended size, or re-submit with --override"
scripts/vgpu submit --name infer --vram 8Gi --image my-model:latest --runtime-class nvidia --override
  #   → admitted ("I know it's undersized — run it")

# autoResize: the platform RAISES it for you at CREATE (capped at fleet max, fully audited) —
kubectl set env deploy/vgpu-controller -n vgpu-system VGPU_RECOMMENDATION_MODE=autoResize
kubectl apply -f examples/recommendation-autoresize.yaml
scripts/vgpu status llama-infer
  #   → "^ auto-resized 16.0 GiB -> 24.7 GiB  (policy raised your request to the recommendation)"
```
Both act only at **Medium+** confidence, honor `…/override-recommendation`, never
shrink, and are **fail-open** (`failurePolicy: Ignore`).

### 6.7 Before/after packing, live on the GPU

```sh
bash demo/h100-before-after.sh        # submits one more than fits; --keep to leave running
```
```
  →  4 × 16 GiB packed onto one 80 GiB H100 (~80% utilization)
     the 5th held Pending (no-over-admission guarantee)
     each pod's nvidia-smi reports the same GPU UUID as its slice
```

---

## 7. Multi-GPU & multi-node  [GPU]

```sh
# multiple GPUs on ONE node (per-card best-fit, fail-loud fragmentation, per-card isolation):
bash scripts/validate-multigpu-a100.sh          # (validated on an 8×V100 node)

# several GPU boxes joined into ONE cluster (WireGuard flannel):
#   server: bash scripts/multinode-server.sh ; agents: bash scripts/multinode-agent.sh
bash scripts/validate-multinode.sh              # spread / cross-node gangs / live node-loss

# a 4-node multi-node soak on kind (no real GPU needed):
bash scripts/kind-multinode-up.sh && bash scripts/soak-multinode-kind.sh   # 9/9
```
Full runbook: `docs/INSTALL-MULTINODE.md`.

---

## 8. Feature → command → output cross-reference

| Feature | Command | Proof / output |
|---|---|---|
| Monitor waste report | `vgpu report` | waste table + $/month |
| Packing 4× | `demo/04-after-vgpujobs-packed.yaml` | 4 slices on 1 GPU; free-bytes drop |
| Gang atomic | `demo/02-vgpugangjob-allreduce.yaml` | Running 0→4 atomic; reservation gates |
| Battery | `bash real_world_test.sh` | 15/15 green |
| Submit flow | `vgpu submit … --runtime-class nvidia` | pod Running on shared GPU |
| Data plane | `kubectl exec … nvidia-smi` | GPU UUID == slice UUID |
| Detect/attribute/warn | `validate-runtime-3.4-a10.sh` | 13/13; pod still Running |
| Eviction | `VGPU_ENFORCEMENT_MODE=evict` | victim evicted, exempt spared |
| Learn/recommend | `vgpu profile NAME` | peak → recommended, confidence |
| autoResize | `VGPU_RECOMMENDATION_MODE=autoResize` | request raised, audited |
| Metrics | `curl :8081/metrics` | capacity/gang/preempt/health |

---

## 9. Teardown

```sh
# kind:
kind delete cluster --name vgpu-test
# real GPU (k3s): the bootstrap installs k3s; remove with /usr/local/bin/k3s-uninstall.sh
# control-plane only (keep cluster): make undeploy
```

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `Pending`, slice `Pending` | no capacity, or scheduler still warming up — `make logs-scheduler` |
| `vgpu profile` says "no profile yet" | node agent hasn't observed it yet — wait 1–2 min after it runs |
| Real GPU pod `StartError` | missing `--runtime-class nvidia`, or pod not pinned to the slice's node |
| `vgpu report` "no monitor metrics" | monitor DaemonSet not installed — `kubectl apply -f deployments/monitor/` |
| dirty battery results | leftover wedged slices — `kind delete cluster` first, then re-run setup |
| webhook errors on apply | cert-manager not ready — re-run `setup-kind-cluster.sh` (it waits for certs) |
| `Forbidden … violates PodSecurity "restricted"` | the namespace enforces `restricted`, which GPU pods can't meet (no `runAsNonRoot`/drop-caps/seccomp; real GPU pods need device access). Relabel to baseline: `kubectl label ns NS pod-security.kubernetes.io/enforce=baseline --overwrite`. Common on hardened enterprise clusters. |

---

## 11. Honest limitations (what's real vs roadmap)

- **Per-pod VRAM isolation is SOFT, not hard.** A pod gets the whole GPU via
  `NVIDIA_VISIBLE_DEVICES`; its budget is governed by observe → warn → opt-in
  evict → right-size, **not** a hardware fence. **MIG-backed hard partitioning is
  roadmap, not done.** Never claim memory-fencing/isolation.
- **Trusted single-tenant only.** Not a hostile-multi-tenant security boundary.
- **Defaults are non-destructive:** `softwarn` enforcement, `recommendOnly` feedback.
  Eviction and any request-correction are explicit opt-ins.
- **kind shows the scheduling half only** (mock GPU, no real injection). The data
  plane (real GPU bind + CDI inject + `nvidia-smi` in pod) needs the `-tags nvml`
  node agent on real hardware.
- The `vgpu` CLI is a kubectl wrapper; the `$` waste figure is an estimate.

---

*Companion docs:* `DEMO.md` (narrated walkthrough) · `docs/QUICKSTART.md` (5-min ML
engineer) · `docs/USER-GUIDE.md` (full manual) · `docs/INSTALL-H100.md` (admin
install) · `docs/architecture.md` (system map) · `docs/benchmarks.md` (the numbers).
