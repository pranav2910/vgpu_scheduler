#!/usr/bin/env bash
# validate-recommendation-3.7b-kind.sh — Phase 3.7b autoResize, on kind.
#
# Proves the mutating VGPUJob webhook RAISES an under-provisioned request to the
# learned recommendation at CREATE — transparently — and respects every safety
# rule. We assert the PERSISTED object (the mutation must be durable and consistent
# for the downstream claim/slice), the audit annotations, and the controller's
# AutoResized / AutoResizeCapped conditions.
#
#   bash scripts/setup-kind-cluster.sh
#   bash scripts/validate-recommendation-3.7b-kind.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS="${NS:-default}"; SYS_NS=vgpu-system
GROUP=infrastructure.pranav2910.com
REQ_BYTES=17179869184      # 16 GiB request
REC_BYTES=24000000000      # ~24 GB recommendation (within a card)
REC_BIG=96000000000        # 96 GB recommendation (exceeds fleet max → capped)
FLEET_MAX=85899345920      # 80 GiB

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "${C_BLU}── $* ──${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
kubectl -n "$SYS_NS" get deploy vgpu-controller >/dev/null 2>&1 \
    || { echo "control plane not deployed — run scripts/setup-kind-cluster.sh first"; exit 2; }

NAMES="arz1 arz2 arz3 arz4"
cleanup() {
    hdr "cleanup"
    for n in $NAMES; do
        kubectl delete vgpujob "$n" vgpuworkloadprofile "$n" vgpuclaim "${n}-claim" \
            vgpuslice "${n}-claim-slice" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    done
    kubectl set env deploy/vgpu-controller -n "$SYS_NS" VGPU_RECOMMENDATION_MODE- >/dev/null 2>&1 || true
    echo "  test objects deleted; controller mode reset to default"
}
trap cleanup EXIT

hdr "rebuild + redeploy controller (3.7b) + apply mutating webhook config"
docker build --provenance=false -t vgpu-controller:latest -f Dockerfile.controller . >/dev/null 2>&1 && echo "  built controller image"
kind load docker-image vgpu-controller:latest --name vgpu-test >/dev/null 2>&1 && echo "  loaded into kind"
kubectl apply -f deployments/manifests/crds/ >/dev/null 2>&1
kubectl apply -f deployments/manifests/webhooks/mutating.yaml >/dev/null 2>&1 && echo "  applied mutating webhook config (incl. vgpujob)"
kubectl set env deploy/vgpu-controller -n "$SYS_NS" VGPU_RECOMMENDATION_MODE=autoResize >/dev/null
kubectl rollout status deploy/vgpu-controller -n "$SYS_NS" --timeout=120s >/dev/null 2>&1 && echo "  controller in autoResize"
sleep 4

seed_profile() { # name confidence recommendedBytes
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: ${GROUP}/v1alpha1
kind: VGPUWorkloadProfile
metadata: { name: $1, namespace: $NS }
EOF
    kubectl patch vgpuworkloadprofile "$1" -n "$NS" --subresource=status --type=merge \
        -p "{\"status\":{\"recommendedVramBytes\":$3,\"peakObservedVramBytes\":$3,\"confidence\":\"$2\",\"observations\":150}}" >/dev/null 2>&1
}
apply_job() { # name override(true/false)
    local meta_ann=""
    [[ "$2" == "true" ]] && meta_ann=$'\n'"  annotations:"$'\n'"    ${GROUP}/override-recommendation: \"true\""
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: ${GROUP}/v1alpha1
kind: VGPUJob
metadata:
  name: $1
  namespace: $NS${meta_ann}
spec:
  priority: 50
  claimTemplate:
    spec: { requestedVramBytes: ${REQ_BYTES}, serviceTier: Guaranteed }
EOF
}
jp() { kubectl get vgpujob "$1" -n "$NS" -o jsonpath="$2" 2>/dev/null; }
ann() { kubectl get vgpujob "$1" -n "$NS" -o jsonpath="{.metadata.annotations.${GROUP//./\\.}/$2}" 2>/dev/null; }
wait_cond() { for _ in $(seq 1 12); do [[ "$(jp "$1" "{.status.conditions[?(@.type==\"$2\")].status}")" == "True" ]] && return 0; sleep 2; done; return 1; }

# ── 1. undersized + High → raised to the recommendation, fully audited ────────
hdr "autoResize raises an under-provisioned request"
seed_profile arz1 High "$REC_BYTES"
apply_job arz1 false
got="$(jp arz1 '{.spec.claimTemplate.spec.requestedVramBytes}')"
[[ "$got" == "$REC_BYTES" ]] && ok "request mutated $REQ_BYTES → $got (== recommendation)" || bad "request not resized (got '$got', want $REC_BYTES)"
[[ "$(ann arz1 original-vram-bytes)" == "$REQ_BYTES" ]] && ok "original-vram-bytes annotation records $REQ_BYTES" || bad "original annotation wrong (got '$(ann arz1 original-vram-bytes)')"
[[ "$(ann arz1 autoresized-vram-bytes)" == "$REC_BYTES" ]] && ok "autoresized-vram-bytes annotation records $REC_BYTES" || bad "resized annotation wrong"
[[ "$(ann arz1 autoresized)" == "true" ]] && ok "autoresized=true marker present" || bad "autoresized marker missing"
wait_cond arz1 AutoResized && ok "controller set AutoResized condition (+ event)" || bad "AutoResized condition not set"

# ── 2. override → NOT resized ─────────────────────────────────────────────────
hdr "override opts out of autoResize"
seed_profile arz2 High "$REC_BYTES"
apply_job arz2 true
got="$(jp arz2 '{.spec.claimTemplate.spec.requestedVramBytes}')"
[[ "$got" == "$REQ_BYTES" ]] && ok "override left the request untouched ($got)" || bad "override was resized (got '$got')"
[[ -z "$(ann arz2 autoresized)" ]] && ok "no autoresized annotation when overridden" || bad "unexpected autoresized annotation"

# ── 3. Low confidence → NOT resized (safety gate) ─────────────────────────────
hdr "Low confidence is never auto-resized"
seed_profile arz3 Low "$REC_BYTES"
apply_job arz3 false
got="$(jp arz3 '{.spec.claimTemplate.spec.requestedVramBytes}')"
[[ "$got" == "$REQ_BYTES" ]] && ok "Low-confidence profile left the request untouched ($got)" || bad "Low confidence was resized (got '$got')"

# ── 4. recommended > fleet max → capped + flagged ─────────────────────────────
hdr "recommendation above a card is capped at fleet max"
seed_profile arz4 High "$REC_BIG"
apply_job arz4 false
got="$(jp arz4 '{.spec.claimTemplate.spec.requestedVramBytes}')"
[[ "$got" == "$FLEET_MAX" ]] && ok "request capped to fleet max ($got)" || bad "not capped (got '$got', want $FLEET_MAX)"
[[ "$(ann arz4 autoresize-capped)" == "$REC_BIG" ]] && ok "autoresize-capped records the uncapped recommendation ($REC_BIG)" || bad "capped annotation wrong (got '$(ann arz4 autoresize-capped)')"
wait_cond arz4 AutoResizeCapped && ok "controller set AutoResizeCapped condition (+ event)" || bad "AutoResizeCapped condition not set"

hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}3.7b — autoResize proven: under-provisioned requests are raised to the recommendation (capped at fleet max), audited, and safe (override/Low-confidence skip).${C_RST}"; exit 0; }
echo; echo "${C_RED}validation had failures${C_RST}"; exit 1
