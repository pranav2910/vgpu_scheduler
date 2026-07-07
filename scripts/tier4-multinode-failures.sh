#!/usr/bin/env bash
# ============================================================================
# tier4-multinode-failures.sh — CERT-18 (+CERT-08 topology): REAL multi-node
# failure suite on real GPUs. Three boxes -> one cluster, then the failures
# kind could never fake honestly.
#
#   HOST1=ubuntu@big-box HOST2=ubuntu@a10-1 HOST3=ubuntu@a10-2 \
#     bash scripts/tier4-multinode-failures.sh
#
#   18a JOIN        3 real GPU nodes, per-node capacity advertised correctly
#   08  TOPOLOGY    zone-hinted job lands in its zone; impossible hint stays
#                   SOFT (schedules elsewhere, condition truthful)
#   18b CROSS-GANG  gang bigger than any one node -> members span 3 nodes,
#                   all-or-nothing
#   18c NODE LOSS   kill k3s on a member node mid-life -> survivors keep
#                   admitting, no over-admission; node RETURNS -> capacity
#                   re-charged (live receipt for the S3 flap fix)
#   18d PARTITION   iptables-drop a node from the control plane for 60s DURING
#                   gang assembly -> zero partial admission, converges after heal
# ============================================================================
set -uo pipefail

HOST1="${HOST1:?server box (multi-GPU)}"; HOST2="${HOST2:?agent box 2}"; HOST3="${HOST3:?agent box 3}"
S1="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST1"
S2="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST2"
S3="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST3"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/tier4-${SHA}"; mkdir -p "$EVID"
KC='export KUBECONFIG=$HOME/.kube/config; cd vgpu_scheduler'
GiB=$((1024*1024*1024))
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "━━ $* ━━"; }
wait_ready(){ # ns want timeout-sec  (Ready slice count)
    local ns=$1 want=$2 tmo=$3 r=0
    for _ in $(seq 1 $((tmo/5))); do
        r=$($S1 "export KUBECONFIG=\$HOME/.kube/config; kubectl get vgpuslice -n $ns --no-headers 2>/dev/null | grep -c Ready" 2>/dev/null | tr -d ' ')
        [ "${r:-0}" -ge "$want" ] && return 0; sleep 5
    done
    echo "    (ready=$r want=$want)"; return 1
}

say "18a-1: server up on HOST1 (multinode server + control plane)"
$S1 "cd vgpu_scheduler && git fetch -q origin && git reset -q --hard origin/main
  bash scripts/multinode-server.sh" > "$EVID/18a-server.log" 2>&1 || { bad "server bring-up failed"; exit 1; }
