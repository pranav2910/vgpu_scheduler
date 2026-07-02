#!/usr/bin/env bash
# ============================================================================
# tier0-scale-storm.sh — the "10,000 engineers" control-plane test. No real
# GPUs: a WORKERS-node kind cluster where every worker fakes GPUS_PER_NODE
# 80Gi cards, then job storms, gang storms at overcapacity, a leader kill
# mid-storm, and a churn wave — with the no-over-admission invariant checked
# after every phase and per-gang all-or-nothing asserted at scale.
#
#   HOST=ubuntu@1.2.3.4 bash scripts/tier0-scale-storm.sh      # remote box
#   WORKERS=12 GPUS_PER_NODE=8 JOBS=800 GANGS=40 ...           # knobs
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
WORKERS="${WORKERS:-12}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
JOBS="${JOBS:-800}"          # wave-1 solo jobs, 8Gi each
GANGS="${GANGS:-40}"         # wave-2 gangs, 8 x 16Gi each
CHURN="${CHURN:-400}"        # wave-3: delete N, submit N
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/tier0-storm-${SHA}"; mkdir -p "$EVID"
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "── $* ──"; }
KC='export KUBECONFIG=$HOME/.kube/config-storm; cd vgpu_scheduler'

say "0a. prereqs: kind binary + docker group (fresh ssh sessions pick the group up)"
$SSH 'set -e
  if ! command -v kind >/dev/null 2>&1; then
    ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) A=amd64;; esac
    curl -sLo /tmp/kind "https://kind.sigs.k8s.io/dl/v0.29.0/kind-linux-$A"
    sudo install -m 0755 /tmp/kind /usr/local/bin/kind
  fi
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  kind version' | tee "$EVID/00a-prereqs.txt"
grep -q "kind v" "$EVID/00a-prereqs.txt" && ok "kind installed" || { bad "kind install failed"; exit 1; }

