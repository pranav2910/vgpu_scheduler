# Demo — see it work end to end

Two tracks. **Track A** runs on a laptop (kind, fake GPU) and proves the
scheduling guarantees. **Track B** runs on one real GPU and proves the runtime
intelligence — slice → over-use → warn → evict → learn → recommend → advise.
Every command below is a script that's already green in CI / on hardware.

---

## Track A — control plane, no GPU needed (~5 min)

The fastest "see it work": the **[`vgpu` CLI](scripts/vgpu)** + the **[`demo/`](demo/)**
before/after.

```sh
scripts/setup-kind-cluster.sh                 # control plane + an 80 GiB mock GPU (one node)
scripts/vgpu submit --name llama --vram 16Gi --image busybox:1.36 --command 'sleep 3600'
scripts/vgpu status  llama                    # Job → Claim → Slice → Pod, one line each
scripts/vgpu profile llama                    # learned: requested vs recommended vs peak
```

Then run the **before/after packing demo** in [`demo/README.md`](demo/README.md):
vanilla K8s strands 3 of 4 whole-GPU pods `Pending`; the scheduler packs all 4
VGPUJobs onto one 80 GiB GPU.

For the full battery + raw flow:

```sh
# One idempotent command: kind cluster + CRDs + scheduler/controller/node-agent.
scripts/setup-kind-cluster.sh

# The adversarial battery: it crashes processes, kills the leader under load,
# over-subscribes capacity, and runs sustained submit/delete cycles — asserting
# the core invariants hold throughout.
bash real_world_test.sh
#   → 15/15 green (Wave 1 correctness · Wave 2 chaos · Wave 3 adversarial)
```

What the battery proves, in composition (not isolation):

- **No over-admission** under heavy over-subscription (180 GiB of demand into 80)
- **Atomic gang scheduling** — gangs commit all-or-nothing, even under contention
- **Liveness** — serialized admission packs the cluster; no fragmentation deadlock
- **Quota + gang composition** — an over-quota gang is held out *whole*
- **Preemption** with bounded, deduplicated, atomic eviction
- **HA failover** — leader killed mid-flight: no over-admission, no duplicate binds
- **No capacity leak** across sustained scheduling cycles

Watch one guarantee by hand — atomic gang admission under contention:

```sh
kubectl get vgpugangreservations -w        # reservations commit or roll back whole
kubectl get vgpuslices -w                  # slices appear all-or-nothing per gang
kubectl -n vgpu-system port-forward deploy/vgpu-scheduler 8081:8081 &
curl -s localhost:8081/metrics | grep -E 'vgpu_gang_admission|vgpu_node_free'
```

---

## Track B — runtime intelligence, one real GPU (~10 min on a 1× A10)

A throwaway GPU box (e.g. a Lambda 1× A10). The bootstrap stands up k3s + the
NVML node agent; then each script drives one stage against **real NVML / cgroups
/ the Kubernetes Eviction API**.

```sh
bash scripts/a10-bootstrap.sh                 # k3s + NVML node agent + CRDs
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### 1. Detect → attribute → soft-warn (`validate-runtime-3.4-a10.sh`, 13/13)

Grant a slice 2 GiB; run a workload that allocates ~4 GiB.

```
3.4a  node flags over-use (vgpu_node_memory_violation_active=1)
3.4b  slice attributed + MemoryViolation condition=True, mirrored to the job, Event
3.4c  the offending POD is labeled + annotated with an enforcement deadline,
      MemoryEnforcement=True — and the pod keeps Running (non-destructive)
```

### 2. Opt-in eviction (`validate-runtime-3.4d-a10.sh`, 5/5)

Same over-use, with `VGPU_ENFORCEMENT_MODE=evict`, plus an exempt workload:

```
✓ victim pod evicted via the PDB-respecting Eviction API — VRAM reclaimed
✓ Warning/MemoryEnforcementEvicted event + actions_total{action="evict"}
✓ exempt pod (…/enforcement-exempt=true) over-using identically stays Running
```

### 3. Learn → recommend → advise (`validate-runtime-3.5-a10.sh`, 8/8)

The feedback loop. A workload requests 2 GiB but uses ~4 GiB:

```
slice_peak    = 4534042624   (4324 MiB — real NVML)
recommended   = 5214149017   (= peak × 1.15, exactly)
confidence    = High
advisory      = True         → VGPUJob Underprovisioned=True + recommended-vram-bytes
pod           = Running      → the advisory NEVER blocks
```

So the system observed the real footprint, recommended a right-sized grant at high
confidence, and flagged the under-provisioned request — without disrupting it.

---

## The proof

| Tag | What it locks |
|---|---|
| `v0.3-adversarial-green` | 14/14 scheduling battery (incl. a found+fixed gang-vs-quota bug) |
| `v0.4-runtime-softwarn-green` | 3.4a/b/c detection → attribution → soft enforcement, A10 |
| `v0.5-runtime-evict-green` | 3.4d opt-in eviction, A10 (victim evicted, exempt spared) |
| `v0.6-feedback-green` | 3.5/3.6 learn → recommend → advise, A10 (8/8) |

Default behavior is always non-destructive: `softwarn` enforcement, recommend-only
feedback. Eviction and any future blocking are explicit, deliberate opt-ins.
See [docs/architecture.md](docs/architecture.md) for how the pieces fit.
