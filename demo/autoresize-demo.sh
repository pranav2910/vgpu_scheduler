#!/usr/bin/env bash
# demo/autoresize-demo.sh — watch the platform auto-correct an under-sized request.
#
# It pretends a workload has already been profiled (peak ~21.5 GiB → recommends
# ~24.7 GiB), turns on `autoResize`, then submits the SAME workload UNDER-provisioned
# (16 GiB) — and shows it admitted at the *recommended* size, raised by the mutating
# webhook before the slice is even created, with a full audit trail.
#
# Reproducible on kind (default) or a real GPU node:
#   bash scripts/setup-kind-cluster.sh            # or scripts/h100-control-plane.sh
#   bash demo/autoresize-demo.sh                  # kind (busybox, no runtimeClass)
#   IMAGE=nvidia/cuda:12.4.1-base-ubuntu22.04 RUNTIME_CLASS=nvidia bash demo/autoresize-demo.sh   # real GPU
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
[[ -r "$KUBECONFIG" ]] || export KUBECONFIG="$HOME/.kube/config"

NS="${NS:-default}"; SYS_NS=vgpu-system; GROUP=infrastructure.pranav2910.com
NAME="${NAME:-autodemo}"
REC_BYTES="${REC_BYTES:-26534109184}"   # ~24.7 GiB recommendation
IMAGE="${IMAGE:-busybox:1.36}"
RUNTIME_CLASS="${RUNTIME_CLASS:-}"

C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
hdr() { echo; echo "${C_BLU}── $* ──${C_RST}"; }
say() { echo "  $*"; }
human() { awk -v b="${1:-0}" 'BEGIN{ if (b>=1073741824) printf "%.1f GiB", b/1073741824; else printf "%d B", b }'; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
kubectl -n "$SYS_NS" get deploy vgpu-controller >/dev/null 2>&1 \
    || { echo "control plane not deployed — run setup-kind-cluster.sh or h100-control-plane.sh first"; exit 2; }

cleanup() {
    hdr "cleanup"
    kubectl delete vgpujob "$NAME" vgpuworkloadprofile "$NAME" vgpuclaim "${NAME}-claim" \
        vgpuslice "${NAME}-claim-slice" pod "${NAME}-workload" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl set env deploy/vgpu-controller -n "$SYS_NS" VGPU_RECOMMENDATION_MODE- >/dev/null 2>&1 || true
    echo "  demo objects deleted; controller mode reset to default"
}
trap cleanup EXIT

hdr "1. the platform has already learned this workload"
say "Pretend '${NAME}' ran before: peak ~21.5 GiB observed → profile recommends $(human "$REC_BYTES")."
kubectl delete vgpujob "$NAME" vgpuworkloadprofile "$NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; sleep 2
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: ${GROUP}/v1alpha1
kind: VGPUWorkloadProfile
metadata: { name: ${NAME}, namespace: ${NS} }
EOF
kubectl patch vgpuworkloadprofile "$NAME" -n "$NS" --subresource=status --type=merge \
    -p "{\"status\":{\"recommendedVramBytes\":${REC_BYTES},\"peakObservedVramBytes\":${REC_BYTES},\"confidence\":\"High\",\"observations\":150}}" >/dev/null
say "profile seeded (confidence High)."

hdr "2. admin turns on autoResize"
kubectl set env deploy/vgpu-controller -n "$SYS_NS" VGPU_RECOMMENDATION_MODE=autoResize >/dev/null
kubectl rollout status deploy/vgpu-controller -n "$SYS_NS" --timeout=120s >/dev/null 2>&1
say "VGPU_RECOMMENDATION_MODE=autoResize"; sleep 4

hdr "3. user submits UNDER-provisioned — asks for only 16Gi"
if [[ -n "$RUNTIME_CLASS" ]]; then
    scripts/vgpu submit --name "$NAME" --vram 16Gi -n "$NS" --image "$IMAGE" \
        --command 'sleep 600' --no-wait --runtime-class "$RUNTIME_CLASS" || true
else
    scripts/vgpu submit --name "$NAME" --vram 16Gi -n "$NS" --image "$IMAGE" \
        --command 'sleep 600' --no-wait || true
fi

hdr "4. what the platform did (raised it BEFORE the claim/slice were created)"
got="$(kubectl get vgpujob "$NAME" -n "$NS" -o jsonpath='{.spec.claimTemplate.spec.requestedVramBytes}' 2>/dev/null)"
orig="$(kubectl get vgpujob "$NAME" -n "$NS" -o jsonpath="{.metadata.annotations.${GROUP//./\\.}/original-vram-bytes}" 2>/dev/null)"
echo "  ${C_YEL}requested by user:${C_RST}  $(human "${orig:-17179869184}")"
echo "  ${C_GRN}scheduled as:${C_RST}      $(human "${got:-0}")   ← auto-raised to the recommendation"
echo
say "the audit trail stamped on the object:"
ann() { kubectl get vgpujob "$NAME" -n "$NS" -o jsonpath="{.metadata.annotations.${GROUP//./\\.}/$1}" 2>/dev/null; }
echo "    original-vram-bytes:    $(ann original-vram-bytes)"
echo "    autoresized-vram-bytes: $(ann autoresized-vram-bytes)"
echo "    autoresized:            $(ann autoresized)"
echo
say "and how a user sees it:"
# (filter the re-learning advisory line — on the kind fake-GPU provider the slice
# makes the node agent re-derive a synthetic peak, which is noise off real hardware)
scripts/vgpu status "$NAME" -n "$NS" 2>/dev/null | grep -v 'underprovisioned' | sed 's/^/    /' || true

hdr "the point"
echo "  The user asked for too little. The platform — only because it had a confident"
echo "  profile — corrected the request to a safe size automatically, transparently, and"
echo "  before scheduling. Override with --override (or raise --vram) to opt out."
