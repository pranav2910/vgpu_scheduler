# The vGPU Tutorial — learn the whole product in 45 minutes

One GPU node, fourteen small steps. Every command below was run on a real
1×A10 (22.5 GiB) and **every "you'll see" block is the machine's actual
output** — if your screen disagrees, something is genuinely wrong.

> **The one idea:** Kubernetes rents GPUs whole-card. vGPU is the host that
> seats workloads by the exact memory they need, keeps an honest waiting line,
> frees seats when a job leaves, learns what each job *really* uses — and never
> lies to you about any of it.
>
> Steps 1–5 also work on a laptop kind cluster (drop `--runtime-class nvidia`).
> Steps 6–13 need a real GPU node — a ~$1/hr A10 rental is perfect.
> Sizes below assume a ~22 GiB card; scale them to yours.

**Setup** (admin, once): [INSTALL.md](INSTALL.md) path 3 brings up the full
stack on a GPU node in ~5 minutes. Then install the CLI anywhere:

```sh
curl -fsSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu -o /tmp/vgpu \
  && sudo install -m 0755 /tmp/vgpu /usr/local/bin/vgpu && rm -f /tmp/vgpu
vgpu version
```

---

## 1. Run your first job

Ask for **memory, not a whole GPU**:

```sh
vgpu submit --name demo --vram 8Gi --image busybox --command 'sleep 3600' --runtime-class nvidia
```
```
submitted: demo  (8.0 GiB VRAM, class=Training, tier=Guaranteed, ns=default)
  VGPUJob/demo -> VGPUClaim/demo-claim -> VGPUSlice/demo-claim-slice -> Pod/demo-workload
  workload pod created by the controller (phase=Running)
```

Four objects, one story: your **order** → the **reservation ticket** → the
**seats assigned** → your **program running in them**.

## 2. Read the status

```sh
vgpu status demo
```
```
workload demo  (ns=default, requested 8.0 GiB)
  Job    Running    VGPUJob/demo
  Claim  Bound      VGPUClaim/demo-claim   bound=demo-claim-slice
  Slice  Ready      VGPUSlice/demo-claim-slice  node=193-122-149-24
  Pod    Running    Pod/demo-workload
```

Four greens = healthy. This is the first command to run when anything is odd.

## 3. Finished jobs give the memory back — automatically

```sh
vgpu submit --name quick --vram 6Gi --image busybox --command 'sleep 30' --runtime-class nvidia
sleep 45 && vgpu status quick
```
```
  Job    Succeeded    VGPUJob/quick
  Claim  Released     VGPUClaim/quick-claim  (workload finished — VRAM grant returned)
  Slice  Released     VGPUSlice/quick-claim-slice  (freed for other workloads)
  Pod    Succeeded    Pod/quick-workload
```

`Succeeded` is a **finish line, not an error** — the program exited cleanly and
its 6 GiB went straight back to the pool. Nobody has to remember to clean up.

## 4. Fill the card — meet the honest waitlist

```sh
# demo already holds 8; three more 6 GiB asks = 26 total, but the card is ~22.
for i in 1 2 3; do vgpu submit --name pack-$i --vram 6Gi --image busybox \
  --command 'sleep 3600' --runtime-class nvidia --no-wait; done
kubectl get vgpuslice
```
```
NAME                 NODE             PHASE   ...
demo-claim-slice     193-122-149-24   Ready
pack-1-claim-slice   193-122-149-24   Ready
pack-2-claim-slice   193-122-149-24   Ready
pack-3-claim-slice                            ← empty row: waiting, not lied to
```

The card is full, so `pack-3` gets **no seats and no fake promises**. Now free
a seat and watch the line move by itself:

```sh
kubectl delete vgpujob pack-1 && sleep 10 && kubectl get vgpuslice   # pack-3 → Ready
```

## 5. Try to cheat — three polite refusals

```sh
vgpu submit --name demo --vram 20Gi --image busybox        # resubmit an existing name
# → refused: 'demo' already exists and holds 8.0 GiB — delete and resubmit to resize

kubectl patch vgpujob demo --type=merge -p '{"spec":{"claimTemplate":{"spec":{"requestedVramBytes":99}}}}'
# → denied: immutability violation ... an edit here would be silently ignored.
#   To resize: kubectl delete vgpujob demo, then resubmit

vgpu status ghost
# → vgpu: no VGPUJob 'ghost' in namespace 'default' (did you 'vgpu submit'?)
```

The theme of the whole product: **it refuses loudly rather than lying quietly.**
Clean up before part two: `kubectl delete vgpujob --all`

---

## 6. The learning loop (real GPU from here on)

