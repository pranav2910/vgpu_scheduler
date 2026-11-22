# Pilot guide — see your GPU waste in 15 minutes

> One of the five install paths — the full map is **[INSTALL.md](INSTALL.md)**.

**The ask:** run a read-only agent on one GPU node, look at the waste report it
prints, and tell us one thing: **does the number match your suspicion?**

That's the whole pilot. No scheduler change, no workload change, no commitment.
Everything below is hardware-validated — each step ships with the test receipt
that proved it.

---

## What you get

```
Cluster GPU Waste Report  (read-only — no scheduling, no mutation, no eviction)

  WORKLOAD (ns/pod)             REQUESTED         USED        WASTE   UTIL  SOURCE
  default/vanilla-burn            23.4 GiB       6.2 GiB      17.2 GiB    27%  annotation
  default/viaclaim-workload       16.0 GiB       0.0 GiB      16.0 GiB     0%  vgpu_claim

  Top wasting pods:                          Top wasting namespaces:
    1. default/vanilla-burn  17.2 GiB          1. default  33.2 GiB

  GPU memory requested:     39.4 GiB
  GPU memory actually used:  6.2 GiB
  Estimated waste:          33.2 GiB
  Estimated waste/month:    $3,032   (at $3.00/GPU-hr)
```

*(Real output from a 1×A10 validation run — your numbers will be your own.)*
Per-workload **requested-vs-used VRAM** — the thing `kubectl top` and node-level
dashboards can't show you — plus CSV/JSON export and an optional Grafana
dashboard.

## What it is — and is not (read this first)

- **Read-only to your cluster.** The RBAC is exactly `pods: get/list/watch` —
  no write, evict, create, or delete verbs anywhere. Verify it yourself in
  60 seconds: `vgpu security audit` checks the live RBAC against this claim.
- **The agent pod is privileged** (`hostPID` + `/dev`) — required for NVML and
  PID→pod attribution, same trade as any GPU telemetry agent (DCGM etc.).
  Treat the container as node-root; details in [SECURITY.md](SECURITY.md).
- **No data leaves your cluster.** No external egress; metrics are scraped
  *from* the agent. What it reads: pod names/namespaces and GPU memory numbers.
  Never Secrets, env values, or payloads.
- The `$` figure is an **estimate** (idle-capacity × your price/hr), not
  guaranteed savings.

## Prerequisites

- A Kubernetes cluster with ≥1 NVIDIA GPU node (driver installed).
- `kubectl` access, ability to create one namespace + one DaemonSet.
- The agent image on your nodes — two options:
  - **Your registry (recommended for multi-node):** build once, push, and point
    the manifest at it:
    ```sh
    make docker-build-nodeagent-nvml
    docker tag vgpu-nodeagent:nvml <your-registry>/vgpu-nodeagent:nvml
    docker push <your-registry>/vgpu-nodeagent:nvml
    # edit deployments/monitor/monitor.yaml: image + imagePullPolicy: IfNotPresent
    ```
  - **Single node / k3s:** build and import locally:
    ```sh
    make docker-build-nodeagent-nvml
    docker save vgpu-nodeagent:nvml | sudo k3s ctr images import -
    ```

## The 15 minutes

```sh
# 0. The CLI — one file, no build (the clone below is only for the image build):
curl -fsSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu -o /tmp/vgpu \
  && sudo install -m 0755 /tmp/vgpu /usr/local/bin/vgpu && rm -f /tmp/vgpu
git clone https://github.com/pranav2910/vgpu_scheduler && cd vgpu_scheduler

# 1. Install the read-only monitor (one namespace, one DaemonSet, minimal RBAC)
vgpu install monitor

# 2. If anything is off, the doctor names the problem AND the fix
vgpu doctor

# 3. Let it observe for ~5 minutes while your normal workloads run, then:
vgpu report --price-per-gpu-hour <your $/GPU-hr>
vgpu report -o csv > waste.csv        # or -o json

# 4. (Optional) the Grafana dashboard — Prometheus discovers the agent via a
#    dedicated read-only credential (never your admin kubeconfig):
scripts/gen-prometheus-kubeconfig.sh
cd deployments && GRAFANA_ADMIN_PASSWORD=<pick-one> docker compose up -d
# open http://<host>:3000 → dashboard "vGPU — GPU waste & right-sizing"

# 5. Verify our permission claims against your live cluster
vgpu security audit

# 6. Done? Removal is verified-complete (incl. cluster-scoped RBAC) and never
#    touches your workloads:
vgpu uninstall monitor
```

If anything misbehaves: `vgpu support-bundle` produces a redacted
tarball (no Secrets are ever read) — review it, then send it with your report.

## What we ask in return (5 minutes, honestly)

1. **Does the waste number match your suspicion?** Higher, lower, about right?
2. Which line item surprised you most?
3. Would you keep the monitor running after the pilot? Why / why not?
4. If this report could *act* — right-size requests, pack workloads — would
   that be valuable enough to pay for? Roughly what would it be worth?
5. Who else (team or company) should see their number?

Send answers + the report (redact pod names if you like) to the maintainer, or
open a GitHub discussion on the repo.

## What happens with your feedback

It decides the roadmap. The scheduler/packing layer, right-sizing
recommendations, and LLM-inference VRAM sizing are built and hardware-validated
behind this monitor — what gets productized next is whatever pilots pull for.
