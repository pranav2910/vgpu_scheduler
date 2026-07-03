#!/usr/bin/env bash
# validate-multigpu-a100.sh — M-GPU on REAL hardware (any multi-GPU NVIDIA box,
# e.g. 8×A100). Run AFTER scripts/h100-control-plane.sh on the box.
#
# Proves, against real NVML + CDI:
#   1. the node advertises the SUM of all cards
#   2. N×4 grants spread across ALL N cards, exactly 4 each, ledger-capped
#   3. fragmentation fails LOUD (node-free plenty, no single card fits)
#   4. two PODS forced onto different cards each see THEIR OWN GPU inside
#      (nvidia-smi UUID in-pod == that slice's deviceUuid; UUIDs differ)
#   5. release restores capacity (quick re-grant)
#
#   export KUBECONFIG=$HOME/.kube/config
#   bash scripts/validate-multigpu-a100.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

GiB=$((1024*1024*1024)); MiB=$((1024*1024))
NS="mgpu-$(date +%s)"
IMAGE="${IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
dim(){ echo "  ${C_DIM}$*${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "run on the GPU node"; exit 2; }

cleanup(){ hdr cleanup; kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; dim "namespace $NS deleted"; }
trap cleanup EXIT

wait_for() { local t=$1 desc=$2; shift 2
    for _ in $(seq 1 $((t/3))); do eval "$*" && return 0; sleep 3; done
    bad "timeout waiting for: $desc"; return 1
}

submit_grant() { # name bytes
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: $1, namespace: $NS }
spec:
  priority: 50
  workloadClass: Inference
  claimTemplate:
    spec:
      requestedVramBytes: $2
      serviceTier: Guaranteed
EOF
}

hdr "the hardware"
CARDS=$(nvidia-smi -L | wc -l | tr -d ' ')
PERCARD_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | sort -n | head -1 | tr -dc '0-9')
PERCARD_BYTES=$((PERCARD_MIB * MiB))
[[ "$CARDS" -ge 2 ]] || { echo "need a multi-GPU node (found $CARDS)"; exit 2; }
NODE=$(kubectl get nodes -o name | head -1 | sed 's|node/||')
dim "$CARDS GPUs × ${PERCARD_MIB} MiB on $NODE"

# Slice size: EXACTLY 4 per card by construction, MiB-granular. 1Gi of headroom
# absorbs the driver reserve; 4×S fits, 5×S cannot. (GiB-flooring here once let
# a 5th slice fit on exactly-16GiB V100s — best-fit correctly took it and the
# validator wrongly flagged the CORRECT packing.)
SLICE_MIB=$(( (PERCARD_MIB - 1024) / 4 ))
SLICE_BYTES=$((SLICE_MIB * MiB))
TOTAL_GRANTS=$((CARDS * 4))
dim "slice size ${SLICE_MIB}Mi · packing $TOTAL_GRANTS grants (exactly 4/card: 4×S+1Gi ≥ card > 5×S)"

hdr "1. node advertises the SUM of all cards"
ADV=$(kubectl get node "$NODE" -o jsonpath='{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}')
EXPECT_MIN=$((CARDS * (PERCARD_BYTES - GiB)))   # tolerate per-card rounding
[[ -n "$ADV" && "$ADV" -ge "$EXPECT_MIN" ]] \
    && ok "capacity $((ADV>>30))Gi ≈ sum of $CARDS cards (re-run h100-control-plane.sh if this fails)" \
    || bad "advertised $ADV < expected ≥$EXPECT_MIN — bootstrap didn't sum the cards?"

kubectl create namespace "$NS" >/dev/null

hdr "2. pack: $TOTAL_GRANTS grants spread across all $CARDS cards"
for i in $(seq 1 "$TOTAL_GRANTS"); do submit_grant "mg-$i" "$SLICE_BYTES"; done
wait_for 300 "all $TOTAL_GRANTS slices Ready" '
    n=$(kubectl get vgpuslice -n '"$NS"' -o custom-columns=:status.phase --no-headers 2>/dev/null | grep -c Ready);
    [[ "$n" == "'"$TOTAL_GRANTS"'" ]]
