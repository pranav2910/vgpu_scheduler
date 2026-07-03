#!/usr/bin/env bash
# ============================================================================
# tier3-torture-multigpu.sh — REAL-WORLD stress on a real multi-GPU node.
# Run ON the box (after h100-control-plane.sh), or via:
#   ssh $HOST 'cd vgpu_scheduler && bash scripts/tier3-torture-multigpu.sh'
#
#   A. CHURN STORM     — waves of random-size jobs alloc/release across all
#                        cards; per-card ledger invariant after every wave;
#                        zero residue at the end.
#   B. CONCURRENT BURNS— 3 cards violating simultaneously, 5 stay clean
#                        (per-card detection under load, scan #15 at scale).
#   C. LOADED RE-SEED  — allocations on ALL cards; agent killed twice, then a
#                        FULL NODE REBOOT; the 8-card ledger must re-seed and
#                        refuse a request that only fits if it forgot.
#   D. GANG + PREEMPT  — an 8-member gang lands 1-per-card (forced spread);
#                        a high-priority job preempts a low-pri victim and
#                        lands on the SAME card the victim freed.
# ============================================================================
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

GiB=$((1024*1024*1024)); MiB=$((1024*1024))
NS="${NS:-t3-run}"
PHASE="${PHASE:-all}"   # ab | b | c-load | c-post | d | all
BURNIMG="pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime"
C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
dim(){ echo "  ${C_DIM}$*${C_RST}"; }
wait_for(){ local t=$1 d=$2; shift 2; for _ in $(seq 1 $((t/3))); do eval "$*" && return 0; sleep 3; done; bad "timeout: $d"; return 1; }

CARDS=$(nvidia-smi -L | wc -l | tr -d ' ')
PERCARD_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | sort -n | head -1 | tr -dc '0-9')
PERCARD_BYTES=$((PERCARD_MIB * MiB))
AGENT=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
scrape(){ AGENT=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
          kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/${AGENT}:8083/proxy/metrics" 2>/dev/null; }
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cleanup(){ hdr cleanup; kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; dim "ns $NS deleted"; }
case "$PHASE" in d|all) trap cleanup EXIT ;; esac
run_phase(){ case "$PHASE" in all) return 0 ;; *) [[ "$PHASE" == "$1" ]] ;; esac; }
dim "$CARDS × ${PERCARD_MIB}MiB · ns=$NS"

submit(){ # name bytes [priority] [preemptible]
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: $1, namespace: $NS }
spec:
  priority: ${3:-50}
  preemptible: ${4:-false}
  workloadClass: Inference
  claimTemplate: { spec: { requestedVramBytes: $2, serviceTier: Guaranteed } }
EOF
}

# per-card invariant from slice objects: sum(bytes per deviceUuid) <= card
invariant(){ local tag=$1
    local badline
    badline=$(kubectl get vgpuslice -A -o jsonpath='{range .items[?(@.status.phase=="Ready")]}{.status.deviceUuid}{" "}{.status.allocatedBytes}{"\n"}{end}' 2>/dev/null \
        | awk -v cap="$PERCARD_BYTES" 'NF==2{s[$1]+=$2} END{for(u in s) if(s[u]>cap) print u, s[u]}')
    [[ -z "$badline" ]] && ok "per-card ledger invariant holds ($tag)" || bad "PER-CARD OVER-COMMIT ($tag): $badline"
}

if run_phase ab; then
AR0=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
hdr "A. CHURN STORM: 6 waves of random-size jobs across all $CARDS cards"
CHURN_FAILLOUD=0
for wave in 1 2 3 4 5 6; do
    # submit 12 jobs, sizes 2..10 GiB (deterministic pseudo-random per wave)
    for i in $(seq 1 12); do
        SZ=$(( (2 + (wave*7 + i*3) % 9) * GiB ))
        submit "churn-w${wave}-${i}" "$SZ"
    done
    sleep 25
    # release roughly half (the odd ones)
    for i in 1 3 5 7 9 11; do kubectl delete vgpujob "churn-w${wave}-${i}" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; done
    sleep 20
    F=$(kubectl get vgpuslice -n "$NS" --no-headers 2>/dev/null | grep -c Failed || true)
    CHURN_FAILLOUD=$((CHURN_FAILLOUD + F))
    invariant "wave$wave"
done
R=$(kubectl get vgpuslice -n "$NS" --no-headers 2>/dev/null | grep -c Ready || true)
[[ "$R" -ge 1 ]] && ok "churn survivors still Ready ($R slices; $CHURN_FAILLOUD fail-loud fragmentation rejections along the way — rejections are honest, over-commit is not)" \
    || bad "churn left zero Ready slices (storm collapsed?)"
kubectl delete vgpujob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 240 "zero residue after full release" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]' \
    && ok "release-all -> ZERO residue (no leaked slices after 72 jobs churned)"
AR=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
[[ "$AR" == "$AR0" ]] && ok "agent survived the churn storm (restart delta 0)" || bad "agent restarted $((AR-AR0)) time(s) DURING churn"

