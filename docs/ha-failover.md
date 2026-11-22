# High availability & failover

The scheduler and controller run **active/standby**: two replicas each, one
holding a Kubernetes lease (the leader) and doing all the work, one hot standby
ready to take over. This is the minimum real HA story — failover does not wait
for a new pod to be scheduled and image-pulled.

Active-active scheduling and any external/shared scheduler-state store are
explicitly **out of scope** (see [Limits](#limits)). All recovered truth comes
from Kubernetes objects (CRDs + leases), never from a side database.

## Components

| | Replicas | Leader-elected | Lease |
|---|---|---|---|
| Scheduler | 2 | yes | `vgpu-scheduler-lock` |
| Controller | 2 | yes | `vgpu-controller-lock` |

Leader election uses controller-runtime's lease-based election with
`LeaderElectionReleaseOnCancel: true`, so a graceful shutdown releases the lease
immediately rather than making the standby wait out the full lease duration.

Only the leader runs reconcilers and the scheduler's in-memory cache warm-up.
The controller additionally serves its admission **webhook on both replicas** —
the webhook Service load-balances across them, so webhook availability survives a
single pod loss independent of who holds the lease.

## Health vs. readiness

The two probes mean different things — readiness is **not** "the process is up":

| Probe | Port | Meaning |
|---|---|---|
| `/healthz` | 8082 | Process is alive. Fails → kubelet restarts the pod. |
| `/readyz` | 8082 | Safe to hold scheduling responsibility. |

Scheduler `/readyz` logic:

- **Leader:** Ready only once the cache warm-up has completed (`IsSeeded()`).
  A freshly promoted leader is **NotReady** until it has re-accounted every
  already-bound slice — the same warm-up that prevents over-admission. This is
  the failover safety gate made observable.
- **Standby (not leader):** Ready. It is healthy and ready to take over.
  Gating standby readiness on leadership would leave it permanently NotReady,
  which would break Deployment availability and rolling updates.

The controller has no in-memory warm-up to gate on (it rebuilds purely from
CRDs), and must keep serving webhooks on every replica, so its `/readyz`
tracks liveness.

## What happens on failover

1. The leader dies (crash, evict, node loss, or `SIGTERM` during a rollout).
2. On graceful shutdown it releases the lease; on a hard kill the lease simply
   expires. The standby acquires the lease (seconds, or up to one lease
   duration on a hard kill).
3. The new leader starts its reconcilers and runs cache warm-up: it lists nodes
   for capacity and **re-accounts the VRAM of every already-bound slice** before
   it will place anything (`Schedule()` returns `CacheNotReadyError` until
   `IsSeeded()`). During this window it is NotReady.
4. Warm-up completes → cache reflects true consumption → the leader is Ready and
   resumes scheduling. `vgpu_scheduler_leader_active` flips 0→1 on the new
   leader and the old leader's series disappears with its pod.

Because the new leader reconstructs consumption before scheduling, a cold-cache
takeover **cannot over-admit** into capacity that is already occupied.

## Graceful shutdown (SIGTERM)

The manager handles `SIGTERM` (via `SetupSignalHandler`): stop dequeuing new
work, let in-flight reconciles finish or abandon safely, release the lease,
exit. No attempt is made to "clean everything up" on the way out — the next
leader rebuilds truth from Kubernetes objects and reservations. Pods set
`terminationGracePeriodSeconds: 30` to give this time before `SIGKILL`.

## Disruption protection

- **PodDisruptionBudget** `minAvailable: 1` on each component — a voluntary
  disruption (node drain, cluster upgrade) can never take out both replicas at
  once.
- **Pod anti-affinity** (preferred, by `kubernetes.io/hostname`) spreads the two
  replicas across nodes so one node failure can't drop both. Preferred (not
  required) so a single-node dev/test cluster can still run both.

## Failover invariants (tested)

Test `2.8` in `real_world_test.sh` kills the active scheduler leader while the
cluster is full (two gangs = 80 GiB) with a third gang waiting, and asserts:

1. **No over-admission** — committed VRAM never exceeds node capacity; the new
   cold-cache leader does not admit the waiting gang into occupied capacity.
2. **No duplicate binds** — Ready-slice count and committed bytes stay exactly
   consistent across the failover.
3. **No stuck gang reservations** — the surviving gangs stay Running, and after
   capacity is freed the new leader schedules the waiting gang (proving it is
   fully functional, not wedged).
4. **Warm-up before Ready** — the new leader reports
   `vgpu_scheduler_cache_warmup_complete=1` before `/readyz` succeeds.
5. **Clean `leader_active` transfer** — exactly one leader before and after;
   the metric moves from the killed leader to the standby.

## Limits

- **Single active leader.** The gang admission slot and cohort state are
  in-memory and per-process. On failover the new leader rebuilds them from the
  reservations (safe), but there is no live hand-off of in-flight admission
  state. This is acceptable because correctness is reconstructed from CRDs.
- **No active-active**, no external/shared scheduler-state store, no etcd-side
  locking beyond Kubernetes leases, no multi-cluster HA. These are future work.