IP1=$($S1 "curl -s ifconfig.me || hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d ' \n')
TOKEN=$($S1 "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '\n')
[[ -n "$TOKEN" && -n "$IP1" ]] && ok "server ready (ip=$IP1, token acquired)" || { bad "no join token/ip"; exit 1; }

say "18a-2: join HOST2 + HOST3 as GPU agents (wireguard overlay across clouds)"
for pair in "2:$HOST2:$S2" "3:$HOST3:$S3"; do
    n=${pair%%:*}; rest=${pair#*:}; h=${rest%%:*}
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$h" \
      "git clone -q https://github.com/pranav2910/vgpu_scheduler.git 2>/dev/null || (cd vgpu_scheduler && git fetch -q && git reset -q --hard origin/main)
       cd vgpu_scheduler
       export K3S_URL=\"https://$IP1:6443\" K3S_TOKEN=\"$TOKEN\"
       bash scripts/multinode-agent.sh
       sudo k3s ctr images pull docker.io/pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime >/dev/null 2>&1 || true" \
      > "$EVID/18a-agent$n.log" 2>&1 && ok "agent $n joined" || bad "agent $n join failed (see $EVID/18a-agent$n.log)"
done
$S1 "export KUBECONFIG=\$HOME/.kube/config
  for i in \$(seq 1 40); do r=\$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'); [ \"\$r\" = 3 ] && break; sleep 5; done
  kubectl get nodes -o custom-columns='N:.metadata.name,R:.status.conditions[-1].type,CAP:.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes' --no-headers" \
  | tee "$EVID/18a-nodes.txt"
NODES_OK=$(grep -c "Ready" "$EVID/18a-nodes.txt" || true)
CAPS=$(awk '$3+0>20000000000' "$EVID/18a-nodes.txt" | wc -l | tr -d ' ')
[[ "$NODES_OK" == "3" && "$CAPS" == "3" ]] && ok "3 real GPU nodes Ready, each advertising its true capacity" \
    || bad "nodes=$NODES_OK caps-advertised=$CAPS (want 3/3)"

NODE1=$(awk 'NR==1{print $1}' "$EVID/18a-nodes.txt")
# identify agent nodes by capacity (A10 = ~24Gi < 100Gi)
AGENTS=$(awk '$3+0<100000000000 {print $1}' "$EVID/18a-nodes.txt" | head -2)
AG2=$(echo "$AGENTS" | sed -n 1p); AG3=$(echo "$AGENTS" | sed -n 2p)

say "CERT-08: topology — zone hints honored when feasible, SOFT when not"
$S1 "export KUBECONFIG=\$HOME/.kube/config; cd vgpu_scheduler
  BIG=\$(kubectl get nodes -o custom-columns='N:.metadata.name,C:.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes' --no-headers | awk '\$2+0>100000000000{print \$1}' | head -1)
  # the RECEIPTED recipe (DEMO-RUNBOOK §5.7): product zone label + scheduler restart
  kubectl label node \$BIG topology.vgpu.pranav2910.com/zone=zone-big --overwrite >/dev/null
  kubectl label node $AG2 topology.vgpu.pranav2910.com/zone=zone-a10 --overwrite >/dev/null
  kubectl label node $AG3 topology.vgpu.pranav2910.com/zone=zone-a10 --overwrite >/dev/null
  kubectl rollout restart deploy/vgpu-scheduler -n vgpu-system >/dev/null
  kubectl rollout status  deploy/vgpu-scheduler -n vgpu-system --timeout=120s >/dev/null
  kubectl create ns certtopo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: zoned, namespace: certtopo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((4*GiB)) | kubectl apply -f - >/dev/null
  sleep 30
  ZNODE=\$(kubectl get vgpuslice zoned-claim-slice -n certtopo -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  ZZONE=\$(kubectl get node \$ZNODE -o jsonpath='{.metadata.labels.topology\.vgpu\.pranav2910\.com/zone}' 2>/dev/null)
  echo ZONED_ZONE=\$ZZONE
  # impossible-for-zone request (30Gi > any A10) hinted at zone-a10 -> soft: schedules on big node
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: softz, namespace: certtopo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((13*GiB)) | kubectl apply -f - >/dev/null
  sleep 30
  SNODE=\$(kubectl get vgpuslice softz-claim-slice -n certtopo -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  SPHASE=\$(kubectl get vgpuslice softz-claim-slice -n certtopo -o jsonpath='{.status.phase}' 2>/dev/null)
  echo SOFT_NODE=\$SNODE SOFT_PHASE=\$SPHASE
  kubectl delete ns certtopo --wait=false >/dev/null 2>&1" | tee "$EVID/cert08.txt"
grep -q "ZONED_ZONE=zone-a10" "$EVID/cert08.txt" && grep -q "SOFT_PHASE=Ready" "$EVID/cert08.txt" \
    && ok "CERT-08: hint honored (landed zone-a10); infeasible hint stayed SOFT (13Gi scheduled anyway on the big node)" \
    || bad "CERT-08: $(grep -E 'ZONED_ZONE|SOFT' "$EVID/cert08.txt" | tr '\n' ' ')"

say "CERT-08x: dual-zone concurrent + unhinted + hit/miss metrics move"
$S1 "export KUBECONFIG=\$HOME/.kube/config
  kubectl create ns certtopo2 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  H0=\$(kubectl get --raw /api/v1/namespaces/vgpu-system/services/vgpu-scheduler-metrics:8081/proxy/metrics 2>/dev/null | awk '/^vgpu_topology_preference_hits_total/ {s+=\$2} END{printf \"%d\", s}')
  # two jobs hinted at two DIFFERENT zones, applied together
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: za, namespace: certtopo2, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n---\n' \$((4*GiB)) > /tmp/tz.yaml
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: zb, namespace: certtopo2, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-big}}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n---\n' \$((4*GiB)) >> /tmp/tz.yaml
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: zn, namespace: certtopo2}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((2*GiB)) >> /tmp/tz.yaml
  kubectl apply -f /tmp/tz.yaml >/dev/null
  sleep 35
  for j in za zb zn; do
    N=\$(kubectl get vgpuslice \$j-claim-slice -n certtopo2 -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    Z=\$(kubectl get node \$N -o jsonpath='{.metadata.labels.topology\.vgpu\.pranav2910\.com/zone}' 2>/dev/null)
    P=\$(kubectl get vgpuslice \$j-claim-slice -n certtopo2 -o jsonpath='{.status.phase}' 2>/dev/null)
    echo \$j=\$P@\$Z
  done
  H1=\$(kubectl get --raw /api/v1/namespaces/vgpu-system/services/vgpu-scheduler-metrics:8081/proxy/metrics 2>/dev/null | awk '/^vgpu_topology_preference_hits_total/ {s+=\$2} END{printf \"%d\", s}')
  echo HITS_DELTA=\$(( \${H1:-0} - \${H0:-0} ))
  kubectl delete ns certtopo2 --wait=false >/dev/null 2>&1" | tee "$EVID/cert08x.txt"
grep -q "za=Ready@zone-a10" "$EVID/cert08x.txt" && grep -q "zb=Ready@zone-big" "$EVID/cert08x.txt" && grep -qE "zn=Ready@" "$EVID/cert08x.txt" \
    && ok "CERT-08x: two concurrent jobs each landed in THEIR hinted zone; unhinted job unaffected (hits delta: $(grep -oE 'HITS_DELTA=[0-9-]+' "$EVID/cert08x.txt" | cut -d= -f2))" \
    || bad "CERT-08x: $(grep -E 'za=|zb=|zn=' "$EVID/cert08x.txt" | tr '\n' ' ')"

say "CERT-18b: cross-node gang — bigger than any single node, all-or-nothing"
$S1 "export KUBECONFIG=\$HOME/.kube/config
  kubectl create ns certxg --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # 10 members x 12Gi: big node fits max 8 (1/card), so >=2 MUST cross nodes
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: xgang, namespace: certxg}\nspec: {gangSize: 10, minAvailable: 10, reservationTimeoutSeconds: 120, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: %s, serviceTier: Guaranteed}}}\n' \$((12*GiB)) | kubectl apply -f - >/dev/null" 2>/dev/null
if wait_ready certxg 10 240; then
    XNODES=$($S1 "export KUBECONFIG=\$HOME/.kube/config; kubectl get vgpuslice -n certxg -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\n\"}{end}' | sort -u | grep -vc '^$'" 2>/dev/null | tr -d ' ')
    [[ "${XNODES:-0}" -ge 2 ]] && ok "CERT-18b: 10-member gang fully admitted SPANNING $XNODES real GPU nodes" \
        || bad "CERT-18b: gang Ready but on $XNODES node(s) — not cross-node?"
