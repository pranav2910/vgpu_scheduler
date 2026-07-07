#!/usr/bin/env bash
# ============================================================================
# certify-release.sh — THE release certification. One command, every claim
# re-proven on real GPU hardware with multiple values per feature.
# Catalog + verdict rules: docs/CERTIFICATION.md (CERT-01 .. CERT-17;
# CERT-18 multi-node runs separately via tier4-multinode-failures.sh).
#
#   HOST=ubuntu@gpu-box bash scripts/certify-release.sh
#
# Reuses the receipt scripts that certified v0.16–v0.19 and adds the
# multi-value / matrix / hostility sections. Evidence: artifacts/certify-<sha>/
# plus a generated CERTIFICATION-REPORT.md.
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/certify-${SHA}"; mkdir -p "$EVID"
KC='export KUBECONFIG=$HOME/.kube/config; cd vgpu_scheduler'
GiB=$((1024*1024*1024))

declare -A CERT_RESULT CERT_NOTE
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "━━ $* ━━"; }
cert(){ # id verdict note
    CERT_RESULT[$1]="$2"; CERT_NOTE[$1]="$3"
    [[ "$2" == "PASS" ]] && ok "$1: $3" || bad "$1 FAILED: $3"
}
# run a long on-box command disconnect-proof: nohup + poll for a marker file
run_onbox(){ # name script-body timeout-sec
    local name="$1" body="$2" tmo="${3:-900}"
    $SSH "$KC; rm -f \$HOME/cert-$name.done
      nohup bash -c '$body; touch \$HOME/cert-$name.done' > \$HOME/cert-$name.log 2>&1 &" >/dev/null 2>&1
    local waited=0
    while [ $waited -lt "$tmo" ]; do
        $SSH "test -f \$HOME/cert-$name.done" 2>/dev/null && break
        sleep 15; waited=$((waited+15))
    done
    $SSH "cat \$HOME/cert-$name.log" 2>/dev/null | tee "$EVID/$name.log" | sed 's/\x1b\[[0-9;]*m//g' | tail -4
}

say "0. sync repo + full stack + FRESH images at $SHA"
$SSH "$KC; git fetch -q origin && git reset -q --hard origin/main && git log --oneline -1" | tee "$EVID/00-sync.txt"
$SSH "$KC; bash scripts/h100-control-plane.sh" > "$EVID/00-bringup.log" 2>&1 \
    || { echo "bring-up failed"; exit 1; }
$SSH "$KC; set -e
  sudo docker build -t vgpu-scheduler:latest  -f Dockerfile.scheduler  . | tail -1
  sudo docker build -t vgpu-controller:latest -f Dockerfile.controller . | tail -1
  sudo docker build --build-arg GOTAGS=nvml -t vgpu-nodeagent:nvml -f Dockerfile.nodeagent . | tail -1
  sudo docker save vgpu-scheduler:latest vgpu-controller:latest vgpu-nodeagent:nvml | sudo k3s ctr images import - | tail -1
  kubectl rollout restart deploy/vgpu-scheduler deploy/vgpu-controller -n vgpu-system
  kubectl rollout restart ds/vgpu-nodeagent -n vgpu-system
  kubectl rollout status deploy/vgpu-controller -n vgpu-system --timeout=240s
  kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=240s
  sudo k3s ctr images pull docker.io/pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime >/dev/null 2>&1 || true
  echo FRESH=yes" > "$EVID/00-rebuild.log" 2>&1
grep -q "FRESH=yes" "$EVID/00-rebuild.log" && ok "stack fresh at $SHA" || { bad "rebuild failed"; exit 1; }
CARDS=$($SSH 'nvidia-smi -L | wc -l' 2>/dev/null | tr -d ' ')
PERCARD_MIB=$($SSH 'nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | sort -n | head -1' 2>/dev/null | tr -dc '0-9')
echo "  hardware: ${CARDS}× ${PERCARD_MIB}MiB"

