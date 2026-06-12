#!/usr/bin/env bash
# validate-multinode.sh — M-NODE D6: prove true multi-node scheduling on a
# cluster built with multinode-server.sh + multinode-agent.sh. Run ON THE SERVER.
#
#   T1  SPREAD        grants exceed one node → slices land on ≥2 nodes, all Ready
#   T2  NODE-FIT      a grant bigger than ANY node never binds (stays Pending)
#   T3  CROSS-NODE GANG  a gang too big for one node commits all-or-nothing
#                     with members on multiple nodes
#   T4  TOPOLOGY      zone labels honored (soft preference, auditable condition)
#   T5  NODE LOSS     delete a node from the API → its capacity vanishes from
#                     the scheduler (RemoveNode), new work lands on survivors
#
# T5 is destructive to the CLUSTER VIEW (the node object is deleted; re-join =
# restart k3s-agent on that box). It runs last and only with --node-loss.
#
#   bash scripts/validate-multinode.sh              # T1–T4
#   bash scripts/validate-multinode.sh --node-loss  # T1–T5
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

GiB=$((1024*1024*1024))
NS="mnode-$(date +%s)"
NODE_LOSS=0; [[ "${1:-}" == "--node-loss" ]] && NODE_LOSS=1

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
dim(){ echo "  ${C_DIM}$*${C_RST}"; }

cleanup(){ hdr cleanup; kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; dim "namespace deleted"; }
trap cleanup EXIT

wait_for() { local t=$1 desc=$2; shift 2
    for _ in $(seq 1 $((t/3))); do eval "$*" && return 0; sleep 3; done
    bad "timeout waiting for: $desc"; return 1
}

submit_grant() { # name bytes [annotation-kv]
    local ann=""
    [[ -n "${3:-}" ]] && ann="  annotations: { ${3} }"$'\n'
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata:
  name: $1
  namespace: $NS
${ann}spec:
  priority: 50
  workloadClass: Inference
  claimTemplate:
    spec:
      requestedVramBytes: $2
      serviceTier: Guaranteed
EOF
}

hdr "preflight: the cluster"
GPU_NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}{"\n"}{end}' | awk 'NF==2 && $2>0 {print}')
NNODES=$(printf '%s\n' "$GPU_NODES" | grep -c . || true)
[[ "$NNODES" -ge 2 ]] || { echo "need ≥2 GPU nodes advertising vgpu-bytes (found $NNODES) — did each agent's advertise one-liner run?"; exit 2; }
SMALLEST=$(printf '%s\n' "$GPU_NODES" | awk '{print $2}' | sort -n | head -1)
AGENTS=$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' "$GPU_NODES" | while read -r n c; do dim "$n → $((c>>30))Gi"; done
[[ "$AGENTS" -ge "$NNODES" ]] && ok "$NNODES GPU nodes, $AGENTS running node agents" \
    || bad "only $AGENTS agent pods for $NNODES nodes (image missing on a node?)"
kubectl create namespace "$NS" >/dev/null

# Grant size: ~40% of the smallest node → 2 fit per node, 3+ forces a spread.
SLICE=$(( (SMALLEST * 2 / 5) / GiB * GiB ))
PER_NODE=2
TOTAL=$((NNODES * PER_NODE))
dim "grant size $((SLICE>>30))Gi · $PER_NODE per node · $TOTAL total"

hdr "T1 — spread: $TOTAL grants must use every node"
for i in $(seq 1 "$TOTAL"); do submit_grant "mn-$i" "$SLICE"; done
wait_for 240 "all $TOTAL slices Ready" '
    n=$(kubectl get vgpuslice -n '"$NS"' -o jsonpath="{range .items[*]}{.status.phase}{\"\n\"}{end}" 2>/dev/null | grep -c "^Ready$");
    [[ "$n" == "'"$TOTAL"'" ]]
' || kubectl get vgpuslice -n "$NS"
NODES_USED=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)
[[ "$NODES_USED" == "$NNODES" ]] && ok "slices landed on all $NNODES nodes" \
    || bad "slices used $NODES_USED/$NNODES nodes"

hdr "T2 — node-level fit: a grant bigger than ANY node never binds"
TOOBIG=$(( SMALLEST + 8*GiB ))
submit_grant "mn-toobig" "$TOOBIG"
sleep 20
TB_NODE=$(kubectl get vgpuslice mn-toobig-claim-slice -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
TB_PHASE=$(kubectl get vgpuslice mn-toobig-claim-slice -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ -z "$TB_NODE" && "$TB_PHASE" != "Ready" && "$TB_PHASE" != "Failed" ]] \
    && ok "$((TOOBIG>>30))Gi grant correctly held Pending (no node can host it)" \
    || bad "too-big grant: node='$TB_NODE' phase='$TB_PHASE' (want unbound Pending)"