Run real training — an 8-layer Transformer — and ask for 12 GiB:

```sh
kubectl apply -f - <<'EOF'
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: {name: real-train}
spec:
  claimTemplate:
    spec: {requestedVramBytes: 12884901888, serviceTier: Guaranteed}   # 12 GiB
  podTemplate:
    spec:
      restartPolicy: Never
      runtimeClassName: nvidia
      containers:
      - name: workload
        image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime
        command: ["python","-c"]
        args:
        - |
          import torch, torch.nn as nn, time
          m = nn.Sequential(*[nn.TransformerEncoderLayer(1024,16,4096,batch_first=True) for _ in range(8)]).cuda()
          opt = torch.optim.AdamW(m.parameters(), lr=1e-4)
          x = torch.randn(32,512,1024,device="cuda")
          for step in range(100000):
              loss = m(x).pow(2).mean(); loss.backward(); opt.step(); opt.zero_grad(set_to_none=True)
              if step%100==0: print(f"step {step} loss {loss.item():.4f}", flush=True)
EOF
kubectl logs -f real-train-workload    # falling loss = real learning; Ctrl-C to stop watching
```

After ~2 minutes, ask the platform what it **measured**:

```sh
vgpu profile real-train
```
```
profile real-train  (ns=default)
  requested    12.0 GiB
  peak observed  11.3 GiB          ← read from the silicon (NVML), not guessed
  recommended  13.0 GiB   <- request this next time
  VERDICT      UNDERPROVISIONED — Requested 12288 MiB but observed peak recommends 13337 MiB
```

It caught a real risk: you're at 94% of your grant — one bigger batch from an
OOM at step 40,000. Follow the advice — delete, resubmit the same YAML with
`requestedVramBytes: 15032385536` (14 GiB) — and the verdict clears:

```
  requested    14.0 GiB
  peak observed  11.3 GiB
  recommended  13.0 GiB
  VERDICT      OK — request covers the observed peak (with headroom)
```

**Observed → learned → right-sized → clean.** That loop is the product.

## 7. Two models, one card

With `real-train` (14 GiB) running, add a small second model — 5 GiB, four
layers (same YAML shape, `name: mini-train`, `requestedVramBytes: 5368709120`,
`TransformerEncoderLayer(512,8,2048…)`, `randn(16,256,512…)`). Then:

```sh
kubectl get vgpuslice        # TWO Ready slices, SAME GPU UUID
nvidia-smi                   # two python processes sharing one physical A10
```

Vanilla Kubernetes would have demanded two GPUs for this. You're running it on one.

## 8. The autopilot — autoResize

Turn it on (admin, once) and deliberately under-ask:

```sh
kubectl set env deployment/vgpu-controller -n vgpu-system VGPU_RECOMMENDATION_MODE=autoResize
kubectl -n vgpu-system rollout status deploy/vgpu-controller
kubectl delete vgpujob mini-train && sleep 10
vgpu submit --name mini-train --vram 1Gi --image busybox --command 'sleep 600' --runtime-class nvidia
vgpu status mini-train
```
```
workload mini-train  (ns=default, requested 1.3 GiB)
  ...
  ^ auto-resized 1.0 GiB -> 1.3 GiB  (policy raised your request to the recommendation)
```