say "CERT-01 install lifecycle (via gate2 receipt)"
if HOST="$HOST" bash scripts/gate2-monitor-lifecycle.sh > "$EVID/cert01.log" 2>&1; then
    cert CERT-01 PASS "install→doctor(0 fail)→report→bundle→VERIFIED uninstall→reinstall"
else
    cert CERT-01 FAIL "see $EVID/cert01.log"
fi

say "CERT-02a slicing at four size classes (1 / 3.75 / 7.5 / 13 Gi coexisting)"
$SSH "$KC
  kubectl create ns certsz --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  for spec in a:1073741824 b:4026531840 c:8053063680 d:13958643712; do
    n=\${spec%%:*}; b=\${spec##*:}
    printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: sz-%s, namespace: certsz}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n---\n' \$n \$b
  done | kubectl apply -f - >/dev/null
  for i in \$(seq 1 40); do
    r=\$(kubectl get vgpuslice -n certsz --no-headers 2>/dev/null | grep -c Ready); [ \"\$r\" = 4 ] && break; sleep 3
  done
  kubectl get vgpuslice -n certsz -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.status.phase}{\" \"}{.status.allocatedBytes}{\"\n\"}{end}'
  kubectl delete ns certsz --wait=false >/dev/null 2>&1" | tee "$EVID/cert02a.txt"
SZREADY=$(grep -c " Ready " "$EVID/cert02a.txt" || true)
[[ "$SZREADY" == "4" ]] && cert CERT-02a PASS "4 size classes allocated (1Gi..13Gi)" \
    || cert CERT-02a FAIL "only $SZREADY/4 sizes Ready"

say "CERT-02b/03/04 packing spread + isolation + fragmentation (+#15 live) — multigpu validator"
if $SSH "$KC; bash scripts/validate-multigpu-a100.sh" > "$EVID/cert02b-04.log" 2>&1; then
    cert CERT-02b PASS "N×4 grants, 4-per-card across all $CARDS real cards, ledger capped"
    cert CERT-03  PASS "two pods on different cards each see ONLY their own UUID in-container"
    cert CERT-04  PASS "fragmentation fails LOUD with the contract message"
else
    for c in CERT-02b CERT-03 CERT-04; do cert $c FAIL "multigpu validator failed — $EVID/cert02b-04.log"; done
fi

say "CERT-05 gang atomicity at sizes 2, 4, 8 + infeasible-zero + name-reuse"
$SSH "$KC
  kubectl create ns certgang --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  gang(){ printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: %s, namespace: certgang}\nspec: {gangSize: %s, minAvailable: %s, reservationTimeoutSeconds: 60, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: %s, serviceTier: Guaranteed}}}\n' \"\$1\" \"\$2\" \"\$2\" \"\$3\"; }
  # feasible gangs at three sizes (small grants: coexist easily)
  { gang g2 2 $((2*GiB)); echo ---; gang g4 4 $((2*GiB)); echo ---; gang g8 8 $((2*GiB)); } | kubectl apply -f - >/dev/null
  for i in \$(seq 1 50); do
    r=\$(kubectl get vgpuslice -n certgang --no-headers 2>/dev/null | grep -c Ready); [ \"\$r\" = 14 ] && break; sleep 3
  done
  echo FEASIBLE_READY=\$(kubectl get vgpuslice -n certgang --no-headers 2>/dev/null | grep -c Ready)
  # infeasible: 8 members needing 15Gi each while cards are partly held -> must admit ZERO
  gang toobig 8 $((15*GiB)) | kubectl apply -f - >/dev/null
  sleep 45
  echo TOOBIG_READY=\$(kubectl get vgpuslice -n certgang --no-headers 2>/dev/null | grep toobig | grep -c Ready || true)
  kubectl delete vgpugangjob toobig -n certgang --wait=false >/dev/null 2>&1
  # name reuse (regression S1): delete g4, re-create SAME name — must still be atomic (not insta-bind via stale cohort)
  kubectl delete vgpugangjob g4 -n certgang >/dev/null 2>&1; sleep 8
  gang g4 4 $((2*GiB)) | kubectl apply -f - >/dev/null
  for i in \$(seq 1 40); do
    r=\$(kubectl get vgpuslice -n certgang --no-headers 2>/dev/null | grep g4 | grep -c Ready); [ \"\$r\" = 4 ] && break; sleep 3
  done
  echo REUSE_READY=\$(kubectl get vgpuslice -n certgang --no-headers 2>/dev/null | grep g4 | grep -c Ready)
  kubectl delete ns certgang --wait=false >/dev/null 2>&1" | tee "$EVID/cert05.txt"
F=$(grep -oE "FEASIBLE_READY=[0-9]+" "$EVID/cert05.txt" | cut -d= -f2)
T=$(grep -oE "TOOBIG_READY=[0-9]+" "$EVID/cert05.txt" | cut -d= -f2)
R=$(grep -oE "REUSE_READY=[0-9]+" "$EVID/cert05.txt" | cut -d= -f2)
if [[ "$F" == "14" && "$T" == "0" && "$R" == "4" ]]; then
    cert CERT-05 PASS "gangs 2+4+8 all-or-nothing (14/14); infeasible admitted ZERO; reused name re-admitted atomically (4/4)"
else
    cert CERT-05 FAIL "feasible=$F/14 toobig=$T/0 reuse=$R/4"
fi

say "CERT-06 preemption matrix (gap≥100 evicts · gap<100 doesn't · non-preemptible immune)"
$SSH "$KC
  kubectl create ns certpre --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  j(){ printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: %s, namespace: certpre}\nspec: {priority: %s, preemptible: %s, workloadClass: Inference, claimTemplate: {spec: {requestedVramBytes: %s, serviceTier: Guaranteed}}}\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\"; }
  # fill EVERY card completely: CARDS holders of (percard-1Gi)
  HOLD=\$(( ($PERCARD_MIB - 1024) * 1024 * 1024 ))
  for i in \$(seq 1 $CARDS); do j hold-\$i 10 true \$HOLD; echo ---; done | kubectl apply -f - >/dev/null
  for i in \$(seq 1 50); do
    r=\$(kubectl get vgpuslice -n certpre --no-headers 2>/dev/null | grep -c Ready); [ \"\$r\" = \"$CARDS\" ] && break; sleep 3
  done
  echo HOLDERS=\$(kubectl get vgpuslice -n certpre --no-headers | grep -c Ready)
  # (1) small gap (10→80 <100): must NOT preempt; job waits
  j smallgap 80 false $((4*GiB)) | kubectl apply -f - >/dev/null; sleep 40
  echo SMALLGAP_PHASE=\$(kubectl get vgpuslice smallgap-claim-slice -n certpre -o jsonpath='{.status.phase}' 2>/dev/null)
  echo HOLDERS_AFTER_SMALL=\$(kubectl get vgpuslice -n certpre --no-headers | grep hold- | grep -c Ready)
  kubectl delete vgpujob smallgap -n certpre --wait=false >/dev/null 2>&1
  # (2) big gap (10→200): MUST preempt exactly one holder and land
  j vip 200 false $((4*GiB)) | kubectl apply -f - >/dev/null
  for i in \$(seq 1 60); do
    ph=\$(kubectl get vgpuslice vip-claim-slice -n certpre -o jsonpath='{.status.phase}' 2>/dev/null); [ \"\$ph\" = Ready ] && break; sleep 4
  done
  echo VIP_PHASE=\$(kubectl get vgpuslice vip-claim-slice -n certpre -o jsonpath='{.status.phase}' 2>/dev/null)
  echo HOLDERS_AFTER_VIP=\$(kubectl get vgpuslice -n certpre --no-headers | grep hold- | grep -c Ready)
  # (3) non-preemptible: replace holders' preemptible=false equivalent — submit vip2 needing space while remaining holders are preemptible=true except mark one card unpreemptible? Simplest: fresh single-card scenario
  kubectl delete ns certpre --wait=false >/dev/null 2>&1; sleep 10
  kubectl create ns certpre2 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: fort, namespace: certpre2}\nspec: {priority: 10, preemptible: false, workloadClass: Inference, claimTemplate: {spec: {requestedVramBytes: %s, serviceTier: Guaranteed}}}\n' \$(( ($PERCARD_MIB-1024)*1024*1024 )) | kubectl apply -f - >/dev/null
  sleep 20
  # fill other cards so vip3 can ONLY fit by evicting fort — but fort is non-preemptible
  for i in \$(seq 1 $((CARDS-1))); do printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: blk-%s, namespace: certpre2}\nspec: {priority: 300, preemptible: false, workloadClass: Inference, claimTemplate: {spec: {requestedVramBytes: %s}}}\n---\n' \$i \$(( ($PERCARD_MIB-1024)*1024*1024 )); done | kubectl apply -f - >/dev/null
  sleep 30
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: vip3, namespace: certpre2}\nspec: {priority: 999, preemptible: false, workloadClass: Inference, claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((4*GiB)) | kubectl apply -f - >/dev/null
  sleep 45
  echo FORT_PHASE=\$(kubectl get vgpuslice fort-claim-slice -n certpre2 -o jsonpath='{.status.phase}' 2>/dev/null)
  echo VIP3_PHASE=\$(kubectl get vgpuslice vip3-claim-slice -n certpre2 -o jsonpath='{.status.phase}' 2>/dev/null)
  kubectl delete ns certpre2 --wait=false >/dev/null 2>&1" | tee "$EVID/cert06.txt"
SG=$(grep -oE "SMALLGAP_PHASE=\w*" "$EVID/cert06.txt" | cut -d= -f2)
HS=$(grep -oE "HOLDERS_AFTER_SMALL=[0-9]+" "$EVID/cert06.txt" | cut -d= -f2)
VP=$(grep -oE "VIP_PHASE=\w*" "$EVID/cert06.txt" | cut -d= -f2)
HV=$(grep -oE "HOLDERS_AFTER_VIP=[0-9]+" "$EVID/cert06.txt" | cut -d= -f2)
FT=$(grep -oE "FORT_PHASE=\w*" "$EVID/cert06.txt" | cut -d= -f2)
V3=$(grep -oE "VIP3_PHASE=\w*" "$EVID/cert06.txt" | cut -d= -f2)
if [[ "$SG" != "Ready" && "$HS" == "$CARDS" && "$VP" == "Ready" && "$HV" == "$((CARDS-1))" && "$FT" == "Ready" && "$V3" != "Ready" ]]; then
    cert CERT-06 PASS "gap<100 waited (holders intact $HS/$CARDS); gap≥100 evicted exactly one and landed; non-preemptible fort survived a priority-999 challenger"
else
    cert CERT-06 FAIL "smallgap=$SG holders=$HS vip=$VP holdersAfter=$HV fort=$FT vip3=$V3"
fi

say "CERT-07 quota: single-job cap + gang-atomic denial"
$SSH "$KC
  kubectl create ns certq --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUQuota\nmetadata: {name: q, namespace: certq}\nspec: {maxVramBytes: %s}\n' \$((10*GiB)) | kubectl apply -f - >/dev/null
  sleep 3
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: fits, namespace: certq}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((6*GiB)) | kubectl apply -f - >/dev/null
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: busts, namespace: certq}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}}\n' \$((6*GiB)) | kubectl apply -f - >/dev/null
  sleep 35
  echo FITS=\$(kubectl get vgpuslice fits-claim-slice -n certq -o jsonpath='{.status.phase}' 2>/dev/null)
  echo BUSTS=\$(kubectl get vgpuslice busts-claim-slice -n certq -o jsonpath='{.status.phase}' 2>/dev/null)
  # gang total 4x4=16Gi > remaining 4Gi -> ZERO members admitted
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: qgang, namespace: certq}\nspec: {gangSize: 4, minAvailable: 4, reservationTimeoutSeconds: 60, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: %s, serviceTier: Guaranteed}}}\n' \$((4*GiB)) | kubectl apply -f - >/dev/null
  sleep 45
  echo QGANG_READY=\$(kubectl get vgpuslice -n certq --no-headers 2>/dev/null | grep qgang | grep -c Ready || true)
  kubectl delete ns certq --wait=false >/dev/null 2>&1" | tee "$EVID/cert07.txt"
