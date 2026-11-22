#!/usr/bin/env bash
# validate-recommendation-3.7-kind.sh — Phase 3.7 recommendation enforcement.
#
# Proves the VGPUJob validating webhook turns a learned recommendation into a
# future-request policy, end to end on a kind cluster (no GPU needed — this is
# admission logic, not data plane):
#
#   recommendOnly  → never blocks
#   warn           → never blocks
#   requireOverride→ blocks an undersized request on a CONFIDENT (Medium+) profile,
#                    UNLESS the override annotation is present;
#                    and NEVER blocks on a Low-confidence profile (the safety gate).
#
# We seed each workload's VGPUWorkloadProfile directly (a standalone profile with
# no backing slices is left untouched by the profile reconciler), then assert the
# admission decision at VGPUJob CREATE. The advisory condition/event surfaces are
# covered by unit tests (they race the profile reconciler on a live cluster).
#
#   bash scripts/setup-kind-cluster.sh      # control plane on kind
#   bash scripts/validate-recommendation-3.7-kind.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS="${NS:-default}"
SYS_NS=vgpu-system
REC="${REC:-24000000000}"   # recommended ~24 GB
REQ="16Gi"                  # undersized request (16 < 24×0.9)
GROUP=infrastructure.pranav2910.com

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "${C_BLU}── $* ──${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
kubectl -n "$SYS_NS" get deploy vgpu-controller >/dev/null 2>&1 \
    || { echo "control plane not deployed — run scripts/setup-kind-cluster.sh first"; exit 2; }

NAMES="rectest1 rectest2 rectest3 rectest4 rectest5"
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

# ── rebuild the controller with the 3.7 code + apply the new webhook config ──
hdr "rebuild + redeploy controller (3.7) + apply webhook config"
docker build --provenance=false -t vgpu-controller:latest -f Dockerfile.controller . >/dev/null 2>&1 && echo "  built controller image"
kind load docker-image vgpu-controller:latest --name vgpu-test >/dev/null 2>&1 && echo "  loaded into kind"
kubectl apply -f deployments/manifests/crds/ >/dev/null 2>&1
kubectl apply -f deployments/manifests/webhooks/validating.yaml >/dev/null 2>&1 && echo "  applied validating webhook config (incl. vgpujob)"

# seed a standalone profile (survives the reconciler — no backing slices).
seed_profile() { # name confidence
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: ${GROUP}/v1alpha1
kind: VGPUWorkloadProfile
metadata: { name: $1, namespace: $NS }
EOF
    kubectl patch vgpuworkloadprofile "$1" -n "$NS" --subresource=status --type=merge \
        -p "{\"status\":{\"recommendedVramBytes\":${REC},\"peakObservedVramBytes\":${REC},\"confidence\":\"$2\",\"observations\":150}}" >/dev/null 2>&1
}

# apply a VGPUJob; echo "ADMITTED" / "REJECTED" / "ERROR:<msg>".
apply_job() { # name override(true/false)
    local meta_ann=""
    [[ "$2" == "true" ]] && meta_ann=$'\n'"  annotations:"$'\n'"    ${GROUP}/override-recommendation: \"true\""
    local out
    out=$(cat <<EOF | kubectl apply -f - 2>&1
apiVersion: ${GROUP}/v1alpha1
kind: VGPUJob
metadata:
  name: $1
  namespace: $NS${meta_ann}
spec:
  priority: 50
  claimTemplate:
    spec:
      requestedVramBytes: 17179869184
      serviceTier: Guaranteed
EOF
)
    if echo "$out" | grep -qi "denied"; then echo "REJECTED"; return; fi
    # Robust: confirm the object actually exists rather than assuming "not denied" = admitted
    # (a malformed apply must not masquerade as ADMITTED).
    if kubectl get vgpujob "$1" -n "$NS" >/dev/null 2>&1; then echo "ADMITTED"; else echo "ERROR:$(echo "$out" | tail -1)"; fi
}

set_mode() { # mode
    kubectl set env deploy/vgpu-controller -n "$SYS_NS" "VGPU_RECOMMENDATION_MODE=$1" >/dev/null
    kubectl rollout status deploy/vgpu-controller -n "$SYS_NS" --timeout=120s >/dev/null 2>&1
    sleep 4   # let the freshly-rolled webhook endpoint settle
}

# ── recommendOnly: never blocks ──────────────────────────────────────────────
hdr "mode=recommendOnly"
set_mode recommendOnly
seed_profile rectest1 High
r=$(apply_job rectest1 false)
[[ "$r" == "ADMITTED" ]] && ok "recommendOnly admits an undersized request (High confidence)" || bad "recommendOnly should admit (got $r)"

# ── warn: never blocks ───────────────────────────────────────────────────────
hdr "mode=warn"
set_mode warn
seed_profile rectest2 High
r=$(apply_job rectest2 false)
[[ "$r" == "ADMITTED" ]] && ok "warn admits an undersized request (event is unit-tested)" || bad "warn should admit (got $r)"

# ── requireOverride: the enforcement mode ────────────────────────────────────
hdr "mode=requireOverride"
set_mode requireOverride

seed_profile rectest3 High
r=$(apply_job rectest3 false)
[[ "$r" == "REJECTED" ]] && ok "requireOverride REJECTS undersized + Medium/High + no override" || bad "should be REJECTED (got $r)"

seed_profile rectest4 High
r=$(apply_job rectest4 true)
[[ "$r" == "ADMITTED" ]] && ok "override annotation admits the undersized request" || bad "override should ADMIT (got $r)"

seed_profile rectest5 Low
r=$(apply_job rectest5 false)
[[ "$r" == "ADMITTED" ]] && ok "Low confidence is NEVER blocked (the safety gate)" || bad "Low confidence should ADMIT (got $r)"

hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}3.7a — recommendation enforcement proven: requireOverride blocks only a confident, undersized, un-overridden request.${C_RST}"; exit 0; }
echo; echo "${C_RED}validation had failures${C_RST}"; exit 1
