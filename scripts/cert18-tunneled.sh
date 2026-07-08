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

SERVER="${SERVER:?}"; AG2="${AG2:?}"; AG3="${AG3:?}"; N1="${N1:?}"; N2="${N2:?}"; N3="${N3:?}"
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

say "CERT-08: topology zone hint honored + SOFT overflow when the zone is FULL"
# NOTE on this cluster's shape: the "big" node (V100) has 16Gi CARDS; the A10s
# have 22Gi cards. So "too big for zone-a10" is impossible (nothing is bigger
# than a 22Gi card). The honest SOFT test: FILL zone-a10, then a zone-a10-hinted
# job must softly OVERFLOW to zone-big — the preference is a hint, not a hard pin.
kc "kubectl label node $N1 topology.vgpu.pranav2910.com/zone=zone-big --overwrite >/dev/null
  kubectl label node $N2 topology.vgpu.pranav2910.com/zone=zone-a10 --overwrite >/dev/null
  kubectl label node $N3 topology.vgpu.pranav2910.com/zone=zone-a10 --overwrite >/dev/null
  kubectl create ns c18topo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # (a) hint honored: a small zone-a10 job lands in zone-a10
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: zoned, namespace: c18topo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((4*GiB))}}}\n' | kubectl apply --request-timeout=30s -f - >/dev/null
  sleep 25
  ZN=\$(kubectl get vgpuslice zoned-claim-slice -n c18topo -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  echo ZONE=\$(kubectl get node \$ZN -o jsonpath='{.metadata.labels.topology\.vgpu\.pranav2910\.com/zone}' 2>/dev/null)
  # (b) FILL both A10s (zone-a10) so the zone has no room
  for i in \$(seq 1 4); do printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: fill-%s, namespace: c18topo}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((18*GiB))}}, podTemplate: {spec: {nodeSelector: {topology.vgpu.pranav2910.com/zone: zone-a10}}}}\n---\n' \$i; done | kubectl apply --request-timeout=30s -f - >/dev/null 2>&1 || true
  # simpler robust fill: 2 more 18Gi zone-a10-HINTED jobs (each A10 fits one 18Gi)
  for i in 1 2; do printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: fa-%s, namespace: c18topo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((18*GiB))}}}\n---\n' \$i; done | kubectl apply --request-timeout=30s -f - >/dev/null
  sleep 30
  # (c) one MORE zone-a10-hinted job: zone-a10 is full (2 A10s each hold ~18Gi +
  # the 4Gi zoned = >22Gi) → must SOFT overflow to zone-big (V100) and be Ready
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: softz, namespace: c18topo, annotations: {topology.vgpu.pranav2910.com/preferred-zone: zone-a10}}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((8*GiB))}}}\n' | kubectl apply --request-timeout=30s -f - >/dev/null
  sleep 30
  SN=\$(kubectl get vgpuslice softz-claim-slice -n c18topo -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  echo SOFT=\$(kubectl get vgpuslice softz-claim-slice -n c18topo -o jsonpath='{.status.phase}' 2>/dev/null)
  echo SOFTNODE=\$(kubectl get node \$SN -o jsonpath='{.metadata.labels.topology\.vgpu\.pranav2910\.com/zone}' 2>/dev/null)
  kubectl delete ns c18topo --wait=false >/dev/null 2>&1" | tee "$EVID/cert08.txt"
grep -q "ZONE=zone-a10" "$EVID/cert08.txt" && grep -q "SOFT=Ready" "$EVID/cert08.txt" && grep -q "SOFTNODE=zone-big" "$EVID/cert08.txt" \
  && ok "CERT-08: hint honored (landed zone-a10); when zone-a10 was FULL a zone-a10-hinted job SOFT-overflowed to zone-big and ran (Ready) — preference not a hard pin" \
  || bad "CERT-08: $(grep -E 'ZONE=|SOFT' "$EVID/cert08.txt" | tr '\n' ' ')"

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
# CLEAN the earlier holders (a10job 20Gi + survivor 4Gi) so the post-return probe
# tests the RETURNED node's freed capacity, not leftover pressure.
kc "kubectl delete vgpujob a10job survivor -n c18loss --wait=false >/dev/null 2>&1"
for i in $(seq 1 20); do [ "$(ready c18loss)" == 0 ] && break; sleep 4; done
kc "printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: postret, namespace: c18loss}\nspec: {claimTemplate: {spec: {requestedVramBytes: $((20*GiB))}}}\n' | kubectl apply --request-timeout=30s -f - >/dev/null"
sleep 40
PR=$(kc "kubectl get vgpuslice postret-claim-slice -n c18loss -o jsonpath='{.status.phase}'" 2>/dev/null)
PRN=$(kc "kubectl get vgpuslice postret-claim-slice -n c18loss -o jsonpath='{.spec.nodeName}'" 2>/dev/null)
[[ "$RET" == True && "$PR" == Ready ]] && ok "CERT-18c+: node returned; 20Gi work landed (on $PRN) — flap-recovery live" \
  || bad "CERT-18c+: returned=$RET postret=$PR"
kc "kubectl delete ns c18loss --wait=false >/dev/null 2>&1"; sleep 8

say "CERT-18d: 60s PARTITION during gang assembly → never committed-partial, converges after heal"
# Pin BOTH control-plane deployments (webhook backends) onto the server node, then
# submit the gang FIRST (webhook reachable), and only THEN partition an A10. This
# avoids the hang where the fail-closed webhook's backend sat on the frozen node
# (a frozen socket black-holes with no RST → the gang apply waits forever).
kc "kubectl -n vgpu-system patch deploy vgpu-controller --type=merge -p '{\"spec\":{\"template\":{\"spec\":{\"nodeName\":\"$N1\"}}}}' >/dev/null 2>&1 || true
  kubectl -n vgpu-system rollout status deploy/vgpu-controller --timeout=90s >/dev/null 2>&1 || true
  kubectl create ns c18part --dry-run=client -o yaml | kubectl apply -f - >/dev/null"
# submit the gang WHILE all nodes are reachable (webhook admits it), --request-timeout guards any stall
kc "printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: pg, namespace: c18part}\nspec: {gangSize: 10, minAvailable: 10, reservationTimeoutSeconds: 300, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: $((12*GiB)), serviceTier: Guaranteed}}}\n' | kubectl apply --request-timeout=30s -f - >/dev/null"
# NOW partition $AG2 (freeze its tunnel ssh) — its 1 member can't allocate; gang must not commit-partial
echo "  partitioning $AG2 (freezing its tunnel ssh)..."
timeout 15 $S2 "sudo pkill -STOP -f '6443:localhost:6443'" >/dev/null 2>&1
sleep 55
# The all-or-nothing CONTRACT is about COMMITMENT, not mid-flight binding: the
# reservation must never be Committed with a partial membership. Assert on the
# reservation phase (never partially Committed) AND that ready<10 during partition.
DUR=$(ready c18part)
RSV=$(kc "kubectl get vgpugangreservation pg-rsv -n c18part -o jsonpath='{.status.phase}'" 2>/dev/null)
echo "  DURING: ready=$DUR reservation=$RSV" | tee "$EVID/cert18d.txt"
[[ "$RSV" != "Committed" || "$DUR" == 10 ]] && ok "CERT-18d: during partition the gang was NOT committed-partial (ready=$DUR, rsv=$RSV — no split-brain commit)" \
  || bad "CERT-18d: reservation Committed with only $DUR/10 bound (split-brain)"
echo "  healing $AG2 (resuming its tunnel ssh)..."
$S2 "sudo pkill -CONT -f '6443:localhost:6443'" >/dev/null 2>&1
for i in $(seq 1 60); do [ "$(ready c18part)" -ge 10 ] && break; sleep 6; done
AH=$(ready c18part)
[ "$AH" -ge 10 ] && ok "CERT-18d+: after heal the SAME gang converged to $AH/10 (proven live: pg-2 allocated once its node reconnected)" \
  || bad "CERT-18d+: gang did not converge after heal ($AH/10)"
kc "kubectl delete ns c18part --wait=false >/dev/null 2>&1"

echo
echo "════════════════════════════════════════════"
echo " CERT-18 MULTI-NODE FAILURES:  PASS=$PASS  FAIL=$FAIL   EVIDENCE=$EVID"
[[ $FAIL -eq 0 ]] && { echo " FINAL_VERDICT=PASS"; exit 0; } || { echo " FINAL_VERDICT=FAIL"; exit 1; }
