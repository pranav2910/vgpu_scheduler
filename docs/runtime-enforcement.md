# Runtime VRAM over-use detection & enforcement (Phase 3.4)

VRAM-slicing only holds if workloads actually stay within the VRAM they were
granted. Phase 3.4 closes that loop — but deliberately, in stages, so nothing is
ever evicted on untrusted accounting:

```
3.4a  detect node-level over-use            ✅ observe-only
3.4b  attribute + mark the slice Violating  ✅ observe-and-mark only
3.4c  soft enforcement (warn / annotate)    ✅ non-destructive
3.4d  opt-in eviction (reclaim VRAM)        ✅ destructive, opt-in   ← HERE
3.4e  MIG-backed hard partitioning
```

Everything through 3.4c is **non-destructive**, and that is still the **default**:
the chain makes over-use visible and auditable (metrics, Events, CRD status) and
surfaces an enforcement *decision* on the offending pod, but touches nothing
running. 3.4d adds the *option* to act — evicting a pod that stays over-budget
past a deadline — but only when an operator explicitly turns it on. The default
(`softwarn`) never evicts. True per-process VRAM partitioning (so a workload
*cannot* exceed its slice) needs MIG and is 3.4e.

## 3.4a — node-level over-use detection (current)

The node agent's observation loop gains a detector. Each cycle, per healthy GPU:

- `granted` = Σ `RequestedVRAMBytes` of slices bound to this node and active
  (nodeName set, phase not Pending/Released/Failed). One GPU per node, so the
  node's grants are that GPU's budget.
- `actual` = the GPU's observed **process-used** VRAM (NVML v2 — excludes
  driver `reserved`; this is why the v2 split mattered).
- `overuse = max(0, actual − granted)`.

A GPU is flagged **only** when `overuse` exceeds a tolerance for several
consecutive cycles (hysteresis — no flapping on transient allocation spikes).

### Surfaced as

| Channel | What |
|---|---|
| Metric | `vgpu_node_memory_overuse_bytes{node, gpu_uuid}` — current over-budget bytes |
| Metric | `vgpu_node_memory_violation_active{node, gpu_uuid}` — 1 while sustained |
| Event | `Warning` / `MemoryViolation` on the **Node**: *"Observed GPU … memory usage exceeded granted VRAM by X MiB for ~Ys (observe-only)"* |

So an operator sees it three ways: Prometheus (alerting), `kubectl get events`
(Kubernetes-native), and the gauge (dashboards) — without any workload impact.

### Tunables (`internal/nodeagent/violation.go`)

| Constant | Default | Meaning |
|---|---|---|
| `overuseToleranceBytes` | 256 MiB | slack before over-budget counts (absorbs noise) |
| `overuseStreakThreshold` | 3 cycles | consecutive over-budget cycles before flagging |
| detector interval | 30s | how often detection runs |

### Explicitly NOT done in 3.4a

No eviction, no throttling, no CRD changes to slices, no per-slice attribution.
A node-level flag says *that* a node is over-subscribed in reality, not yet
*which* workload — that's 3.4b.

## 3.4b — per-slice attribution + mark `Violating` (current)

Now over-use is attributed to the *exact slice* and marked Kubernetes-natively.

**Attribution chain** (no new CRD field — reuses existing contracts):

```
GPU process (NVML) → PID → pod (/proc/<pid>/cgroup) → claim-ref annotation → VGPUSlice (matching ClaimRef)
```

- `nvmlDeviceGetComputeRunningProcesses` / `GetGraphicsRunningProcesses` →
  `(host pid, usedMem)` per GPU.
- `pid → pod UID` by parsing `/proc/<pid>/cgroup` (cgroup v1/v2, systemd &
  cgroupfs drivers). Requires `hostPID: true` so NVML's host PIDs are readable.
- `pod → slice`: the pod carries `infrastructure.pranav2910.com/claim-ref`
  (stamped by the mutating webhook); the slice's `spec.claimRef` matches it.
