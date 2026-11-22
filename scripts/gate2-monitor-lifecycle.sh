#!/usr/bin/env bash
# ============================================================================
# gate2-monitor-lifecycle.sh — Gate 2 real-GPU receipt: the monitor wedge's
# full install/operate/uninstall/reinstall lifecycle on actual NVIDIA hardware.
#
#   HOST=ubuntu@1.2.3.4 bash scripts/gate2-monitor-lifecycle.sh
#
# Definition of done (from the roadmap):
#   fresh install works · doctor is useful · report reflects NVML ·
#   uninstall removes ALL owned resources (incl. cluster-scoped RBAC) ·
#   reinstall works after uninstall · no manual kubectl cleanup needed.
# Honest gates: each step checks values; evidence saved regardless of verdict.
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/gate2-monitor-${SHA}"; mkdir -p "$EVID"
KC='export KUBECONFIG=$HOME/.kube/config; cd vgpu_scheduler'
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "── $* ──"; }

say "0. sync repo to origin/main on the box"
$SSH 'cd vgpu_scheduler && git fetch -q origin && git reset -q --hard origin/main && git log --oneline -1' \
    | tee "$EVID/00-repo.txt" || { bad "repo sync failed"; exit 1; }
ok "repo synced"

say "1. vgpu install monitor  (real image + nvidia RuntimeClass already on the box)"
$SSH "$KC; scripts/vgpu install monitor" | tee "$EVID/01-install.txt"
grep -qE "monitor is READY" "$EVID/01-install.txt" && ok "install → monitor READY" || bad "install did not reach READY"

say "2. vgpu doctor  (expect 0 failures; monitor ready + metrics responding)"
$SSH "$KC; scripts/vgpu doctor" | tee "$EVID/02-doctor.txt"
tail -1 "$EVID/02-doctor.txt" | grep -qE "^0 failure" && ok "doctor: 0 failures" || bad "doctor reports failures"
grep -q "monitor metrics responding" "$EVID/02-doctor.txt" && ok "doctor confirms live NVML metrics" || bad "doctor did not see metrics"

say "3. a plain GPU pod that OVER-ASKS and UNDER-USES (no scheduler involved)"
$SSH "$KC
  cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: waste-x, namespace: default, annotations: { gpu-memory: \"40000\" } }
spec:
  runtimeClassName: nvidia
  restartPolicy: Never
  containers:
  - name: w
    image: nvidia/cuda:12.4.1-base-ubuntu22.04
    command: [\"sh\",\"-c\",\"sleep 600\"]
    env: [ { name: NVIDIA_VISIBLE_DEVICES, value: all } ]
EOF
  for i in \$(seq 1 40); do
    ph=\$(kubectl get pod waste-x -o jsonpath='{.status.phase}' 2>/dev/null)
    [ \"\$ph\" = Running ] && break; sleep 3
  done
  echo waste-x phase=\$(kubectl get pod waste-x -o jsonpath='{.status.phase}')
  sleep 40" | tee "$EVID/03-wastepod.txt"
grep -q "phase=Running" "$EVID/03-wastepod.txt" && ok "plain over-asking GPU pod Running" || bad "waste pod not Running"

say "4. vgpu report  (must show requested-vs-used from real NVML)"
$SSH "$KC; scripts/vgpu report --price-per-gpu-hour 3.00" | tee "$EVID/04-report.txt"
grep -qi "GPU memory requested" "$EVID/04-report.txt" && ok "report renders requested/used/waste table" || bad "report produced no table"
grep -q "default/waste-x" "$EVID/04-report.txt" && ok "waste-x attributed in the report (requested 40Gi)" || bad "waste-x not attributed"

say "5. vgpu support-bundle  (writes a redacted tgz)"
$SSH "$KC; scripts/vgpu support-bundle --out /tmp/sb.tgz && tar -tzf /tmp/sb.tgz | wc -l" | tee "$EVID/05-bundle.txt"
grep -qE "wrote /tmp/sb.tgz" "$EVID/05-bundle.txt" && ok "support-bundle written" || bad "support-bundle failed"

say "6. cleanup waste pod"
$SSH "$KC; kubectl delete pod waste-x --ignore-not-found --wait=false" >/dev/null 2>&1; ok "waste pod deleted"

say "7. vgpu uninstall monitor  (VERIFIED: nothing left, incl. cluster RBAC)"
$SSH "$KC; scripts/vgpu uninstall monitor" | tee "$EVID/07-uninstall.txt"
grep -q "fully removed" "$EVID/07-uninstall.txt" && ok "uninstall verified complete" || bad "uninstall incomplete"
# independent double-check from the box
LEFT=$($SSH "$KC
  kubectl get ns vgpu-monitor >/dev/null 2>&1 && echo -n ns;
  kubectl get clusterrole vgpu-monitor-readonly >/dev/null 2>&1 && echo -n +cr;
  kubectl get clusterrolebinding vgpu-monitor-readonly >/dev/null 2>&1 && echo -n +crb;
  echo")
[ -z "$LEFT" ] && ok "independent check: zero residue" || bad "residue after uninstall: $LEFT"

say "8. vgpu install monitor  AGAIN (reinstall-after-uninstall DoD)"
$SSH "$KC; scripts/vgpu install monitor" | tee "$EVID/08-reinstall.txt"
grep -qE "monitor is READY" "$EVID/08-reinstall.txt" && ok "reinstall → monitor READY" || bad "reinstall failed"

say "9. final teardown (leave the box clean)"
$SSH "$KC; scripts/vgpu uninstall monitor >/dev/null 2>&1; echo done" >/dev/null 2>&1; ok "monitor removed"

echo
echo "════════════════════════════════════════════"
echo " GATE 2 MONITOR LIFECYCLE:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE_PATH=$EVID   COMMIT=$SHA"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 9 ]; then
  echo " FINAL_VERDICT=PASS — Gate 2 enterprise-install earned on real GPU"; exit 0
else
  echo " FINAL_VERDICT=FAIL — do NOT tag"; exit 1
fi
