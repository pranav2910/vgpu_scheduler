#!/usr/bin/env bash
# Phase 3.5 + 3.6 — real-hardware validation of the runtime feedback loop:
#
#   observe (real NVML) → per-slice runtime stats → workload profile +
#   recommendation → non-blocking under-provisioning advisory
#
# Deploys the controller in MINIMAL mode (VGPU_DISABLE_WEBHOOKS=true → no
# cert-manager) and temporarily speeds up the node agent's observation interval
# so confidence reaches Medium in a couple of minutes. Requires the NVML node
# agent (run scripts/a10-bootstrap.sh first).
#
#   bash scripts/a10-bootstrap.sh
#   export KUBECONFIG=$HOME/.kube/config
#   bash scripts/validate-runtime-3.5-a10.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS="${NS:-default}"
AGENT_NS="${AGENT_NS:-vgpu-system}"
GRANT_BYTES="${GRANT_BYTES:-2147483648}"   # 2 GiB requested (deliberately too low)
HOG_BYTES="${HOG_BYTES:-4294967296}"       # workload uses ~4 GiB
HOG_IMAGE="${HOG_IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
JOB=p35; CLAIM=p35-claim; SLICE=p35-claim-slice; POD=p35-hog

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "── $* ──"; }

DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

cleanup() {
    hdr "cleanup"
    kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    # Force-remove finalizers the controller added, so demo objects don't hang.
    for k in vgpuslice/"$SLICE" vgpuclaim/"$CLAIM" vgpujob/"$JOB" vgpuworkloadprofile/"$JOB"; do
        kubectl patch "$k" -n "$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
    kubectl delete vgpuslice "$SLICE" vgpuclaim "$CLAIM" vgpujob "$JOB" vgpuworkloadprofile "$JOB" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl -n "$AGENT_NS" set env daemonset/vgpu-nodeagent VGPU_OBSERVE_INTERVAL- >/dev/null 2>&1
    kubectl delete -f deployments/manifests/controller_deployment_nowebhook.yaml --ignore-not-found --wait=false >/dev/null 2>&1
    echo "  demo objects + minimal controller removed; node agent interval restored"
}
trap cleanup EXIT

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
NODE=$(kubectl -n "$AGENT_NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
[[ -z "$NODE" ]] && { echo "no vgpu-nodeagent pod — run scripts/a10-bootstrap.sh first"; exit 2; }

# ── speed up observation so confidence reaches Medium in ~2 min ───────────────
hdr "speed up node-agent observation (2s interval)"
kubectl -n "$AGENT_NS" set env daemonset/vgpu-nodeagent VGPU_OBSERVE_INTERVAL=2s >/dev/null
kubectl -n "$AGENT_NS" rollout status daemonset/vgpu-nodeagent --timeout=120s || { echo "agent rollout failed"; exit 2; }

# ── deploy the demo FIRST, before the controller ─────────────────────────────
# Critical ordering: there is no scheduler here, so the slice's nodeName must be
# set by hand. If the controller were already running it would materialize its
# OWN claim+slice (with no nodeName, which the node agent ignores) the instant the
# job appears. So we create everything first — slice with nodeName + Ready — then
# start the controller, which ADOPTS these by name instead of recreating them.
hdr "deploy demo: request $((GRANT_BYTES>>20)) MiB, workload uses $((HOG_BYTES>>20)) MiB"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: $JOB, namespace: $NS }
spec:
  workloadClass: Training
  claimTemplate: { spec: { requestedVramBytes: $GRANT_BYTES, serviceTier: Guaranteed } }
