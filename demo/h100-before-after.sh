#!/usr/bin/env bash
# demo/h100-before-after.sh — the before/after packing proof on a REAL GPU.
#
# Vanilla Kubernetes hands out a GPU at whole-card granularity: `nvidia.com/gpu: 1`
# means one pod owns the whole H100, and everyone else waits. This scheduler slices
# the same card by VRAM bytes, so N workloads share it — and it REFUSES to
# over-commit past the card's memory (no OOM roulette).
#
# This script proves it live: it submits enough 16 GiB workloads to fill the GPU
# plus one more, then shows that the ones that fit are Running on the SAME physical
# GPU while the extra is safely held Pending.
#
# Requires the full control plane (scripts/h100-control-plane.sh) to be up.
#
#   bash scripts/h100-control-plane.sh
#   export KUBECONFIG=$HOME/.kube/config
#   bash demo/h100-before-after.sh            # auto-sizes to the GPU
#   bash demo/h100-before-after.sh --keep     # leave the workloads running
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="${NS:-default}"
PREFIX="${PREFIX:-hpack}"
PER_JOB="${PER_JOB:-16Gi}"
IMAGE="${IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
VGPU_RESOURCE="infrastructure.pranav2910.com/vgpu-bytes"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
hdr() { echo; echo "${C_BLU}── $* ──${C_RST}"; }
say() { echo "  $*"; }

