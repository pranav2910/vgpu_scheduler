#!/usr/bin/env bash
# Lightweight Phase 3.4b hardware check — NO Kubernetes, just Docker.
#
# Proves the one thing kind's fake provider can't: that NVML reports
# per-process GPU memory on real hardware (the input to per-slice attribution).
# Runs a GPU memory hog, then runs our probe and confirms it lists that
# process's PID + memory, matching nvidia-smi.
#
#   git clone <repo> && cd vgpu_scheduler
#   bash scripts/validate-runtime-3.4-docker.sh
#
# Needs Docker + the NVIDIA container toolkit (default on Lambda Stack).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
HOG_IMAGE="${HOG_IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"

# Use sudo for docker if the user isn't in the docker group.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi
echo "using: $DOCKER"
$DOCKER info >/dev/null 2>&1 || { echo "${C_RED}docker not usable${C_RST}"; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "${C_RED}nvidia-smi not found${C_RST}"; exit 2; }

echo; echo "── build the NVML probe ──"
$DOCKER build --build-arg GOTAGS=nvml -t vgpu-gpu-probe:nvml -f Dockerfile.gpu-probe . >/dev/null \
    || { echo "${C_RED}probe build failed${C_RST}"; exit 2; }
echo "${C_GRN}✓${C_RST} built vgpu-gpu-probe:nvml"

echo; echo "── start a GPU memory hog (~4 GiB) ──"
$DOCKER rm -f v34hog >/dev/null 2>&1 || true
$DOCKER run -d --rm --gpus all --name v34hog "$HOG_IMAGE" \
    python -c "import torch,time; torch.empty(2*1024**3, dtype=torch.float16, device='cuda'); print('allocated'); time.sleep(600)" >/dev/null \
    || { echo "${C_RED}could not start hog (image pull / GPU access?)${C_RST}"; exit 2; }
trap '$DOCKER rm -f v34hog >/dev/null 2>&1' EXIT

echo "  waiting for the hog to allocate (image pull can take a few min)..."
for i in $(seq 1 60); do
    $DOCKER logs v34hog 2>&1 | grep -q allocated && { echo "  ${C_GRN}✓${C_RST} hog allocated GPU memory"; break; }
    if ! $DOCKER ps --format '{{.Names}}' | grep -q v34hog; then echo "  ${C_RED}hog exited early:${C_RST}"; $DOCKER logs v34hog 2>&1 | tail; exit 1; fi
    sleep 5
done
sleep 3

echo; echo "── ${C_GRN}OUR NVML PROVIDER${C_RST} — GPU processes (3.4b attribution input) ──"
$DOCKER run --rm --gpus all vgpu-gpu-probe:nvml

echo; echo "── ${C_GRN}nvidia-smi${C_RST} ground truth ──"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

echo; echo "── verdict ──"
echo "  The probe's 'GPU processes' block should list a pid with ~4 GiB used,"
echo "  matching the pid in nvidia-smi above. That confirms NVML per-process"
echo "  attribution works on this hardware — the read 3.4b's slice attribution"
echo "  is built on. (The cgroup→pod→slice mapping is unit-tested; the full k8s"
echo "  marking E2E is scripts/validate-runtime-3.4-a10.sh, which needs k3s.)"
