# Demo — one GPU, the work of four

Copy-pasteable manifests + a narrated before/after that shows the core value on a
laptop (kind, no GPU): vanilla Kubernetes strands GPUs at whole-GPU granularity;
this scheduler packs many workloads onto one card.

| File | What |
|---|---|
| `00-demo-namespace.yaml` | optional isolated `vgpu-demo` namespace |
| `01-vgpujob-training.yaml` | a single Training workload asking for a 16 GiB slice |
| `02-vgpugangjob-allreduce.yaml` | a 4-rank gang (all-or-nothing) |
| `03-before-plain-gpu-pods.yaml` | **before**: 4 plain pods each demanding a whole `nvidia.com/gpu` |
| `04-after-vgpujobs-packed.yaml` | **after**: the same 4 workloads as VGPUJobs, 16 GiB each |
| `h100-before-after.sh` | **on a real GPU**: the same before/after, auto-sized to the card (runs the packing live + reports utilization) |
| `autoresize-demo.sh` | **self-correction (3.7b)**: submit under-provisioned → the platform auto-raises the request to the learned recommendation (kind or real GPU) |

Submit workloads with the [`vgpu` CLI](../scripts/vgpu) (`vgpu submit/status/profile`)
or raw `kubectl apply` as below.

## Setup (once)

```sh
scripts/setup-kind-cluster.sh                 # control plane + an 80 GiB mock GPU on one node
kubectl get pods -n vgpu-system               # scheduler, controller, node agent → Running
kubectl apply -f demo/00-demo-namespace.yaml
```

## Before — vanilla Kubernetes, whole-GPU granularity

Make the node look like a stock 1-GPU box, then ask for 4 whole GPUs:

```sh
NODE=$(kubectl get nodes -o name | head -1 | sed 's|node/||')
kubectl patch node "$NODE" --subresource=status --type=merge \
  -p '{"status":{"capacity":{"nvidia.com/gpu":"1"},"allocatable":{"nvidia.com/gpu":"1"}}}'

kubectl apply -f demo/03-before-plain-gpu-pods.yaml
kubectl get pods -n vgpu-demo -l group=plain-gpu -o wide
#   → exactly 1 Running, 3 Pending. THE PAIN.
kubectl describe pod -n vgpu-demo plain-gpu-1 | grep -A3 Events
#   → "FailedScheduling … Insufficient nvidia.com/gpu" — 75% of the card is stranded.
```

## After — the vGPU scheduler, byte-granular slices

```sh
kubectl delete -f demo/03-before-plain-gpu-pods.yaml
kubectl patch node "$NODE" --subresource=status --type=merge \
  -p '{"status":{"capacity":{"nvidia.com/gpu":"0"},"allocatable":{"nvidia.com/gpu":"0"}}}'

kubectl apply -f demo/04-after-vgpujobs-packed.yaml      # same 4 workloads, 16 GiB each
kubectl get vgpujobs,vgpuslices -n vgpu-demo -o wide
#   → all 4 jobs Running, 4 slices ALL on one node. 4×16 GiB = 64 GiB on one 80 GiB GPU.

kubectl -n vgpu-system port-forward deploy/vgpu-scheduler 8081:8081 >/dev/null 2>&1 &
curl -s localhost:8081/metrics | grep vgpu_node_free_bytes
#   → free VRAM dropped ~80 GiB → ~16 GiB. On vanilla K8s, 3 of these would still be Pending.
```

**The headline:** same hardware, 4× the work — because the scheduler packs by VRAM
bytes instead of whole GPUs.

## Bonus — the all-or-nothing gang

```sh
kubectl apply -f demo/02-vgpugangjob-allreduce.yaml      # 4 ranks × 12 GiB
kubectl get vgpugangjob ddp-allreduce -n vgpu-demo -o wide   # Running climbs 0→4 atomically
kubectl get vgpugangreservations -n vgpu-demo               # one reservation gates the whole gang
```

Bump `gangSize`/`minAvailable` to 8 (8×12 = 96 GiB > 80) and re-apply to watch it sit
in `Reserving`, then roll back cleanly within `reservationTimeoutSeconds` — no deadlock,
no stranded half-gang.

## On real hardware (the same story, live)

The manifests above run on a mock-GPU kind cluster so you can see the packing on a
laptop. To run it on an actual GPU node, stand up the full control plane and use the
auto-sizing script:

```sh
bash scripts/h100-control-plane.sh            # full control plane on the GPU node
export KUBECONFIG=$HOME/.kube/config
bash demo/h100-before-after.sh                # submits one more than fits; --keep to leave running
```

On an 80 GiB H100 this packs **4× 16 GiB workloads onto one physical GPU** (~80%
utilization) and shows the 5th **held Pending** — the no-over-admission guarantee.
Each pod's `nvidia-smi` reports the same GPU UUID as its slice. Full runbook:
[../docs/INSTALL-H100.md](../docs/INSTALL-H100.md).

## Honest note on what's real here

The scheduling, VRAM bin-packing, claim/slice lifecycle, gang reservations, and the
metrics above are **genuinely implemented**, and on a real GPU node the data plane is
real too: with the `-tags nvml` node agent the allocator binds an actual GPU UUID,
writes a CDI spec, and the mutating webhook injects the device — a pod gets the GPU and
`nvidia-smi` works inside it (validated end to end on an A10 **and** a 1× H100;
`scripts/validate-submit-flow-h100.sh` → 14/14). This kind demo shows only the
**scheduling** half (mock GPU, no real injection on a laptop).

The one honest limitation: per-pod VRAM isolation is **soft**, not hard. A pod is given
the whole GPU via `NVIDIA_VISIBLE_DEVICES` and its VRAM budget is governed by
observe → warn → opt-in evict → right-size (see
[../docs/runtime-feedback.md](../docs/runtime-feedback.md)), not by a hardware fence.
**MIG-backed hard partitioning** is the next step, not done yet.
