#!/usr/bin/env bash
# validate-multigpu-kind.sh — M-GPU D4 gate: prove the device-aware allocator on
# a kind cluster with EIGHT fake GPUs, before any money is spent on hardware.
#
# Reconfigures the node agent to model 8× 80Gi cards (VGPU_FAKE_GPU_COUNT=8) and
# the node to advertise their SUM (640Gi), then asserts, end-to-end through the
# real scheduler + controller + allocator:
#
#   1. 32× 16Gi grants all Ready, spread across EXACTLY 8 distinct card UUIDs
#   2. every card holds exactly 4 (best-fit packs tight, never over-packs)
#   3. per-card committed bytes never exceed the card (ledger enforcement)
#   4. fragmentation fails LOUD: 24Gi with 128Gi node-free but 16Gi max per
#      card → slice Failed carrying the exact contract message
#   5. release restores per-card capacity (delete all → re-grant works)
#
# Pure resource grants (no podTemplate) — no GPU, no images, runs on a laptop:
#   scripts/setup-kind-cluster.sh && bash scripts/validate-multigpu-kind.sh
#
# Restores the original single-card model + capacity on exit.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VGPU_RESOURCE="infrastructure.pranav2910.com/vgpu-bytes"
AGENT_NS="vgpu-system"
GiB=$((1024*1024*1024))
CARDS=8
CARD_BYTES=$((80*GiB))
SUM_BYTES=$((CARDS*CARD_BYTES))
NS="mgpu-$(date +%s)"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
dim(){ echo "  ${C_DIM}$*${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
NODE=$(kubectl get nodes -o name | head -1 | sed 's|node/||')
[[ -n "$NODE" ]] || { echo "no node"; exit 2; }
kubectl -n "$AGENT_NS" get ds vgpu-nodeagent >/dev/null 2>&1 || { echo "run scripts/setup-kind-cluster.sh first"; exit 2; }

ORIG_CAP=$(kubectl get node "$NODE" -o jsonpath="{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}" 2>/dev/null)
ORIG_COUNT=$(kubectl -n "$AGENT_NS" get ds vgpu-nodeagent -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VGPU_FAKE_GPU_COUNT")].value}' 2>/dev/null)

restore() {
    hdr "restore original single-card model"
    kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    if [[ -n "$ORIG_COUNT" ]]; then
        kubectl -n "$AGENT_NS" set env ds/vgpu-nodeagent "VGPU_FAKE_GPU_COUNT=$ORIG_COUNT" >/dev/null 2>&1
    else
        kubectl -n "$AGENT_NS" set env ds/vgpu-nodeagent "VGPU_FAKE_GPU_COUNT-" >/dev/null 2>&1
    fi
    kubectl -n "$AGENT_NS" rollout status ds/vgpu-nodeagent --timeout=120s >/dev/null 2>&1
    if [[ -n "$ORIG_CAP" ]]; then
        kubectl patch node "$NODE" --subresource=status --type=merge \
            -p "{\"status\":{\"capacity\":{\"${VGPU_RESOURCE}\":\"${ORIG_CAP}\"},\"allocatable\":{\"${VGPU_RESOURCE}\":\"${ORIG_CAP}\"}}}" >/dev/null 2>&1
    fi
    dim "agent env + node capacity restored"
}
trap restore EXIT

wait_for() { # seconds desc pred...
    local t=$1 desc=$2; shift 2
    for _ in $(seq 1 $((t/3))); do
        if eval "$*"; then return 0; fi
        sleep 3
    done
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

hdr "clean baseline (a previous run's teardown must fully drain first)"
# Back-to-back runs raced here once: 33 slices still releasing + the agent
# DaemonSet mid-rollover from the prior run's restore ate the pack timeout.
wait_for 240 "zero vgpuslices cluster-wide" '
    n=$(kubectl get vgpuslice -A --no-headers 2>/dev/null | wc -l | tr -d " ");
    [[ "$n" == "0" ]]
' || { echo "  cluster still digesting a previous run — re-run when clean"; exit 1; }
kubectl -n "$AGENT_NS" rollout status ds/vgpu-nodeagent --timeout=120s >/dev/null 2>&1
ok "no leftover slices; agent settled"

hdr "model an 8-card node (8× 80Gi fake GPUs, capacity = sum = 640Gi)"
kubectl -n "$AGENT_NS" set env ds/vgpu-nodeagent "VGPU_FAKE_GPU_COUNT=$CARDS" "VGPU_FAKE_GPU_MEM_BYTES=$CARD_BYTES" >/dev/null
kubectl -n "$AGENT_NS" rollout status ds/vgpu-nodeagent --timeout=120s >/dev/null || { bad "agent rollout"; exit 1; }
kubectl patch node "$NODE" --subresource=status --type=merge \
    -p "{\"status\":{\"capacity\":{\"${VGPU_RESOURCE}\":\"${SUM_BYTES}\"},\"allocatable\":{\"${VGPU_RESOURCE}\":\"${SUM_BYTES}\"}}}" >/dev/null
kubectl create namespace "$NS" >/dev/null
ok "agent models $CARDS cards; node advertises $((SUM_BYTES>>30))Gi"

hdr "pack the node: 32× 18Gi grants (4 per card across 8 cards; 8Gi hole each)"
for i in $(seq 1 32); do submit_grant "mg-$i" $((18*GiB)); done
wait_for 240 "all 32 slices Ready" '
    n=$(kubectl get vgpuslice -n '"$NS"' -o custom-columns=:status.phase --no-headers 2>/dev/null | grep -c Ready);
    [[ "$n" == "32" ]]
' || { kubectl get vgpuslice -n "$NS" | head -12; exit 1; }
ok "32/32 slices Ready"

# Distribution: exactly 8 distinct UUIDs, exactly 4 slices each, ≤ card bytes each.
MAP=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.status.deviceUuid}{" "}{.spec.requestedVramBytes}{"\n"}{end}')
DISTINCT=$(printf '%s\n' "$MAP" | awk 'NF{print $1}' | sort -u | wc -l | tr -d ' ')
[[ "$DISTINCT" == "$CARDS" ]] && ok "slices spread across exactly $CARDS distinct cards" \
    || bad "distinct cards = $DISTINCT, want $CARDS"
PERCARD_BAD=$(printf '%s\n' "$MAP" | awk 'NF{c[$1]++; s[$1]+=$2} END{for(u in c) if(c[u]!=4 || s[u]>'"$CARD_BYTES"') print u": count="c[u]" bytes="s[u]}')
[[ -z "$PERCARD_BAD" ]] && ok "every card holds exactly 4×18Gi (72Gi) and never exceeds its 80Gi (ledger enforced)" \
    || bad "per-card violation: $PERCARD_BAD"

hdr "fragmentation fails LOUD: 24Gi (node free 64Gi, max per-card hole 8Gi)"
submit_grant "mg-frag" $((24*GiB))
wait_for 120 "frag slice fails loud" '
    ph=$(kubectl get vgpuslice mg-frag-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null);
    [[ "$ph" == "Failed" ]]
' || { kubectl get vgpuslice,vgpujob -n "$NS" | grep frag; exit 1; }
# status.lastError carries the message verbatim (yaml output folds long
# strings across lines, so assert via jsonpath, not a yaml grep).
FRAGMSG=$(kubectl get vgpuslice mg-frag-claim-slice -n "$NS" -o jsonpath='{.status.lastError}' 2>/dev/null)
WANT="No single GPU has 24Gi free; node has 64Gi free across GPUs. Fragmented capacity."
[[ "$FRAGMSG" == "$WANT" ]] \
    && ok "exact fail-loud contract message present on the slice" \
    || bad "fragmentation message wrong: got '$FRAGMSG' want '$WANT'"
JPH=$(kubectl get vgpujob mg-frag -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$JPH" == "Failed" ]] && ok "failure mirrored to the job (phase=Failed — user sees it)" \
    || bad "job phase = $JPH, want Failed"

hdr "release restores per-card capacity"
kubectl delete vgpujob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 180 "all slices released/gone" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " ");
    [[ "$n" == "0" ]]
' || exit 1
for i in $(seq 1 8); do submit_grant "mg-post-$i" $((16*GiB)); done
wait_for 120 "8 post-release grants Ready" '
    n=$(kubectl get vgpuslice -n '"$NS"' -o custom-columns=:status.phase --no-headers 2>/dev/null | grep -c Ready);
    [[ "$n" == "8" ]]
' && ok "released capacity fully reusable (8× 16Gi re-granted)" || bad "post-release grants did not become Ready"

echo
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}M-GPU proven on 8 fake cards: best-fit spread, per-card ledger, fail-loud fragmentation, clean release. Safe to buy the 8×A100.${C_RST}"
    exit 0
fi
echo; echo "${C_RED}multi-GPU validation FAILED — do not buy hardware yet${C_RST}"; exit 1
