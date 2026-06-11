#!/usr/bin/env bash
# Deploy the FULL vGPU control plane on a real GPU node (e.g. an H100), so the
# complete submit flow works end to end with no manual wiring:
#
#   vgpu submit -> VGPUJob -> VGPUClaim -> VGPUSlice -> scheduler placement
#   -> node-agent CDI allocation -> webhook auto-injects the GPU -> pod runs
#
# On top of the NVML node agent it adds exactly what that doesn't: the node's
# vGPU VRAM capacity, cert-manager + admission webhooks, the controller (with
# webhooks), and the scheduler. Idempotent; runs the node-agent base itself if
# it isn't up yet.
#
#   git clone <repo> && cd vgpu_scheduler
#   bash scripts/h100-control-plane.sh
#   # then submit a workload:
#   scripts/vgpu submit --name demo --vram 16Gi \
#     --image nvidia/cuda:12.4.1-base-ubuntu22.04 \
#     --command 'nvidia-smi -L; sleep 3600' --runtime-class nvidia
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NS=vgpu-system
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
VGPU_RESOURCE="infrastructure.pranav2910.com/vgpu-bytes"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_RST=$'\033[0m'
say() { echo; echo "── $* ──"; }
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; }
die() { echo "  ${C_RED}✗ $*${C_RST}" >&2; exit 1; }

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found — this targets a real GPU node"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

# ── 0. base: the NVML node agent. On a FRESH box (no k3s/kubectl yet) OR if the
#         node agent is absent, run the base bootstrap first — it installs k3s
#         (which provides kubectl) + the NVML node agent. GPU-agnostic.
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl -n "$NS" get daemonset vgpu-nodeagent >/dev/null 2>&1; then
    say "base stack not found — running scripts/a10-bootstrap.sh (k3s + NVML node agent; GPU-agnostic)"
    bash scripts/a10-bootstrap.sh || die "base bootstrap failed"
    hash -r 2>/dev/null || true   # refresh PATH so the just-installed kubectl is found
fi
command -v kubectl >/dev/null 2>&1 || die "kubectl not found even after the base bootstrap"
NODE=$(kubectl -n "$NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
[[ -z "$NODE" ]] && die "no node agent pod — the base bootstrap may have failed"
ok "node agent on $NODE"

# ── 0b. ALWAYS (re)apply CRDs + RBAC, even when the base bootstrap was skipped
#         (box already had the node agent). Otherwise re-running this script picks
#         up new controller code but NOT new CRD fields (e.g. spec.podTemplate,
#         which the API server would prune) or new RBAC (e.g. pods create/delete).
say "sync CRDs + RBAC (idempotent — picks up schema/permission changes)"
kubectl apply -f deployments/manifests/crds/ >/dev/null || die "applying CRDs failed"
kubectl apply -f deployments/manifests/rbac/ >/dev/null || die "applying RBAC failed"
ok "CRDs + RBAC applied"

# ── 1. advertise the node's vGPU capacity (the scheduler schedules against this) ─
say "advertise node vGPU capacity"
# SUM across all GPUs (M-GPU: a node advertises the total of its healthy
# cards — `head -1` advertised only device 0, stranding every other card on a
# multi-GPU box). Card-level fit is enforced by the allocator's best-fit +
# fragmentation fail-loud; this figure is the node-pooled scheduler's view.
total_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {printf "%d", s}')
[[ -n "$total_mib" && "$total_mib" -gt 0 ]] || die "could not read GPU memory from nvidia-smi"
CAP="${VGPU_CAPACITY:-$(( total_mib * 1024 * 1024 ))}"
kubectl patch node "$NODE" --subresource=status --type=merge \
    -p "{\"status\":{\"capacity\":{\"${VGPU_RESOURCE}\":\"${CAP}\"},\"allocatable\":{\"${VGPU_RESOURCE}\":\"${CAP}\"}}}" >/dev/null \
    || die "advertising node capacity failed"
ok "node $NODE advertises ${VGPU_RESOURCE}=${CAP} ($(( CAP >> 30 )) GiB)"

# ── 2. cert-manager (admission webhooks need TLS) ────────────────────────────
say "cert-manager ($CERT_MANAGER_VERSION)"
if ! kubectl get deploy -n cert-manager cert-manager-webhook >/dev/null 2>&1; then
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null \
        || die "applying cert-manager failed"
fi
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment --all >/dev/null 2>&1 \
    || die "cert-manager did not become Available"
ok "cert-manager ready"

# ── 3. webhook cert (self-signed issuer) + Service + Mutating/Validating configs ─
say "admission webhooks"
kubectl apply -f deployments/manifests/webhooks/ >/dev/null || die "applying webhooks failed"
echo "  waiting for cert-manager to issue the webhook TLS secret..."
for i in $(seq 1 90); do
    kubectl -n "$NS" get secret vgpu-controller-webhook-cert >/dev/null 2>&1 && break
    sleep 2
done
kubectl -n "$NS" get secret vgpu-controller-webhook-cert >/dev/null 2>&1 \
    || die "webhook TLS secret (vgpu-controller-webhook-cert) was not issued"
ok "webhook Certificate + Service + configs applied; TLS secret issued"

# ── 4. build + import the controller + scheduler images ──────────────────────
say "build + import controller + scheduler"
$DOCKER build --provenance=false -t vgpu-controller:latest -f Dockerfile.controller . >/dev/null || die "controller build failed"
$DOCKER build --provenance=false -t vgpu-scheduler:latest  -f Dockerfile.scheduler  . >/dev/null || die "scheduler build failed"
$DOCKER save vgpu-controller:latest | sudo k3s ctr images import - >/dev/null || die "controller image import failed"
$DOCKER save vgpu-scheduler:latest  | sudo k3s ctr images import - >/dev/null || die "scheduler image import failed"
ok "images built + imported into k3s"

# ── 5. deploy the controller (with webhooks) + the scheduler ─────────────────
say "deploy controller + scheduler"
kubectl apply -f deployments/manifests/controller_deployment.yaml >/dev/null || die "controller deploy failed"
kubectl apply -f deployments/manifests/scheduler_deployment.yaml  >/dev/null || die "scheduler deploy failed"
kubectl -n "$NS" rollout restart deployment/vgpu-controller deployment/vgpu-scheduler >/dev/null 2>&1 || true
kubectl -n "$NS" rollout status deployment/vgpu-controller --timeout=180s \
    || { kubectl -n "$NS" logs deploy/vgpu-controller --tail=30 2>/dev/null; die "controller not ready"; }
kubectl -n "$NS" rollout status deployment/vgpu-scheduler  --timeout=180s \
    || { kubectl -n "$NS" logs deploy/vgpu-scheduler  --tail=30 2>/dev/null; die "scheduler not ready"; }
ok "controller + scheduler running"

say "control plane up"
cat <<EOF
  The full vGPU control plane is deployed on $NODE.

  Submit a workload — ONE command, auto-runs on a shared GPU:

      scripts/vgpu submit --name demo --vram 16Gi \\
        --image nvidia/cuda:12.4.1-base-ubuntu22.04 \\
        --command 'nvidia-smi -L; sleep 3600' --runtime-class nvidia
      scripts/vgpu status  demo
      scripts/vgpu profile demo

  Or run the automated end-to-end proof:

      bash scripts/validate-submit-flow-h100.sh
EOF
