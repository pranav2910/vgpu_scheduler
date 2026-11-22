# Security — the honest blast radius

This is the complete security posture: what each component can touch, what data
is collected, what leaves your cluster (nothing), and where the sharp edges are.
**Verify it live at any time** — the printout below is checked against your
cluster's actual RBAC, so the docs cannot silently drift from reality:

```sh
vgpu security audit
```

---

## 1. Scope: what this system is — and is not

- **Fit for:** trusted, single-tenant Kubernetes GPU clusters (one org's teams
  sharing GPUs they own).
- **NOT a hostile-multi-tenant boundary.** VRAM isolation is **soft
  governance** (observe → warn → opt-in evict → right-size), not hardware
  memory-fencing. Two slices on one card are not fenced from each other.
  MIG-backed hard isolation is roadmap, not shipped.

## 2. Monitor mode (the read-only wedge)

| Question | Answer |
|---|---|
| Mutates pods? | **No** |
| Evicts pods? | **No** |
| Creates CRDs? | **No** |
| Replaces your scheduler? | **No** — runs beside K8s/KAI/Volcano/Run:ai/Slurm |
| External egress? | **None.** It talks only to the kubelet-local NVML and the K8s API; metrics are scraped *from* it |
| Kubernetes RBAC | **Exactly** `pods: get, list, watch` — one ClusterRole, no write/impersonate/escalate/bind verbs anywhere |
| Data collected | pod name/namespace/node, GPU UUID, requested + used VRAM bytes. **Never** Secrets, env values, or workload payloads |

**The honest caveat — say it before a customer asks:** the agent pod runs
`privileged` + `hostPID` with `/dev` mounted, because NVML and PID→pod
attribution require it. That makes the **agent container node-root**.
"Read-only" is a statement about your *cluster* (the RBAC), not about the
process's host privileges — the same trade every GPU telemetry agent (e.g.
DCGM exporter) makes. Review `deployments/monitor/monitor.yaml`; it is ~120
lines on purpose.

## 3. Full stack permissions matrix

| Component | Runs as | Host access | K8s writes | Notes |
|---|---|---|---|---|
| Scheduler ×2 | distroless, `runAsNonRoot`, no caps, RO rootfs, seccomp | none | vGPU CRDs (status/bind), leases | leader-elected; warm-up gate before Ready |
| Controller ×2 | distroless, `runAsNonRoot`, no caps, RO rootfs, seccomp | none | vGPU CRDs, owned Pods, events, leases | admission webhooks (see §4) |
| Node agent (DaemonSet) | **privileged**, `hostPID` | NVML, `/dev`, CDI dir, checkpoint dir | slice status, pod labels/annotations, opt-in Eviction API | node-root on GPU nodes — required for the data plane |
| Monitor (DaemonSet) | **privileged**, `hostPID` | NVML, `/dev` | **none** | §2 |

RBAC sources of truth: `deployments/manifests/rbac/` and the monitor manifest.
No role anywhere carries `secrets` access, wildcards, `impersonate`, `escalate`,
or `bind`.

## 4. Admission webhooks

- **Mutating (pods):** injects the GPU device **only** into pods carrying the
  `vgpu-claim` label — it cannot touch any other pod. Mutating (VGPUJob):
  `autoResize` may raise an under-provisioned request (audited via annotations
  + condition; never shrinks; honors the override annotation).
- **Validating:** VRAM bounds, immutability, gang invariants — `failurePolicy:
  Fail` (fail-closed). The advisory `requireOverride` policy is deliberately
  fail-open (`Ignore`) — do not treat it as a hard quota.

## 5. Enforcement safety rails

- Default is **softwarn**: detect → attribute → label/annotate → event. Nothing
  is evicted, throttled, or failed.
- Eviction is **opt-in** (`VGPU_ENFORCEMENT_MODE=evict`), goes through the
  **PDB-respecting Eviction API** (never a raw delete), is rate-limited per
  node, and is exemptible **only by a namespace label** — a workload cannot
  self-exempt by labeling its own pod (closed as an audit finding).

## 6. Data collection & support bundles

`vgpu support-bundle` collects: versions, node lists, events, vGPU workload
YAML + logs, monitor metrics. It **never reads Secret objects**, and env values
matching password/token/key patterns are `[REDACTED]` before archiving. Review
the tarball before sending it anywhere — it is plain files.

## 7. Threat model (summary)

- **In scope:** protecting the cluster from accidental over-admission, capacity
  leaks, and the platform's own components misbehaving; least-privilege RBAC;
  no committed secrets; supply-chain gates (gofmt/vet/tests/govulncheck in CI;
  images pinned to a patched toolchain).
- **Out of scope (today):** hostile co-tenants on the same GPU (soft
  isolation), a compromised node agent (it is node-root by requirement), and
  Byzantine kubelets. Defense-in-depth that IS present: CDI teardown validates
  AllocationIDs against a strict allowlist before touching host paths;
  checkpoint writes are atomic; kubeconfigs are created mode 600.

## 8. Uninstall

- Monitor: `vgpu uninstall monitor` — deletes all five resources **including
  the cluster-scoped ClusterRole/Binding** (a naive namespace-delete orphans
  them), waits for namespace termination, and **verifies** nothing is left.
  Your workloads are never touched (validated on hardware).
- Full stack: `make uninstall` (control plane, keeps CRDs) or `make undeploy`
  (complete removal — deletes CRDs and therefore all vGPU custom resources).

## 9. Reporting a vulnerability

Open a GitHub security advisory on the repository, or email the maintainer.
Please do not open public issues for exploitable problems.
