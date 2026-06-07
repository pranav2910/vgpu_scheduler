#!/usr/bin/env bash
# Prove the FULL submit flow on a real GPU node (H100): ONE `vgpu submit` and the
# workload pod auto-runs on a shared GPU — no manual slice/pod wiring. This is the
# v0.8 milestone: the complete ML-engineer experience, end to end on hardware.
#
# Requires the full control plane (scripts/h100-control-plane.sh).
#
#   bash scripts/h100-control-plane.sh
#   bash scripts/validate-submit-flow-h100.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NS="${NS:-default}"
NAME="${NAME:-h100demo}"
VRAM="${VRAM:-16Gi}"
SMI_IMAGE="${SMI_IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
CLAIM="${NAME}-claim"; SLICE="${NAME}-claim-slice"; POD="${NAME}-workload"
# Declarative proof set: a raw VGPUJob-with-podTemplate applied with kubectl (no CLI).
DNAME="${NAME}decl"; DCLAIM="${DNAME}-claim"; DSLICE="${DCLAIM}-slice"; DPOD="${DNAME}-workload"
case "$VRAM" in *Gi) DBYTES=$(( ${VRAM%Gi} * 1073741824 )) ;; *) DBYTES=17179869184 ;; esac

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "── $* ──"; }

cleanup() {
    hdr "cleanup"
    kubectl delete pod "$POD" "$DPOD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    for k in vgpuslice/"$SLICE" vgpuclaim/"$CLAIM" vgpujob/"$NAME" vgpuworkloadprofile/"$NAME" \
             vgpuslice/"$DSLICE" vgpuclaim/"$DCLAIM" vgpujob/"$DNAME" vgpuworkloadprofile/"$DNAME"; do
        kubectl patch "$k" -n "$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
    kubectl delete vgpujob "$NAME" "$DNAME" vgpuclaim "$CLAIM" "$DCLAIM" vgpuslice "$SLICE" "$DSLICE" \
        vgpuworkloadprofile "$NAME" "$DNAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    echo "  demo objects deleted"
}
trap cleanup EXIT

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
kubectl -n vgpu-system get deploy vgpu-scheduler vgpu-controller >/dev/null 2>&1 \
    || { echo "control plane not deployed — run scripts/h100-control-plane.sh first"; exit 2; }

# ── the ONE command an ML engineer runs ──────────────────────────────────────
hdr "submit a workload — one command, the whole flow"
scripts/vgpu submit --name "$NAME" --vram "$VRAM" -n "$NS" \
    --image "$SMI_IMAGE" --command 'nvidia-smi -L; sleep 3600' \
    --runtime-class "$RUNTIME_CLASS" --wait 180 \
    || bad "vgpu submit did not complete (see output above)"

hdr "wait for the pod to run (image pull can take a minute)"
podphase=""
for i in $(seq 1 60); do
    podphase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$podphase" == "Running" || "$podphase" == "Succeeded" ]] && break
    [[ "$podphase" == "Failed" ]] && { kubectl logs "$POD" -n "$NS" 2>/dev/null | tail -5; break; }
    sleep 5
done