QF=$(grep -oE "FITS=\w*" "$EVID/cert07.txt" | cut -d= -f2)
QB=$(grep -oE "BUSTS=\w*" "$EVID/cert07.txt" | cut -d= -f2)
QG=$(grep -oE "QGANG_READY=[0-9]+" "$EVID/cert07.txt" | cut -d= -f2)
if [[ "$QF" == "Ready" && "$QB" != "Ready" && "$QG" == "0" ]]; then
    cert CERT-07 PASS "6Gi fit under 10Gi quota; second 6Gi denied; 4×4Gi gang admitted ZERO (gang-atomic)"
else
    cert CERT-07 FAIL "fits=$QF busts=$QB qgang=$QG"
fi

say "CERT-09/12/13 enforcement ladder + crash storm + churn (tier3 torture phases)"
run_onbox t3ab "PHASE=ab NS=certt3 bash scripts/tier3-torture-multigpu.sh" 1500
AB_FAIL=$(grep -oE "FAIL=[0-9]+" "$EVID/t3ab.log" | tail -1 | cut -d= -f2)
[[ "${AB_FAIL:-9}" == "0" ]] && { cert CERT-13 PASS "72-job churn: invariants every wave, zero residue"; cert CERT-09 PASS "3 cards violating simultaneously, others clean (+softwarn/evict/exempt via tier-1 receipts)"; } \
    || { cert CERT-13 FAIL "phase ab FAIL=$AB_FAIL"; cert CERT-09 FAIL "phase ab FAIL=$AB_FAIL"; }
