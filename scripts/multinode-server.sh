#!/usr/bin/env bash
# multinode-server.sh — node 1 of a multi-node vGPU cluster (M-NODE D5).
#
# Installs k3s as a SERVER with cross-instance networking that works between
# cloud boxes over their public IPs:
#   --flannel-backend=wireguard-native   encrypted node-to-node overlay; needs
#                                        only UDP 51820 reachable between nodes
#   --node-external-ip / --tls-san       so agents join via the public IP
#
# Then reuses the existing single-node machinery unchanged:
#   a10-bootstrap.sh        nvidia runtime + nodeagent image + CRDs + agent DS
#   h100-control-plane.sh   scheduler/controller/webhooks + THIS node's capacity
#
# Ends by printing the exact join command for every additional GPU node.
#
#   git clone <repo> && cd vgpu_scheduler && bash scripts/multinode-server.sh
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_GRN=$'\033[1;32m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
say(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; }
die(){ echo "  ✗ $*"; exit 1; }

command -v nvidia-smi >/dev/null 2>&1 || die "run on a GPU node"

# Public IP: how agents (and kubectl from elsewhere) reach this server.
PUBLIC_IP="${PUBLIC_IP:-$(curl -s --max-time 5 ifconfig.me || true)}"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP=$(hostname -I | awk '{print $1}')
[[ -n "$PUBLIC_IP" ]] || die "could not determine this node's IP (set PUBLIC_IP=...)"

say "k3s SERVER (wireguard-native flannel, external IP $PUBLIC_IP)"
if command -v k3s >/dev/null 2>&1; then
    ok "k3s already installed — assuming it was installed by this script with the right flags"
else
    curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="server \
        --write-kubeconfig-mode 644 \
        --flannel-backend=wireguard-native \
        --node-external-ip=$PUBLIC_IP \
        --tls-san=$PUBLIC_IP" sh - || die "k3s server install failed"
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for _ in $(seq 1 40); do kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break; sleep 3; done
kubectl get nodes | grep -q ' Ready ' || die "server node not Ready"
ok "server Ready"

say "single-node machinery (nvidia runtime, images, CRDs, agent, control plane)"
bash scripts/a10-bootstrap.sh
bash scripts/h100-control-plane.sh

TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)
say "JOIN INFO — run on EVERY additional GPU node (after cloning the repo there)"
cat <<EOF

  export K3S_URL="https://${PUBLIC_IP}:6443"
  export K3S_TOKEN="${TOKEN}"
  bash scripts/multinode-agent.sh

  Requirements between nodes: TCP 6443 (join/API) and UDP 51820 (WireGuard)
  reachable from the agent to this server.

  After each agent joins, it prints a capacity one-liner to run back HERE.
  Then validate the whole cluster from this node:

      bash scripts/validate-multinode.sh
EOF