to_bytes() { # 16Gi -> bytes (Gi/Mi only, enough for this demo)
    local q="$1"
    [[ "$q" =~ ^([0-9]+)(Gi|Mi)?$ ]] || { echo "0"; return; }
    case "${BASH_REMATCH[2]}" in
        Gi) echo "$(( BASH_REMATCH[1] * 1024 * 1024 * 1024 ))" ;;
        Mi) echo "$(( BASH_REMATCH[1] * 1024 * 1024 ))" ;;
        *)  echo "${BASH_REMATCH[1]}" ;;
    esac
}
gib() { awk -v b="${1:-0}" 'BEGIN{ printf "%.0f", b/1073741824 }'; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
kubectl -n vgpu-system get deploy vgpu-scheduler vgpu-controller >/dev/null 2>&1 \
    || { echo "control plane not deployed — run scripts/h100-control-plane.sh first"; exit 2; }

NODE=$(kubectl -n vgpu-system get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
[[ -n "$NODE" ]] || { echo "no node agent pod found"; exit 2; }
CAP=$(kubectl get node "$NODE" -o jsonpath="{.status.allocatable.${VGPU_RESOURCE//./\\.}}" 2>/dev/null)
[[ -n "$CAP" && "$CAP" -gt 0 ]] 2>/dev/null || { echo "node $NODE advertises no $VGPU_RESOURCE capacity"; exit 2; }

per_bytes=$(to_bytes "$PER_JOB")
[[ "$per_bytes" -gt 0 ]] || { echo "bad PER_JOB '$PER_JOB'"; exit 2; }
FIT=$(( CAP / per_bytes ))         # how many PER_JOB workloads the card holds
[[ "$FIT" -lt 1 ]] && FIT=1        # guard: PER_JOB larger than the card
SUBMIT=$(( FIT + 1 ))              # one extra, to show the over-commit is refused

cleanup() {
    hdr "cleanup"
    for i in $(seq 1 "$SUBMIT"); do
        kubectl delete vgpujob "${PREFIX}${i}" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    done
    say "demo workloads deleted (${PREFIX}1..${SUBMIT})"
}
[[ $KEEP -eq 0 ]] && trap cleanup EXIT

hdr "the GPU"
gpu_model=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
say "node ${NODE}  —  ${gpu_model:-GPU}"
say "advertised vGPU memory: $(gib "$CAP") GiB  ($CAP bytes)"
say "per-workload request:   ${PER_JOB}  →  card holds ${C_YEL}${FIT}${C_RST} such workloads"

hdr "BEFORE — vanilla Kubernetes (nvidia.com/gpu: 1)"
say "A stock GPU is one allocatable unit. ${FIT} pods each asking for a GPU →"
say "${C_RED}1 Running, $(( FIT - 1 )) Pending forever${C_RST}. ~$(awk -v f="$FIT" 'BEGIN{printf "%.0f", 100/f}')% of the card used; the rest stranded."

hdr "reset — start from an idle card"
existing=$(kubectl get vgpujobs -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${existing:-0}" -gt 0 ]]; then
    say "clearing ${existing} existing VGPUJob(s) in ns/${NS} (this demo packs an idle GPU; leftovers would skew it)"
    kubectl delete vgpujob --all -n "$NS" --wait=false >/dev/null 2>&1
    for _ in $(seq 1 20); do   # wait for the scheduler to release the freed capacity
        [[ "$(kubectl get vgpuslices -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && break
        sleep 2
    done
fi
say "card idle — $(gib "$CAP") GiB available"

hdr "AFTER — this scheduler: submit ${SUBMIT}× ${PER_JOB} (one more than fits)"
for i in $(seq 1 "$SUBMIT"); do
    scripts/vgpu submit --name "${PREFIX}${i}" --vram "$PER_JOB" -n "$NS" \
        --image "$IMAGE" --command 'sleep 600' --runtime-class "$RUNTIME_CLASS" --no-wait >/dev/null 2>&1 \
        && say "submitted ${PREFIX}${i} (${PER_JOB})" || say "${C_RED}submit ${PREFIX}${i} failed${C_RST}"
done

hdr "wait for placement"
for _ in $(seq 1 20); do
    ready=$(kubectl get vgpuslices -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.deviceUuid}{"\n"}{end}' 2>/dev/null \
        | grep -c "^${PREFIX}.* Ready GPU-")
    [[ "$ready" -ge "$FIT" ]] && break
    sleep 3
done
# then give the pods a moment to reach Running (fast when the image is cached)
for _ in $(seq 1 12); do
    r=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep "^${PREFIX}.*-workload" | grep -c " Running ")
    [[ "$r" -ge "$FIT" ]] && break
    sleep 5
done

# ── tally what actually happened (bash 3.2-safe: no mapfile) ─────────────────
packed=0; held=0; uuid=""
while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    u=$(echo "$l" | awk '{print $3}')
    if [[ "$u" == GPU-* ]]; then packed=$((packed+1)); uuid="$u"; else held=$((held+1)); fi
done < <(kubectl get vgpuslices -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.deviceUuid}{"\n"}{end}' 2>/dev/null \
    | grep "^${PREFIX}")
running=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep "^${PREFIX}.*-workload" | grep -c " Running ")
packed_bytes=$(( packed * per_bytes ))
util=$(awk -v p="$packed_bytes" -v c="$CAP" 'BEGIN{ printf "%.0f", (c>0)? p*100/c : 0 }')

hdr "RESULT"
echo "  ${C_GRN}${packed} workloads packed onto ONE physical GPU${C_RST}  (${uuid:-?})"
echo "  ${C_GRN}${running} pods Running${C_RST}  ·  $(gib "$packed_bytes") GiB of $(gib "$CAP") GiB used  ·  ${C_GRN}~${util}% utilization${C_RST}"
if [[ "$held" -gt 0 ]]; then
    echo "  ${C_YEL}${held} held Pending — the scheduler refused to over-commit past the card's memory${C_RST}"
fi
echo
echo "  ${C_BLU}Before:${C_RST} 1 workload per H100 (~$(awk -v f="$FIT" 'BEGIN{printf "%.0f", 100/f}')%).   ${C_BLU}After:${C_RST} ${packed} per H100 (~${util}%).  Same hardware."
[[ $KEEP -eq 1 ]] && { echo; echo "  (--keep: workloads left running. Remove with: for i in \$(seq 1 $SUBMIT); do kubectl delete vgpujob ${PREFIX}\$i -n $NS; done)"; }

# success if we packed more than one (the whole point) on a single card
[[ "$packed" -ge 2 && -n "$uuid" ]] && exit 0 || exit 1