say "0b. bring up ${WORKERS}-worker kind storm cluster (${GPUS_PER_NODE} fake 80Gi GPUs per worker)"
$SSH "cd vgpu_scheduler && git fetch -q origin && git reset -q --hard origin/main
  export KUBECONFIG=\$HOME/.kube/config-storm
  kind delete cluster --name vgpu-storm >/dev/null 2>&1
  CLUSTER=vgpu-storm WORKERS=$WORKERS bash scripts/kind-multinode-up.sh
  kubectl set env ds/vgpu-nodeagent -n vgpu-system VGPU_FAKE_GPU_COUNT=$GPUS_PER_NODE
  kubectl rollout status ds/vgpu-nodeagent -n vgpu-system --timeout=300s >/dev/null
  sleep 20   # agents re-advertise multi-GPU capacity
  TOTAL=\$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.capacity.vgpu\.pranav2910\.com/vram}{\"\n\"}{end}' | awk '{s+=\$1} END{print s}')
  echo CLUSTER_CAPACITY_BYTES=\$TOTAL" > "$EVID/00-bringup.log" 2>&1
CAP=$(grep -oE "CLUSTER_CAPACITY_BYTES=[0-9]+" "$EVID/00-bringup.log" | cut -d= -f2)
if [ -n "${CAP:-}" ] && [ "$CAP" -ge 1000000000000 ]; then
  ok "storm cluster up: capacity $((CAP/1073741824)) GiB across $WORKERS workers"
else
  bad "storm cluster has no capacity (CAP='${CAP:-empty}') — vacuous-pass guard (round-1: kind was missing and this check passed on an empty label)"
  exit 1
fi

# invariant checker: for every node, sum(Ready-slice allocatedBytes) <= capacity.
# min_ready guards against vacuous passes: an empty cluster trivially "holds".
check_invariant() {
    local tag="$1" min_ready="${2:-1}"
    $SSH "$KC
      kubectl get vgpuslices -A -o jsonpath='{range .items[?(@.status.phase==\"Ready\")]}{.spec.nodeName}{\" \"}{.status.allocatedBytes}{\"\n\"}{end}' \
        | awk 'NF==2 {a[\$1]+=\$2} END {for (n in a) print n, a[n]}' > /tmp/alloc.txt
      kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.status.capacity.vgpu\.pranav2910\.com/vram}{\"\n\"}{end}' > /tmp/cap.txt
      READY=\$(kubectl get vgpuslices -A --no-headers 2>/dev/null | grep -c ' Ready' || true)
      echo READY_COUNT=\$READY
      awk 'NR==FNR {cap[\$1]=\$2; next} {if (\$2 > cap[\$1]) {print \"OVERCOMMIT\", \$1, \$2, cap[\$1]; bad=1}} END {exit bad}' /tmp/cap.txt /tmp/alloc.txt \
        && echo INVARIANT_OK || echo INVARIANT_VIOLATED" | tee "$EVID/invariant-$tag.txt"
    RC=$(grep -oE "READY_COUNT=[0-9]+" "$EVID/invariant-$tag.txt" | cut -d= -f2)
    if grep -q "INVARIANT_OK" "$EVID/invariant-$tag.txt" && [ "${RC:-0}" -ge "$min_ready" ]; then
        ok "no-over-admission invariant holds ($tag, ready=$RC ≥ $min_ready)"
    else
        bad "invariant check failed ($tag): ready=${RC:-0} (min $min_ready) or over-admission"
    fi
}

say "1. WAVE 1: $JOBS solo jobs (8Gi) in one burst"
T0=$(date +%s)
$SSH "$KC
  for ns in storm-{0..9}; do kubectl create ns \$ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
  { for i in \$(seq 1 $JOBS); do
      ns=storm-\$(( i % 10 ))
      printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: solo-%04d, namespace: %s}\nspec: {claimTemplate: {spec: {requestedVramBytes: 8589934592}}}\n---\n' \$i \$ns
    done; } | kubectl apply -f - >/dev/null
  echo SUBMITTED=$JOBS
  for i in \$(seq 1 60); do
    R=\$(kubectl get vgpuslices -A --no-headers 2>/dev/null | grep -c ' Ready' || true)
    echo tick=\$i ready=\$R
    [ \"\$R\" -ge $JOBS ] && break
    sleep 10
  done" | tee "$EVID/01-wave1.txt" | tail -3
T1=$(date +%s)
READY1=$(grep -oE "ready=[0-9]+" "$EVID/01-wave1.txt" | tail -1 | cut -d= -f2)
[ "${READY1:-0}" -ge "$JOBS" ] && ok "wave 1: all $JOBS jobs Ready in $((T1-T0))s (includes bring-up of namespaces)" \
    || bad "wave 1 incomplete: $READY1/$JOBS Ready"
check_invariant wave1 "$JOBS"
$SSH "$KC; kubectl get pods -n vgpu-system -l control-plane=vgpu-scheduler -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{\" \"}{end}'" > "$EVID/01-restarts.txt"
grep -qE "^0 0 ?$" "$EVID/01-restarts.txt" && ok "scheduler survived wave 1 (0 restarts)" || bad "scheduler restarted under wave 1: $(cat "$EVID/01-restarts.txt")"

say "2. WAVE 2: $GANGS gangs (8×16Gi) pushing PAST capacity — all-or-nothing must hold at scale"
$SSH "$KC
  { for g in \$(seq 1 $GANGS); do
      printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUGangJob\nmetadata: {name: gang-%03d, namespace: storm-%d}\nspec: {gangSize: 8, minAvailable: 8, reservationTimeoutSeconds: 90, priority: 100, workloadClass: Training, preemptible: false, podTemplate: {spec: {requestedVramBytes: 17179869184, serviceTier: Guaranteed}}}\n---\n' \$g \$(( g % 10 ))
    done; } | kubectl apply -f - >/dev/null
  echo GANGS_SUBMITTED=$GANGS
  sleep 45" > "$EVID/02-gangs-submit.txt" 2>&1
grep -q "GANGS_SUBMITTED" "$EVID/02-gangs-submit.txt" && ok "gang storm submitted" || bad "gang submit failed"

say "3. LEADER KILL mid-storm"
$SSH "$KC
  LEADER=\$(kubectl get lease -n vgpu-system 2>/dev/null | grep -i sched | awk '{print \$2}' | head -1)
  kubectl get pods -n vgpu-system -l control-plane=vgpu-scheduler --no-headers | head -2
  kubectl delete pod -n vgpu-system \$(kubectl get pods -n vgpu-system -l control-plane=vgpu-scheduler -o jsonpath='{.items[0].metadata.name}') --wait=false
  echo LEADER_KILLED=yes; sleep 30" > "$EVID/03-leaderkill.txt" 2>&1
grep -q "LEADER_KILLED=yes" "$EVID/03-leaderkill.txt" && ok "leader killed mid-storm" || bad "leader kill step failed"

say "4. gangs settle: every gang ALL-8-Ready or ZERO-Ready (no partial admission at scale)"
$SSH "$KC
  sleep 120
  kubectl get vgpuslices -A -o jsonpath='{range .items[*]}{.metadata.namespace}{\"/\"}{.metadata.annotations.gang\.vgpu\.pranav2910\.com/gang}{\" \"}{.status.phase}{\"\n\"}{end}' 2>/dev/null \
    | grep -v '^[^ ]*/ ' | awk '\$1 ~ /gang-/ { total[\$1]++; if (\$2==\"Ready\") ready[\$1]++ }
      END { part=0; full=0; zero=0
            for (g in total) { r=ready[g]+0
              if (r==0) zero++
              else if (r==total[g] && r==8) full++
              else { part++; print \"PARTIAL\", g, r\"/\"total[g] } }
            print \"full=\"full, \"zero=\"zero, \"partial=\"part }'" | tee "$EVID/04-gang-settle.txt"
grep -q "partial=0" "$EVID/04-gang-settle.txt" && ok "gang all-or-nothing held at scale: $(grep -oE 'full=[0-9]+ zero=[0-9]+' "$EVID/04-gang-settle.txt")" \
    || bad "PARTIAL gang admission detected at scale"
check_invariant wave2 "$JOBS"

say "5. CHURN: delete $CHURN random solos, submit $CHURN replacements"
$SSH "$KC
  kubectl get vgpujobs -A --no-headers | awk '\$2 ~ /^solo-/ {print \$1, \$2}' | shuf -n $CHURN > /tmp/victims.txt
  while read ns n; do kubectl delete vgpujob \$n -n \$ns --wait=false >/dev/null 2>&1; done < /tmp/victims.txt
  { for i in \$(seq 1 $CHURN); do
      printf 'apiVersion: infrastructure.pranav2910.com/v1alpha1\nkind: VGPUJob\nmetadata: {name: churn-%04d, namespace: storm-%d}\nspec: {claimTemplate: {spec: {requestedVramBytes: 8589934592}}}\n---\n' \$i \$(( i % 10 ))
    done; } | kubectl apply -f - >/dev/null
  echo CHURNED=$CHURN
  sleep 150
  kubectl get vgpuslices -A --no-headers 2>/dev/null | grep -c ' Ready' | sed 's/^/ready_after_churn=/'" | tee "$EVID/05-churn.txt" | tail -2
grep -q "CHURNED=$CHURN" "$EVID/05-churn.txt" && ok "churn wave executed" || bad "churn failed"
check_invariant churn "$(( JOBS - CHURN ))"
$SSH "$KC; kubectl get pods -n vgpu-system -l control-plane=vgpu-scheduler -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{\" \"}{end}'; echo" > "$EVID/05-restarts.txt"
ok "final scheduler restart counts: $(cat "$EVID/05-restarts.txt" | tr -d '\n') (1 expected: the deliberate leader kill)"

say "6. teardown storm cluster"
$SSH 'export KUBECONFIG=$HOME/.kube/config-storm; kind delete cluster --name vgpu-storm >/dev/null 2>&1; echo down'
ok "storm cluster deleted"

echo
echo "════════════════════════════════════════════"
echo " TIER-0 SCALE STORM:  PASS=$PASS  FAIL=$FAIL"
echo " scale: $WORKERS nodes × $GPUS_PER_NODE GPUs | $JOBS solos + $GANGS gangs(×8) + $CHURN churn | leader kill mid-storm"
echo " EVIDENCE_PATH=$EVID   COMMIT=$SHA"
if [ "$FAIL" -eq 0 ]; then echo " FINAL_VERDICT=PASS"; exit 0; else echo " FINAL_VERDICT=FAIL"; exit 1; fi
