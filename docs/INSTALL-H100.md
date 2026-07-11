# Install the full platform on a single GPU node — runbook

> One of the five install paths — the full map is **[INSTALL.md](INSTALL.md)**.

A from-scratch, copy-paste runbook for bringing the **full vGPU control plane** up
on a single real GPU box and proving it end to end. Validated on H100, A10, A100
and V100 (the script is GPU-agnostic — its name is historical).

> **Who runs this:** the **platform/admin**, once per cluster. ML engineers don't
> run any of this — they just get `kubectl` access + the `vgpu` CLI
> (see [USER-GUIDE.md](USER-GUIDE.md)).

## Prerequisites

A GPU node with NVIDIA drivers, `docker`, and `git` (Lambda / most cloud GPU
images ship all three). You need `sudo`. Nothing else — the script installs k3s
(which provides `kubectl`) itself.

## 1. Clone (HTTPS — no SSH key needed; the repo is public)

```sh
git clone https://github.com/pranav2910/vgpu_scheduler.git
cd vgpu_scheduler
```

## 2. Bring up the whole control plane — one script

```sh
bash scripts/h100-control-plane.sh
```

On a fresh box this is fully self-contained. It:

1. runs the base bootstrap (installs **k3s** + the **NVML node agent**, registers
   the NVIDIA container runtime + `RuntimeClass/nvidia`);
2. advertises the GPU's VRAM as schedulable capacity
   (`infrastructure.pranav2910.com/vgpu-bytes`);
3. installs **cert-manager** and the **admission webhooks** (issues the TLS secret);
4. builds + imports the **controller** and **scheduler** images;
5. deploys controller + scheduler (2 replicas each, leader-elected).

It's idempotent — safe to re-run. Expect a few minutes (it builds 3 Go images).

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -n vgpu-system     # scheduler ×2, controller ×2, node agent → Running
```

## 3. Prove it end to end

```sh
bash scripts/validate-submit-flow-h100.sh
```

Expected: **`PASS=14 FAIL=0`**. It proves both entry points on the real GPU:

- `vgpu submit` → Job → Claim → Slice → placement → real GPU bind → pod runs,
  and `nvidia-smi` **inside the pod** reports the same GPU UUID as the slice;
- a raw `kubectl apply -f` of a VGPUJob with `spec.podTemplate` → the controller
  creates and owns the pod, which auto-runs on the GPU (fully declarative).

## 4. Use it (the ML-engineer experience)

```sh
# install the CLI properly (or use scripts/vgpu from this checkout — same file)
curl -fsSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu -o /tmp/vgpu \
  && sudo install -m 0755 /tmp/vgpu /usr/local/bin/vgpu && rm -f /tmp/vgpu

# run a workload on a shared slice of the GPU
vgpu submit --name demo --vram 16Gi \
  --image nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --command 'nvidia-smi -L; sleep 3600' --runtime-class nvidia

vgpu status  demo          # Job / Claim / Slice / Pod, node + alloc
vgpu profile demo          # learned peak vs requested → right-size advice
```

The feedback loop: run a workload that actually uses VRAM and `vgpu profile` reports
the observed peak and a right-sized recommendation (`peak × 1.15`), non-blocking —
e.g. a job that asks for 16 GiB but allocates ~21 GiB profiles to
`recommended ≈ 24.7 GiB / UNDERPROVISIONED`, and keeps running.

## 5. The packing proof (before/after)

```sh
bash demo/h100-before-after.sh     # auto-sizes to the GPU; --keep to leave it running
```

It submits one more 16 GiB workload than the card holds and shows the ones that fit
**Running on the same physical GPU**, with the extra **safely held Pending** — the
no-over-admission guarantee. On an 80 GiB H100: **4 workloads share one card
(~80% utilization)** where vanilla Kubernetes (`nvidia.com/gpu: 1`) runs exactly **1**.

## Cleanup

```sh
kubectl delete vgpujob --all                 # remove workloads (cascades to claims/slices/pods)
# tear the cluster down entirely:
/usr/local/bin/k3s-uninstall.sh
```

## Reference: a real run

On a 1× H100 80GB (node `68-209-74-147`, `GPU-a66d3a8d…`, 79.6 GiB advertised):
`validate-submit-flow-h100.sh` → **14/14**; four `16Gi` workloads packed onto the
one GPU with the fifth correctly held; an under-provisioned job profiled to
`peak 21.5 GiB → recommended 24.7 GiB / UNDERPROVISIONED` while still running.