' || { kubectl get vgpuslice -n "$NS" | head -12; exit 1; }
MAP=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.status.deviceUuid}{" "}{.spec.requestedVramBytes}{"\n"}{end}')
DISTINCT=$(printf '%s\n' "$MAP" | awk 'NF{print $1}' | sort -u | wc -l | tr -d ' ')
[[ "$DISTINCT" == "$CARDS" ]] && ok "slices spread across exactly $CARDS distinct REAL cards" \
    || bad "distinct cards = $DISTINCT, want $CARDS"
PERCARD_BAD=$(printf '%s\n' "$MAP" | awk 'NF{c[$1]++; s[$1]+=$2} END{for(u in c) if(c[u]!=4 || s[u]>'"$PERCARD_BYTES"') print u" count="c[u]" bytes="s[u]}')
[[ -z "$PERCARD_BAD" ]] && ok "every card holds exactly 4 grants within its capacity (ledger enforced)" \
    || bad "per-card violation: $PERCARD_BAD"

hdr "3. fragmentation fails LOUD"
# After exact-4 packing, no card has a full slice-size hole left (≤1Gi each),
# but node-wide the holes sum to several Gi: one more slice-sized request fits
# the node pool and NO single card — the exact fail-loud case.
FRAG_BYTES=$SLICE_BYTES
dim "per-card hole ≤1Gi · requesting one more slice (${SLICE_MIB}Mi)"
submit_grant "mg-frag" "$FRAG_BYTES"
wait_for 120 "frag slice Failed" '
    ph=$(kubectl get vgpuslice mg-frag-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null);
    [[ "$ph" == "Failed" ]]
' && {
    FRAGMSG=$(kubectl get vgpuslice mg-frag-claim-slice -n "$NS" -o jsonpath='{.status.lastError}' 2>/dev/null)
    [[ "$FRAGMSG" == *"Fragmented capacity."* ]] \
        && ok "fail-loud contract message present ($FRAGMSG)" \
        || bad "Failed but without the fragmentation message (lastError: '$FRAGMSG')"
} || kubectl get vgpuslice,vgpujob -n "$NS" 2>/dev/null | grep frag
kubectl delete vgpujob mg-frag -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1

hdr "4. two PODS on different cards each see their own GPU (CDI, in-container)"
kubectl delete vgpujob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 240 "packing released" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " ");
    [[ "$n" == "0" ]]
' || exit 1
BIG_BYTES=$(( (PERCARD_BYTES * 60 / 100 / GiB) * GiB ))   # ~60% of a card → two can NEVER share one (decisive on 16GB cards too)
for n in mga mgb; do
    scripts/vgpu submit --name "$n" -n "$NS" --vram "$((BIG_BYTES>>30))Gi" \
        --image "$IMAGE" --command 'nvidia-smi -L; sleep 600' --runtime-class nvidia >/dev/null \
        || bad "vgpu submit $n failed"
done
wait_for 300 "both pods Running" '
    a=$(kubectl get pod mga-workload -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null);
    b=$(kubectl get pod mgb-workload -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null);
    [[ "$a" == "Running" && "$b" == "Running" ]]
' || { kubectl get pods,vgpuslice -n "$NS"; exit 1; }
UA=$(kubectl get vgpuslice mga-claim-slice -n "$NS" -o jsonpath='{.status.deviceUuid}')
UB=$(kubectl get vgpuslice mgb-claim-slice -n "$NS" -o jsonpath='{.status.deviceUuid}')
[[ -n "$UA" && -n "$UB" && "$UA" != "$UB" ]] && ok "slices bound to two DIFFERENT cards ($UA vs $UB)" \
    || bad "slices not on distinct cards (a=$UA b=$UB)"
sleep 5
LA=$(kubectl logs mga-workload -n "$NS" 2>/dev/null | grep -o 'GPU-[0-9a-f-]*' | head -1)
LB=$(kubectl logs mgb-workload -n "$NS" 2>/dev/null | grep -o 'GPU-[0-9a-f-]*' | head -1)
[[ "$LA" == "$UA" ]] && ok "pod A sees ITS card inside the container ($LA)" || bad "pod A in-container UUID $LA != slice $UA"
[[ "$LB" == "$UB" ]] && ok "pod B sees ITS card inside the container ($LB)" || bad "pod B in-container UUID $LB != slice $UB"