kubectl delete vgpujob mn-toobig -n "$NS" --wait=false >/dev/null 2>&1

hdr "T3 — cross-node gang: $TOTAL×$((SLICE>>30))Gi (cannot fit on one node) commits atomically"
kubectl delete vgpujob -n "$NS" --all --wait=false >/dev/null 2>&1
wait_for 240 "T1 grants drained" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]
' || exit 1
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: mn-gang, namespace: $NS }
spec:
  gangSize: $TOTAL
  minAvailable: $TOTAL
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 120
  podTemplate:
    spec:
      requestedVramBytes: $SLICE
      serviceTier: Guaranteed
EOF
wait_for 180 "gang Committed" '
    ph=$(kubectl get vgpugangreservation -n '"$NS"' mn-gang-rsv -o jsonpath="{.status.phase}" 2>/dev/null);
    [[ "$ph" == "Committed" ]]
' || kubectl get vgpugangreservation,vgpuslice -n "$NS"
GANG_NODES=$(kubectl get vgpuslice -n "$NS" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)
[[ "$GANG_NODES" -ge 2 ]] && ok "gang committed with members across $GANG_NODES nodes (all-or-nothing held cross-node)" \
    || bad "gang members on $GANG_NODES node(s), want ≥2"
kubectl delete vgpugangjob mn-gang -n "$NS" --wait=false >/dev/null 2>&1
wait_for 240 "gang drained" '
    n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]
' || true

hdr "T4 — topology: zone preference honored (soft, auditable)"
read -r NODE_A CAP_A <<<"$(printf '%s\n' "$GPU_NODES" | head -1)"
read -r NODE_B CAP_B <<<"$(printf '%s\n' "$GPU_NODES" | sed -n 2p)"
kubectl label node "$NODE_A" topology.vgpu.pranav2910.com/zone=zone-a --overwrite >/dev/null
kubectl label node "$NODE_B" topology.vgpu.pranav2910.com/zone=zone-b --overwrite >/dev/null
submit_grant "mn-zoneb" "$SLICE" '"topology.vgpu.pranav2910.com/preferred-zone": "zone-b"'
wait_for 90 "zone-preferring grant Ready" '
    ph=$(kubectl get vgpuslice mn-zoneb-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null);
    [[ "$ph" == "Ready" ]]
' || true
ZN=$(kubectl get vgpuslice mn-zoneb-claim-slice -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
[[ "$ZN" == "$NODE_B" ]] && ok "preferred zone-b honored (landed on $ZN)" \
    || bad "zone preference missed: landed on '$ZN', preferred $NODE_B (check TopologyPreferenceSatisfied condition)"
kubectl delete vgpujob mn-zoneb -n "$NS" --wait=false >/dev/null 2>&1

if [[ "$NODE_LOSS" == "1" ]]; then
    hdr "T5 — node loss: delete $NODE_B from the API; new work must land on survivors"
    wait_for 120 "prior grants drained" '
        n=$(kubectl get vgpuslice -n '"$NS"' --no-headers 2>/dev/null | wc -l | tr -d " "); [[ "$n" == "0" ]]
    ' || true
    kubectl delete node "$NODE_B" >/dev/null 2>&1
    dim "node object deleted (re-join later: ssh to $NODE_B and 'sudo systemctl restart k3s-agent')"
    sleep 10
    submit_grant "mn-afterloss" "$SLICE"
    wait_for 120 "post-loss grant Ready on a survivor" '
        ph=$(kubectl get vgpuslice mn-afterloss-claim-slice -n '"$NS"' -o jsonpath="{.status.phase}" 2>/dev/null);
        nd=$(kubectl get vgpuslice mn-afterloss-claim-slice -n '"$NS"' -o jsonpath="{.spec.nodeName}" 2>/dev/null);
        [[ "$ph" == "Ready" && -n "$nd" && "$nd" != "'"$NODE_B"'" ]]
    ' && ok "ghost node never used: new grant Ready on a surviving node (RemoveNode live)" \
      || bad "post-loss grant did not land cleanly on a survivor"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Multi-node proven: spread, node-level fit, cross-node gang atomicity, topology${C_RST}${C_GRN}$([[ $NODE_LOSS == 1 ]] && echo ', live node-loss')${C_GRN}.${C_RST}"
    exit 0
fi
echo; echo "${C_RED}multi-node validation FAILED${C_RST}"; exit 1