---
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: $CLAIM, namespace: $NS }
spec: { jobRef: $JOB, requestedVramBytes: $GRANT_BYTES }
---
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUSlice
metadata: { name: $SLICE, namespace: $NS }
spec: { claimRef: $CLAIM, nodeName: $NODE, requestedVramBytes: $GRANT_BYTES }
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  annotations: { infrastructure.pranav2910.com/claim-ref: $CLAIM }
spec:
  nodeName: $NODE
  restartPolicy: Never
  runtimeClassName: ${RUNTIME_CLASS}
  containers:
  - name: hog
    image: $HOG_IMAGE
    command: ["python","-c"]
    args: ["import torch,time; n=$HOG_BYTES//2; x=torch.empty(n, dtype=torch.float16, device='cuda'); print('allocated'); time.sleep(3600)"]
    env:
    - { name: NVIDIA_VISIBLE_DEVICES, value: "all" }
    - { name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility" }
EOF
# Mark the slice Ready (nodeName already in spec) so the node agent observes it.
kubectl patch vgpuslice "$SLICE" -n "$NS" --subresource=status --type=merge \
    -p "{\"status\":{\"phase\":\"Ready\",\"allocatedBytes\":$GRANT_BYTES}}" >/dev/null 2>&1
echo "  demo created (slice $SLICE bound to $NODE, Ready)"

# ── now deploy the controller in minimal (no-webhook) mode; it adopts the above ─
hdr "deploy controller (minimal, no cert-manager)"
$DOCKER build --provenance=false -t vgpu-controller:latest -f Dockerfile.controller . >/dev/null \
    || { echo "controller build failed"; exit 2; }
$DOCKER save vgpu-controller:latest | sudo k3s ctr images import - >/dev/null \
    || { echo "controller image import failed"; exit 2; }
kubectl apply -f deployments/manifests/controller_deployment_nowebhook.yaml >/dev/null
kubectl -n "$AGENT_NS" rollout status deployment/vgpu-controller --timeout=150s \
    || { echo "controller rollout failed"; kubectl -n "$AGENT_NS" logs deploy/vgpu-controller --tail=30; exit 2; }
echo "  controller running (reconcilers only)"

echo "  waiting for the workload to allocate GPU memory (image pull can take a few min)..."
for i in $(seq 1 72); do
    kubectl logs "$POD" -n "$NS" 2>/dev/null | grep -q allocated && { echo "  allocated"; break; }
    sleep 5
done

# ── poll the feedback loop (≈2-3 min to Medium confidence) ────────────────────
hdr "poll: slice stats → profile → advisory"
for i in $(seq 1 40); do
    peak=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
    prec=$(kubectl get vgpuworkloadprofile "$JOB" -n "$NS" -o jsonpath='{.status.recommendedVramBytes}' 2>/dev/null)
    pconf=$(kubectl get vgpuworkloadprofile "$JOB" -n "$NS" -o jsonpath='{.status.confidence}' 2>/dev/null)
    adv=$(kubectl get vgpujob "$JOB" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Underprovisioned")].status}' 2>/dev/null)
    echo "  t=$((i*10))s  slice_peak=${peak:-0}  prof_recommended=${prec:-0}  confidence=${pconf:-<none>}  advisory=${adv:-<none>}"
    [[ "$adv" == "True" ]] && break
    sleep 10
done

# ── assertions ───────────────────────────────────────────────────────────────
hdr "3.5a — node agent records real-NVML runtime stats on the slice"
peak=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
[[ "${peak:-0}" -gt "$GRANT_BYTES" ]] \
    && ok "slice peakObservedVramBytes=$peak > granted $GRANT_BYTES (real NVML)" \
    || bad "slice runtime stats missing/too low (peak=${peak:-0})"

hdr "3.5b — controller aggregates a workload profile + recommendation"
prec=$(kubectl get vgpuworkloadprofile "$JOB" -n "$NS" -o jsonpath='{.status.recommendedVramBytes}' 2>/dev/null)
ppeak=$(kubectl get vgpuworkloadprofile "$JOB" -n "$NS" -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
pconf=$(kubectl get vgpuworkloadprofile "$JOB" -n "$NS" -o jsonpath='{.status.confidence}' 2>/dev/null)
[[ "${ppeak:-0}" -gt "$GRANT_BYTES" ]] && ok "profile peakObservedVramBytes=$ppeak" || bad "profile peak missing (got ${ppeak:-0})"
[[ "${prec:-0}" -gt "$GRANT_BYTES" ]] && ok "profile recommendedVramBytes=$prec > requested $GRANT_BYTES" || bad "profile recommendation missing/low (got ${prec:-0})"
[[ "$pconf" == "Medium" || "$pconf" == "High" ]] && ok "profile confidence=$pconf" || bad "profile confidence not Medium/High (got '${pconf:-<none>}')"

hdr "3.6 — non-blocking under-provisioning advisory on the job"
adv=$(kubectl get vgpujob "$JOB" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Underprovisioned")].status}' 2>/dev/null)
[[ "$adv" == "True" ]] && ok "VGPUJob Underprovisioned condition = True" || bad "advisory did not fire (got '${adv:-<none>}')"
kubectl get vgpujob "$JOB" -n "$NS" -o json 2>/dev/null | grep -Eq '"infrastructure\.pranav2910\.com/recommended-vram-bytes":' \
    && ok "job annotated with recommended-vram-bytes" || bad "recommended-vram-bytes annotation missing"
kubectl get events -n "$NS" --field-selector reason=UnderprovisionedRequest 2>/dev/null | grep -q "$JOB" \
    && ok "Warning/UnderprovisionedRequest event emitted" || bad "no UnderprovisionedRequest event"
pphase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$pphase" == "Running" ]] && ok "workload still Running — advisory is non-blocking" || bad "pod is ${pphase:-<gone>} — advisory must not block"

hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}Phase 3.5 + 3.6 feedback loop validated on real hardware${C_RST}"; exit 0; }
echo; echo "${C_RED}validation had failures${C_RST}"; exit 1
