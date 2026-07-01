#!/usr/bin/env bash
# Phase 3.4d opt-in eviction — real-hardware validation (run on a GPU node).
#
# Proves, against REAL NVML + the Kubernetes Eviction API, that in evict mode:
#   - a pod that sustains GPU-memory over-use past the eviction deadline is
#     EVICTED (VRAM reclaimed), with a MemoryEnforcementEvicted event + metric
#   - a pod opted out via infrastructure.pranav2910.com/enforcement-exempt=true,
#     over-using the SAME way, is NOT evicted (still Running) — only blocked-metric
#
# Requires the NVML node agent already deployed (use scripts/a10-bootstrap.sh).
# This script flips the daemonset to VGPU_ENFORCEMENT_MODE=evict for the test and
# restores softwarn on exit. Default everywhere else stays softwarn.
#
#   bash scripts/a10-bootstrap.sh
#   export KUBECONFIG=$HOME/.kube/config
#   bash scripts/validate-runtime-3.4d-a10.sh
set -uo pipefail

NS="${NS:-default}"
AGENT_NS="${AGENT_NS:-vgpu-system}"
GRANT_BYTES="${GRANT_BYTES:-2147483648}"   # 2 GiB granted per slice
HOG_BYTES="${HOG_BYTES:-4294967296}"       # each workload allocates ~4 GiB (2 over)
HOG_IMAGE="${HOG_IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
EXEMPT_LABEL="infrastructure.pranav2910.com/enforcement-exempt"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "── $* ──"; }

cleanup() {
    hdr "cleanup (restore softwarn)"
    kubectl delete pod v34d-victim v34d-exempt -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete vgpuslice v34d-victim-slice v34d-exempt-slice -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete vgpuclaim v34d-victim-claim v34d-exempt-claim -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete vgpujob v34d-victim-job v34d-exempt-job -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl -n "$AGENT_NS" set env daemonset/vgpu-nodeagent VGPU_ENFORCEMENT_MODE=softwarn >/dev/null 2>&1
    echo "  demo objects deleted; daemonset restored to softwarn"
}
trap cleanup EXIT

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
NODE=$(kubectl -n "$AGENT_NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
[[ -z "$NODE" ]] && { echo "no vgpu-nodeagent pod — run scripts/a10-bootstrap.sh first"; exit 2; }

# ── flip the agent into evict mode ───────────────────────────────────────────
hdr "enable evict mode on the node agent"
kubectl -n "$AGENT_NS" set env daemonset/vgpu-nodeagent VGPU_ENFORCEMENT_MODE=evict >/dev/null
kubectl -n "$AGENT_NS" rollout status daemonset/vgpu-nodeagent --timeout=120s || { echo "agent rollout failed"; exit 2; }
AGENT=$(kubectl -n "$AGENT_NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}')
scrape() { kubectl get --raw "/api/v1/namespaces/$AGENT_NS/pods/${AGENT}:8083/proxy/metrics" 2>/dev/null; }
if ! scrape | grep -q '^vgpu_memory_enforcement_mode{[^}]*} 2'; then
    echo "agent did not report evict mode (vgpu_memory_enforcement_mode=2)"; exit 2
fi
echo "node agent: $AGENT on $NODE (enforcement=evict)"

# ── deploy a victim (evictable) + an exempt workload, both over-using ────────
deploy() {  # $1=name  $2=exempt(true/"")
    local n="$1" exempt="$2" exline=""
    [[ "$exempt" == "true" ]] && exline=$'\n    '"$EXEMPT_LABEL: \"true\""
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: v34d-$n-job, namespace: $NS }
spec:
  workloadClass: Training
  claimTemplate: { spec: { requestedVramBytes: $GRANT_BYTES, serviceTier: Guaranteed } }
---
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: v34d-$n-claim, namespace: $NS }
spec: { jobRef: v34d-$n-job, requestedVramBytes: $GRANT_BYTES }
---
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUSlice
metadata: { name: v34d-$n-slice, namespace: $NS }
spec: { claimRef: v34d-$n-claim, nodeName: $NODE, requestedVramBytes: $GRANT_BYTES }
---
apiVersion: v1
kind: Pod
metadata:
  name: v34d-$n
  namespace: $NS
  labels:
    app: v34d-$n${exline}
  annotations: { infrastructure.pranav2910.com/claim-ref: v34d-$n-claim }
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
    kubectl patch vgpuslice "v34d-$n-slice" -n "$NS" --subresource=status --type=merge \
        -p "{\"status\":{\"phase\":\"Ready\",\"allocatedBytes\":$GRANT_BYTES}}" >/dev/null 2>&1
}

