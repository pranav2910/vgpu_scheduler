# Examples cookbook — CLI and YAML, by use case

Every recipe below shows both entry points where both exist: the **CLI** (quickest)
and the **YAML** (for GitOps — ready-to-apply files live in [`examples/`](../examples/)).
They produce identical objects: `vgpu submit --dry-run` prints the YAML it would apply.

**The one YAML gotcha:** `requestedVramBytes` takes **bytes**, not `"16Gi"`.
Don't do the math by hand — `vgpu submit ... --dry-run > job.yaml` does it for you.

| You type | Bytes |
|---|---|
| 512Mi | 536870912 |
| 2Gi | 2147483648 |
| 4Gi | 4294967296 |
| 8Gi | 8589934592 |
| 12Gi | 12884901888 |
| 16Gi | 17179869184 |
| 24Gi | 25769803776 |
| 40Gi | 42949672960 |
| 64Gi | 68719476736 |

---

## 1. Your first job (16 GiB training)

```sh
vgpu submit --name train-llama --vram 16Gi \
  --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime \
  --command 'python train.py' --runtime-class nvidia

vgpu status train-llama                 # Job → Claim → Slice → Pod, node + GPU UUID
kubectl logs train-llama-workload -f
```

YAML: [`examples/job-training.yaml`](../examples/job-training.yaml)

## 2. The tiniest ask (512 MiB, capacity only)

Slicing is byte-granular — sub-GiB requests are first-class. A `VGPUJob` with only a
`claimTemplate` (no `podTemplate`) reserves capacity without running a container:

```sh
vgpu submit --name tiny-hold --vram 512Mi --image busybox --no-wait   # CLI always runs a pod
```

YAML (claim-only variant): [`examples/job-minimal.yaml`](../examples/job-minimal.yaml)

## 3. An inference service that must never die

High priority wins contention; `preemptible: false` means it can never be chosen as
a victim — at any priority gap.

```sh
vgpu submit --name embed-api --vram 12Gi --image my-embedder:v3 \
  --class Inference --priority 200 --runtime-class nvidia
```

YAML: [`examples/job-inference-high-priority.yaml`](../examples/job-inference-high-priority.yaml)

## 4. Cheap batch work that yields (and the preemption rule)

Low priority + `preemptible: true` = filler work that gives way when something
important needs the space. The rule is a **gap of ≥ 100**:

| Victim priority | Requester priority | Outcome |
|---|---|---|
| 10 (preemptible) | 110 | victim evicted (gap = 100) |
| 10 (preemptible) | 109 | requester **waits** (gap = 99) |
| 10, `preemptible: false` | 999 | requester waits — non-preemptible is immune |
| 10 and 30 both preemptible | 200 | the **pri-10** job is evicted first (lowest first) |

```sh
vgpu submit --name backfill --vram 24Gi --image my-batch:latest \
  --class Batch --tier BestEffort --priority 10 --runtime-class nvidia
```

YAML (adds `preemptionGraceSeconds: 30` for checkpointing):
[`examples/job-batch-preemptible.yaml`](../examples/job-batch-preemptible.yaml)

## 5. Distributed training — all 4 workers or none

Gangs are YAML-only. Either every member gets a slice or none do; a gang that can't
assemble within `reservationTimeoutSeconds` releases everything it held.

```sh
kubectl apply -f examples/gang-distributed-training.yaml
kubectl get vgpugangjob ddp-run -o wide        # RUNNING climbs 0 → 4 atomically
```

YAML: [`examples/gang-distributed-training.yaml`](../examples/gang-distributed-training.yaml)
(4 × 12 GiB, `minAvailable: 4`, timeout 300 s, non-preemptible)

## 6. Prefer a zone — without getting stuck

Label nodes once, hint per job. The hint is **soft**: if the preferred zone is full
the job still runs elsewhere, and the slice condition `TopologyPreferenceSatisfied`
records truthfully whether it was honored.

```sh
kubectl label node gpu-a topology.vgpu.pranav2910.com/zone=zone-fast
kubectl apply -f examples/job-zone-preference.yaml
```

YAML: [`examples/job-zone-preference.yaml`](../examples/job-zone-preference.yaml)

## 7. Cap a team's total GPU memory

```sh
kubectl apply -f examples/quota-team.yaml      # team-a capped at 64 GiB total
kubectl patch vgpuquota team-a-cap --type=merge \
  -p '{"spec":{"maxVramBytes":103079215104}}'  # raise LIVE to 96 GiB — waiting jobs unblock, no resubmit
```

⚠️ `spec.targetNamespace` is **required** — the quota applies to that namespace, not
to the namespace the quota object lives in. A gang whose *total* exceeds the cap
admits **zero** members.

YAML: [`examples/quota-team.yaml`](../examples/quota-team.yaml)

## 8. The right-sizing loop

```sh
vgpu profile train-llama
#   requested     16.0 GiB
#   peak observed 21.5 GiB
#   recommended   24.7 GiB   ← ask for this next time
#   VERDICT       UNDERPROVISIONED

vgpu submit --name train-llama-2 --vram 25Gi --image ... --runtime-class nvidia   # right-sized
vgpu submit --name thrifty --vram 8Gi --image ... --override --runtime-class nvidia # undersized ON PURPOSE
```

`--override` matters when the cluster enforces recommendations
(`requireOverride` policy). Policy + autoResize examples:
[`examples/recommendation-require-override.yaml`](../examples/recommendation-require-override.yaml) ·
[`examples/recommendation-autoresize.yaml`](../examples/recommendation-autoresize.yaml)

## 9. Scripting patterns

```sh
vgpu submit --name sweep-lr3 --vram 8Gi --image x --no-wait      # fire-and-forget (batches)
vgpu submit --name peek --vram 40Gi --image x --dry-run          # print YAML, apply nothing
vgpu submit --name t1 --vram 4Gi --image x -n team-a             # another namespace
vgpu submit --name pin --vram 2Gi --image x --node gpu-node-3    # pin to a node (demos only)
vgpu submit --name slow --vram 16Gi --image x --wait 300         # patient clusters
```

## 10. Watching the cluster (read-only)

```sh
vgpu report                                    # requested-vs-used per pod, live
vgpu report --price-per-gpu-hour 3.00          # + estimated $ wasted/month
vgpu report -o csv > waste.csv                 # same rows as the table, for finance
vgpu report -o json --top 5                    # top 5 wasters, machine-readable
vgpu report --filter-ns team-a                 # one team only
vgpu doctor                                    # every missing dependency, with its fix
vgpu security audit                            # blast radius, verified against live RBAC
vgpu support-bundle --out debug.tar.gz         # redacted diagnostics (never reads Secrets)
```

---

Cleanup for any example: `kubectl delete vgpujob <name>` (cascades to claim → slice →
pod) · `kubectl delete vgpugangjob <name>` · `kubectl delete vgpuquota <name>`.
