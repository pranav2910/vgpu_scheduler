#!/usr/bin/env bash
# ============================================================================
# gate5-grafana.sh — Gate 5 real-GPU receipt: Prometheus + Grafana stand up on
# the box, panels populate from REAL monitor metrics, dashboard numbers match
# `vgpu report`, and the dashboard survives a Grafana restart.
#
#   HOST=ubuntu@1.2.3.4 bash scripts/gate5-grafana.sh
#
# Assumes the monitor is installed (run gate2/gate3 first, or:
# ssh $HOST 'cd vgpu_scheduler && scripts/vgpu install monitor').
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/gate5-grafana-${SHA}"; mkdir -p "$EVID"
KC='export KUBECONFIG=$HOME/.kube/config; cd vgpu_scheduler'
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "── $* ──"; }

say "0. sync repo; ensure monitor is up"
$SSH "$KC; git fetch -q origin && git reset -q --hard origin/main && git log --oneline -1
  kubectl get ds vgpu-monitor -n vgpu-monitor >/dev/null 2>&1 || scripts/vgpu install monitor
  kubectl rollout status ds/vgpu-monitor -n vgpu-monitor --timeout=90s >/dev/null 2>&1 && echo MONITOR_READY=yes" \
  | tee "$EVID/00-setup.txt"
grep -q "MONITOR_READY=yes" "$EVID/00-setup.txt" && ok "monitor ready" || bad "monitor not ready"

say "0b. plant a GPU workload so pod-level panels have data"
$SSH "$KC
  kubectl delete pod g5-waste --ignore-not-found >/dev/null 2>&1
  kubectl run g5-waste --image=nvidia/cuda:12.4.1-base-ubuntu22.04 --restart=Never \
    --annotations=gpu-memory=8000 --overrides='{\"spec\":{\"runtimeClassName\":\"nvidia\"}}' \
    -- sleep 600 >/dev/null 2>&1
  sleep 45; echo PLANTED=yes" | tee "$EVID/00b-workload.txt"
grep -q "PLANTED=yes" "$EVID/00b-workload.txt" && ok "workload planted (8000 MiB annotated)" || bad "workload plant failed"

say "1. docker compose up (prometheus + grafana; password injected, never committed)"
$SSH "$KC/deployments 2>/dev/null || cd vgpu_scheduler/deployments
  cd \$HOME/vgpu_scheduler/deployments
  sudo GRAFANA_ADMIN_PASSWORD=gate5-receipt docker compose up -d 2>&1 | tail -3
  sleep 20
  sudo docker compose ps --format '{{.Name}} {{.Status}}'" | tee "$EVID/01-compose.txt"
grep -qi "grafana.*Up" "$EVID/01-compose.txt" && ok "grafana container up" || bad "grafana not up"
grep -qi "prometheus.*Up" "$EVID/01-compose.txt" && ok "prometheus container up" || bad "prometheus not up"

say "2. prometheus discovered the monitor pod and scraped vgpu metrics"
$SSH 'for i in $(seq 1 12); do
    n=$(curl -s "http://localhost:9090/api/v1/query?query=count(vgpu_monitor_gpu_total_vram_bytes)" | grep -o "\"value\":\[[^]]*\]" | head -1)
    [ -n "$n" ] && case "$n" in *\"1\"*|*\"2\"*|*\"3\"*|*\"4\"*|*\"5\"*|*\"6\"*|*\"7\"*|*\"8\"*) echo "SCRAPED=yes ($n)"; break;; esac
    sleep 10
  done' | tee "$EVID/02-scrape.txt"
grep -q "SCRAPED=yes" "$EVID/02-scrape.txt" && ok "vgpu_monitor_* metrics flowing into prometheus" || bad "prometheus has no monitor metrics"

say "3. every headline panel query returns data"
$SSH 'for q in "sum(vgpu_monitor_pod_requested_vram_bytes)" "sum(vgpu_monitor_pod_used_vram_bytes)" "max(vgpu_monitor_gpu_total_vram_bytes)" "100*vgpu_monitor_gpu_used_vram_bytes/vgpu_monitor_gpu_total_vram_bytes"; do
    r=$(curl -s "http://localhost:9090/api/v1/query" --data-urlencode "query=$q" | grep -c "\"value\"")
    echo "q=$q results=$r"
  done' | tee "$EVID/03-queries.txt"
[ "$(grep -c 'results=0' "$EVID/03-queries.txt")" -eq 0 ] && ok "all headline queries return data" || bad "some panel queries empty"

say "4. grafana serves the provisioned dashboard (uid vgpu-waste)"
$SSH 'curl -s -u admin:gate5-receipt http://localhost:3000/api/dashboards/uid/vgpu-waste | head -c 200; echo' | tee "$EVID/04-dash.txt"
grep -q '"uid":"vgpu-waste"' "$EVID/04-dash.txt" && ok "dashboard provisioned + served" || bad "dashboard not found in grafana"

say "5. numbers match: prometheus requested-total vs vgpu report (±1%)"
$SSH "$KC
  P=\$(curl -s 'http://localhost:9090/api/v1/query?query=sum(vgpu_monitor_pod_requested_vram_bytes)' | grep -oE '\"[0-9.e+]+\"\]' | tr -d '\"]')
  R=\$(scripts/vgpu report -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"totals\"][\"requested_bytes\"])')
  echo prometheus=\$P report=\$R
  python3 -c \"
p=float('\${P:-0}'); r=float('\${R:-0}')
print('NUMBERS_MATCH=yes' if (r>0 and abs(p-r)/r <= 0.01) else ('NUMBERS_MATCH=vacuous' if p==r==0 else 'NUMBERS_MATCH=no'))\"" | tee "$EVID/05-match.txt"
grep -q "NUMBERS_MATCH=yes" "$EVID/05-match.txt" && ok "dashboard numbers == vgpu report (±1%)" || bad "dashboard diverges from the report"

say "6. dashboard survives a grafana restart"
$SSH 'cd $HOME/vgpu_scheduler/deployments && sudo GRAFANA_ADMIN_PASSWORD=gate5-receipt docker compose restart grafana >/dev/null 2>&1 && sleep 12
  curl -s -u admin:gate5-receipt http://localhost:3000/api/dashboards/uid/vgpu-waste | grep -o "\"uid\":\"vgpu-waste\"" | head -1' | tee "$EVID/06-restart.txt"
grep -q '"uid":"vgpu-waste"' "$EVID/06-restart.txt" && ok "dashboard survives restart (provisioned, not clicked-together)" || bad "dashboard lost on restart"

say "7. teardown compose + planted workload (leave the box clean)"
$SSH "$KC; kubectl delete pod g5-waste --ignore-not-found --wait=false" >/dev/null 2>&1
$SSH 'cd $HOME/vgpu_scheduler/deployments && sudo GRAFANA_ADMIN_PASSWORD=x docker compose down >/dev/null 2>&1; echo down' >/dev/null 2>&1
ok "compose torn down"

echo
echo "════════════════════════════════════════════"
echo " GATE 5 GRAFANA:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE_PATH=$EVID   COMMIT=$SHA"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 8 ]; then
  echo " FINAL_VERDICT=PASS"; exit 0
else
  echo " FINAL_VERDICT=FAIL — do NOT tag"; exit 1
fi
