#!/usr/bin/env bash
# Phase 3.4a/3.4b real-hardware validation (run on a GPU node, e.g. Lambda A10).
#
# Proves, against REAL NVML + /proc cgroups, that:
#   3.4a  the node flags GPU over-use beyond what was granted
#   3.4b  the over-using workload is attributed to its VGPUSlice and marked
#         (MemoryViolation condition + metric + Event)
#
# It does NOT need the scheduler/controller/webhook — the node-agent detectors
# read slices, pods, and NVML directly. So the minimal stack is just:
#
#   # 1. a single-node k8s with the NVIDIA toolkit (k3s shown):
#   curl -sfL https://get.k3s.io | sh -            # + nvidia-container-toolkit
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   # 2. CRDs + namespace + node-agent RBAC/SA:
#   kubectl apply -f deployments/manifests/crds/
#   kubectl apply -f deployments/manifests/namespace.yaml
#   kubectl apply -f deployments/manifests/rbac/nodeagent_rbac.yaml
#   kubectl apply -f deployments/manifests/sa/            # node-agent ServiceAccount
#   # 3. the NVML node agent (hostPID, real provider):
#   make docker-build-nodeagent-nvml
#   sudo k3s ctr images import <(docker save vgpu-nodeagent:nvml)   # load into k3s
#   kubectl apply -f deployments/manifests/nodeagent_daemonset_nvml.yaml
#   # 4. then run this:
#   bash scripts/validate-runtime-3.4-a10.sh
#
# Requirements on the host: kubectl, a running vgpu-nodeagent pod (provider=nvml).
set -uo pipefail

NS="${NS:-default}"
AGENT_NS="${AGENT_NS:-vgpu-system}"
GRANT_BYTES="${GRANT_BYTES:-2147483648}"   # 2 GiB granted to the slice
HOG_BYTES="${HOG_BYTES:-4294967296}"       # workload allocates ~4 GiB (2 GiB over)
HOG_IMAGE="${HOG_IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
SLICE=v34-demo-slice; CLAIM=v34-demo-claim; JOB=v34-demo-job; POD=v34-demo-hog

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "── $* ──"; }

cleanup() {
    hdr "cleanup"
    kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete vgpuslice "$SLICE" vgpuclaim "$CLAIM" vgpujob "$JOB" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    echo "  demo objects deleted"
}
trap cleanup EXIT

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
AGENT=$(kubectl -n "$AGENT_NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$AGENT" ]] && { echo "no vgpu-nodeagent pod in $AGENT_NS — deploy the NVML node agent first"; exit 2; }
NODE=$(kubectl -n "$AGENT_NS" get pod "$AGENT" -o jsonpath='{.spec.nodeName}')
scrape() { kubectl get --raw "/api/v1/namespaces/$AGENT_NS/pods/${AGENT}:8083/proxy/metrics" 2>/dev/null; }
if ! scrape | grep -q 'vgpu_gpu_provider_info{[^}]*provider="nvml"[^}]*} 1'; then
    echo "node agent is not running the NVML provider (fake/degraded). Build with -tags nvml."; exit 2
fi
echo "node agent: $AGENT on node $NODE (provider=nvml)"

# ── create the slice/claim/job (grant 2 GiB) + an over-allocating pod ────────
hdr "deploy demo: slice granted $((GRANT_BYTES>>20)) MiB, workload uses $((HOG_BYTES>>20)) MiB"
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
  containers:
  - name: hog
    image: $HOG_IMAGE
    command: ["python","-c"]
    args: ["import torch,time; n=$HOG_BYTES//2; x=torch.empty(n, dtype=torch.float16, device='cuda'); print('allocated', x.numel()*2, 'bytes'); time.sleep(3600)"]
    resources: { limits: { nvidia.com/gpu: "1" } }
EOF
# Mark the slice Ready so the detector counts its grant.
kubectl patch vgpuslice "$SLICE" -n "$NS" --subresource=status --type=merge \
    -p "{\"status\":{\"phase\":\"Ready\",\"allocatedBytes\":$GRANT_BYTES}}" >/dev/null 2>&1

echo "  waiting for the workload to allocate GPU memory (image pull can take a few min)..."
for i in $(seq 1 60); do
    phase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    if kubectl logs "$POD" -n "$NS" 2>/dev/null | grep -q allocated; then echo "  workload allocated GPU memory"; break; fi
    [[ "$phase" == "Failed" || "$phase" == "Succeeded" ]] && { echo "  pod $phase early:"; kubectl logs "$POD" -n "$NS" 2>/dev/null | tail -5; break; }
    sleep 5
done

# ── poll detection (node 3.4a + slice 3.4b) ──────────────────────────────────
hdr "poll for detection (hysteresis ≈ 90s)"
for i in $(seq 1 18); do
    M=$(scrape)
    nodeov=$(echo "$M" | grep '^vgpu_node_memory_overuse_bytes' | head -1 | awk '{print $2}')
    nodevi=$(echo "$M" | grep '^vgpu_node_memory_violation_active' | head -1 | awk '{print $2}')
    slicevi=$(echo "$M" | grep "vgpu_memory_violation_active{[^}]*slice=\"$SLICE\"" | head -1 | awk '{print $2}')
    echo "  t=$((i*10))s  node_overuse=${nodeov:-0}  node_violation=${nodevi:-0}  slice_violation=${slicevi:-0}"
    [[ "${nodevi:-0}" == "1" && "${slicevi:-0}" == "1" ]] && break
    sleep 10
done

# ── assertions ───────────────────────────────────────────────────────────────
hdr "3.4a — node-level over-use"
M=$(scrape)
[[ "$(echo "$M" | grep '^vgpu_node_memory_violation_active' | head -1 | awk '{print $2}')" == "1" ]] \
    && ok "node flags over-use (vgpu_node_memory_violation_active=1)" \
    || bad "node did not flag over-use"

hdr "3.4b — per-slice attribution + mark"
[[ "$(echo "$M" | grep "vgpu_memory_violation_active{[^}]*slice=\"$SLICE\"" | head -1 | awk '{print $2}')" == "1" ]] \
    && ok "slice $SLICE attributed + flagged (vgpu_memory_violation_active=1)" \
    || bad "slice $SLICE not flagged — attribution (cgroup→pod→claim→slice) may have missed"
cond=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="MemoryViolation")].status}' 2>/dev/null)
[[ "$cond" == "True" ]] && ok "VGPUSlice MemoryViolation condition = True (kubectl-visible)" || bad "slice condition not True (got '${cond:-<none>}')"
jcond=$(kubectl get vgpujob "$JOB" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="MemoryViolation")].status}' 2>/dev/null)
[[ "$jcond" == "True" ]] && ok "parent VGPUJob mirrors MemoryViolation = True" || bad "job did not mirror (got '${jcond:-<none>}')"
kubectl get events -n "$NS" --field-selector reason=MemoryViolation 2>/dev/null | grep -q "$SLICE" \
    && ok "Warning/MemoryViolation Event emitted on the slice" \
    || bad "no MemoryViolation Event for the slice"

hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}Phase 3.4a/3.4b validated on real hardware${C_RST}"; exit 0; }
echo; echo "${C_RED}validation had failures${C_RST}"; exit 1