hdr "5. scan #15: PER-CARD over-use detection on a multi-GPU node"
# The node-overuse detector once compared each card's usage to the NODE-WIDE
# grant sum → on an 8-GPU node one card's use vs the whole node's grant is
# always hugely negative, so it NEVER fired. Fixed to per-card (Status.DeviceUUID).
# Prove it fires: grant pod A a SMALL slice, then have it allocate WAY past that
# slice on its own card. Only per-card accounting flags this; node-wide hides it.
SMALL_MIB=2048                                   # 2 GiB grant
BURN_GIB=$(( (PERCARD_MIB - 2048) / 1024 ))      # burn ~most of the 16 GiB card → ≫ 2 GiB grant
kubectl delete vgpujob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 240 "cards released before #15 probe" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]' || true
scripts/vgpu submit --name overcard -n "$NS" --vram "${SMALL_MIB}Mi" --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime \
    --runtime-class nvidia \
    --command "python -c 'import torch,time; x=torch.empty(int(${BURN_GIB}*1024**3)//2, dtype=torch.float16, device=\"cuda\").normal_(); torch.cuda.synchronize(); print(\"burning ${BURN_GIB}GiB on a ${SMALL_MIB}Mi grant\", flush=True); time.sleep(600)'" >/dev/null \
    || bad "overcard submit failed"
wait_for 240 "overcard pod Running" '
    [[ "$(kubectl get pod overcard-workload -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null)" == "Running" ]]' || kubectl get pods -n "$NS"
OVER_UUID=$(kubectl get vgpuslice overcard-claim-slice -n "$NS" -o jsonpath='{.status.deviceUuid}')
dim "overcard on card $OVER_UUID: granted ${SMALL_MIB}Mi, burning ~${BURN_GIB}GiB — waiting for the per-card detector (streak×interval)"
# Probe via the kubectl API proxy — the nvml container has no wget/curl (the
# first run of this step failed on the PROBE, while the agent's own logs showed
# the detector firing perfectly: "exceeds granted by 12601 MiB (granted=2048 MiB)").
AGENT=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
scrape() { kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/${AGENT}:8083/proxy/metrics" 2>/dev/null; }
if wait_for 180 "per-card overuse metric > 0 for the burning card" '
    v=$(kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/'"$AGENT"':8083/proxy/metrics" 2>/dev/null | awk -F"[ {}]" "/^vgpu_node_memory_overuse_bytes.*'"$OVER_UUID"'/ {print \$NF}" | tail -1);
    [[ -n "$v" && "${v%.*}" -gt 1073741824 ]]'; then
    OB=$(scrape | awk -F'[ {}]' "/^vgpu_node_memory_overuse_bytes.*$OVER_UUID/ {print \$NF}" | tail -1)
    ok "PER-CARD over-use detected on card $OVER_UUID (overuse≈$(( ${OB%.*} >> 30 ))GiB > its own 2Gi grant) — node-wide accounting would report 0"
    ACTIVE=$(scrape | awk -F'[ {}]' "/^vgpu_node_memory_violation_active.*$OVER_UUID/ {print \$NF}" | tail -1)
    [[ "${ACTIVE%.*}" == "1" ]] && ok "card marked violating (vgpu_node_memory_violation_active=1)" || bad "overuse seen but card not marked violating (active=$ACTIVE)"
    CLEAN=$(scrape | awk -F'[ {}]' "/^vgpu_node_memory_violation_active/ && !/$OVER_UUID/ {s+=\$NF} END{printf \"%d\", s}")
    [[ "${CLEAN:-0}" == "0" ]] && ok "all 7 OTHER cards stay clean (violation isolated to the burning card)" || bad "other cards wrongly flagged (sum=$CLEAN)"
else
    bad "scan #15: per-card over-use NOT detected — detector still node-wide?"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Multi-GPU proven on real hardware: $CARDS cards, best-fit spread, ledger caps, fail-loud fragmentation, per-card CDI injection.${C_RST}"
    exit 0
fi
echo; echo "${C_RED}multi-GPU hardware validation FAILED${C_RST}"; exit 1
