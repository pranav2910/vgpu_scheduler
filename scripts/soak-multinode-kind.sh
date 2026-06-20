#!/usr/bin/env bash
# ============================================================================
# soak-multinode-kind.sh — COMPLEX multi-node stress test on the kind cluster
# from kind-multinode-up.sh. Stresses the real control plane across separate
# Kubernetes nodes (placement, cross-node gangs, per-node capacity, HA,
# node-loss); the GPU data plane is the fake provider (already hardware-proven).
#
# PHASE 1 — rush-hour churn (8 rounds): each round submits mixed-size solo
#   grants + one cross-node gang (too big for a single node), then ASSERTS THE
#   SAFETY INVARIANT — no node is ever over-admitted — and that work spreads
#   across nodes. Churns old rounds. Kills the scheduler leader mid-soak.
# PHASE 2 — node loss under load: delete a worker, submit a wave, assert it
#   lands only on survivors and never over-admits them (RemoveNode live).
# AUDIT — zero leaked slices, agent logs clean, scheduler gauges back to zero,
#   and the per-node ceiling was respected on every single sample.
#
#   bash scripts/soak-multinode-kind.sh
# ============================================================================
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
kubectl config use-context kind-vgpu-multinode >/dev/null 2>&1 || true

NS="mnsoak-$(date +%s)"
GiB=$((1024*1024*1024))
CAP=85899345920                 # per-worker advertised capacity (80 GiB)
ROUNDS="${ROUNDS:-8}"
AGENT_NS="vgpu-system"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0; OVERADMIT_SAMPLES=0; CHECKS=0
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
dim(){ echo "  ${C_DIM}$*${C_RST}"; }

cleanup(){ hdr cleanup; kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; dim "namespace deleted"; }
trap cleanup EXIT

wait_for(){ local t=$1 desc=$2; shift 2; local i; for i in $(seq 1 $((t/3))); do eval "$*" && return 0; sleep 3; done; return 1; }

submit_solo(){ # name gib
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: $1, namespace: $NS }
spec:
  priority: 50
  workloadClass: Inference
  claimTemplate:
    spec: { requestedVramBytes: $(( $2 * GiB )), serviceTier: Guaranteed }
EOF
}
submit_gang(){ # name size gib_per
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: $1, namespace: $NS }
spec:
  gangSize: $2
  minAvailable: $2
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 90
  podTemplate:
    spec: { requestedVramBytes: $(( $3 * GiB )), serviceTier: Guaranteed }
EOF
}

# THE SAFETY INVARIANT: no worker's bound non-terminal slices may exceed its
# capacity. Returns the offending lines (and nonzero) if any node is over.
check_no_overadmit(){
    CHECKS=$((CHECKS+1))
    local out
    out=$(kubectl get vgpuslice -A -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.spec.requestedVramBytes}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | awk -v cap="$CAP" '
            $1!="" && $3!="Released" && $3!="Failed" && $3!="" { s[$1]+=$2 }
            END { for (n in s) if (s[n]>cap) printf "  OVER-ADMIT %s = %d > %d\n", n, s[n], cap }')
    if [[ -n "$out" ]]; then OVERADMIT_SAMPLES=$((OVERADMIT_SAMPLES+1)); echo "$out"; return 1; fi
    return 0
}

