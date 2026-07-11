# vGPU — User Guide

A step-by-step manual for running your workloads on shared GPUs.

> **The one idea:** you ask for the **GPU memory you need** (e.g. `16Gi`), not a
> whole GPU. The platform finds room on a GPU, runs your workload there next to
> others, and tells you the right amount to ask for next time.

---

## 0. Before you start (one-time)

You do **not** need this repository or any build tools. You need exactly two
things: `kubectl` access to a cluster where your platform team has already
installed vGPU, and the single `vgpu` command.

```sh
# 1. point KUBECONFIG at your cluster (your platform team gives you this)
export KUBECONFIG=/path/to/your/kubeconfig

# 2. install the vgpu CLI — one file, no repo, no compiler
curl -fsSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu -o /tmp/vgpu \
  && sudo install -m 0755 /tmp/vgpu /usr/local/bin/vgpu && rm -f /tmp/vgpu

vgpu version         # confirm it works
vgpu --help
```

That's it. `vgpu` is a zero-dependency wrapper around `kubectl` — it talks to the
cluster's API server exactly like `kubectl` does, so it needs nothing but a
working `KUBECONFIG`.

> **Already have the repo cloned?** You can skip the curl and just symlink the
> script instead: `sudo ln -sf "$PWD/scripts/vgpu" /usr/local/bin/vgpu`.

> On a real GPU cluster, add `--runtime-class nvidia` to every `submit`
> (examples below already include it). On a local/test cluster, drop it.

---

## 1. Run a workload

```sh
vgpu submit --name my-job --vram 16Gi --image my-model:latest --runtime-class nvidia
```

That reads as: *“run my-model, call it my-job, give it 16 GiB of GPU memory.”*

| Flag | Meaning |
|---|---|
| `--name` | a label for your workload (required) |
| `--vram` | how much GPU memory you need, e.g. `16Gi`, `8Gi`, `512Mi` (required) |
| `--image` | your container image (required) |
| `--runtime-class nvidia` | required on real GPU clusters |
| `--command 'CMD'` | optional: override the container command |
| `--priority N` | optional: scheduling priority 0–1000 (default 50) |
| `-n NAMESPACE` | optional: target namespace (default `default`) |

What you'll see:

```
submitted: my-job  (16.0 GiB VRAM, class=Training, tier=Guaranteed, ns=default)
  VGPUJob/my-job  ->  VGPUClaim/my-job-claim  ->  VGPUSlice/my-job-claim-slice  ->  Pod/my-job-workload  (all by the controller)
  waiting up to 120s for the controller to place the workload...
  workload pod created by the controller (phase=Pending)
  next:  vgpu status my-job
```

Your workload now runs on a slice of a shared GPU.

> **`vgpu` is just convenience.** The `VGPUJob` is the source of truth — the
> controller owns the whole chain (claim → slice → **pod**). So this is exactly
> equivalent and works with GitOps (Argo/Flux), no CLI required:
>
> ```sh
> vgpu submit --name my-job --vram 16Gi --image my-model:latest \
>   --runtime-class nvidia --dry-run > my-job.yaml   # render the VGPUJob
> kubectl apply -f my-job.yaml                        # apply it directly
> ```

---

## 2. Check where it is

```sh
vgpu status my-job
```

```
workload my-job  (requested 16.0 GiB)
  Job    Scheduled    VGPUJob/my-job
  Claim  Bound        VGPUClaim/my-job-claim
  Slice  Ready        VGPUSlice/my-job-claim-slice   node=gpu-1   alloc=alloc-…
  Pod    Running      Pod/my-job-workload
```

`Pod  Running` = your workload is on the GPU. (Right after submit it may show
`Pending` for a few seconds while the image pulls.)

---

## 3. See your workload's output

The pod is always named **`<name>-workload`**:

```sh
kubectl logs my-job-workload -f
```

To open a shell or check the GPU inside the pod:

```sh
kubectl exec -it my-job-workload -- bash
kubectl exec my-job-workload -- nvidia-smi
```

---

## 4. Right-size it (the part that saves money)

After your workload has run for a minute or two:

```sh
vgpu profile my-job
```

If you guessed about right:

```
  requested     16.0 GiB
  peak observed 14.2 GiB
  recommended   16.4 GiB
  VERDICT       OK — request covers the observed peak (with headroom)
```

If you asked for **too little** (this is the valuable case):

```
  requested     16.0 GiB
  peak observed 21.3 GiB
  recommended   24.5 GiB        <- ask for this next time
  VERDICT       UNDERPROVISIONED — you asked 16 GiB but peaked at 21 GiB
```

Your workload keeps running (it is **not** killed) — the platform just tells you
the right number. Use it on your next run:

```sh
vgpu submit --name my-job-v2 --vram 24Gi --image my-model:latest --runtime-class nvidia
```

If you asked for **too much**, the recommendation will be lower than your request
— shrink it and free that memory for a teammate.

---

## 5. Distributed / multi-worker training (all-or-nothing)

For a job that needs several workers that must all start together:

```sh
kubectl apply -f - <<'EOF'
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: ddp-run }
spec:
  gangSize: 4            # 4 workers
  minAvailable: 4        # all 4 or none (no half-started jobs)
  podTemplate:
    spec:
      requestedVramBytes: 12884901888   # 12 GiB per worker
      serviceTier: Guaranteed
EOF

kubectl get vgpugangjob ddp-run -o wide    # RUNNING climbs 0 -> 4 atomically
```

Either all four workers get a GPU slice, or none do — you never get a deadlocked
job holding half the GPUs.

---

## 6. Clean up

```sh
kubectl delete vgpujob my-job                          # removes the claim + slice
kubectl delete pod my-job-workload --ignore-not-found  # removes the workload pod
```

---

## Command reference

| Task | Command |
|---|---|
| Run a workload | `vgpu submit --name N --vram 16Gi --image IMG --runtime-class nvidia` |
| Override the command | `vgpu submit … --command 'python train.py'` |
| Check status | `vgpu status N` |
| See the right-size advice | `vgpu profile N` |
| View logs | `kubectl logs N-workload -f` |
| Shell into the pod | `kubectl exec -it N-workload -- bash` |
| List your workloads | `kubectl get vgpujobs` |
| Delete a workload | `kubectl delete vgpujob N` |
| All flags | `vgpu submit --help` |

---

## Troubleshooting

| You see | What it means | Do this |
|---|---|---|
| `Pod  Pending` in `status` | image still pulling, or no GPU has room | wait a minute; if it persists, your request may be larger than any GPU's free memory — lower `--vram` |
| `slice not allocated yet` on submit | the scheduler hasn't placed it | re-run `vgpu status N`; if stuck, ask your platform team to check capacity |
| `vgpu profile` shows `0 observations` | the workload just started | wait a minute and re-run — the platform observes on an interval |
| `nvidia-smi: command not found` inside the pod | the GPU wasn't injected | confirm you passed `--runtime-class nvidia` |
| `kubectl: command not found` / auth errors | `KUBECONFIG` not set | `export KUBECONFIG=…` (from your platform team) |

---

## The habit to remember

Stop thinking *“I need a GPU.”* Start thinking *“I need 16 GiB.”* Submit by
memory, check the **profile**, and right-size from what it tells you. The platform
handles finding space, sharing the card safely, and keeping you honest about size.
