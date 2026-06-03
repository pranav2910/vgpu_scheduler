#!/usr/bin/env bash
# One-shot bootstrap for the Phase 3.4 real-hardware E2E on a fresh GPU node
# (Lambda A10 / Lambda Stack 22.04). Stands up the MINIMUM stack the node-agent
# detectors need and verifies the agent reads the GPU via NVML:
#
#   k3s  →  NVIDIA runtime (RuntimeClass)  →  CRDs/RBAC  →  NVML node agent
#
# Then run the validation it enables:
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   bash scripts/validate-runtime-3.4-a10.sh
#
# Idempotent — safe to re-run. Needs sudo + docker + a working nvidia-smi (all
# present on Lambda Stack). No host Go toolchain required: the agent builds in
# Docker. The node agent only OBSERVES the GPU (no device plugin needed); it gets
# driver + NVML via the nvidia RuntimeClass, the same way the GPU workload does.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_RST=$'\033[0m'
say() { echo; echo "── $* ──"; }
ok()  { echo "${C_GRN}✓${C_RST} $*"; }
die() { echo "${C_RED}✗ $*${C_RST}"; exit 1; }

AGENT_NS=vgpu-system
IMG=vgpu-nodeagent:nvml
CONTAINERD_CFG=/var/lib/rancher/k3s/agent/etc/containerd/config.toml

DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

# ── 0. preflight ─────────────────────────────────────────────────────────────
say "preflight"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found — need the NVIDIA driver (Lambda Stack provides it)"
$DOCKER info >/dev/null 2>&1 || die "docker not usable"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1
ok "GPU + docker present (docker=\"$DOCKER\")"

# ── 1. k3s ───────────────────────────────────────────────────────────────────
say "k3s (single-node)"
if ! command -v k3s >/dev/null 2>&1; then
    echo "installing k3s (kubeconfig world-readable)..."
    curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh - \
        || die "k3s install failed"
else
    ok "k3s already installed"
fi
command -v kubectl >/dev/null 2>&1 || sudo ln -sf "$(command -v k3s)" /usr/local/bin/kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for _ in $(seq 1 40); do
    kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
    sleep 3
done
kubectl get nodes 2>/dev/null | grep -q ' Ready ' || die "k3s node did not become Ready"
ok "k3s node Ready ($(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null))"

# ── 2. NVIDIA runtime for k3s containerd ─────────────────────────────────────
say "NVIDIA container runtime (k3s containerd)"
# k3s auto-detects nvidia-container-runtime at startup and registers an 'nvidia'
# containerd runtime. If not, configure it via nvidia-ctk on the k3s template.
if ! sudo grep -q 'runtimes.nvidia' "$CONTAINERD_CFG" 2>/dev/null; then
    echo "${C_YEL}k3s did not auto-detect the nvidia runtime — configuring via nvidia-ctk${C_RST}"
    command -v nvidia-ctk >/dev/null 2>&1 || die "nvidia-ctk not found — install nvidia-container-toolkit, then re-run"
    # Seed the k3s containerd template from the working config so we ADD the
    # nvidia runtime without dropping k3s's own CRI settings (k3s uses a present
    # config.toml.tmpl verbatim).
    [[ -f "${CONTAINERD_CFG}.tmpl" ]] || sudo cp "$CONTAINERD_CFG" "${CONTAINERD_CFG}.tmpl"
    sudo nvidia-ctk runtime configure --runtime=containerd --config="${CONTAINERD_CFG}.tmpl" >/dev/null 2>&1 || true
    sudo systemctl restart k3s
    for _ in $(seq 1 20); do
        sudo grep -q 'runtimes.nvidia' "$CONTAINERD_CFG" 2>/dev/null && break
        sleep 3
    done
fi
sudo grep -q 'runtimes.nvidia' "$CONTAINERD_CFG" 2>/dev/null \
    || die "k3s containerd has no nvidia runtime. Manual fix: ensure /usr/bin/nvidia-container-runtime exists, then 'sudo systemctl restart k3s'."
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
ok "nvidia runtime registered + RuntimeClass/nvidia present"

# ── 3. build + import the NVML node-agent image ──────────────────────────────
say "build + import $IMG"
# --provenance=false → a single-platform image so 'k3s ctr images import' gets a
# clean manifest (buildkit's default attestation manifest can trip up ctr import).
$DOCKER build --provenance=false --build-arg GOTAGS=nvml -t "$IMG" -f Dockerfile.nodeagent . >/dev/null \
    || die "node-agent image build failed"
$DOCKER save "$IMG" | sudo k3s ctr images import - >/dev/null \
    || die "importing the image into k3s containerd failed"
ok "image built + imported into k3s"

# ── 4. CRDs + namespace + RBAC ───────────────────────────────────────────────
say "CRDs + namespace + RBAC"
kubectl apply -f deployments/manifests/crds/ >/dev/null || die "applying CRDs failed"
kubectl apply -f deployments/manifests/namespace.yaml >/dev/null
kubectl apply -f deployments/manifests/rbac/ >/dev/null || die "applying RBAC failed"
ok "CRDs + namespace + RBAC applied"

# ── 5. deploy the NVML node agent (with the nvidia runtime class) ────────────
say "deploy the NVML node agent"
kubectl apply -f deployments/manifests/nodeagent_daemonset_nvml.yaml >/dev/null
# k3s is not the nvidia-default runtime → the agent needs runtimeClassName: nvidia
# so the toolkit injects libnvidia-ml.so.1 (NVML) into the container.
kubectl -n "$AGENT_NS" patch daemonset vgpu-nodeagent --type merge \
    -p '{"spec":{"template":{"spec":{"runtimeClassName":"nvidia"}}}}' >/dev/null
kubectl -n "$AGENT_NS" rollout status daemonset/vgpu-nodeagent --timeout=180s \
    || die "node-agent daemonset did not become ready (kubectl -n $AGENT_NS describe ds/vgpu-nodeagent)"
AGENT=$(kubectl -n "$AGENT_NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
ok "node agent running: $AGENT"

# ── 6. verify the NVML provider is live ──────────────────────────────────────
say "verify provider=nvml"
scrape() { kubectl get --raw "/api/v1/namespaces/$AGENT_NS/pods/${AGENT}:8083/proxy/metrics" 2>/dev/null; }
for _ in $(seq 1 20); do
    scrape | grep -q 'vgpu_gpu_provider_info{[^}]*provider="nvml"[^}]*} 1' && break
    sleep 3
done
if scrape | grep -q 'vgpu_gpu_provider_info{[^}]*provider="nvml"[^}]*} 1'; then
    ok "node agent is reading the GPU via NVML"
    scrape | grep -E '^vgpu_gpu_(total|used|free|reserved)_memory_bytes' | head -4
    scrape | grep -E '^vgpu_memory_enforcement_mode' | head -1
else
    echo "${C_YEL}agent is up but not reporting provider=nvml. Recent logs:${C_RST}"
    kubectl -n "$AGENT_NS" logs "$AGENT" --tail=30
    die "NVML provider not live — check driver injection (runtimeClassName=nvidia + nvidia toolkit)"
fi

say "bootstrap complete"
echo "  The stack is up and the node agent reads the GPU via NVML."
echo "  Run the Phase 3.4a/3.4b/3.4c end-to-end validation now:"
echo
echo "      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo "      bash scripts/validate-runtime-3.4-a10.sh"
