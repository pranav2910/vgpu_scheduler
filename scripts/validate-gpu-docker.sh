#!/usr/bin/env bash
# Real-GPU NVML validation WITHOUT Kubernetes — runs the node agent's exact NVML
# provider in a container and shows it next to nvidia-smi. Ideal for a Lambda
# Cloud instance (or any Ubuntu box with the NVIDIA driver + Docker +
# nvidia-container-toolkit, all of which Lambda Stack ships by default).
#
#   git clone <repo> && cd vgpu_scheduler
#   scripts/validate-gpu-docker.sh
#
# This proves checks 1-5 + 8 on real hardware (provider=nvml, UUID, total VRAM,
# used/free, health, and — re-run after a CUDA job — that used/free track a
# workload). The Kubernetes drift + capacity-unchanged checks (6,7) come from the
# full path: deploy nodeagent_daemonset_nvml.yaml and run validate-gpu-nvml.sh.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
IMG="${IMG:-vgpu-gpu-probe:nvml}"

die() { echo "${C_RED}✗ $*${C_RST}"; exit 1; }

command -v docker      >/dev/null 2>&1 || die "docker not found"
command -v nvidia-smi  >/dev/null 2>&1 || die "nvidia-smi not found — is the NVIDIA driver installed?"

echo "── driver / GPU present ──"
nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader || die "nvidia-smi failed"

echo
echo "── confirm containers can see the GPU ──"
if ! docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L 2>/dev/null; then
    echo "${C_RED}✗ 'docker run --gpus all' could not access the GPU.${C_RST}"
    echo "  Install the NVIDIA container toolkit, then retry:"
    echo "    ${C_DIM}distribution=\$(. /etc/os-release; echo \$ID\$VERSION_ID)"
    echo "    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    echo "    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https#' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    echo "    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
    echo "    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker${C_RST}"
    exit 1
fi
echo "${C_GRN}✓ GPU is reachable from containers${C_RST}"

echo
echo "── build the NVML probe (our exact provider code, -tags nvml) ──"
docker build --build-arg GOTAGS=nvml -t "$IMG" -f Dockerfile.gpu-probe . >/dev/null || die "image build failed"
echo "${C_GRN}✓ built $IMG${C_RST}"

echo
echo "── ${C_GRN}OUR NVML PROVIDER${C_RST} sees: ──"
docker run --rm --gpus all "$IMG" || die "probe failed (NVML init / device access)"

echo
echo "── ${C_GRN}nvidia-smi${C_RST} (ground truth) sees: ──"
nvidia-smi --query-gpu=index,name,uuid,memory.total,memory.used,memory.free --format=csv

echo
echo "── verdict ──"
echo "  Compare the two blocks above:"
echo "    • UUID must match exactly"
echo "    • total MiB must match (±1 MiB rounding)"
echo "    • used/free should be in the same ballpark (they drift as the GPU is used)"
echo
echo "  ${C_DIM}Workload check (#8): run a CUDA job, then re-run this script —"
echo "    docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 \\"
echo "      bash -c 'for i in \$(seq 1 20); do nvidia-smi; sleep 2; done' &"
echo "    used should rise / free should fall in OUR provider's output too.${C_RST}"
echo
echo "  ${C_DIM}Full k8s validation (drift + capacity-unchanged, checks 6-7):"
echo "    install k3s + nvidia-container-toolkit, then:"
echo "    kubectl apply -f deployments/manifests/nodeagent_daemonset_nvml.yaml"
echo "    scripts/validate-gpu-nvml.sh${C_RST}"
