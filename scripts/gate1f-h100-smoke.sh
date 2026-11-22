#!/usr/bin/env bash
# ============================================================================
# gate1f-h100-smoke.sh — Gate 1f: the real-GPU receipt for v0.16-audit-hardening.
#
# Runs FROM the dev machine against a fresh single-GPU box over SSH:
#   1. clone/update the repo on the box at origin/main
#   2. bring up the full control plane (scripts/h100-control-plane.sh)
#   3. the smoke: submit 16Gi → pod Running → nvidia-smi INSIDE the pod →
#      GPU UUID == slice deviceUuid → delete → capacity returns to the card
#   4. pull evidence (logs, nvidia-smi, status dumps) back to artifacts/
#
#   HOST=ubuntu@1.2.3.4 bash scripts/gate1f-h100-smoke.sh
#
# Honest gates: every step checks its own exit/values; the script's exit code
# is the verdict. Evidence is saved regardless of pass/fail.
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/gate1f-h100-${SHA}"
mkdir -p "$EVID"

PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say()  { echo; echo "── $* ──"; }

say "0. connectivity + GPU"
$SSH 'nvidia-smi -L && nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader' \
    | tee "$EVID/00-gpu.txt" || { bad "ssh/nvidia-smi failed"; echo "VERDICT: FAIL"; exit 1; }
ok "box reachable, GPU visible"

say "1. clone/update repo on the box"
$SSH 'set -e
  if [ -d vgpu_scheduler/.git ]; then cd vgpu_scheduler && git fetch origin && git reset --hard origin/main
  else git clone https://github.com/pranav2910/vgpu_scheduler.git && cd vgpu_scheduler; fi
  git log --oneline -1' | tee "$EVID/01-repo.txt" || { bad "repo sync failed"; exit 1; }
ok "repo at origin/main on the box"

say "2. control plane bring-up (k3s + NVML agent + scheduler + controller) — takes minutes"
$SSH 'cd vgpu_scheduler && bash scripts/h100-control-plane.sh' > "$EVID/02-bringup.log" 2>&1
BRC=$?
tail -6 "$EVID/02-bringup.log"
[ $BRC -eq 0 ] && ok "control plane up" || { bad "bring-up failed (see $EVID/02-bringup.log)"; echo "VERDICT: FAIL"; exit 1; }

KC='export KUBECONFIG=$HOME/.kube/config'

say "3. capacity BEFORE (scheduler view + node advertisement)"
$SSH "$KC
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} vgpu-bytes={.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}{\"\n\"}{end}'
  kubectl get pods -n vgpu-system --no-headers" | tee "$EVID/03-before.txt"
grep -q "vgpu-bytes=[1-9]" "$EVID/03-before.txt" && ok "real VRAM capacity advertised" || bad "no vgpu-bytes capacity on the node"

say "4. SUBMIT: vgpu submit 16Gi (runtime-class nvidia)"
$SSH "$KC
  cd vgpu_scheduler
  kubectl delete vgpujob smoke --ignore-not-found >/dev/null 2>&1; sleep 3
  scripts/vgpu submit --name smoke --vram 16Gi --image nvidia/cuda:12.4.1-base-ubuntu22.04 \
      --command 'nvidia-smi -L && sleep 600' --runtime-class nvidia --wait 180
  scripts/vgpu status smoke" | tee "$EVID/04-submit.txt"
grep -qE "Pod +Running" "$EVID/04-submit.txt" && ok "workload pod Running on the shared GPU" || bad "pod did not reach Running"

say "5. THE MONEY SHOT: nvidia-smi INSIDE the pod; UUID must match the slice"
$SSH "$KC
  cd vgpu_scheduler
  SLICE_UUID=\$(kubectl get vgpuslice smoke-claim-slice -o jsonpath='{.status.deviceUuid}')
  echo \"slice deviceUUID: \$SLICE_UUID\"
  POD_SMI=\$(kubectl exec smoke-workload -- nvidia-smi -L 2>/dev/null)
  echo \"in-pod nvidia-smi: \$POD_SMI\"
  case \"\$POD_SMI\" in *\"\$SLICE_UUID\"*) echo UUID_MATCH=yes ;; *) echo UUID_MATCH=no ;; esac" | tee "$EVID/05-uuid.txt"
grep -q "UUID_MATCH=yes" "$EVID/05-uuid.txt" && ok "pod sees EXACTLY the slice's GPU (CDI injection proven)" || bad "UUID mismatch / no GPU in pod"

say "6. RELEASE: delete → capacity returns"
$SSH "$KC
  cd vgpu_scheduler
  kubectl delete vgpujob smoke --wait=false
  for i in \$(seq 1 30); do
    n=\$(kubectl get vgpuslices -A --no-headers 2>/dev/null | wc -l)
    [ \"\$n\" -eq 0 ] && break; sleep 4
  done
  kubectl get vgpuslices -A --no-headers 2>/dev/null | wc -l | xargs echo slices_left=
  kubectl -n vgpu-system logs deploy/vgpu-scheduler --tail=100 2>/dev/null | grep -E 'Released|free' | tail -3" | tee "$EVID/06-release.txt"
grep -q "slices_left= *0" "$EVID/06-release.txt" && ok "slice released; no residue" || bad "slice residue after delete"

say "7. agent + checkpoint evidence"
$SSH "$KC
  kubectl -n vgpu-system logs ds/vgpu-nodeagent --tail=60 2>/dev/null | grep -iE 'alloc|releas|checkpoint|nvml' | tail -10" \
  | tee "$EVID/07-agent.txt" || true

echo
echo "════════════════════════════════════════════"
echo " GATE 1f SMOKE:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE_PATH=$EVID"
echo " COMMIT=$SHA"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 5 ]; then
  echo " FINAL_VERDICT=PASS — tag v0.16-audit-hardening-green is earned"
  exit 0
else
  echo " FINAL_VERDICT=FAIL — do NOT tag"
  exit 1
fi