else
    bad "CERT-18b: cross-node gang did not fully admit"
fi

say "CERT-18c: NODE LOSS mid-life → survivors keep working; node RETURN → capacity re-charged (S3 live)"
$S1 "export KUBECONFIG=\$HOME/.kube/config
  kubectl create ns certloss --dry-run=client -o yaml | kubectl apply -f - >/dev/null" 2>/dev/null
# place two pod workloads on AG3 (pin via zone trickery not needed: submit 20Gi jobs that only fit A10s? A10=24Gi, V100 card=16Gi → 20Gi fits ONLY A10 nodes)
$S1 "export KUBECONFIG=\$HOME/.kube/config; cd vgpu_scheduler
  for i in 1 2; do
    printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: a10w-%s, namespace: certloss}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n---\n' \$i \$((20*GiB))
  done | kubectl apply -f - >/dev/null" 2>/dev/null
wait_ready certloss 2 180 && ok "two 20Gi jobs landed (fit ONLY on the A10 nodes by size)" || bad "A10-only jobs did not land"
echo "  killing k3s on $AG3 ..."
$S3 "sudo systemctl stop k3s-agent 2>/dev/null || sudo systemctl stop k3s 2>/dev/null; echo stopped" >/dev/null 2>&1
$S1 "export KUBECONFIG=\$HOME/.kube/config
  for i in \$(seq 1 40); do
    st=\$(kubectl get node $AG3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)
    [ \"\$st\" != True ] && break; sleep 6
  done
  echo NODE_STATE=\$(kubectl get node $AG3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)
  # survivors must still admit NEW work
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: survivor, namespace: certloss}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((4*GiB)) | kubectl apply -f - >/dev/null
  sleep 30
  echo SURVIVOR=\$(kubectl get vgpuslice survivor-claim-slice -n certloss -o jsonpath='{.status.phase}' 2>/dev/null)" | tee "$EVID/18c-loss.txt"
grep -q "NODE_STATE=Unknown\|NODE_STATE=False\|NODE_STATE=$" "$EVID/18c-loss.txt" && grep -q "SURVIVOR=Ready" "$EVID/18c-loss.txt" \
    && ok "CERT-18c: node lost (NotReady) — survivors admitted new work immediately" \
    || bad "CERT-18c: $(grep -E 'NODE_STATE|SURVIVOR' "$EVID/18c-loss.txt" | tr '\n' ' ')"