# ── the control plane materialized the whole chain (no manual wiring) ────────
hdr "control plane: VGPUJob → Claim → Slice (auto)"
jp=$(kubectl get vgpujob "$NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ -n "$jp" ]] && ok "VGPUJob $NAME present ($jp)" || bad "VGPUJob $NAME missing"
cp=$(kubectl get vgpuclaim "$CLAIM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ -n "$cp" ]] && ok "VGPUClaim $CLAIM auto-created by the controller ($cp)" || bad "claim not created (controller running?)"
node=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
sp=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
uuid=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.deviceUuid}' 2>/dev/null)
[[ -n "$node" ]] && ok "scheduler placed the slice on $node" || bad "slice has no nodeName — scheduler didn't place it (node capacity advertised?)"
[[ "$sp" == "Ready" ]] && ok "slice Ready (node agent allocated)" || bad "slice not Ready (got '${sp:-<none>}')"
[[ "$uuid" == GPU-* && "$uuid" != GPU-MOCK* ]] && ok "slice bound a REAL GPU ($uuid)" || bad "slice deviceUuid not a real GPU (got '${uuid:-<none>}')"

# ── the pod auto-ran on the shared GPU (the webhook injected it) ─────────────
hdr "pod auto-runs on the shared GPU (webhook injected it)"
[[ "$podphase" == "Running" || "$podphase" == "Succeeded" ]] && ok "pod $POD started ($podphase)" || bad "pod did not start (got '${podphase:-<none>}')"
poduuid=$(kubectl exec "$POD" -n "$NS" -- nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | tr -d '\r' | head -1)
[[ -n "$poduuid" ]] && ok "nvidia-smi works INSIDE the pod (sees $poduuid)" || bad "nvidia-smi failed inside the pod — GPU not injected"
[[ -n "$poduuid" && "$poduuid" == "$uuid" ]] \
    && ok "pod GPU UUID == slice deviceUuid — full submit flow proven end to end" \
    || bad "pod GPU '$poduuid' != slice '$uuid'"

# ── declarative proof: a RAW `kubectl apply -f` (no vgpu CLI) runs the pod ────
# This is the "VGPUJob owns the Pod" guarantee: the Job alone is the workload.
hdr "declarative: kubectl apply -f a VGPUJob with podTemplate (no CLI) runs the pod"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: ${DNAME}, namespace: ${NS} }
spec:
  priority: 50
  workloadClass: Training
  claimTemplate:
    spec:
      requestedVramBytes: ${DBYTES}
      serviceTier: Guaranteed
  podTemplate:
    spec:
      restartPolicy: Never
      runtimeClassName: ${RUNTIME_CLASS}
      containers:
      - name: workload
        image: ${SMI_IMAGE}
        command: ["bash","-c","nvidia-smi -L; sleep 3600"]
        resources: {}
EOF
echo "  applied VGPUJob/${DNAME} (with podTemplate) — no CLI, no manual pod"
dpodphase=""
for i in $(seq 1 60); do
    dpodphase=$(kubectl get pod "$DPOD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$dpodphase" == "Running" || "$dpodphase" == "Succeeded" ]] && break
    [[ "$dpodphase" == "Failed" ]] && { kubectl logs "$DPOD" -n "$NS" 2>/dev/null | tail -5; break; }
    sleep 5
done
dcp=$(kubectl get vgpuclaim "$DCLAIM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ -n "$dcp" ]] && ok "controller auto-created the Claim from the Job ($dcp)" || bad "no claim — controller didn't process the declarative Job"
downer=$(kubectl get pod "$DPOD" -n "$NS" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
[[ "$downer" == "VGPUJob" ]] && ok "Pod is OWNED by the VGPUJob (the CONTROLLER created it, not us)" || bad "pod not owned by VGPUJob (got '${downer:-<none>}')"
duuid=$(kubectl get vgpuslice "$DSLICE" -n "$NS" -o jsonpath='{.status.deviceUuid}' 2>/dev/null)
[[ "$duuid" == GPU-* && "$duuid" != GPU-MOCK* ]] && ok "declarative slice bound a REAL GPU ($duuid)" || bad "slice deviceUuid not a real GPU (got '${duuid:-<none>}')"
[[ "$dpodphase" == "Running" || "$dpodphase" == "Succeeded" ]] && ok "pod auto-ran from a raw kubectl apply ($dpodphase)" || bad "declarative pod did not start (got '${dpodphase:-<none>}')"
dpoduuid=$(kubectl exec "$DPOD" -n "$NS" -- nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | tr -d '\r' | head -1)
[[ -n "$dpoduuid" && "$dpoduuid" == "$duuid" ]] \
    && ok "nvidia-smi inside the declarative pod sees the slice's GPU — \`kubectl apply\` alone runs on a shared GPU" \
    || bad "declarative pod GPU '$dpoduuid' != slice '$duuid'"
dpc=$(kubectl get vgpujob "$DNAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="PodCreated")].status}' 2>/dev/null)
[[ "$dpc" == "True" ]] && ok "VGPUJob carries PodCreated=True (explainability wedge)" || bad "VGPUJob missing PodCreated=True (got '${dpc:-<none>}')"

hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}v0.9 — VGPUJob owns the Pod: both \`vgpu submit\` AND a raw \`kubectl apply -f vgpujob.yaml\` run a workload on a shared GPU (fully declarative).${C_RST}"; exit 0; }
echo; echo "${C_RED}validation had failures${C_RST}"; exit 1
