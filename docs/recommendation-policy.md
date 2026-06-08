# Recommendation enforcement (Phase 3.7a)

The platform learns each workload's real VRAM footprint (see
[runtime-feedback.md](runtime-feedback.md)) and recommends a right-sized request.
**Recommendation enforcement** decides how strongly that recommendation is applied
to *future* submissions — from a silent note, to a warning, to requiring an
explicit override.

> One line: *"This workload is under-provisioned — and depending on policy, we can
> note it, warn, or require you to acknowledge it before running."*

---

## For platform admins — choosing the mode

Set `VGPU_RECOMMENDATION_MODE` on the **controller** deployment. Default is
`recommendOnly` (nothing is ever blocked).

| mode | condition + annotation + metric | event | admission |
|---|---|---|---|
| `recommendOnly` *(default)* | ✓ | — | always allowed |
| `warn` | ✓ | Warning | always allowed |
| `requireOverride` | ✓ | Warning | **rejected unless the job has the override annotation** |
| `autoResize` | `AutoResized` condition | Normal | allowed; **request raised to the recommendation** (capped at fleet max) |

```sh
# enable requireOverride (e.g. for a cost-sensitive shared cluster)
kubectl set env deployment/vgpu-controller -n vgpu-system VGPU_RECOMMENDATION_MODE=requireOverride

# back to advisory-only
kubectl set env deployment/vgpu-controller -n vgpu-system VGPU_RECOMMENDATION_MODE=recommendOnly
```

### Safety properties (deliberate)

- **Confidence gate** — `requireOverride` blocks **only at `Medium`+ confidence**
  (≥20 stable observations). A `Low`-confidence profile is never enough to block a
  user's workload; early recommendations are directional, not authoritative.
- **Fail-open** — the enforcing webhook is `failurePolicy: Ignore` and never errors
  a request closed. A missing profile, a lookup failure, or a controller outage all
  **admit** the job. This is *policy*, not data integrity — it must never halt job
  submission cluster-wide.
- **Tolerance** — a request within **10%** of the recommendation is treated as
  adequately sized (no advisory, no block).
- **Never mutates the request, never changes the job phase.** Enforcement only
  rejects-at-admission (requireOverride) or annotates (all modes). Auto-resizing the
  request (`autoResize`) and a hard block with no override path are intentionally
  **not** built.

---

### `autoResize` (3.7b) — automatic right-sizing

`autoResize` goes one step past advising: a **mutating webhook raises** an
under-provisioned request up to the recommendation **at CREATE**, before the claim
and slice are made — so the whole scheduling chain sees one consistent, right-sized
request. It is the most automated mode, so it is built to never surprise:

- **Never silent.** Every resize stamps the job and surfaces an `AutoResized`
  condition + a Normal event. You can read both numbers straight off the object:
  ```yaml
  metadata:
    annotations:
      infrastructure.pranav2910.com/original-vram-bytes:   "17179869184"  # what you asked for
      infrastructure.pranav2910.com/autoresized-vram-bytes: "24000000000" # what it became
      infrastructure.pranav2910.com/autoresized: "true"
  ```
- **Never shrinks.** It only raises. An over-provisioned request is left alone
  (shrinking could starve a workload that legitimately spikes above its observed peak).
- **Capped at fleet max.** If the recommendation exceeds a single card, the request
  is clamped to fleet max and a distinct `AutoResizeCapped` condition + event fire
  (*"Profile recommended 96Gi, capped to fleet max 80Gi — workload may need a larger
  GPU class or model parallelism"*).
- **Override and safety still apply.** `--override` (the annotation) opts out; only
  `Medium`+ confidence; fail-open; CREATE-only.

```sh
kubectl set env deployment/vgpu-controller -n vgpu-system VGPU_RECOMMENDATION_MODE=autoResize
```

## For ML engineers — what you see and how to override

Check what the platform learned:

```sh
vgpu profile my-job
```

```
profile my-job  (ns=default)
  requested    16.0 GiB
  peak observed  21.5 GiB
  recommended  24.7 GiB   <- request this next time
  confidence   High  (142 observations)
  policy mode  requireOverride
  VERDICT      UNDERPROVISIONED — Requested 16384 MiB but recommends 25325 MiB (confidence High).
  next time    request 24.7 GiB  —  or keep this size and add --override
               (this cluster enforces requireOverride: an undersized re-submit is rejected without --override)
```

Two ways forward:

```sh
# 1. right-size (recommended) — request what it actually needs
vgpu submit --name my-job --vram 25Gi --image my-model:latest --runtime-class nvidia

# 2. run undersized on purpose — acknowledge the recommendation and override it
vgpu submit --name my-job --vram 16Gi --image my-model:latest --runtime-class nvidia --override
```

If a cluster enforces `requireOverride` and you submit undersized without
`--override`, the submission is rejected with a clear message:

```
vgpu: submission rejected by the recommendation policy:
  ... requested 16384 MiB is below this workload's recommended 25325 MiB (confidence High) ...
  → raise --vram to the recommended size (see: vgpu profile my-job), or
    re-submit with --override to run undersized on purpose.
```

Under the hood `--override` just stamps the VGPUJob:

```yaml
metadata:
  annotations:
    infrastructure.pranav2910.com/override-recommendation: "true"
```

When you override, the job still carries an `Underprovisioned` condition (reason
`RequestBelowRecommendationOverridden`) so the choice is auditable — but it runs,
and no warning event is emitted (it was your explicit decision).

---

## Observability

| metric | meaning |
|---|---|
| `vgpu_recommendation_mode{mode}` | the controller's active mode (1 for the configured one) |
| `vgpu_recommendation_rejections_total{namespace}` | under-provisioned CREATE requests rejected |
| `vgpu_recommendation_overrides_total{namespace}` | under-provisioned CREATE requests admitted via override |
| `vgpu_workload_underprovisioned{namespace,workload}` | 1 while a workload is under-provisioned (advisory) |

---

## Validate it

No GPU required — this is admission logic:

```sh
bash scripts/setup-kind-cluster.sh
bash scripts/validate-recommendation-3.7-kind.sh   # 5/5: all modes incl. the Low-confidence safety gate
```

See also: [runtime-feedback.md](runtime-feedback.md) (how the recommendation is
learned) and [examples/recommendation-require-override.yaml](../examples/recommendation-require-override.yaml).