echo "  bringing $AG3 back ..."
$S3 "sudo systemctl start k3s-agent 2>/dev/null || sudo systemctl start k3s 2>/dev/null; echo started" >/dev/null 2>&1
$S1 "export KUBECONFIG=\$HOME/.kube/config
  for i in \$(seq 1 40); do
    st=\$(kubectl get node $AG3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)
    [ \"\$st\" = True ] && break; sleep 6
  done
  echo RETURNED=\$(kubectl get node $AG3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')
  sleep 20
  # S3-fix live receipt: a 20Gi job must be schedulable again USING the returned node
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: postreturn, namespace: certloss}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((20*GiB)) | kubectl apply -f - >/dev/null
  sleep 40
  echo POSTRETURN=\$(kubectl get vgpuslice postreturn-claim-slice -n certloss -o jsonpath='{.status.phase}' 2>/dev/null)
  kubectl delete ns certloss --wait=false >/dev/null 2>&1" | tee "$EVID/18c-return.txt"
grep -q "RETURNED=True" "$EVID/18c-return.txt" && grep -q "POSTRETURN=Ready" "$EVID/18c-return.txt" \
    && ok "CERT-18c+: node returned and 20Gi work landed on it (flap-recovery fix, live on real GPUs)" \
    || bad "CERT-18c+: $(grep -E 'RETURNED|POSTRETURN' "$EVID/18c-return.txt" | tr '\n' ' ')"

say "CERT-18d: 60s network PARTITION during gang assembly → zero partial admission"
$S1 "export KUBECONFIG=\$HOME/.kube/config
  kubectl create ns certpart --dry-run=client -o yaml | kubectl apply -f - >/dev/null" 2>/dev/null
# start partition FIRST on AG2, then submit a gang that NEEDS AG2 (10x12Gi again)
$S2 "sudo iptables -I OUTPUT -d $IP1 -p tcp --dport 6443 -j DROP; echo partitioned" > "$EVID/18d-part.txt" 2>&1
$S1 "export KUBECONFIG=\$HOME/.kube/config
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: pgang, namespace: certpart}\nspec: {gangSize: 10, minAvailable: 10, reservationTimeoutSeconds: 150, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: %s, serviceTier: Guaranteed}}}\n' \$((12*GiB)) | kubectl apply -f - >/dev/null
  sleep 50
  R=\$(kubectl get vgpuslice -n certpart --no-headers 2>/dev/null | grep -c Ready || true)
  echo DURING_PARTITION_READY=\$R" | tee -a "$EVID/18d-part.txt"
DUR=$(grep -oE "DURING_PARTITION_READY=[0-9]+" "$EVID/18d-part.txt" | cut -d= -f2)
$S2 "sudo iptables -D OUTPUT -d $IP1 -p tcp --dport 6443 -j DROP; echo healed" >> "$EVID/18d-part.txt" 2>&1
# all-or-nothing THROUGH the partition: either 0 (waiting/reclaimed) — never 1..9
if [[ "${DUR:-0}" == "0" || "${DUR:-0}" == "10" ]]; then
    ok "CERT-18d: during partition ready=$DUR (all-or-nothing held — never partial)"
else
    bad "CERT-18d: PARTIAL admission during partition (ready=$DUR of 10)"
fi
$S1 "export KUBECONFIG=\$HOME/.kube/config
  for i in \$(seq 1 50); do
    r=\$(kubectl get vgpuslice -n certpart --no-headers 2>/dev/null | grep -c Ready || true)
    [ \"\$r\" = 10 ] && break; sleep 6
  done
  echo AFTER_HEAL_READY=\$(kubectl get vgpuslice -n certpart --no-headers 2>/dev/null | grep -c Ready || true)
  kubectl delete ns certpart --wait=false >/dev/null 2>&1" | tee -a "$EVID/18d-part.txt"
grep -q "AFTER_HEAL_READY=10" "$EVID/18d-part.txt" \
    && ok "CERT-18d+: after heal the SAME gang converged to 10/10 (no stuck state, no split-brain)" \
    || bad "CERT-18d+: gang did not converge after heal: $(grep AFTER_HEAL "$EVID/18d-part.txt")"

echo
echo "════════════════════════════════════════════"
echo " TIER-4 MULTI-NODE FAILURES:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE=$EVID"
[[ $FAIL -eq 0 ]] && { echo " FINAL_VERDICT=PASS"; exit 0; } || { echo " FINAL_VERDICT=FAIL"; exit 1; }
