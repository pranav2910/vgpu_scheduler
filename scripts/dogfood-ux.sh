#!/usr/bin/env bash
# ============================================================================
# dogfood-ux.sh — CERT-19: the user-journey HONESTY receipt.
#
# Scripted version of the founder dogfooding session (2026-07-09) that caught
# three bugs the 22-test behavior certification missed: 'recommended 0 B',
# the silent resize no-op, and misleading historical-profile rendering.
# Behavior tests prove the product WORKS; this suite proves the product never
# LIES to the user: it drives scripts/vgpu exactly like a human and asserts
# the CLI's story matches cluster truth at every step.
#
# Runs against ANY live vGPU cluster (kind or real GPU):
#   bash scripts/dogfood-ux.sh                          # kind (no runtime class)
#   RUNTIME_CLASS=nvidia bash scripts/dogfood-ux.sh     # real GPU node
# Env: NS=dogfood  VRAM=2Gi  VRAM2=5Gi  (VRAM2 must differ from VRAM)
# ============================================================================
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS="${NS:-dogfood}"; RTC="${RUNTIME_CLASS:-}"; V1="${VRAM:-2Gi}"; V2="${VRAM2:-5Gi}"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
EVID="artifacts/dogfood-$SHA"; mkdir -p "$EVID"
PASS=0; FAIL=0
ok(){  echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "━━ $* ━━"; }
VG="scripts/vgpu"
RTCARGS=""; [ -n "$RTC" ] && RTCARGS="--runtime-class $RTC"
to_bytes(){ # 2Gi / 512Mi / 3G → bytes (mirrors the CLI's parser for the sizes we use)
  local v="$1" n unit
  n="${v%%[!0-9]*}"; unit="${v#"$n"}"
  case "$unit" in
    Gi) echo $((n*1024*1024*1024)) ;;
    Mi) echo $((n*1024*1024)) ;;
    G)  echo $((n*1000*1000*1000)) ;;
    *)  echo 0 ;;
  esac
}
V1B=$(to_bytes "$V1"); V1H="${V1%Gi}.0 GiB"

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete vgpujob --all -n "$NS" --wait=true >/dev/null 2>&1
kubectl delete vgpuworkloadprofile --all -n "$NS" --wait=true >/dev/null 2>&1
sleep 3

say "D1: status of a job that doesn't exist → nonzero + points at the fix"
set +e; OUT=$($VG status ghost-job -n "$NS" 2>&1); RC=$?; set -e 2>/dev/null || true
echo "$OUT" > "$EVID/d1.txt"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "vgpu submit"; then
  ok "D1: exit=$RC and suggests 'vgpu submit'"
else bad "D1: exit=$RC output='$OUT'"; fi

say "D2: submit $V1 → CLI story matches cluster truth"
$VG submit --name df-a --vram "$V1" -n "$NS" --image busybox \
  --command 'sleep 3600' $RTCARGS --wait 120 > "$EVID/d2-submit.txt" 2>&1 || true
sleep 5
GOTB=$(kubectl get vgpuclaim df-a-claim -n "$NS" -o jsonpath='{.spec.requestedVramBytes}' 2>/dev/null)
STATUS=$($VG status df-a -n "$NS" 2>&1); echo "$STATUS" > "$EVID/d2-status.txt"
if [ "$GOTB" = "$V1B" ] && echo "$STATUS" | grep -q "requested $V1H"; then
  ok "D2: claim=$GOTB bytes AND status says 'requested $V1H' — story == truth"
else bad "D2: claim='$GOTB' (want $V1B); status: $(echo "$STATUS" | head -1)"; fi

say "D3: profile of a live job with no learnable usage NEVER advises '0 B'"
PROF=""
for _ in $(seq 1 18); do
  PROF=$($VG profile df-a -n "$NS" 2>&1) && echo "$PROF" | grep -q "requested" && break
  sleep 5