- Each process's VRAM is summed onto its slice and compared to the slice's grant
  (same tolerance + hysteresis as 3.4a).

**Marking** — a sustained over-use gets a status **Condition**, *not* a phase
change (the slice stays `Ready`):

```yaml
status:
  conditions:
    - type: MemoryViolation
      status: "True"
      reason: ObservedGpuMemoryOveruse
      message: "Observed GPU memory usage exceeded allocated VRAM by 512 MiB for ~90s (observe-only, no eviction)"
```

A summary `MemoryViolation` condition (reason `ChildSliceViolation`) is mirrored
onto the parent `VGPUJob`. Per-slice metrics gain attribution labels —
`vgpu_memory_violation_active{node,namespace,slice}`,
`vgpu_memory_violation_excess_bytes{node,namespace,slice}`,
`vgpu_memory_violations_total{node,namespace,slice,reason}` — and a
`Warning`/`MemoryViolation` Event is emitted on the slice. So an operator sees
the offending slice via `kubectl describe vgpuslice`, `kubectl get events`, and
Prometheus.

Marking ≠ termination: a violating slice is `Ready + MemoryViolation=True`, never
`Failed`. The condition is the hook enforcement (3.4c+) will later act on.

**Deployment**: the NVML node agent (`nodeagent_daemonset_nvml.yaml`) sets
`hostPID: true`; RBAC grants `pods:list` + `vgpuclaims/vgpujobs:get` +
`vgpujobs/status`. The default (fake) build has no real GPU processes, so it
attributes nothing — no false positives on kind.