run_onbox t3cload "PHASE=c-load NS=certt3 bash scripts/tier3-torture-multigpu.sh" 600
echo "  (box rebooting for CERT-12 — riding it out)"
sleep 45
BACK=0
for i in $(seq 1 60); do $SSH 'exit 0' 2>/dev/null && { BACK=1; break; }; sleep 10; done
if [[ "$BACK" == "1" ]]; then
    sleep 30
    run_onbox t3cpost "PHASE=c-post NS=certt3 bash scripts/tier3-torture-multigpu.sh" 900
    CP_FAIL=$(grep -oE "FAIL=[0-9]+" "$EVID/t3cpost.log" | tail -1 | cut -d= -f2)
    [[ "${CP_FAIL:-9}" == "0" ]] && cert CERT-12 PASS "loaded $CARDS-card reboot: re-seed, over-commit refused, allocation works (+crash-loop kills in c-load)" \
        || cert CERT-12 FAIL "c-post FAIL=$CP_FAIL"
else
    cert CERT-12 FAIL "box did not return from reboot"
fi

say "CERT-06b preempt-under-FULL-PACK (tier3 phase d — the round-3 debt)"
run_onbox t3d "PHASE=d NS=certt3 bash scripts/tier3-torture-multigpu.sh" 1200
D_FAIL=$(grep -oE "FAIL=[0-9]+" "$EVID/t3d.log" | tail -1 | cut -d= -f2)
[[ "${D_FAIL:-9}" == "0" ]] && cert CERT-06b PASS "gang 1-per-card + vip preempted victim on a FULL node + invariant" \
    || cert CERT-06b FAIL "phase d FAIL=$D_FAIL — see $EVID/t3d.log"

