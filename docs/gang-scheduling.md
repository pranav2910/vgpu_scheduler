# Gang scheduling: guarantees and design

A **gang** is a set of GPU slices that must be scheduled all-or-nothing: a
distributed training job with N workers makes no progress with N−1 GPUs, so
admitting a partial gang wastes the capacity it holds. This document describes
what the scheduler guarantees for gangs, how it achieves those guarantees under
contention, and the limits of the current implementation.

The headline property is **atomic gang scheduling under contention**: when more
gangs are submitted than the cluster can hold, the scheduler admits a maximal
set of whole gangs and never strands capacity behind half-formed ones.

## The four guarantees

1. **Safety — no over-admission.** The sum of committed slice VRAM never
   exceeds a node's capacity. A gang only commits once every member holds a
   confirmed reservation. This holds across scheduler restarts (the cache is
   re-seeded from bound slices before scheduling resumes) and controller
   crashes (the reservation state machine is idempotent).

2. **Atomicity — all or nothing.** A gang's slices are reserved speculatively
   and either *all* transition to committed together or the whole reservation
   rolls back. There is no observable state where some members are bound and the
   gang is then abandoned with the rest unschedulable.

3. **Liveness — make progress when capacity exists.** Under stable capacity, if
   some subset of the pending gangs would fit, the scheduler admits whole gangs
   from that subset rather than deadlocking with every gang holding a fragment.
   This is the property the *serialized admission gate* (below) exists to
   protect.

4. **Explainability — say why a gang waits.** A gang that cannot be admitted
   surfaces a reason rather than silently pending: which gang is ahead of it,
   or that it has been backed off as un-assemblable.

## How a gang is scheduled

The flow spans three components:

- **Controller** (`VGPUGangJob` reconciler) fans a gang job out into N child
  `VGPUJob`s and one `VGPUGangReservation`, denormalizing `gangSize` and the
  gang's `priority` onto the children so the scheduler can read them cheaply.
- **Scheduler** runs the per-slice pipeline: Filter → Score → Reserve (take a
  *speculative* hold in the in-memory VRAM cache) → **gang gate** → Bind →
  Confirm (promote the hold to committed).
- **Cache** (`internal/scheduler/cache.go`) tracks three tiers per slice:
  *assumed* (speculative hold), *confirmed* (bound), and *allocated*
  (node-agent-acknowledged). A TTL reaper releases assumed holds that are never
  confirmed.

The reservation state machine is `Pending → Reserving → Reserved → Committed`,
with terminal `Failed` / `Released`. See the `VGPUGangReservation` type for the
authoritative transitions.

## Serialized admission (the liveness fix)

A naive gate lets every contending gang hold its speculative reservations at
once. Under contention this **fragments capacity**: with 80 GiB free and five
4×10 GiB gangs submitted at once, each gang can grab a sub-quorum of slices,
none reaches quorum, and the cluster under-packs — it commits *one* gang (or
zero) when it should commit *two*. The result is safe (no over-admission) but
not live.

The fix gives the gate (`GangBindingGate`, `internal/scheduler/gang.go`) a
single **admission slot**:

- Only the gang currently holding the slot (the *admitting* gang) may keep
  cache reservations. Its own siblings get `GangBindDeferred` — hold and wait
  for quorum.
- Every *other* contending gang gets `GangBindWait`: the caller releases that
  slice's speculative reservation immediately. Non-admitted gangs therefore
  hold **zero** capacity and cannot fragment it.
- When the slot is free it is claimed by the **head** of the contending set,
  ordered **priority desc → age asc → name asc** (`pickAdmissionHeadLocked`).
  Priority and age ride the slice as the `gang.vgpu.pranav2910.com/priority`
  annotation, so head selection needs no API call on the hot path.
- Admission is **sticky**: once a gang claims the slot it keeps it until it
  reaches quorum (commit, slot frees) or stalls. A late-arriving higher-priority
  gang does *not* preempt an in-flight assembly — priority orders the slot only
  while it is free, which avoids orphaning the partial holds of a gang that was
  about to complete.

So the gangs commit one at a time, each fully assembling before the next holds
any capacity. Five 4×10 GiB gangs into 80 GiB commit exactly two, with the
remaining three failing on their reservation deadline — deterministically,
not probabilistically.

### Not letting an impossible gang starve the rest

If the admitting gang cannot assemble — e.g. it needs more capacity than is
free — it would otherwise hold the slot forever. Two mechanisms bound this:

- **Stall timeout** (`gangAdmissionTimeout`, 20s): if the admitting gang holds
  the slot this long without reaching quorum, the gate assumes it cannot
  assemble right now, frees the slot, and puts the gang in **backoff**.
- **Backoff** (`gangAdmissionBackoff`, 15s): a stalled gang is skipped for slot
  selection for this window, giving other contenders a clear run. After it
  elapses the gang is eligible again. A genuinely un-assemblable gang therefore
  *cycles* — claim → stall → back off → let others through → retry — rather
  than blocking the cluster, until its reservation deadline fails it outright.

The slot is also freed immediately (no timeout wait) when the admitting gang's
reservation goes terminal (`forgetCohort`) or its cohort is reaped as stale
(`gateMaxHoldAge`, 90s).

## Explainability

- **Per-slice, in the gate logs:** `[gang] <slice> waiting: gang <X> admitting
  first` (this gang is behind another), `[gang] <slice> deferred ... (HOLDING
  reservation)` (admitted, waiting for siblings), `[gang] admitting gang <X>
  stalled ... backing off` (an un-assemblable gang yielding the slot).
- **Topology placement, on the slice:** the `TopologyPreferenceSatisfied`
  condition records `PreferredZoneHonored` or `TopologyPreferenceMiss` with the
  zone that was actually chosen (Phase 2.5).

## Tunables

| Constant | Default | Meaning |
|---|---|---|
| `gangAdmissionTimeout` | 20s | Max time the admitting gang may hold the slot without quorum before it is backed off. |
| `gangAdmissionBackoff` | 15s | How long a stalled gang is skipped for slot selection. |
| `gateMaxHoldAge` | 90s | A half-formed cohort older than this is reaped. |

Invariant on the timeouts: `gangAdmissionTimeout` < the gang reservation
deadline, so the slot recycles several times before any one gang's reservation
fails. `gateMaxHoldAge` > the slice reservation TTL, so the cache reaper, not
the gate, owns capacity release.

## Known limits

- **Single scheduler instance.** The gate's admission slot is in-memory and
  per-process. Correctness depends on a single active scheduler — guaranteed
  today by leader election (one active replica). A future active-active design
  would need the slot to move to a shared store (a lease or a CRD field).
- **Priority is best-effort, not strict preemption.** Priority orders the slot
  only when it is free; an in-flight lower-priority assembly is never preempted.
  A high-priority gang submitted mid-assembly waits at most one
  `gangAdmissionTimeout` for the slot. Strict priority preemption of in-flight
  gangs is out of scope.
- **Node-level topology only.** Zone awareness (Phase 2.5) models one GPU per
  node and expresses a *soft* preference; there is no intra-node NVLink-domain
  packing yet.
- **Throughput vs. determinism.** Serialized admission trades a little
  scheduling throughput under heavy contention (gangs assemble one at a time)
  for deterministic packing. This is the right trade for gang workloads, where a
  fragmented half-gang is pure waste.
