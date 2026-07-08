# Quickstart — run a workload on a shared GPU in 5 minutes

> One of the five install paths — the full map is **[INSTALL.md](INSTALL.md)**.

**For ML engineers.** You need `kubectl` access to a cluster where your platform team
has already installed vGPU. You do **not** need this repo or any build tools.
*(Admins setting up a cluster: start at [INSTALL.md](INSTALL.md).)*

The one idea: **ask for the GPU memory you need (`16Gi`), not a whole GPU.** The
platform packs your workload onto a shared card and tells you the right size next time.

```sh
# 1. Install the vgpu CLI — one file, no repo, no compiler
curl -sSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu \
  -o /usr/local/bin/vgpu && chmod +x /usr/local/bin/vgpu
export KUBECONFIG=/path/to/your/kubeconfig          # your platform team gives you this
vgpu version                                         # confirm it works (no cluster needed)

# 2. Run a workload — request MEMORY, not a whole GPU
vgpu submit --name my-job --vram 16Gi \
  --image my-model:latest --command 'python train.py' --runtime-class nvidia

# 3. Watch it land on a shared GPU
vgpu status my-job          # Job → Claim → Slice → Pod, with the node + GPU
kubectl logs my-job-workload -f

# 4. Right-size it (the step that saves money)
vgpu profile my-job
#   requested    16.0 GiB
#   peak observed 21.5 GiB
#   recommended  24.7 GiB   <- ask for this next time
#   VERDICT      UNDERPROVISIONED — you asked 16, you actually need ~25

# 5. Clean up
kubectl delete vgpujob my-job
```

That's it — your job ran on a *slice* of a shared GPU, and the platform learned its
real footprint.

### Cheat sheet
| Task | Command |
|---|---|
| Run a workload | `vgpu submit --name N --vram 16Gi --image IMG --runtime-class nvidia` |
| Override the command | `vgpu submit … --command 'python train.py'` |
| Status | `vgpu status N` |
| Logs | `kubectl logs N-workload -f` |
| Right-size advice | `vgpu profile N` |
| Run undersized on purpose | `vgpu submit … --override` |
| Delete | `kubectl delete vgpujob N` |
| All flags | `vgpu submit --help` |

### Two things worth knowing
- **`--runtime-class nvidia`** is required on real GPU clusters; drop it on a local/test cluster.
- If your cluster **enforces** right-sizing, an undersized re-submit may be rejected with a clear hint — either raise `--vram` or add `--override`. See [recommendation-policy.md](recommendation-policy.md).

**Next:** the full manual with gang (multi-worker) jobs, troubleshooting, and the
habit of right-sizing → [USER-GUIDE.md](USER-GUIDE.md). Want it by example instead?
[EXAMPLES.md](EXAMPLES.md) has CLI + YAML side by side for 10 use cases.