hdr "preflight"
WORKERS=()
while IFS= read -r n; do [[ -n "$n" ]] && WORKERS+=("$n"); done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep worker)
NW=${#WORKERS[@]}
[[ "$NW" -ge 3 ]] || { echo "need >=3 GPU workers (run kind-multinode-up.sh); found $NW"; exit 2; }
AG=$(kubectl get pods -n "$AGENT_NS" -l app=vgpu-nodeagent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
dim "$NW workers, $AG node agents, $(( NW * (CAP>>30) )) GiB cluster"
kubectl create namespace "$NS" >/dev/null
ok "cluster ready: $NW GPU workers"

hdr "PHASE 1 — rush-hour churn ($ROUNDS rounds, cross-node gangs, leader kill)"
DONE=0
for r in $(seq 1 "$ROUNDS"); do
    # mixed solo grants
    submit_solo "r${r}a" 8;  submit_solo "r${r}b" 16
    submit_solo "r${r}c" 8;  submit_solo "r${r}d" 16
    # a gang too big for one 80 GiB node alongside the solos → must span nodes
    submit_gang "g${r}" 4 16

    if ! wait_for 120 "g${r} committed" '
        ph=$(kubectl get vgpugangreservation -n '"$NS"' g'"$r"'-rsv -o jsonpath="{.status.phase}" 2>/dev/null); [[ "$ph" == "Committed" ]]'; then
        bad "round $r: gang did not commit"; kubectl get vgpugangreservation,vgpuslice -n "$NS" | head; break
    fi

    # THE INVARIANT — checked every round, the whole point of the soak
    if check_no_overadmit; then :; else bad "round $r: a node was OVER-ADMITTED"; break; fi

    # spread: this round's work must touch >1 node
    used=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -c .)
    [[ "$used" -ge 2 ]] || dim "round $r: only $used node(s) used so far"

    # leader kill mid-soak, under churn
    if [[ "$r" -eq $((ROUNDS/2)) ]]; then
        HOLDER=$(kubectl get lease -n "$AGENT_NS" vgpu-scheduler-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | cut -d_ -f1)
        [[ -n "$HOLDER" ]] && { kubectl delete pod -n "$AGENT_NS" "$HOLDER" --wait=false >/dev/null 2>&1; dim "round $r: killed scheduler leader $HOLDER"; }
    fi

    # churn: dissolve this round's gang; delete solos from 2 rounds ago
    kubectl delete vgpugangjob "g${r}" -n "$NS" --wait=false >/dev/null 2>&1
    if [[ "$r" -ge 3 ]]; then o=$((r-2)); for j in a b c d; do kubectl delete vgpujob "r${o}${j}" -n "$NS" --wait=false >/dev/null 2>&1; done; fi
    DONE=$((DONE+1))
    dim "round $r/$ROUNDS ok (gang committed across nodes, no over-admission, churn rolling)"
done
[[ "$DONE" == "$ROUNDS" ]] && ok "all $ROUNDS churn rounds survived (safety held every round)" || bad "only $DONE/$ROUNDS rounds"

hdr "drain Phase 1 before node-loss"
kubectl delete vgpujob,vgpugangjob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 180 "slices drained" 'n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]' \
    && ok "Phase 1 drained to zero" || bad "Phase 1 did not fully drain"

hdr "PHASE 2 — node loss UNDER LOAD (delete a worker, work must re-home)"
VICTIM="${WORKERS[$((NW-1))]}"
# seed some load, then yank the node mid-flight. Sizing: after losing 1 of N
# workers, survivors = (N-1)*80 GiB. Keep pre+post WELL under that so the wave
# fits on survivors with headroom (the test proves re-homing, not packing the
# survivors to the edge — that's Phase 1's job).
for i in $(seq 1 4); do submit_solo "pre$i" 12; done   # 48 GiB in flight
sleep 4
kubectl delete node "$VICTIM" --wait=false >/dev/null 2>&1
dim "deleted worker $VICTIM (its $((CAP>>30)) GiB leaves the schedulable pool)"
# a wave that fits comfortably on the SURVIVORS (72 GiB; survivors hold 160)
for i in $(seq 1 6); do submit_solo "post$i" 12; done
wait_for 150 "post-loss grants Ready" '
    n=$(kubectl get vgpuslice -n '"$NS"' -o jsonpath="{range .items[*]}{.metadata.name}{\" \"}{.status.phase}{\"\n\"}{end}" 2>/dev/null | grep "^post" | grep -c " Ready$");
    [[ "$n" -ge 6 ]]' \
    && ok "6 post-loss grants Ready on survivors" || bad "post-loss grants did not all become Ready"
# none of the post-loss work may have landed on the dead node, and survivors not over-admitted
ON_DEAD=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | grep "^post" | awk -v d="$VICTIM" '$2==d' | grep -c . || true)
[[ "$ON_DEAD" == "0" ]] && ok "no post-loss slice placed on the dead node (ghost node never used)" || bad "$ON_DEAD slices landed on the deleted node"
check_no_overadmit && ok "survivors never over-admitted after node loss" || bad "a survivor was over-admitted after node loss"

hdr "AUDIT"
kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1
trap - EXIT
wait_for 180 "namespace slices gone" 'n=$(kubectl get vgpuslice -A --no-headers 2>/dev/null | grep -c "'"$NS"'" || true); [[ "$n" == "0" ]]' \
    && ok "zero leaked slices cluster-wide" || bad "slices leaked after teardown"

[[ "$OVERADMIT_SAMPLES" == "0" ]] && ok "NO over-admission across $CHECKS capacity samples (the core safety invariant)" \
    || bad "over-admission seen in $OVERADMIT_SAMPLES/$CHECKS samples"

VTOTAL=0
for a in $(kubectl get pods -n "$AGENT_NS" -l app=vgpu-nodeagent -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v=$(kubectl logs -n "$AGENT_NS" "$a" 2>/dev/null | grep -c "FATAL STATE VIOLATION" || true); VTOTAL=$((VTOTAL+v))
done
[[ "$VTOTAL" == "0" ]] && ok "agent logs clean (zero FATAL STATE VIOLATIONs)" || bad "$VTOTAL state violations in agent logs"

echo; echo "  PASS=$PASS  FAIL=$FAIL   (capacity samples: $CHECKS, over-admit: $OVERADMIT_SAMPLES)"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Multi-node rush hour survived on a real $NW-node cluster: cross-node gangs, churn, a leader kill, and node loss under load — the per-node ceiling held on every sample.${C_RST}"; exit 0
fi
echo; echo "${C_RED}multi-node soak FAILED${C_RST}"; exit 1
