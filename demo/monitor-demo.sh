#!/usr/bin/env bash
# demo/monitor-demo.sh — see the read-only GPU waste report on a real GPU.
#
# Creates a couple of PLAIN GPU pods (NO vgpu scheduler involved — just
# runtimeClassName=nvidia + an annotation declaring how much they "asked for")
# that over-request and under-use VRAM, lets the read-only monitor observe them,
# then prints `vgpu report`. This is the wedge in action: it works beside ANY
# scheduler, changes nothing, and shows the waste.
#
#   bash scripts/a10-bootstrap.sh                       # k3s + nvidia runtime + vgpu-nodeagent:nvml
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   kubectl apply -f deployments/monitor/monitor.yaml   # the read-only monitor
#   bash demo/monitor-demo.sh                           # this (use --keep to leave pods running)
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NS="${NS:-default}"
MON_NS="${MON_NS:-vgpu-monitor}"
IMAGE="${IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
PRICE="${PRICE:-3.00}"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1

C_GRN=$'\033[1;32m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "run on the GPU node"; exit 2; }
kubectl -n "$MON_NS" get ds vgpu-monitor >/dev/null 2>&1 \
    || { echo "monitor not installed — run: kubectl apply -f deployments/monitor/monitor.yaml"; exit 2; }

cleanup(){ hdr cleanup; kubectl delete pod waste-a waste-b -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; echo "  demo pods deleted"; }
[[ $KEEP -eq 0 ]] && trap cleanup EXIT

# A plain GPU pod that DECLARES <ann_mib> MiB (gpu-memory annotation — what the
# monitor reads as "requested") but actually allocates <use_gib> GiB. Gets the GPU
# via the nvidia runtime + NVIDIA_VISIBLE_DEVICES (no device plugin / no vgpu).
mkpod() { # name ann_mib use_gib
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  annotations:
    gpu-memory: "$2"
spec:
  runtimeClassName: ${RUNTIME_CLASS}
  restartPolicy: Never
  containers:
  - name: w
    image: ${IMAGE}
    command: ["python","-c","import torch,time; torch.empty(int($3*1024**3)//2,dtype=torch.float16,device='cuda').normal_(); torch.cuda.synchronize(); print('using ~$3 GiB',flush=True); time.sleep(3600)"]
    env:
    - { name: NVIDIA_VISIBLE_DEVICES, value: "all" }
EOF
}

hdr "create two plain GPU pods that OVER-ASK and UNDER-USE (no scheduler involved)"
echo "  waste-a: asks 40000 MiB (~39 GiB), uses ~16 GiB"
echo "  waste-b: asks 24000 MiB (~23 GiB), uses ~8 GiB"
mkpod waste-a 40000 16
mkpod waste-b 24000 8

hdr "wait for the pods to run + the monitor to observe (image pull can take a minute)"
for n in waste-a waste-b; do
    for _ in $(seq 1 60); do
        ph=$(kubectl get pod "$n" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$ph" == "Running" || "$ph" == "Succeeded" ]] && break
        [[ "$ph" == "Failed" ]] && { kubectl logs "$n" -n "$NS" 2>/dev/null | tail -5; break; }
        sleep 5
    done
done
echo "  pods running; giving the monitor ~45s to sample…"
sleep 45

hdr "the read-only GPU waste report"
scripts/vgpu report -n "$MON_NS" --price-per-gpu-hour "$PRICE"

echo
echo "${C_GRN}That report came from a read-only DaemonSet observing PLAIN pods — no scheduler, no mutation, no CRDs.${C_RST}"
[[ $KEEP -eq 1 ]] && echo "  (--keep: pods left running; delete with: kubectl delete pod waste-a waste-b -n $NS)"