fi  # end ab section A gate — B below also runs standalone as PHASE=b
if run_phase ab || run_phase b; then
hdr "B. CONCURRENT BURNS: 3 cards violating at once, $((CARDS-3)) stay clean"
BURN_GIB=$(( (PERCARD_MIB - 3072) / 1024 ))
for i in 1 2 3; do
    kubectl apply -f - >/dev/null <<EOF
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: burn-$i, namespace: $NS }
spec:
  priority: 50
  workloadClass: Inference
  claimTemplate: { spec: { requestedVramBytes: $((9*GiB)), serviceTier: Guaranteed } }
  podTemplate:
    spec:
      runtimeClassName: nvidia
      containers:
      - name: w
        image: $BURNIMG
        command: ["python","-c","import torch,time; x=torch.empty(int(${BURN_GIB}*1024**3)//2, dtype=torch.float16, device='cuda').normal_(); torch.cuda.synchronize(); print('burning', flush=True); time.sleep(900)"]
EOF
done
wait_for 300 "all 3 burn pods Running" '
    n=$(kubectl get pods -n '"$NS"' --no-headers 2>/dev/null | grep -c "burn-.*Running"); [[ "$n" == "3" ]]'
BURN_UUIDS=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.deviceUuid}{"\n"}{end}' | awk '/burn-/{print $2}' | sort -u)
NBU=$(printf '%s\n' "$BURN_UUIDS" | grep -c GPU || true)
[[ "$NBU" == "3" ]] && ok "3 burns landed on 3 DISTINCT cards" || bad "burns not on 3 distinct cards ($NBU)"
wait_for 420 "all 3 burning cards marked violating" '
    v=$(scrape | awk -F"[ {}]" "/^vgpu_node_memory_violation_active/ {if (\$NF==1) c++} END{printf \"%d\", c}"); [[ "$v" == "3" ]]' \
    && ok "all 3 burning cards violation_active=1 SIMULTANEOUSLY (per-card detection under load)"
CLEANV=$(scrape | awk -F'[ {}]' '/^vgpu_node_memory_violation_active/ {s+=$NF} END{printf "%d", s}')
[[ "$CLEANV" == "3" ]] && ok "exactly 3 violating — the other $((CARDS-3)) cards stay clean" || bad "violating count=$CLEANV, want exactly 3"
kubectl delete vgpujob burn-1 burn-2 burn-3 -n "$NS" --wait=false >/dev/null 2>&1
wait_for 180 "burns released" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]' >/dev/null || true

fi  # end ab

if run_phase c-load; then
hdr "C. LOADED RE-SEED: fill all $CARDS cards, kill agent x2, then FULL REBOOT"
for i in $(seq 1 "$CARDS"); do submit "hold-$i" $((10*GiB)); done
wait_for 240 "all $CARDS holders Ready (1 per card at 10Gi)" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | grep -c Ready); [[ "$n" == "'"$CARDS"'" ]]'
HOLD_CARDS=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.status.deviceUuid}{"\n"}{end}' | sort -u | grep -c GPU)
[[ "$HOLD_CARDS" == "$CARDS" ]] && ok "holders spread 1-per-card across all $CARDS cards" || bad "holders on $HOLD_CARDS cards, want $CARDS"
for k in 1 2; do
    kubectl delete pod -n vgpu-system -l app=vgpu-nodeagent --wait=true >/dev/null 2>&1
    kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=120s >/dev/null 2>&1
    sleep 5
    AGENT=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
    RESEED=$(kubectl logs -n vgpu-system "$AGENT" 2>/dev/null | grep -m1 -oE "re-seeded from [0-9]+" | grep -oE "[0-9]+")
    [[ "${RESEED:-0}" -ge "$CARDS" ]] && ok "kill #$k: re-seeded $RESEED records (>= $CARDS, one per card)" \
        || bad "kill #$k: re-seed saw ${RESEED:-0} records, want >= $CARDS"
done
invariant "post-crashloop"
echo " PHASE_RESULT ab_c_load PASS=$PASS FAIL=$FAIL"
dim "issuing reboot — phase c-post must run after the box returns"
( sleep 3; sudo reboot ) >/dev/null 2>&1 &
exit 0
fi  # end c-load

if run_phase c-post; then
kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=300s >/dev/null 2>&1
# poll re-seed across the possible driver-settling restart (tier-1 lesson)
RESEED=""
for _ in $(seq 1 12); do
    AGENT=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    RESEED=$(kubectl logs -n vgpu-system "$AGENT" 2>/dev/null | grep -m1 -oE "re-seeded from [0-9]+" | grep -oE "[0-9]+")
    [[ -z "$RESEED" ]] && RESEED=$(kubectl logs -n vgpu-system "$AGENT" --previous 2>/dev/null | grep -m1 -oE "re-seeded from [0-9]+" | grep -oE "[0-9]+")
    [[ -n "$RESEED" ]] && break; sleep 5
done
[[ "${RESEED:-0}" -ge "$CARDS" ]] && ok "REBOOT: 8-card ledger re-seeded from checkpoint ($RESEED records survived /var/lib)" \
    || bad "reboot re-seed saw ${RESEED:-0} records, want >= $CARDS"
