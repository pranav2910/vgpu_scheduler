# Runtime Feedback Engine — GPU behavior profiles (Phase 3.5)

The 3.4 enforcement chain already attributes observed GPU VRAM to each slice
every cycle — but it only used the instantaneous value to decide enforcement,
then discarded it. Phase 3.5 **accumulates** that signal into a durable
per-workload **behavior profile**, so the system learns what each workload
actually needs and *recommends* the right grant. Reactive → self-correcting.

> A job grants 4 GiB but repeatedly peaks at 9 GiB → after enough observations
> its `VGPUWorkloadProfile` carries `recommendedVramBytes ≈ 10.35 GiB,
> confidence: High`, and an `Underprovisioned` condition. The next submission (or
> a future scheduler — 3.6) can right-size it.

**Observe-only.** 3.5 never changes scheduling, admission, quota, or enforcement.
It is the same observe-first discipline that made 3.4 safe: first prove the
profile data is stable and useful, *then* let the scheduler act on it (3.6).

## Architecture — observe (node) → aggregate (controller) → recommend

A gang job's slices span multiple nodes, so per-workload aggregation must have a
single writer or node agents would fight over one profile:

```
node agent (per slice, no contention)        controller (leader, single writer)
  observe attributed VRAM each cycle            watch slices → group by job
  → record stats on VGPUSlice.status        →   → aggregate into VGPUWorkloadProfile
```

- **Node agent** keeps in-memory per-slice running stats (peak, EWMA average,
  sample count, and incident counters from the 3.4 events it already fires) and
  flushes them onto `VGPUSlice.status` — on a new peak or every ~2 min, not every
  cycle (low etcd churn). Counters are tracked as deltas and merged additively, so
  a restart loses at most one flush interval. Each slice has exactly one owning
  node → no contention. Runs in **every** enforcement mode (learning is
  independent of enforcement, so even `off` builds a profile).
- **Controller** (leader-elected, the *sole* profile writer) watches slices,
  groups them by job (`slice → claim → claim.JobRef`), and rolls them up into a
  `VGPUWorkloadProfile`. Correct for multi-node gangs.

## The CRD — `VGPUWorkloadProfile`

Named 1:1 with the workload (the `VGPUJob`), with **no owner reference**, so it
survives job deletion and accumulates across re-runs.

```
$ kubectl get vgpuworkloadprofiles
NAME    REQUESTED     PEAK          RECOMMENDED   CONFIDENCE   EVICTIONS
job1    4294967296    9663676416    11114270720   High         4
```

All status; the spec is just `workloadRef`. Accumulated fields
(`peakObservedVramBytes`, `observations`, `violationCount`, `softWarnCount`,
`evictionCount`) are **monotonic high-water marks** — they never regress when
slices churn or a job is re-run (v1; cross-run *additive* totals are a noted
follow-up).

## The math (pure, unit-tested — `api/v1alpha1`)

| Field | Rule |
|---|---|
| `peakObservedVramBytes` | max attributed usage across the job's slices (monotonic) |
| `avgObservedVramBytes` | EWMA (recency-weighted) |
| `recommendedVramBytes` | `peak × (1 + headroom)`, headroom **15%** (`RecommendedVRAMBytes`) |
| `confidence` | `Low` (<20 obs) → `Medium` (20–99, or peak still climbing) → `High` (≥100 **and** peak stable) (`Confidence`) |
| `Underprovisioned` condition | `recommended > requested` |

VRAM must cover the **peak** (a workload OOMs at peak, not average), so the
recommendation keys off peak + headroom. **Confidence requires a *stable* peak**:
a still-growing peak stays `Medium` even past 100 samples, because the true
maximum may not be known yet — it rises to `High` only once the peak stops
climbing. Per-workload gauges are also exported:
`vgpu_workload_recommended_vram_bytes`, `vgpu_workload_peak_observed_vram_bytes`,
`vgpu_workload_profile_confidence{0=Low,1=Medium,2=High}`.

## Explicitly NOT done in 3.5

3.5 itself has no effect on scheduling, admission, quota, or enforcement — it only
produces the recommendation. *Consuming* that recommendation is 3.6 (below).

## 3.6 — soft feedback-aware scheduling (current)

The first consumer of the profile, and deliberately the gentlest: a **non-blocking
advisory**. When a `VGPUJob`'s requested VRAM is below its profile's
recommendation — *at sufficient confidence* — the controller warns, but the job
is still admitted and scheduled exactly as before.

On each job reconcile (and whenever the profile's recommendation changes — the
job reconciler watches profiles), it compares
`job.spec.claimTemplate.spec.requestedVramBytes` against
`profile.status.recommendedVramBytes`, and if the request is lower **and**
confidence is `Medium`/`High` (never warn on a thin `Low` profile), it surfaces:

| Surface | What |
|---|---|
| Condition | `Underprovisioned=True` on the job (reason `RequestBelowRecommendation`, message naming requested vs recommended + confidence) |
| Annotation | `infrastructure.pranav2910.com/recommended-vram-bytes` on the job (machine-readable) |
| Event | `Warning`/`UnderprovisionedRequest` on the job (on the False→True transition) |
| Metric | `vgpu_workload_underprovisioned{namespace,workload}` = 1 |

