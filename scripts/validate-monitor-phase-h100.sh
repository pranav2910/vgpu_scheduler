#!/usr/bin/env bash
# validate-monitor-phase-h100.sh — LIVE before/after proof that the monitor's
# GPU-waste report counts ONLY running pods.
#
# Creates three GPU pods that ALL declare a request but differ in phase:
#   live-running : Running, under-uses        → SHOULD appear (legitimate waste)
#   done-job     : Succeeded (allocate→exit)  → must NOT appear (job finished)
#   pending-job  : Pending (init-blocked)     → must NOT appear (never started)
#
# Phase 1 runs `vgpu report` against the CURRENTLY-RUNNING monitor. If that binary
# predates the phase-filter fix, the Succeeded + Pending pods show up as phantom
# 100% waste — the bug, reproduced on real hardware. Phase 2 rebuilds + redeploys
# the monitor from the current source. Phase 3 reports again: the non-running pods
# are gone, the Running one remains, and the cluster waste total drops.
#
#   cd ~/vgpu_scheduler && git pull && bash scripts/validate-monitor-phase-h100.sh
#
# Read-only monitor; the only thing this rebuilds is the monitor image. The three
# test pods are deleted on exit.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NS="${NS:-default}"
MON_NS="${MON_NS:-vgpu-monitor}"
IMAGE="${IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
PRICE="${PRICE:-3.00}"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RST=$'\033[0m'
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }

command -v kubectl    >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "run on the GPU node"; exit 2; }
kubectl -n "$MON_NS" get ds vgpu-monitor >/dev/null 2>&1 \
    || { echo "monitor not installed — kubectl apply -f deployments/monitor/monitor.yaml"; exit 2; }

cleanup(){ hdr cleanup; kubectl delete pod live-running done-job pending-job -n "$NS" \
    --ignore-not-found --wait=false >/dev/null 2>&1; echo "  test pods deleted"; }
trap cleanup EXIT

hdr "create three GPU pods that all DECLARE a request but differ in phase"
echo "  live-running : Running, under-uses        → SHOULD appear (legit waste)"
echo "  done-job     : Succeeded (allocate→exit)  → must NOT appear"
echo "  pending-job  : Pending (init-blocked)     → must NOT appear"

# Running, under-using pod (legitimate waste — must be PRESERVED by the filter).
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: live-running
  namespace: $NS
  annotations: { gpu-memory: "16000" }
spec:
  runtimeClassName: ${RUNTIME_CLASS}
  restartPolicy: Never
  containers:
  - name: w
    image: ${IMAGE}
    command: ["python","-c","import torch,time; torch.empty(int(6*1024**3)//2,dtype=torch.float16,device='cuda').normal_(); torch.cuda.synchronize(); print('running ~6 GiB',flush=True); time.sleep(3600)"]
    env:
    - { name: NVIDIA_VISIBLE_DEVICES, value: "all" }
EOF

# Succeeded pod: allocate VRAM then EXIT (no sleep). Lingers as a finished pod that
# still carries a 40000 MiB request — the classic phantom-waste case.
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: done-job
  namespace: $NS
  annotations: { gpu-memory: "40000" }
spec:
  runtimeClassName: ${RUNTIME_CLASS}
  restartPolicy: Never
  containers:
  - name: w
    image: ${IMAGE}
    command: ["python","-c","import torch; torch.empty(int(6*1024**3)//2,dtype=torch.float16,device='cuda').normal_(); torch.cuda.synchronize(); print('done',flush=True)"]
    env:
    - { name: NVIDIA_VISIBLE_DEVICES, value: "all" }
EOF

# Pending pod: schedules to the node (so the monitor lists it) but an init container
# blocks forever, so the pod never leaves Pending and never touches the GPU.
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pending-job
  namespace: $NS
  annotations: { gpu-memory: "24000" }
spec:
  restartPolicy: Never
  initContainers:
  - name: block
    image: busybox:1.36
    command: ["sh","-c","sleep 3600"]
  containers:
  - name: w
    image: busybox:1.36
    command: ["sh","-c","echo started"]
EOF

hdr "wait for the three phases to settle"
r=""; d=""; p=""
for _ in $(seq 1 72); do
    r=$(kubectl get pod live-running -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    d=$(kubectl get pod done-job     -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    p=$(kubectl get pod pending-job  -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$r" == "Running" && "$d" == "Succeeded" && "$p" == "Pending" ]] && break
    sleep 5
done
echo "  live-running=$r  done-job=$d  pending-job=$p"
kubectl get pods -n "$NS" 2>/dev/null | grep -E 'NAME|live-running|done-job|pending-job'
echo "  giving the monitor ~40s to observe…"; sleep 40

hdr "${C_YEL}BEFORE${C_RST}  — report from the CURRENTLY-RUNNING monitor binary"
echo "  (if this is the pre-fix binary, done-job + pending-job appear as phantom 100% waste)"
scripts/vgpu report -n "$MON_NS" --price-per-gpu-hour "$PRICE"

hdr "rebuild + redeploy the monitor from the current source (the fix)"
$DOCKER build --provenance=false --build-arg GOTAGS=nvml -t vgpu-nodeagent:nvml -f Dockerfile.nodeagent . >/dev/null \
    || { echo "${C_RED}image build failed${C_RST}"; exit 1; }
$DOCKER save vgpu-nodeagent:nvml | sudo k3s ctr images import - >/dev/null \
    || { echo "${C_RED}image import failed${C_RST}"; exit 1; }
kubectl -n "$MON_NS" rollout restart ds/vgpu-monitor >/dev/null
kubectl -n "$MON_NS" rollout status  ds/vgpu-monitor --timeout=150s \
    || { echo "${C_RED}monitor rollout failed${C_RST}"; exit 1; }
echo "  new monitor up; giving it ~40s to observe…"; sleep 40

hdr "${C_GRN}AFTER${C_RST}  — report from the rebuilt monitor (only Running should remain)"
OUT="$(scripts/vgpu report -n "$MON_NS" --price-per-gpu-hour "$PRICE" 2>&1)"
echo "$OUT"

hdr "assertions"
PASS=0; FAIL=0
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
printf '%s\n' "$OUT" | grep -q 'live-running' \
    && ok "Running pod still reported (legitimate waste preserved)" \
    || bad "Running pod MISSING — filter is over-aggressive"
printf '%s\n' "$OUT" | grep -q 'done-job' \
    && bad "done-job (Succeeded) STILL shown as waste — fix not active" \
    || ok "Succeeded pod excluded (no phantom waste)"
printf '%s\n' "$OUT" | grep -q 'pending-job' \
    && bad "pending-job (Pending) STILL shown as waste — fix not active" \
    || ok "Pending pod excluded (no phantom waste)"

echo; echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Phase filter confirmed LIVE on real hardware: only Running pods count toward waste.${C_RST}"
    exit 0
fi
echo; echo "${C_RED}phase-filter validation FAILED${C_RST}"; exit 1