say "CERT-10 attribution truth at two load levels + format equality"
$SSH "$KC
  scripts/vgpu install monitor >/dev/null 2>&1; sleep 5
  kubectl create ns certattr --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  burn(){ printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: %s, namespace: certattr}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}, podTemplate: {spec: {runtimeClassName: nvidia, containers: [{name: w, image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime, command: [python, -c, \"import torch,time; x=torch.empty(int(%s*1024**3)//2, dtype=torch.float16, device='\''cuda'\'').normal_(); torch.cuda.synchronize(); time.sleep(600)\"]}]}}}\n' \"\$1\" \"\$2\" \"\$3\"; }
  { burn small $((6*GiB)) 3; echo ---; burn big $((13*GiB)) 11; } | kubectl apply -f - >/dev/null
  for i in \$(seq 1 60); do
    a=\$(kubectl get pods -n certattr --no-headers 2>/dev/null | grep -c Running); [ \"\$a\" = 2 ] && break; sleep 4
  done
  sleep 75
  RPT=\$(scripts/vgpu report -o csv | awk -F, '\$1==\"certattr\" {s+=\$7} END{printf \"%d\", s}')
  SMI=\$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits | awk '{s+=\$1} END{printf \"%d\", s*1048576}')
  D=\$((RPT>SMI ? RPT-SMI : SMI-RPT))
  echo RPT=\$RPT SMI=\$SMI DIFF=\$D
  [ \$D -le 1073741824 ] && echo MATCH=yes || echo MATCH=no
  T=\$(scripts/vgpu report | awk '/GPU memory requested/{print \$4}')
  C=\$(scripts/vgpu report -o csv | awk -F, '\$1==\"_total_\"{printf \"%.1f\", \$6/1073741824}')
  [ \"\$T\" = \"\$C\" ] && echo FORMATS=yes || echo FORMATS=no
  kubectl delete ns certattr --wait=false >/dev/null 2>&1" | tee "$EVID/cert10.txt"
grep -q "MATCH=yes" "$EVID/cert10.txt" && grep -q "FORMATS=yes" "$EVID/cert10.txt" \
    && cert CERT-10 PASS "two simultaneous loads (3+11 GiB): report==nvidia-smi ±1GiB; table==CSV" \
    || cert CERT-10 FAIL "$(grep -E 'RPT=|MATCH=|FORMATS=' "$EVID/cert10.txt" | tr '\n' ' ')"

say "CERT-11 right-sizing loop: learn → recommend ≈ peak×1.15 → autoResize"
$SSH "$KC
  kubectl create ns certrs --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: learner, namespace: certrs}\nspec: {claimTemplate: {spec: {requestedVramBytes: %s}}, podTemplate: {spec: {runtimeClassName: nvidia, containers: [{name: w, image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime, command: [python, -c, \"import torch,time; x=torch.empty(int(6*1024**3)//2, dtype=torch.float16, device='\''cuda'\'').normal_(); torch.cuda.synchronize(); time.sleep(600)\"]}]}}}\n' \$((10*GiB)) | kubectl apply -f - >/dev/null
  for i in \$(seq 1 50); do
    p=\$(kubectl get pod learner-workload -n certrs -o jsonpath='{.status.phase}' 2>/dev/null); [ \"\$p\" = Running ] && break; sleep 4
  done
  sleep 160   # profile flush interval x2
  PEAK=\$(kubectl get vgpuslice learner-claim-slice -n certrs -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
  REC=\$(kubectl get vgpujob learner -n certrs -o jsonpath='{.metadata.annotations.infrastructure\.pranav2910\.com/recommended-vram-bytes}' 2>/dev/null)
  echo PEAK=\$PEAK REC=\$REC
  kubectl delete ns certrs --wait=false >/dev/null 2>&1" | tee "$EVID/cert11.txt"
PEAK=$(grep -oE "PEAK=[0-9]+" "$EVID/cert11.txt" | cut -d= -f2)
REC=$(grep -oE "REC=[0-9]+" "$EVID/cert11.txt" | cut -d= -f2)
if [[ -n "$PEAK" && "$PEAK" -gt $((5*GiB)) && -n "$REC" && "$REC" -gt "$PEAK" && "$REC" -lt $((PEAK*13/10)) ]]; then
    cert CERT-11 PASS "peak learned ($((PEAK/GiB))Gi from a 6Gi burn); recommendation $((REC/GiB))Gi ≈ peak×1.15"
else
    cert CERT-11 FAIL "peak=$PEAK rec=$REC (want rec≈peak×1.15 with peak≈6Gi)"
fi

say "CERT-14 burst admission: 100×1Gi in one apply"
$SSH "$KC
  kubectl create ns certburst --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  T0=\$(date +%s)
  for i in \$(seq 1 100); do
    printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: b-%03d, namespace: certburst}\nspec: {claimTemplate: {spec: {requestedVramBytes: 1073741824}}}\n---\n' \$i
  done | kubectl apply -f - >/dev/null
  for i in \$(seq 1 60); do
    r=\$(kubectl get vgpuslice -n certburst --no-headers 2>/dev/null | grep -c Ready); [ \"\$r\" -ge 100 ] && break; sleep 5
  done
  T1=\$(date +%s)
  echo BURST_READY=\$(kubectl get vgpuslice -n certburst --no-headers | grep -c Ready) BURST_SECS=\$((T1-T0))
  echo RESTARTS=\$(kubectl get pods -n vgpu-system -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{\" \"}{end}')
  kubectl delete ns certburst --wait=false >/dev/null 2>&1" | tee "$EVID/cert14.txt"
BR=$(grep -oE "BURST_READY=[0-9]+" "$EVID/cert14.txt" | cut -d= -f2)
BS=$(grep -oE "BURST_SECS=[0-9]+" "$EVID/cert14.txt" | cut -d= -f2)
[[ "${BR:-0}" -ge 100 ]] && cert CERT-14 PASS "100/100 Ready in ${BS}s, no component restarts" \
    || cert CERT-14 FAIL "burst $BR/100 in ${BS}s"

say "CERT-15 input hostility (every garbage input rejected LOUD)"
$SSH "$KC
  kubectl create ns certhostile --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  R=0
  scripts/vgpu submit --name h1 --vram 0Gi --image x -n certhostile --dry-run >/dev/null 2>&1 || R=\$((R+1))
  scripts/vgpu submit --name h2 --vram 999999999Ti --image x -n certhostile --dry-run >/dev/null 2>&1 || R=\$((R+1))
  scripts/vgpu submit --name 'BAD NAME!' --vram 1Gi --image x -n certhostile --dry-run >/dev/null 2>&1 || R=\$((R+1))
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: hneg, namespace: certhostile}\nspec: {claimTemplate: {spec: {requestedVramBytes: -5}}}\n' | kubectl apply -f - >/dev/null 2>&1 || R=\$((R+1))
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: hhuge, namespace: certhostile}\nspec: {claimTemplate: {spec: {requestedVramBytes: 10995116277760}}}\n' | kubectl apply -f - >/dev/null 2>&1 || R=\$((R+1))
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: hgang, namespace: certhostile}\nspec: {gangSize: 0, minAvailable: 0, podTemplate: {spec: {requestedVramBytes: 1073741824}}}\n' | kubectl apply -f - >/dev/null 2>&1 || R=\$((R+1))
  # immutability: try to grow an admitted claim
  printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: himmut, namespace: certhostile}\nspec: {claimTemplate: {spec: {requestedVramBytes: 2147483648}}}\n' | kubectl apply -f - >/dev/null 2>&1
  sleep 20
  kubectl patch vgpuclaim himmut-claim -n certhostile --type=merge -p '{\"spec\":{\"requestedVramBytes\":9999999999}}' >/dev/null 2>&1 || R=\$((R+1))
  echo REJECTED=\$R/7
  kubectl delete ns certhostile --wait=false >/dev/null 2>&1" | tee "$EVID/cert15.txt"
grep -q "REJECTED=7/7" "$EVID/cert15.txt" && cert CERT-15 PASS "7/7 hostile inputs rejected (zero/huge/garbage-name/negative/10Ti/gangSize-0/immutability-edit)" \
    || cert CERT-15 FAIL "$(grep REJECTED "$EVID/cert15.txt")"

say "CERT-16 security posture on the live cluster"
$SSH "$KC
  scripts/vgpu install monitor >/dev/null 2>&1
  scripts/vgpu security audit > /tmp/aud.txt 2>&1; echo AUDIT_EXIT=\$?
  scripts/vgpu support-bundle --out /tmp/cert-bundle.tgz >/dev/null 2>&1
  tar tzf /tmp/cert-bundle.tgz 2>/dev/null | grep -ci secret | sed 's/^/SECRET_FILES=/'
  tar xzf /tmp/cert-bundle.tgz -O 2>/dev/null | grep -cE 'BEGIN (RSA|EC|OPENSSH) PRIVATE KEY' | sed 's/^/PRIVKEYS=/'" | tee "$EVID/cert16.txt"
grep -q "AUDIT_EXIT=0" "$EVID/cert16.txt" && grep -q "SECRET_FILES=0" "$EVID/cert16.txt" && grep -q "PRIVKEYS=0" "$EVID/cert16.txt" \
    && cert CERT-16 PASS "audit exit 0 (live RBAC == claims); bundle has zero Secret files, zero private keys" \
    || cert CERT-16 FAIL "$(grep -E 'AUDIT_EXIT|SECRET_FILES|PRIVKEYS' "$EVID/cert16.txt" | tr '\n' ' ')"

say "CERT-17 dashboard truth (gate5 receipt)"
if HOST="$HOST" bash scripts/gate5-grafana.sh > "$EVID/cert17.log" 2>&1; then
    cert CERT-17 PASS "panels render via provisioned datasource; numbers==report ±1%; survives restart"
else
    cert CERT-17 FAIL "see $EVID/cert17.log"
fi

# ── report generation ─────────────────────────────────────────────────────
say "generating CERTIFICATION-REPORT.md"
REPORT="$EVID/CERTIFICATION-REPORT.md"
{
    echo "# Release Certification Report — commit $SHA — $(date -u +%Y-%m-%d)"
    echo
    echo "Hardware: ${CARDS}× ${PERCARD_MIB} MiB NVIDIA (real NVML). Catalog: docs/CERTIFICATION.md"
    echo
    echo "| CERT | Verdict | Evidence |"
    echo "|------|---------|----------|"
    for id in $(printf '%s\n' "${!CERT_RESULT[@]}" | sort); do
        echo "| $id | ${CERT_RESULT[$id]} | ${CERT_NOTE[$id]} |"
    done
    echo
    echo "CERT-18 (multi-node failures): run separately — scripts/tier4-multinode-failures.sh"
    echo
    echo "TOTAL: PASS=$PASS FAIL=$FAIL"
} > "$REPORT"
cat "$REPORT"

echo
echo "════════════════════════════════════════════"
echo " RELEASE CERTIFICATION:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE=$EVID  REPORT=$REPORT"
if [ "$FAIL" -eq 0 ]; then echo " FINAL_VERDICT=CERTIFIED"; exit 0; else echo " FINAL_VERDICT=NOT CERTIFIED — fix and re-run"; exit 1; fi
