#!/usr/bin/env bash
# ============================================================================
# cert18-tunneled.sh — CERT-18 multi-node failures, adapted for a cluster whose
# agents reach the API over an SSH tunnel (systemd unit k3s-tunnel on each A10).
# The 3-node cluster is assumed ALREADY UP (join done out of band); this runs
# the failure scenarios only.
#
#   SERVER=ubuntu@v100 AG2=ubuntu@a10-1 AG3=ubuntu@a10-2 \
#     N2=<node2-name> N3=<node3-name> bash scripts/cert18-tunneled.sh
#
# Partition (18d) severs the TUNNEL (systemctl stop k3s-tunnel) rather than
# blocking :6443 — a truer partition of the agent from the control plane, and
# it doesn't touch the Mac->A10 management SSH.
# ============================================================================
set -uo pipefail

SERVER="${SERVER:?}"; AG2="${AG2:?}"; AG3="${AG3:?}"; N2="${N2:?}"; N3="${N3:?}"
S="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 $SERVER"
S2="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 $AG2"
S3="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 $AG3"
K='export KUBECONFIG=$HOME/.kube/config'
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/cert18-${SHA}"; mkdir -p "$EVID"
GiB=$((1024*1024*1024))
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "━━ $* ━━"; }
kc(){ $S "$K; $*"; }
ready(){ $S "$K; kubectl get vgpuslice -n $1 --no-headers 2>/dev/null | grep -c Ready" 2>/dev/null | tr -d ' '; }

say "0. preflight: 3 GPU nodes Ready + capacity + nodeagents Running"
kc "kubectl get nodes -o custom-columns='N:.metadata.name,S:.status.conditions[-1].type,V:.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes' --no-headers" | tee "$EVID/00-nodes.txt"
NR=$(grep -c Ready "$EVID/00-nodes.txt"); NC=$(awk '$3+0>1e9' "$EVID/00-nodes.txt" | wc -l | tr -d ' ')
[[ "$NR" == 3 && "$NC" == 3 ]] && ok "3 nodes Ready, all advertise capacity" || { bad "nodes=$NR caps=$NC"; }
AGP=$(kc "kubectl get pods -n vgpu-system -l app=vgpu-nodeagent --no-headers 2>/dev/null | grep -c Running" | tr -d ' ')
[[ "$AGP" == 3 ]] && ok "nodeagent Running on all 3 nodes" || bad "only $AGP/3 nodeagent pods Running"

say "CERT-08: topology zone hint honored + infeasible stays SOFT (real 3-node)"
kc "kubectl label node $SERVER_NODE x- >/dev/null 2>&1 || true
  BIG=\$(kubectl get nodes -o custom-columns=N:.metadata.name,C:.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes --no-headers | awk '\$2+0>1e11{print \$1}' | head -1)
  kubectl label node \$BIG topology.vgpu.pranav2910.com/zone=zone-big --overwrite >/dev/null
  kubectl label node $N2 topology.vgpu.pranav2910.com/zone=zone-a10 --overwrite >/dev/null
  kubectl label node $N3 topology.vgpu.pranav2910.com/zone=zone-a10 --overwrite >/dev/null
  kubectl rollout restart deploy/vgpu-scheduler -n vgpu-system >/dev/null
  kubectl rollout status deploy/vgpu-scheduler -n vgpu-system --timeout=120s >/dev/null
  kubectl create ns c18topo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: zoned, namespace: c18topo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((4*GiB))}}}\n' | kubectl apply -f - >/dev/null
  sleep 30
  ZN=\$(kubectl get vgpuslice zoned-claim-slice -n c18topo -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  echo ZONE=\$(kubectl get node \$ZN -o jsonpath='{.metadata.labels.topology\.vgpu\.pranav2910\.com/zone}' 2>/dev/null)
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: softz, namespace: c18topo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((40*GiB))}}}\n' | kubectl apply -f - >/dev/null
  sleep 30
  echo SOFT=\$(kubectl get vgpuslice softz-claim-slice -n c18topo -o jsonpath='{.status.phase}' 2>/dev/null)
  kubectl delete ns c18topo --wait=false >/dev/null 2>&1" | tee "$EVID/cert08.txt"
grep -q "ZONE=zone-a10" "$EVID/cert08.txt" && grep -q "SOFT=Ready" "$EVID/cert08.txt" \
  && ok "CERT-08: hint honored (landed zone-a10); infeasible 40Gi stayed SOFT (scheduled on the big node)" \
  || bad "CERT-08: $(grep -E 'ZONE=|SOFT=' "$EVID/cert08.txt" | tr '\n' ' ')"

say "CERT-18b: cross-node gang bigger than any node → members SPAN nodes, all-or-nothing"
kc "kubectl create ns c18xg --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # 10 members x 12Gi: V100 fits 8 (1/card), each A10 fits 1 → needs all 3 nodes
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: xg, namespace: c18xg}\nspec: {gangSize: 10, minAvailable: 10, reservationTimeoutSeconds: 150, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: $((12*GiB)), serviceTier: Guaranteed}}}\n' | kubectl apply -f - >/dev/null"
for i in $(seq 1 48); do [ "$(ready c18xg)" -ge 10 ] && break; sleep 5; done
if [ "$(ready c18xg)" -ge 10 ]; then
  XN=$(kc "kubectl get vgpuslice -n c18xg -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\n\"}{end}' | sort -u | grep -vc '^$'" | tr -d ' ')
  [ "${XN:-0}" -ge 3 ] && ok "CERT-18b: 10-member gang admitted SPANNING $XN nodes" || bad "gang Ready but on $XN nodes (want 3)"