Raising the request (or losing confidence) clears every surface. It **never**
blocks admission, mutates the request, changes the job phase, or touches quota/
enforcement. Hard actions — *blocking* a request below recommendation, or auto-
adjusting it — are explicitly deferred (3.7+), gated behind this advisory being
trusted. Same observe-first discipline, one more rung up.

The flow end-to-end:

```
run workload → NVML sees real peak → slice stats → profile recommends →
  re-submit with a too-low request → Underprovisioned warning (still admitted)
```

## 3.7 — recommendation enforcement (turn advice into policy)

3.6 only *advises*. 3.7 lets an operator make the recommendation a **future-request
policy**, selected by `VGPU_RECOMMENDATION_MODE` on the controller:

| mode | condition + annotation + metric | event | admission |
|---|---|---|---|
| `recommendOnly` *(default)* | ✓ | — | allow |
| `warn` | ✓ | Warning | allow |
| `requireOverride` | ✓ | Warning | **reject CREATE unless overridden** |
| `autoResize` (3.7b) | `AutoResized` cond | Normal | allow; **request raised to the recommendation** (capped at fleet max) |

`requireOverride` is enforced by a **VGPUJob validating webhook**: it rejects the
CREATE of a job whose `requestedVramBytes` is below its profile's
`recommendedVramBytes` (beyond a 10% tolerance), returning a message that names the
recommended size and the escape hatch. Two safety properties are deliberate and
load-bearing:

- **Confidence gate.** It blocks **only at `Medium`+ confidence**. A `Low`-confidence
  profile (e.g. a few observations) never blocks — early recommendations are
  directional, not authoritative.
- **Fail-open.** The webhook is `failurePolicy: Ignore` and never errors a request
  closed: a missing profile, a lookup failure, or an outage all *admit*. This is
  advisory policy, not data integrity — it must never halt job submission.

Escape hatch — run undersized on purpose:

```yaml
metadata:
  annotations:
    infrastructure.pranav2910.com/override-recommendation: "true"
```

The controller then stamps the `Underprovisioned` condition with reason
`RequestBelowRecommendationOverridden` (and emits no event — it was the user's
explicit choice). `autoResize` (mutate the request up) and a hard `block` (no
override path) are intentionally **not** built yet.

`autoResize` (3.7b) goes further: a **mutating** VGPUJob webhook raises an
under-provisioned request to the recommendation at CREATE (capped at fleet max),
stamping audit annotations (`original-vram-bytes`, `autoresized-vram-bytes`) that
the controller turns into an `AutoResized` / `AutoResizeCapped` condition + event.
It never shrinks, never overrides an override, and is fail-open. See
[recommendation-policy.md](recommendation-policy.md).

Validate on kind (no GPU — this is admission logic):
`scripts/validate-recommendation-3.7-kind.sh` exercises the reject/override/
Low-confidence gate (5/5); `scripts/validate-recommendation-3.7b-kind.sh` exercises
autoResize raise/override/Low/capped + audit (11/11). The decision matrices and
fail-open are also unit-tested (`internal/recommendation`, `internal/webhook`).

## Deployment & validation

The new CRD ships in `deployments/manifests/crds/`; the controller RBAC gains
`vgpuworkloadprofiles` (+`/status`), and the slice CRD schema gains the runtime-
stat fields (a structural schema prunes unknown fields, so they must be declared).
The node agent already has `vgpuslices/status` write.

Validation:
- **Pure math** — `RecommendedVRAMBytes` and `Confidence` (headroom, thresholds,
  peak-stability gate).
- **Controller aggregation** — recommendation + `Underprovisioned`; confidence
  rising to `High` only after the peak stabilizes; **multi-slice** roll-up (peak =
  max, counts summed, other jobs excluded); the profile **surviving** its slices
  disappearing (cross-run persistence); peak **monotonicity** (a later lower
  observation never lowers the recommendation).
- **Node agent** — observed stats flushed to the slice status on peak growth, and
  violation onsets counted after a flush.
- **3.6 advisory** — fires only when underprovisioned *and* confident; stays quiet
  when the request is adequate, confidence is `Low`, or no profile exists; clears
  when the request is raised; and never changes the job phase (non-blocking).
- **Hardware (A10)** — `scripts/validate-runtime-3.5-a10.sh` runs the whole loop on
  real NVML: it deploys the controller in **minimal mode**
  (`VGPU_DISABLE_WEBHOOKS=true` → no cert-manager) and a workload that over-uses a
  2 GiB grant, then asserts the slice carries real-NVML peak stats, the
  `VGPUWorkloadProfile` recommends > requested at Medium/High confidence, and the
  job's `Underprovisioned` advisory fires while the pod keeps **Running**. The
  node agent's observation interval is configurable (`VGPU_OBSERVE_INTERVAL`) so
  confidence ramps in minutes.