done
echo "$PROF" > "$EVID/d3-profile.txt"
if echo "$PROF" | grep -Eq 'recommended[[:space:]]+0 B'; then
  bad "D3: profile recommends literal 0 B (the dogfood bug is back)"
elif echo "$PROF" | grep -q "none yet" || echo "$PROF" | grep -Eq 'recommended[[:space:]]+[1-9]'; then
  ok "D3: recommendation line is honest ('none yet' or a real value)"
else bad "D3: unexpected profile output: $(echo "$PROF" | grep recommended)"; fi
if echo "$PROF" | grep -q "requested.*$V1H"; then
  ok "D3b: profile 'requested' matches the live claim ($V1H) — no stale display"
else bad "D3b: profile requested line disagrees with live claim: $(echo "$PROF" | grep requested)"; fi

say "D4: re-submit same name, different size ($V2) → CLI refuses LOUDLY, cluster unchanged"
set +e; OUT=$($VG submit --name df-a --vram "$V2" -n "$NS" --image busybox --command 'sleep 1' $RTCARGS 2>&1); RC=$?; set -e 2>/dev/null || true
echo "$OUT" > "$EVID/d4.txt"
STILL=$(kubectl get vgpuclaim df-a-claim -n "$NS" -o jsonpath='{.spec.requestedVramBytes}' 2>/dev/null)
JOBT=$(kubectl get vgpujob df-a -n "$NS" -o jsonpath='{.spec.claimTemplate.spec.requestedVramBytes}' 2>/dev/null)
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "already exists" && echo "$OUT" | grep -q "$V1H"; then
  ok "D4: refused (exit=$RC), names the existing job AND its current grant ($V1H)"
else bad "D4: rc=$RC out=$(echo "$OUT" | head -2)"; fi
if [ "$STILL" = "$V1B" ] && [ "$JOBT" = "$V1B" ]; then
  ok "D4b: claim AND job template still $V1B bytes — nothing silently changed"
else bad "D4b: claim=$STILL jobTemplate=$JOBT (want $V1B) — something mutated"; fi

say "D5: direct kubectl edit of the size → webhook DENIES with the resize recipe"
set +e
PERR=$(kubectl patch vgpujob df-a -n "$NS" --type=merge \
  -p '{"spec":{"claimTemplate":{"spec":{"requestedVramBytes":6442450944}}}}' 2>&1); RC=$?
set -e 2>/dev/null || true
echo "$PERR" > "$EVID/d5.txt"
if [ "$RC" -ne 0 ] && echo "$PERR" | grep -q "immutability violation" && echo "$PERR" | grep -q "delete vgpujob"; then
  ok "D5: webhook denied the edit and told the user how to actually resize"
else bad "D5: rc=$RC err=$(echo "$PERR" | head -2)"; fi

say "D6: delete the job → profile survives, labeled as HISTORY, still never '0 B'"
kubectl delete vgpujob df-a -n "$NS" --wait=true >/dev/null 2>&1; sleep 5
PROF2=$($VG profile df-a -n "$NS" 2>&1); echo "$PROF2" > "$EVID/d6.txt"
if echo "$PROF2" | grep -q "SAVED history"; then
  ok "D6: historical profile is labeled as history (job gone, data kept by design)"
else bad "D6: no history label: $(echo "$PROF2" | head -3)"; fi
if echo "$PROF2" | grep -Eq 'recommended[[:space:]]+0 B'; then
  bad "D6b: historical profile recommends 0 B"
else ok "D6b: historical recommendation line stays honest"; fi

kubectl delete ns "$NS" --wait=false >/dev/null 2>&1

echo
echo "════════════════════════════════════════════"
echo " CERT-19 DOGFOOD/UX HONESTY:  PASS=$PASS  FAIL=$FAIL   EVIDENCE=$EVID"
[ "$FAIL" -eq 0 ] && { echo " FINAL_VERDICT=PASS"; exit 0; } || { echo " FINAL_VERDICT=FAIL"; exit 1; }