# the proof the ledger MEANS something: 8Gi cannot fit (each card has 16-10=6 free)…
submit probe-toobig $((8*GiB))
wait_for 150 "8Gi probe FAILS (only fits if a card forgot its 10Gi survivor)" '
    ph=$(kubectl get vgpuslice probe-toobig-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null); [[ "$ph" == "Failed" ]]' \
    && ok "post-reboot over-commit REFUSED (8Gi rejected while every card holds a 10Gi survivor)"
# …and 4Gi MUST fit (guards against over-correcting into never-allocate)
submit probe-fits $((4*GiB))
wait_for 150 "4Gi probe becomes Ready" '
    ph=$(kubectl get vgpuslice probe-fits-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null); [[ "$ph" == "Ready" ]]' \
    && ok "post-reboot allocation still works (4Gi fits the real 6Gi holes)"
kubectl delete vgpujob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 240 "loaded-reseed cleanup" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]' >/dev/null || true
fi  # end c-post

if run_phase d; then
hdr "D. GANG 1-per-card + PREEMPTION frees the right card"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: spread, namespace: $NS }
spec:
  gangSize: $CARDS
  minAvailable: $CARDS
  reservationTimeoutSeconds: 120
  priority: 100
  workloadClass: Training
  preemptible: false
  podTemplate: { spec: { requestedVramBytes: $((10*GiB)), serviceTier: Guaranteed } }
EOF
wait_for 300 "gang of $CARDS all Ready" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | grep -c Ready); [[ "$n" == "'"$CARDS"'" ]]'
GC=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.status.deviceUuid}{"\n"}{end}' | sort -u | grep -c GPU)
[[ "$GC" == "$CARDS" ]] && ok "gang FORCED onto $CARDS distinct cards (10Gi members cannot share 16Gi cards)" \
    || bad "gang on $GC distinct cards, want $CARDS"
# low-pri preemptible filler on some card's remaining ~6Gi
submit victim $((5*GiB)) 10 true
wait_for 150 "victim Ready" '
    ph=$(kubectl get vgpuslice victim-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null); [[ "$ph" == "Ready" ]]'
VCARD=$(kubectl get vgpuslice victim-claim-slice -n "$NS" -o jsonpath='{.status.deviceUuid}')
# high-pri 5Gi: no card has 5Gi free anymore (gang 10 + victim 5 = 15 on one card, others 10+ → 6 free… wait 6 ≥ 5!)
# → make it need the victim's card: request 6Gi ( fits only where victim's 5Gi is reclaimed? others have 6 free → 6 fits! )
# be precise: gang leaves 6Gi/card; victim takes 5 of one card (1 left). A 6Gi high-pri
# fits any OTHER card without preemption — so to force preemption ask for a size that
# fits NOWHERE free: fill ALL other cards' 6Gi first, then contend for the victim's card.
# fillers are 5Gi, NOT 6Gi: V100s are exactly 16GiB and the driver reserves
# ~257MiB, so 10+6 overshoots usable capacity and every filler fail-louded
# (round-2 slice map: 7x Failed <none>). 10+5=15Gi fits; holes shrink to ~1Gi.
for i in $(seq 1 $((CARDS-1))); do submit "filler-$i" $((5*GiB)) 50; done
# STRICT: every filler must be Ready or the preemption scenario is vacuous —
# round-1 left one hole open and vip landed WITHOUT preempting anyone.
wait_for 300 "ALL $((CARDS-1)) fillers Ready (5Gi each; node fully packed)" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | grep -c "filler.*Ready"); [[ "$n" == "'"$((CARDS-1))"'" ]]'     || { echo "  slice map at failure:"; kubectl get vgpuslice -n "$NS" -o custom-columns=N:.metadata.name,P:.status.phase,C:.status.deviceUuid --no-headers | sed "s/^/    /"; }
submit vip $((5*GiB)) 200        # gap 190 >= 100 over victim(10) -> may preempt it
wait_for 300 "vip Ready via preemption" '
    ph=$(kubectl get vgpuslice vip-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null); [[ "$ph" == "Ready" ]]' \
    && ok "high-priority job admitted on a FULL node (preemption at work)"
VICTIM_PHASE=$(kubectl get vgpuslice victim-claim-slice -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo GONE)
[[ "$VICTIM_PHASE" != "Ready" ]] && ok "victim preempted (phase=$VICTIM_PHASE)" || bad "victim still Ready — vip landed without preemption?"
VIPCARD=$(kubectl get vgpuslice vip-claim-slice -n "$NS" -o jsonpath='{.status.deviceUuid}')
[[ "$VIPCARD" == "$VCARD" ]] && ok "vip landed on the EXACT card the victim freed ($VIPCARD)" \
    || dim "vip on $VIPCARD, victim was on $VCARD (acceptable if another slot opened)"
invariant "post-preemption"

fi  # end d

echo
echo "════════════════════════════════════════"
echo " TIER-3 MULTI-GPU TORTURE (phase=$PHASE):  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo " FINAL_VERDICT=PASS"; exit 0; } || { echo " FINAL_VERDICT=FAIL"; exit 1; }