hdr "deploy victim (evictable) + exempt workload — each grants $((GRANT_BYTES>>20)) MiB, uses $((HOG_BYTES>>20)) MiB"
deploy victim ""
deploy exempt true
echo "  waiting for both workloads to allocate GPU memory (image pull can take a few min)..."
for i in $(seq 1 72); do
    a=$(kubectl logs v34d-victim -n "$NS" 2>/dev/null | grep -c allocated)
    b=$(kubectl logs v34d-exempt -n "$NS" 2>/dev/null | grep -c allocated)
    [[ "${a:-0}" -ge 1 && "${b:-0}" -ge 1 ]] && { echo "  both allocated"; break; }
    sleep 5
done

# ── poll for eviction (≈90s detect + 60s warn + 120s evict grace) ────────────
hdr "poll for eviction (≈270s end-to-end)"
for i in $(seq 1 40); do
    vphase=$(kubectl get pod v34d-victim -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    vgone=$(kubectl get pod v34d-victim -n "$NS" 2>/dev/null | grep -c v34d-victim)
    echo "  t=$((i*10))s  victim_phase=${vphase:-<gone>}  victim_present=${vgone:-0}"
    [[ "${vgone:-0}" == "0" || "$vphase" == "Failed" || "$vphase" == "Succeeded" ]] && break
    sleep 10
done

# ── assertions ───────────────────────────────────────────────────────────────
hdr "3.4d — eviction of the offending pod"
vgone=$(kubectl get pod v34d-victim -n "$NS" 2>/dev/null | grep -c v34d-victim)
vphase=$(kubectl get pod v34d-victim -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "${vgone:-0}" == "0" || "$vphase" == "Failed" ]] \
    && ok "victim pod evicted (gone/Failed) — VRAM reclaimed" \
    || bad "victim pod still present and ${vphase:-?} — eviction did not fire"
kubectl get events -n "$NS" --field-selector reason=MemoryEnforcementEvicted 2>/dev/null | grep -q v34d-victim \
    && ok "Warning/MemoryEnforcementEvicted event emitted for the victim" \
    || bad "no MemoryEnforcementEvicted event for the victim"
M=$(scrape)
[[ "$(echo "$M" | grep -E '^vgpu_memory_enforcement_actions_total\{[^}]*action="evict"' | head -1 | awk '{print $2}')" =~ ^[1-9] ]] \
    && ok "vgpu_memory_enforcement_actions_total{action=\"evict\"} >= 1" \
    || bad "evict action metric not incremented"

hdr "3.4d — exempt pod is spared"
ephase=$(kubectl get pod v34d-exempt -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$ephase" == "Running" ]] \
    && ok "exempt pod still Running — eviction correctly skipped" \
    || bad "exempt pod is ${ephase:-<gone>} — it must NOT be evicted"
[[ "$(echo "$M" | grep -E '^vgpu_memory_evictions_blocked_total\{[^}]*reason="exempt"' | head -1 | awk '{print $2}')" =~ ^[1-9] ]] \
    && ok "vgpu_memory_evictions_blocked_total{reason=\"exempt\"} >= 1" \
    || bad "exempt blocked metric not incremented"

hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}Phase 3.4d opt-in eviction validated on real hardware${C_RST}"; exit 0; }
echo; echo "${C_RED}validation had failures${C_RST}"; exit 1