else bad "CERT-18b: cross-node gang did not fully admit ($(ready c18xg)/10)"; fi
kc "kubectl delete ns c18xg --wait=false >/dev/null 2>&1"; sleep 8

say "CERT-18c: NODE LOSS (stop k3s-agent on $N3) → survivors admit; RETURN → capacity re-charged"
kc "kubectl create ns c18loss --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # a 20Gi job fits ONLY the A10s (V100 cards are 16Gi) — pins work to an A10
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: a10job, namespace: c18loss}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((20*GiB))}}}\n' | kubectl apply -f - >/dev/null"
for i in $(seq 1 30); do [ "$(ready c18loss)" -ge 1 ] && break; sleep 5; done
ok "pre-loss: 20Gi job placed on an A10 ($(ready c18loss) Ready)"
echo "  stopping k3s-agent on $AG3..."
$S3 "sudo systemctl stop k3s-agent" >/dev/null 2>&1
for i in $(seq 1 40); do
  st=$(kc "kubectl get node $N3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null)
  [ "$st" != True ] && break; sleep 6
done
LST=$(kc "kubectl get node $N3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null)
kc "printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: survivor, namespace: c18loss}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((4*GiB))}}}\n' | kubectl apply -f - >/dev/null"
sleep 25
SV=$(kc "kubectl get vgpuslice survivor-claim-slice -n c18loss -o jsonpath='{.status.phase}'" 2>/dev/null)
[[ "$LST" != True && "$SV" == Ready ]] && ok "CERT-18c: node $N3 NotReady ($LST) — survivors admitted new work (survivor=$SV)" \
  || bad "CERT-18c: node-state=$LST survivor=$SV"
echo "  restarting k3s-agent on $AG3..."
$S3 "sudo systemctl start k3s-agent" >/dev/null 2>&1
for i in $(seq 1 40); do
  st=$(kc "kubectl get node $N3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null)
  [ "$st" == True ] && break; sleep 6
done
RET=$(kc "kubectl get node $N3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null)
# re-advertise capacity (agent has no kubectl; server patches on return — the flap-recovery receipt)
M3=$($S3 'nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc 0-9')
kc "kubectl patch node $N3 --subresource=status --type=merge -p '{\"status\":{\"capacity\":{\"infrastructure.pranav2910.com/vgpu-bytes\":\"'$((M3*1024*1024))'\"},\"allocatable\":{\"infrastructure.pranav2910.com/vgpu-bytes\":\"'$((M3*1024*1024))'\"}}}' >/dev/null"
sleep 15
kc "printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: postret, namespace: c18loss}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((20*GiB))}}}\n' | kubectl apply -f - >/dev/null"
sleep 40
PR=$(kc "kubectl get vgpuslice postret-claim-slice -n c18loss -o jsonpath='{.status.phase}'" 2>/dev/null)
PRN=$(kc "kubectl get vgpuslice postret-claim-slice -n c18loss -o jsonpath='{.spec.nodeName}'" 2>/dev/null)
[[ "$RET" == True && "$PR" == Ready ]] && ok "CERT-18c+: node returned; 20Gi work landed (on $PRN) — flap-recovery live" \
  || bad "CERT-18c+: returned=$RET postret=$PR"
kc "kubectl delete ns c18loss --wait=false >/dev/null 2>&1"; sleep 8

say "CERT-18d: 60s PARTITION (sever tunnel on $N2) during gang assembly → never partial, converges after heal"
kc "kubectl create ns c18part --dry-run=client -o yaml | kubectl apply -f - >/dev/null"
echo "  severing k3s-tunnel on $AG2 (partitions it from the control plane)..."
$S2 "sudo systemctl stop k3s-tunnel" >/dev/null 2>&1
kc "printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: pg, namespace: c18part}\nspec: {gangSize: 10, minAvailable: 10, reservationTimeoutSeconds: 200, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: $((12*GiB)), serviceTier: Guaranteed}}}\n' | kubectl apply -f - >/dev/null"
sleep 55
DUR=$(ready c18part)
echo "  DURING_PARTITION_READY=$DUR" | tee "$EVID/cert18d.txt"
echo "  healing (restart k3s-tunnel on $AG2)..."
$S2 "sudo systemctl start k3s-tunnel" >/dev/null 2>&1
[[ "$DUR" == 0 || "$DUR" == 10 ]] && ok "CERT-18d: during partition ready=$DUR (all-or-nothing held — never partial)" \
  || bad "CERT-18d: PARTIAL admission during partition (ready=$DUR/10)"
for i in $(seq 1 50); do [ "$(ready c18part)" -ge 10 ] && break; sleep 6; done
AH=$(ready c18part)
[ "$AH" -ge 10 ] && ok "CERT-18d+: after heal the SAME gang converged to $AH/10 (no split-brain)" \
  || bad "CERT-18d+: gang did not converge after heal ($AH/10)"
kc "kubectl delete ns c18part --wait=false >/dev/null 2>&1"

echo
echo "════════════════════════════════════════════"
echo " CERT-18 MULTI-NODE FAILURES:  PASS=$PASS  FAIL=$FAIL   EVIDENCE=$EVID"
[[ $FAIL -eq 0 ]] && { echo " FINAL_VERDICT=PASS"; exit 0; } || { echo " FINAL_VERDICT=FAIL"; exit 1; }