You asked 1 GiB; the platform knew (from step 7's learning) this workload needs
~1.3 and **corrected the request before the reservation was created** — audited
in the job's annotations (`original-vram-bytes` / `autoresized-vram-bytes`).
`--override` opts out. `requireOverride` is the stricter sibling: undersized
submits are *rejected* unless you sign the risk with `--override`.
Reset when done: `... VGPU_RECOMMENDATION_MODE=recommendOnly`

## 9. The VIP rules — preemption

Fill the card with a consenting low-priority tenant and a non-consenting one:

```sh
kubectl delete vgpujob --all && sleep 10
# student: 15Gi, priority 10, preemptible:true  |  wall: 7Gi, priority 50, preemptible:false
# (YAML for both in EXAMPLES.md §4 — spec.preemptible is YAML-only)
```

Three submissions, three rules:

```sh
vgpu submit --name vip-weak --vram 12Gi ... --priority 109 --no-wait
# → waits forever: gap 109−10 = 99 < 100. Marginal importance evicts nobody.

vgpu submit --name vip --vram 12Gi ... --priority 110 --no-wait
# → student evicted WITH a paper trail, vip Running, wall untouched:
kubectl get vgpujob student -o jsonpath='{.status.conditions[?(@.type=="Preempted")].message}'
#   Preempted by default/vip-claim-slice; grace=15s

vgpu submit --name emperor --vram 10Gi ... --priority 999 --no-wait
# → waits forever: wall is preemptible:false. Rank never beats consent.
```

## 10. All-or-nothing gangs

```sh
kubectl delete vgpujob --all && kubectl apply -f examples/gang-distributed-training.yaml
kubectl get vgpugangjob -o wide          # RUNNING: 0 → 3, atomically — never 1 or 2
```

Now an **impossible** gang (3×10 GiB on what's left) with a 60 s timeout:

```
NAME              GANG          PHASE      REASON
gang-doomed-rsv   gang-doomed   Released   deadline 60s exceeded with only 0/3 slots reserved
```

Zero members ever started — no half-started job hoarding GPUs — and it
explained its own death. The next normal submit lands instantly: no debris.

## 11. Team budgets — quota with a live raise

```sh
kubectl create ns team-a
kubectl apply -f examples/quota-team.yaml            # team-a capped at 10 GiB
vgpu submit --name q1 --vram 8Gi -n team-a ...       # Running (8 of 10)
vgpu submit --name q2 --vram 4Gi -n team-a ... --no-wait
kubectl get vgpujob -n team-a                        # q2 ClaimCreated — card has room, BUDGET doesn't
kubectl patch vgpuquota team-a-cap --type=merge -p '{"spec":{"maxVramBytes":17179869184}}'
sleep 25 && kubectl get vgpujob -n team-a            # q2 Running — nobody resubmitted anything
```

Finance says yes → one patch → the queue moves. Other namespaces never feel it.

## 12. Catching a liar — the enforcement ladder

Grant a job 2 GiB; its program grabs 4:

```sh
vgpu submit --name hog --vram 2Gi --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime \
  --command $'python - <<PY\nimport torch,time\na=torch.empty(int(4*2**30),dtype=torch.uint8,device=0)\ntime.sleep(1200)\nPY' \
  --runtime-class nvidia
```

⏱ **Be patient here: the ladder is deliberate.** ~90 s of sustained over-use
before it's a violation, ~90 s more of grace before enforcement engages.

```sh
sleep 200
kubectl get events --sort-by=.lastTimestamp | grep -i violation | tail -1
#   MemoryViolation ... exceeded allocated VRAM by 2276 MiB for ~90s (observe-only, no eviction)

kubectl get pods -A -l infrastructure.pranav2910.com/memory-violation=true
#   default  hog-workload      ← find every offender in the cluster with ONE selector
```

Default mode **warns and stamps — never kills**. Eviction is an explicit opt-in:

```sh
kubectl -n vgpu-system set env ds/vgpu-nodeagent VGPU_ENFORCEMENT_MODE=evict
# ~3–4 min later (fresh streak + deadline):
#   MemoryEnforcementEvicted ... Evicted pod hog-workload for sustained GPU VRAM
#   over-use (2276 MiB over grant) past the enforcement deadline (policy=evict, PDB-respecting)
kubectl -n vgpu-system set env ds/vgpu-nodeagent VGPU_ENFORCEMENT_MODE=softwarn   # disarm
```

Innocent neighbors never feel any of it — attribution is per-process, not per-card.

## 13. The money report

```sh
vgpu install monitor && vgpu doctor
vgpu report --price-per-gpu-hour 1.00
```
```
  WORKLOAD (ns/pod)             REQUESTED     USED       WASTE   UTIL  SOURCE
  default/real-train-workload    14.0 GiB   11.3 GiB   2.7 GiB    81%  vgpu_claim
  ...
  Estimated waste/month:    $87   (at $1.00/GPU-hr, ~0.12 cards idle)
```

`-o csv` / `-o json` for finance, `--filter-ns` per team. The Grafana dashboard
(`deployments/`, see [PILOT.md](PILOT.md)) shows the same numbers — they must
agree with the CLI within 1%, and that agreement is itself a certified test.

## 14. Clean up

```sh
kubectl delete vgpujob,vgpugangjob --all -A
kubectl delete vgpuquota,vgpuworkloadprofile --all -A
kubectl get vgpuslice -A     # "No resources found" = every seat back in the pool
```

---

## Where next

| You want | Go to |
|---|---|
| The 5-minute version of steps 1–2 | [QUICKSTART.md](QUICKSTART.md) |
| Copy-paste recipes (CLI + YAML side by side) | [EXAMPLES.md](EXAMPLES.md) |
| The full CLI manual + troubleshooting | [USER-GUIDE.md](USER-GUIDE.md) |
| Install paths (monitor / full / multi-node) | [INSTALL.md](INSTALL.md) |
| What's proven and how (certification receipts) | [CERTIFICATION.md](CERTIFICATION.md) |
| Security posture / blast radius | [SECURITY.md](SECURITY.md) |
