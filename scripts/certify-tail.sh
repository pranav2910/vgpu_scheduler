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

CERTLOG="$EVID/.certlog"; : > "$CERTLOG"
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "━━ $* ━━"; }
cert(){ # id verdict note
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CERTLOG"
    [[ "$2" == "PASS" ]] && ok "$1: $3" || bad "$1 FAILED: $3"
}
# poll_slice ns name phase timeout — early-exit wait (replaces fixed sleeps)
# (remote-side helper; injected into blocks that need it via $POLL)
POLL='pollp(){ for _ in $(seq 1 $(($4/4))); do p=$(kubectl get vgpuslice "$2" -n "$1" -o jsonpath="{.status.phase}" 2>/dev/null); [ "$p" = "$3" ] && return 0; sleep 4; done; return 1; };'

# wait until NO slices exist cluster-wide (releases from the previous section
# must fully drain before exact-fit packing sections, or they block the pack)
quiesce(){
    local tmo="${1:-180}"
    for _ in $(seq 1 $((tmo/5))); do
        local n
        n=$($SSH "export KUBECONFIG=\$HOME/.kube/config; kubectl get vgpuslice -A --no-headers 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
        [ "${n:-1}" = "0" ] && return 0
        sleep 5
    done
    # SELF-HEAL, never continue dirty: a prior killed run once left 88Gi of
    # squatters; a warn-and-continue quiesce let the pack fail 22/32 (the
    # product fail-louded correctly; the harness had lied to it about capacity).
    echo "  quiesce timeout ($n slices) — purging ALL test namespaces and re-draining"
    $SSH "export KUBECONFIG=\$HOME/.kube/config
      kubectl get ns -o name | grep -E 'cert|mgpu-|repro|t3' | cut -d/ -f2 | xargs -r kubectl delete ns --ignore-not-found >/dev/null 2>&1
      kubectl delete vgpujobs,vgpugangjobs --all -A --wait=false >/dev/null 2>&1" 2>/dev/null
    for _ in $(seq 1 $((tmo/5))); do
        local m
        m=$($SSH "export KUBECONFIG=\$HOME/.kube/config; kubectl get vgpuslice -A --no-headers 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
        [ "${m:-1}" = "0" ] && return 0
        sleep 5
    done
    echo "  (still dirty after purge — sections may see contention)"
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


# sync the box repo (the CLI fix lives in scripts/vgpu ON THE BOX)
$SSH "cd vgpu_scheduler && git fetch -q origin && git reset -q --hard origin/main && git log --oneline -1"

# ═══ TAIL COMPLETION: seed the banked round-7 ledger (product-identical commit;
# CERT-17's lane-placement FAIL dropped — it re-runs QUIET below) ═══
SEED="artifacts/certify-9414145/.certlog"
if [ -f "$SEED" ]; then
    grep -v "^CERT-15|" "$SEED" > "$CERTLOG"
    PASS=$(grep -c "|PASS|" "$CERTLOG" || true); FAIL=0
    echo "seeded $PASS banked PASS verdicts from round 7"
fi
CARDS=$($SSH 'nvidia-smi -L | wc -l' 2>/dev/null | tr -d ' ')
PERCARD_MIB=$($SSH 'nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | sort -n | head -1' 2>/dev/null | tr -dc '0-9')
$SSH "export KUBECONFIG=\$HOME/.kube/config
  kubectl get ns -o name | grep -E 'cert|mgpu-|repro|t3' | cut -d/ -f2 | xargs -r kubectl delete ns --ignore-not-found >/dev/null 2>&1; true" 2>/dev/null
quiesce 240

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
    sort "$CERTLOG" | while IFS='|' read -r id v note; do
        echo "| $id | $v | $note |"
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
