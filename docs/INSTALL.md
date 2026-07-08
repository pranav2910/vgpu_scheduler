# Install — pick your path

One page, five paths. Find your row, follow one link. Every other page in `docs/`
is a deep-dive; this is the map.

| You are | You want | Go to |
|---|---|---|
| **ML engineer** | run jobs on a cluster that already has vGPU | [1. Just the CLI](#1-just-the-cli--no-repo-no-build) |
| **Platform engineer** | see GPU waste — change *nothing* about scheduling | [2. Read-only monitor](#2-read-only-monitor-the-15-minute-pilot) |
| **Platform engineer** | the full platform on **one** GPU node | [3. Full platform, single node](#3-full-platform-single-gpu-node) |
| **Platform engineer** | several GPU boxes as **one** cluster | [4. Multi-node cluster](#4-multi-node-cluster) |
| **Contributor** | hack on it locally, no GPU | [5. Local dev on kind](#5-local-dev-on-kind-no-gpu) |

---

## 1. Just the CLI — no repo, no build

```sh
curl -sSL https://github.com/pranav2910/vgpu_scheduler/releases/latest/download/vgpu \
  -o /usr/local/bin/vgpu && chmod +x /usr/local/bin/vgpu
vgpu version        # works offline; cluster commands need only kubectl + a kubeconfig
```

A single zero-dependency file (bash around `kubectl`), published with a sha256 on
every release. Then: **[QUICKSTART.md](QUICKSTART.md)** (run + right-size a job in
5 minutes) and **[USER-GUIDE.md](USER-GUIDE.md)** (the full manual).

## 2. Read-only monitor (the 15-minute pilot)

Watches **requested-vs-actual** VRAM per pod beside *any* scheduler (vanilla, KAI,
Volcano, Run:ai). RBAC is list/watch pods — nothing else. No CRDs, no mutation.

```sh
# a. get the agent image onto your GPU node(s) — build+push to your registry,
#    or build+import on k3s (exact commands: PILOT.md → Prerequisites)
# b. then:
vgpu install monitor        # applies the manifest (repo checkout or GitHub raw)
vgpu doctor                 # names any problem AND its fix
vgpu report --price-per-gpu-hour 3.00
```

Deep-dives: **[monitor-mode.md](monitor-mode.md)** (what it reads, honest blast
radius) · **[PILOT.md](PILOT.md)** (the full 15-minute pilot incl. Grafana).

## 3. Full platform, single GPU node

Scheduler + controller + webhooks + node agent on one GPU box, from scratch —
one script, idempotent, ~5 minutes. Validated on H100, A10, A100, V100 (any
NVIDIA data-center GPU with the standard driver).

```sh
git clone https://github.com/pranav2910/vgpu_scheduler.git && cd vgpu_scheduler
bash scripts/h100-control-plane.sh        # name is historical — GPU-agnostic
```

Deep-dive: **[INSTALL-H100.md](INSTALL-H100.md)** (prereqs, validation, packing proof).

## 4. Multi-node cluster

Several GPU boxes joined into one vGPU cluster: cross-node spread, gangs atomic
across machines, node-loss handling. Certified end-to-end (CERT-18, one scripted
run: gang spanning 3 nodes, node kill/return, true network partition with no
split-brain — [CERT-18-MULTINODE-REPORT.md](CERT-18-MULTINODE-REPORT.md)).

```sh
# server box:
git clone https://github.com/pranav2910/vgpu_scheduler.git && cd vgpu_scheduler
bash scripts/multinode-server.sh          # prints K3S_URL/K3S_TOKEN + agent command
# every other box: export those, then
bash scripts/multinode-agent.sh
```

Deep-dive: **[INSTALL-MULTINODE.md](INSTALL-MULTINODE.md)** (ports, capacity
advertisement, node-recovery, validation).

## 5. Local dev on kind (no GPU)

```sh
scripts/setup-kind-cluster.sh     # kind + cert-manager + CRDs + all deployments
bash real_world_test.sh           # the validation battery (mock GPU capacity)
```

## Uninstall

```sh
vgpu uninstall monitor            # verified-complete removal incl. cluster RBAC
kubectl delete vgpujob --all      # workloads (cascades: claims → slices → pods)
/usr/local/bin/k3s-uninstall.sh   # tear down a script-installed k3s node entirely
```

---

**Why do paths 2–4 need a repo checkout?** Cluster images are built from source
today. Versioned registry images + a Helm chart (`monitor` and `full` profiles)
are the next packaging milestone — when they land, those paths collapse to a
one-line `helm install`. The CLI (path 1) already needs nothing.