**Validation**: the full attribution + marking logic is unit-tested
deterministically (synthetic `/proc` cgroups, fake pods/slices, stub provider).
The two hardware-only reads — real `/proc/<pid>/cgroup` and NVML process
listing — get their E2E proof on a real GPU node via
`scripts/validate-runtime-3.4-a10.sh`: it grants a slice 2 GiB, runs a CUDA
workload that allocates ~4 GiB, and asserts both 3.4a (node over-use) and 3.4b
(the slice's `MemoryViolation` condition + metric + Event) fire against live
NVML/cgroup data. Only the node agent + CRDs are needed (no scheduler/controller).

## 3.4c — soft enforcement (warn / annotate) (current)

3.4b records over-use on *infrastructure* objects (the slice + job). 3.4c is the
first stage that *acts* on a sustained violation — but deliberately stops short
of touching the running workload. It reaches the **workload's own pod** and runs
a grace-gated decision so the pod owner (not just the cluster operator) sees the
problem and the consequence:

```
3.4b = infrastructure visibility   (kubectl describe vgpuslice)
3.4c = workload-owner visibility   (kubectl describe pod)
```

`kubectl describe pod` now shows *"this pod is exceeding its GPU-memory grant,
and this is when enforcement would happen under a future hard mode"* — without
anything being evicted.

### Enforcement mode (the policy gate)

The node agent reads `VGPU_ENFORCEMENT_MODE`:

| Mode | Behavior | Available |
|---|---|---|
| `off` | 3.4b marking only — no pod surfaces | yes |
| `softwarn` | **3.4c ceiling** — stamp pod, record decision, warn, recover | yes (**default**) |
| `evict` / `throttle` | parsed but **rejected** → falls back to `softwarn` | no (Phase 3.4d) |

`softwarn` is the default precisely because it is non-destructive. The hard modes
exist as a parsing seam only, so enabling real teeth (3.4d) is a deliberate code
change, never a one-character config edit.

### Escalation state machine

Layered on 3.4b's hysteresis, with a wall-clock grace timer:

| State | Meaning | Surfaces |
|---|---|---|
| `Clear` | within grant | none (cleared) |
| `Observed` | 3.4b violating, **within** grace | 3.4b condition only |
| `SoftWarned` | violating **past** grace | pod + slice + job + events + metrics |

The grace anchor is the moment 3.4b flags the slice (`MemoryViolation=True`); the
default `enforcementGracePeriod` is **60s**, so ~90s detect + 60s grace ≈ 150s to
`SoftWarned`.

### Surfaces

| Object | What 3.4c writes |
|---|---|
| **Pod** (new) | label `…/memory-violation=true` (selector-friendly); annotations `…/enforcement=SoftWarn`, `…/memory-excess-bytes`, `…/violation-since`, `…/enforcement-deadline`, and an explicit `…/enforcement-note` |
| **Slice** | `MemoryEnforcement` condition (`SoftWarnEngaged` ⇄ `WithinGrant`) — alongside 3.4b's `MemoryViolation` |
| **Job** | summary `MemoryEnforcement` condition (reason `ChildSliceSoftWarn`) |
| **Events** | engage → `Warning`/`MemoryEnforcementSoftWarn` on pod + slice; recover → `Normal`/`MemoryEnforcementCleared` |
| **Metrics** | `vgpu_memory_enforcement_mode{node}`; `vgpu_memory_enforcement_active{node,namespace,slice}`; `vgpu_memory_enforcement_actions_total{node,namespace,slice,mode,action}` |

> The `enforcement-deadline` is **informational** in softwarn mode — nothing is
> evicted. It marks when a future hard mode (3.4d) *would* act. The
> `enforcement-note` annotation states this verbatim so a deadline is never
> mistaken for an impending kill.

### Recovery is first-class

When the slice returns within grant, 3.4c reverses **every** surface it added:
the pod label/annotations are removed (the unrelated `claim-ref` annotation is
left intact), the slice/job `MemoryEnforcement` conditions flip to `False`, a
`Normal` event is emitted, and `vgpu_memory_enforcement_active` drops to 0. Exact
cleanup is driven by remembering which pods were stamped — not by re-deriving
them — so a workload that stopped using the GPU entirely is still un-stamped. A
startup sweep also drops any stamp left behind by a previous agent lifetime, so a
restart can never strand a label.

### Tunables (`internal/nodeagent/enforcement.go`)

| Constant | Default | Meaning |
|---|---|---|
| `enforcementGracePeriod` | 60s | how long over-use must persist *after* 3.4b flags it before soft enforcement engages |
| `VGPU_ENFORCEMENT_MODE` | `softwarn` | enforcement ceiling (`off` \| `softwarn`) |

### Explicitly NOT done in 3.4c

No pod eviction, no eviction-API call, no cgroup/MPS throttle, no MIG, no
scheduler feedback (the offender's future claims are *not* blocked), no
`phase: Failed`. A `SoftWarned` slice is still `Ready`. The pod is mutated only on
its labels/annotations — never its spec. The decision + deadline are the hook
that 3.4d will act on.

### Deployment

`VGPU_ENFORCEMENT_MODE=softwarn` is set in `nodeagent_daemonset_nvml.yaml`. RBAC
adds `pods: patch` (merge-patch of labels/annotations) on top of 3.4b's
`pods: get,list`. The default (fake) build attributes no real processes, so it
engages nothing on kind — no false positives.

**Validation**: the state machine is unit-tested deterministically with an
injected clock — within grace nothing is stamped; past grace the pod is
labeled/annotated and the slice/job carry `MemoryEnforcement=True`; on recovery
every surface (including the pod) is reversed while unrelated metadata survives;
`off` mode stamps nothing. The hardware E2E in `scripts/validate-runtime-3.4-a10.sh`
additionally asserts, against live NVML, that the over-using **pod** carries the
violation label + enforcement annotations + deadline, the `MemoryEnforcement`
condition is `True`, and — critically — the pod is **still `Running`** (soft =
non-destructive).

## 3.4d — opt-in eviction (current)

The first stage that actually *acts* on a workload. One hardware reality drives
the whole design: **a non-MIG GPU cannot cap VRAM per process** — there is no
cgroup-style memory limit for GPU memory. So "hard enforcement" of a VRAM budget
means exactly one thing — **evict the offending pod to reclaim its VRAM**.
("Throttle" applies to *compute* (MPS) and reclaims no VRAM, so it is out of
scope; true per-process VRAM caps are MIG, 3.4e.)

3.4d is therefore **grace-gated, opt-in, PDB-respecting eviction**, layered on
3.4c. It does *not* change the default — eviction only happens when an operator
sets the mode explicitly.

### Mode gate (opt-in)

`VGPU_ENFORCEMENT_MODE`: `off | softwarn | evict`. The default stays **`softwarn`**
(non-destructive). `evict` is the only value that enables eviction; `throttle` /
`hard` are rejected (they are not valid VRAM actions) and fall back to `softwarn`.

### When a pod is evicted

The 3.4c `enforcement-deadline` becomes **binding**. Timeline (defaults):

```
onset ──(60s soft grace)──▶ SoftWarned ──(120s eviction grace)──▶ Evicted
  3.4b flagged              pod labeled/warned                    pod evicted
```

So a pod is evicted only after **sustained, attributed, hysteresis-confirmed**
over-use that persisted ~270s end-to-end *and* past the soft-warn window — never
on a transient spike. If usage drops within grant before the deadline, recovery
clears everything and **nothing is evicted**.

### Safety rails (all enforced)

| Rail | Behavior |
|---|---|
| **Opt-in** | default `softwarn`; eviction only when mode is explicitly `evict` |
| **Eviction API** | uses `pods/eviction` (PDB-respecting, graceful) — **never** a raw delete or force-delete |
| **PDB-blocked** | if a PodDisruptionBudget would be violated, the pod is **not** deleted; a `MemoryEvictionBlocked` event + `vgpu_memory_evictions_blocked_total{reason="pdb"}` fire, and the slice stays marked + warned (retried next cycle) |
| **Exemption** | a pod (or its namespace) labeled `infrastructure.pranav2910.com/enforcement-exempt=true` is never evicted — still detected, marked, soft-warned |
| **Rate limit** | ≤ `maxEvictionsPerWindow` (3) evictions per node per `evictionWindow` (5 min); excess is deferred with `reason="ratelimited"` |
| **Audit** | on eviction: a `Warning`/`MemoryEnforcementEvicted` pod Event, the slice `MemoryEnforcement` condition `reason=Evicted`, a job mirror (`ChildSliceEvicted`), and `vgpu_memory_enforcement_actions_total{action="evict"}` |

The slice **grant survives** the eviction — 3.4d corrects the offending *pod*, not
the allocation. A controller-managed workload may reschedule; if the new pod
over-uses again, it is re-evaluated and (after the grace) evicted again, visibly.

### Tunables (`internal/nodeagent/enforcement.go`)

| Constant | Default | Meaning |
|---|---|---|
| `evictionGracePeriod` | 120s | additional grace after soft-warn before eviction |
| `maxEvictionsPerWindow` | 3 | per-node eviction budget |
| `evictionWindow` | 5m | rate-limit window |
| `enforcementExemptLabel` | `…/enforcement-exempt` | pod/namespace opt-out |

### Explicitly NOT done in 3.4d

No raw/force delete, no compute throttle, no MIG, no scheduler-level punishment
(the offender's *future* claims are not blocked). VRAM is reclaimed by eviction
alone.

### Deployment & validation

RBAC adds `pods/eviction: create` and `namespaces: get` (exemption) on top of
3.4c. The policy — evict-after-grace, exemption, rate limit, PDB-block-retries —
is unit-tested deterministically with an injected clock and a **stubbed evictor**
(so the rails are exercised without a live cluster). The real Eviction API call
and end-to-end reclaim are covered by the A10 evict E2E
(`scripts/validate-runtime-3.4d-a10.sh`): a slice granted 2 GiB, a 4 GiB workload,
mode `evict` → the offending pod is evicted past the deadline while an
**exempt** pod over-using the same way is **not**.
