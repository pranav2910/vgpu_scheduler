#!/usr/bin/env bash
# ============================================================================
# tier1-torture-a10.sh — Tier-1 single-GPU torture suite: the real-world
# failure scenarios a single card can prove. Driven from the workstation:
#
#   HOST=ubuntu@1.2.3.4 bash scripts/tier1-torture-a10.sh
#
# Covers: over-usage ladder (detect → softwarn → evict), exemption honored in
# evict mode, neighbor blast-radius (DOCUMENTED, not asserted — physics),
# attribution under CUDA fork-storm, k3s/containerd restart mid-workload,
# agent crash-loop under load, and FULL NODE REBOOT survival with an
# over-commit assertion (the checkpoint-persistence receipt).
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/tier1-torture-${SHA}"; mkdir -p "$EVID"
KC='export KUBECONFIG=$HOME/.kube/config; cd vgpu_scheduler'
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "── $* ──"; }
PYTORCH=pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime

# burner: submits a vgpu job whose pod allocates REAL VRAM via torch.
# $1 name, $2 grant, $3 gib-to-actually-use, $4 extra vgpu-submit args
submit_burner() {
    $SSH "$KC
      scripts/vgpu submit --name $1 --vram $2 --image $PYTORCH \
        --command 'python -c \"import torch,time; x=torch.empty(int($3*1024**3)//2, dtype=torch.float16, device=\\\"cuda\\\").normal_(); torch.cuda.synchronize(); print(\\\"holding ${3}GiB\\\", flush=True); time.sleep(1800)\"' \
        --runtime-class nvidia --wait 240 $4 | tail -2"
}

say "0. sync + full stack + FRESH images at $SHA"
$SSH "$KC; git fetch -q origin && git reset -q --hard origin/main && git log --oneline -1" | tee "$EVID/00-repo.txt"
$SSH "$KC; bash scripts/h100-control-plane.sh" > "$EVID/00-bringup.log" 2>&1 \
    && ok "control plane up" || { bad "bring-up failed"; exit 1; }
$SSH "$KC
  set -e
  sudo docker build -t vgpu-scheduler:latest  -f Dockerfile.scheduler  . | tail -1
  sudo docker build -t vgpu-controller:latest -f Dockerfile.controller . | tail -1
  sudo docker build --build-arg GOTAGS=nvml -t vgpu-nodeagent:nvml -f Dockerfile.nodeagent . | tail -1
  sudo docker save vgpu-scheduler:latest vgpu-controller:latest vgpu-nodeagent:nvml | sudo k3s ctr images import - | tail -1
  kubectl rollout restart deploy/vgpu-scheduler deploy/vgpu-controller -n vgpu-system
  kubectl rollout restart ds/vgpu-nodeagent -n vgpu-system
  kubectl rollout status deploy/vgpu-controller -n vgpu-system --timeout=240s
  kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=240s
  kubectl delete vgpujobs --all -A --wait=false 2>/dev/null; sleep 5
  echo FRESH_IMAGES=yes" > "$EVID/00-rebuild.log" 2>&1
grep -q "FRESH_IMAGES=yes" "$EVID/00-rebuild.log" && ok "fresh images at THIS commit" \
    || { bad "rebuild failed (see $EVID/00-rebuild.log)"; exit 1; }

say "1. OVER-USAGE detect→softwarn: grant 4Gi, actually use ~8Gi (default mode never destroys)"
submit_burner overuser 4Gi 8 "" | tee "$EVID/01-submit.txt"
$SSH "$KC
  sleep 100   # detection needs a sustained streak of observe cycles
  kubectl get vgpuslices overuser-claim-slice -o jsonpath='{.status.phase} {.status.observedVramBytes}'; echo
  kubectl get pod overuser-workload -o jsonpath='{.metadata.labels}'; echo
  kubectl get events --field-selector involvedObject.name=overuser-claim-slice -o jsonpath='{range .items[*]}{.reason} {end}'; echo
  kubectl get pod overuser-workload -o jsonpath='{.status.phase}'; echo" | tee "$EVID/01-overuse.txt"
grep -qiE "violat" "$EVID/01-overuse.txt" && ok "over-use DETECTED (violation label/event present)" || bad "over-use not detected"
grep -q "Running" "$EVID/01-overuse.txt" && ok "softwarn mode: violating pod NOT evicted (non-destructive default)" || bad "pod gone in softwarn mode?!"

