#!/usr/bin/env bash
# multinode-agent.sh — join a GPU node to the multi-node vGPU cluster (M-NODE D5).
#
# Run on each ADDITIONAL GPU box, after the server printed K3S_URL/K3S_TOKEN:
#
#   git clone <repo> && cd vgpu_scheduler
#   export K3S_URL="https://<server-ip>:6443"
#   export K3S_TOKEN="<token>"
#   bash scripts/multinode-agent.sh
#
# What it does on THIS node:
#   1. k3s AGENT join (wireguard flannel rides the server's setting)
#   2. NVIDIA runtime for the agent's containerd (restart target: k3s-agent)
#   3. builds + imports all three images locally — the node agent DaemonSet
#      lands here immediately, and scheduler/controller replicas may too (HA)
#   4. computes this node's GPU capacity (sum of cards) and prints the
#      advertise one-liner to run ON THE SERVER (agents have no API access)
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_GRN=$'\033[1;32m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
say(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; }
die(){ echo "  ✗ $*"; exit 1; }

command -v nvidia-smi >/dev/null 2>&1 || die "run on a GPU node"
[[ -n "${K3S_URL:-}" && -n "${K3S_TOKEN:-}" ]] || die "export K3S_URL and K3S_TOKEN from the server's join info first"
[[ "$K3S_URL$K3S_TOKEN" != *"<"* ]] || die "K3S_URL/K3S_TOKEN still contain a <placeholder> — paste the REAL values the server printed"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

MY_IP="${PUBLIC_IP:-$(curl -s --max-time 5 ifconfig.me || true)}"
[[ -n "$MY_IP" ]] || MY_IP=$(hostname -I | awk '{print $1}')

say "k3s AGENT join → $K3S_URL (this node: $MY_IP)"
if command -v k3s >/dev/null 2>&1 && systemctl is-active k3s-agent >/dev/null 2>&1; then
    ok "k3s agent already running"
else
    curl -sfL https://get.k3s.io | sudo K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
        INSTALL_K3S_EXEC="agent --node-external-ip=$MY_IP" sh - || die "k3s agent join failed"
fi
for _ in $(seq 1 40); do systemctl is-active k3s-agent >/dev/null 2>&1 && break; sleep 3; done
systemctl is-active k3s-agent >/dev/null 2>&1 || die "k3s-agent service not active"
ok "agent service active"

say "NVIDIA runtime for the agent's containerd"
CONTAINERD_CFG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"
if sudo grep -q 'nvidia' "$CONTAINERD_CFG" 2>/dev/null; then
    ok "nvidia runtime already present"
else
    command -v nvidia-ctk >/dev/null 2>&1 || die "nvidia-ctk not found — install nvidia-container-toolkit"
    sudo cp "$CONTAINERD_CFG" "${CONTAINERD_CFG}.tmpl" 2>/dev/null || true
    sudo nvidia-ctk runtime configure --runtime=containerd --config="${CONTAINERD_CFG}.tmpl" >/dev/null 2>&1 || true
    sudo systemctl restart k3s-agent
    sleep 5
    sudo grep -q 'nvidia' "$CONTAINERD_CFG" 2>/dev/null || sudo grep -q 'nvidia' "${CONTAINERD_CFG}.tmpl" 2>/dev/null \
        || die "agent containerd has no nvidia runtime; check nvidia-container-toolkit, then 'sudo systemctl restart k3s-agent'"
    ok "nvidia runtime configured (k3s-agent restarted)"
fi

say "build + import images locally (DS + possible HA replicas land here)"
$DOCKER build --provenance=false --build-arg GOTAGS=nvml -t vgpu-nodeagent:nvml -f Dockerfile.nodeagent . >/dev/null || die "nodeagent build failed"
$DOCKER build --provenance=false -t vgpu-controller:latest -f Dockerfile.controller . >/dev/null || die "controller build failed"
$DOCKER build --provenance=false -t vgpu-scheduler:latest  -f Dockerfile.scheduler  . >/dev/null || die "scheduler build failed"
$DOCKER save vgpu-nodeagent:nvml   | sudo k3s ctr images import - >/dev/null || die "nodeagent import failed"
$DOCKER save vgpu-controller:latest | sudo k3s ctr images import - >/dev/null || die "controller import failed"
$DOCKER save vgpu-scheduler:latest  | sudo k3s ctr images import - >/dev/null || die "scheduler import failed"
ok "3 images imported into this node's k3s"

NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')
TOTAL_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{s+=$1} END {printf "%d", s}')
CAP=$((TOTAL_MIB * 1024 * 1024))
say "DONE on this node — now run ON THE SERVER:"
cat <<EOF

  kubectl patch node ${NODE_NAME} --subresource=status --type=merge \\
    -p '{"status":{"capacity":{"infrastructure.pranav2910.com/vgpu-bytes":"${CAP}"},"allocatable":{"infrastructure.pranav2910.com/vgpu-bytes":"${CAP}"}}}'

  # then confirm the node + its agent pod:
  kubectl get nodes
  kubectl get pods -n vgpu-system -o wide | grep nodeagent

  ($(nvidia-smi -L | wc -l | tr -d ' ') GPU(s), ${TOTAL_MIB} MiB total → advertises ${CAP} bytes ≈ $((CAP>>30))Gi)
EOF