say "2. EVICT mode: same violation must now evict — and a labeled-exempt namespace must NOT be"
$SSH "$KC
  kubectl set env ds/vgpu-nodeagent -n vgpu-system VGPU_ENFORCEMENT_MODE=evict
  kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=120s >/dev/null
  # let the agent re-observe the still-running overuser past its deadline
  for i in \$(seq 1 40); do
    ph=\$(kubectl get pod overuser-workload -o jsonpath='{.status.phase}' 2>/dev/null || echo GONE)
    [ \"\$ph\" = GONE ] && break; sleep 6
  done
  kubectl get pod overuser-workload >/dev/null 2>&1 && echo EVICTED=no || echo EVICTED=yes" | tee "$EVID/02-evict.txt"
grep -q "EVICTED=yes" "$EVID/02-evict.txt" && ok "evict mode: sustained violator EVICTED" || bad "violator survived evict mode"
$SSH "$KC
  kubectl create ns exempt-zone --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label ns exempt-zone infrastructure.pranav2910.com/enforcement-exempt=true --overwrite >/dev/null
  true" >/dev/null 2>&1
submit_burner exemptuser 4Gi 8 "-n exempt-zone" >/dev/null 2>&1
$SSH "$KC
  sleep 150
  kubectl get pod exemptuser-workload -n exempt-zone -o jsonpath='{.status.phase}' 2>/dev/null || echo GONE" | tee "$EVID/02-exempt.txt"
grep -q "Running" "$EVID/02-exempt.txt" && ok "exempt namespace honored even in evict mode (violating pod alive)" || bad "exempt namespace pod evicted"
$SSH "$KC
  kubectl delete vgpujob exemptuser -n exempt-zone --wait=false 2>/dev/null
  kubectl set env ds/vgpu-nodeagent -n vgpu-system VGPU_ENFORCEMENT_MODE=softwarn
  kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=120s >/dev/null; echo reset" >/dev/null

say "3. NEIGHBOR BLAST-RADIUS (documented, not asserted — no memory fencing by design)"
submit_burner victim 8Gi 6 "" >/dev/null 2>&1
submit_burner hog 8Gi 15 "" | tee "$EVID/03-submit.txt"   # hog: grant 8, try to use 15 of a 24G card
$SSH "$KC
  sleep 90
  echo '--- what physically happened ---'
  kubectl get pods victim-workload hog-workload -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} restarts={.status.containerStatuses[0].restartCount}{\"\n\"}{end}' 2>/dev/null
  kubectl logs victim-workload --tail 3 2>/dev/null | head -3
  kubectl logs hog-workload --tail 3 2>/dev/null | head -3
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader" | tee "$EVID/03-blast.txt"
ok "blast-radius behavior recorded to evidence (honesty doc: no hardware fencing between slices)"
$SSH "$KC; kubectl delete vgpujob victim hog --wait=false 2>/dev/null; sleep 8" >/dev/null 2>&1

say "4. ATTRIBUTION FORK-STORM: compliant pod spawning short-lived CUDA procs must NOT be flagged"
$SSH "$KC
  scripts/vgpu submit --name stormer --vram 4Gi --image $PYTORCH \
    --command 'python -c \"
import multiprocessing as mp, time
def burn():
    import torch
    x = torch.empty(int(0.5*1024**3)//2, dtype=torch.float16, device=\\\"cuda\\\").normal_()
    torch.cuda.synchronize()
if __name__ == \\\"__main__\\\":
    ctx = mp.get_context(\\\"spawn\\\")
    for i in range(40):
        p = ctx.Process(target=burn); p.start(); p.join()
        print(\\\"spawn\\\", i, flush=True)
    print(\\\"storm done - idling\\\", flush=True); time.sleep(1200)\"' \
    --runtime-class nvidia --wait 240 | tail -1" | tee "$EVID/04-submit.txt"
$SSH "$KC
  sleep 120
  kubectl get pod stormer-workload -o jsonpath='{.status.phase}'; echo
  kubectl get vgpuslices stormer-claim-slice -o jsonpath='{.status.phase}'; echo
  kubectl get pod stormer-workload -o jsonpath='{.metadata.labels}' | grep -c violation || echo NO_VIOLATION_LABEL
  AGENT=\$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
  kubectl get pod -n vgpu-system \$AGENT -o jsonpath='agent_restarts={.status.containerStatuses[0].restartCount}'; echo" | tee "$EVID/04-storm.txt"
grep -q "NO_VIOLATION_LABEL" "$EVID/04-storm.txt" && ok "fork-storm: compliant pod never flagged (PID churn attribution sane)" || bad "phantom violation under PID churn"
grep -q "agent_restarts=0" "$EVID/04-storm.txt" && ok "agent healthy through the storm (0 restarts)" || bad "agent crashed during PID churn"
$SSH "$KC; kubectl delete vgpujob stormer --wait=false 2>/dev/null" >/dev/null 2>&1

say "5. k3s/containerd RESTART mid-workload: running pod keeps its GPU"
submit_burner survivor 6Gi 4 "" >/dev/null 2>&1
$SSH "$KC
  kubectl wait pod survivor-workload --for=condition=Ready --timeout=120s >/dev/null 2>&1
  sudo systemctl restart k3s
  for i in \$(seq 1 30); do kubectl get nodes >/dev/null 2>&1 && break; sleep 5; done
  sleep 20
  ph=\$(kubectl get pod survivor-workload -o jsonpath='{.status.phase}')
  echo pod_after_restart=\$ph
  kubectl exec survivor-workload -- nvidia-smi -L 2>/dev/null | head -1
  kubectl get vgpuslices survivor-claim-slice -o jsonpath='slice={.status.phase}'; echo" | tee "$EVID/05-k3s-restart.txt"
grep -q "pod_after_restart=Running" "$EVID/05-k3s-restart.txt" && ok "workload survived k3s/containerd restart" || bad "workload died on k3s restart"
grep -q "GPU 0" "$EVID/05-k3s-restart.txt" && ok "in-pod GPU access intact after restart (CDI injection durable)" || bad "pod lost its GPU after containerd restart"

say "6. AGENT CRASH-LOOP under load: 3 kills, checkpoint re-seed every time, no over-commit"
$SSH "$KC
  for i in 1 2 3; do
    kubectl delete pod -n vgpu-system -l app=vgpu-nodeagent --wait=true >/dev/null 2>&1
    kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=120s >/dev/null 2>&1
    sleep 6
    AGENT=\$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
    kubectl logs -n vgpu-system \$AGENT 2>/dev/null | grep -c 're-seeded from' | sed \"s/^/kill\$i reseed_lines=/\"
  done
  kubectl get vgpuslices survivor-claim-slice -o jsonpath='slice_still={.status.phase}'; echo" | tee "$EVID/06-crashloop.txt"
[ "$(grep -c 'reseed_lines=1' "$EVID/06-crashloop.txt")" -eq 3 ] && ok "3/3 restarts re-seeded from checkpoint" || bad "a restart failed to re-seed from checkpoint"
grep -q "slice_still=Ready" "$EVID/06-crashloop.txt" && ok "allocation stable through crash-loop" || bad "slice disturbed by agent crash-loop"

say "7. FULL NODE REBOOT: checkpoint survives, allocation restored, over-commit REFUSED"
$SSH "$KC; sudo ls -la /var/lib/vgpu-state/ | tail -2" | tee "$EVID/07-pre-reboot.txt"
$SSH 'sudo reboot' 2>/dev/null || true
echo "  (box rebooting — polling ssh for up to 6 min)"
UP=0
for i in $(seq 1 36); do
  sleep 10
  ssh -o ConnectTimeout=6 "$HOST" 'echo up' >/dev/null 2>&1 && { UP=1; break; }
done
[ "$UP" = 1 ] && ok "box back after reboot" || { bad "box did not return in 6 min"; echo "VERDICT: FAIL"; exit 1; }
$SSH "$KC
  for i in \$(seq 1 40); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 6; done
  kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=240s >/dev/null 2>&1
  echo '--- checkpoint file (must have survived the REBOOT — /var/lib not tmpfs) ---'
  sudo cat /var/lib/vgpu-state/allocations.json 2>/dev/null | head -3
  AGENT=\$(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
  kubectl logs -n vgpu-system \$AGENT 2>/dev/null | grep -m1 're-seeded from'
  # THE over-commit assertion: survivor holds 6Gi of 24GB. A 20Gi request must
  # be REFUSED — it only fits if the reboot leaked the old allocation.
  scripts/vgpu submit --name toolarge --vram 20Gi --image nvidia/cuda:12.4.1-base-ubuntu22.04 \
    --command 'sleep 60' --runtime-class nvidia --no-wait >/dev/null 2>&1
  sleep 25
  ph=\$(kubectl get vgpuslices toolarge-claim-slice -o jsonpath='{.status.phase}' 2>/dev/null)
  echo toolarge_phase=\${ph:-none}
  kubectl delete vgpujob toolarge --wait=false 2>/dev/null
  true" | tee "$EVID/07-post-reboot.txt"
grep -q "allocationID" "$EVID/07-post-reboot.txt" && ok "checkpoint file SURVIVED the reboot" || bad "checkpoint gone after reboot"
grep -q "re-seeded from" "$EVID/07-post-reboot.txt" && ok "agent re-seeded its ledger from the surviving checkpoint" || bad "no re-seed after reboot"
grep -qE "toolarge_phase=(Pending|Failed|none|Scheduled)" "$EVID/07-post-reboot.txt" && \
  ! grep -qE "toolarge_phase=(Ready|Allocating)" "$EVID/07-post-reboot.txt" && \
  ok "OVER-COMMIT REFUSED: 20Gi request not allocated while 6Gi survivor holds (ledger honest after reboot)" || bad "over-commit after reboot — ledger lost the survivor"

say "8. teardown"
$SSH "$KC; kubectl delete vgpujobs --all -A --wait=false 2>/dev/null; kubectl delete ns exempt-zone --wait=false 2>/dev/null; echo clean" >/dev/null 2>&1
ok "workloads cleaned"

echo
echo "════════════════════════════════════════════"
echo " TIER-1 TORTURE:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE_PATH=$EVID   COMMIT=$SHA"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 14 ]; then
  echo " FINAL_VERDICT=PASS"; exit 0
else
  echo " FINAL_VERDICT=FAIL"; exit 1
fi
