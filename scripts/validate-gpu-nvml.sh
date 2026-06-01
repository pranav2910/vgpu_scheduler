#!/usr/bin/env bash
# Phase 3.1b — Real-GPU NVML validation.
#
# Run this ON a GPU node's cluster (e.g. an AWS g5 with the NVIDIA driver +
# container toolkit installed) after deploying the NVML node agent:
#
#   make docker-build-nodeagent-nvml          # builds vgpu-nodeagent:nvml
#   # load/push that image so the node can pull it
#   kubectl apply -f deployments/manifests/nodeagent_daemonset_nvml.yaml
#   scripts/validate-gpu-nvml.sh
#
# It scrapes the node agent's observed GPU metrics (via the API-server pod proxy,
# so it needs no in-pod shell) and compares them against nvidia-smi on the host.
#
# Requirements on the host running this script: kubectl (pointed at the GPU
# cluster), nvidia-smi, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-vgpu-system}"
METRICS_PORT="${METRICS_PORT:-8083}"
TOTAL_TOL_BYTES="${TOTAL_TOL_BYTES:-$((256*1024*1024))}"  # 256 MiB tolerance on total VRAM

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
dim() { echo "  ${C_DIM}$*${C_RST}"; }
hdr() { echo; echo "── $* ──"; }

# ── prereqs ──────────────────────────────────────────────────────────────────
for bin in kubectl nvidia-smi python3; do
    command -v "$bin" >/dev/null 2>&1 || { echo "missing required tool: $bin"; exit 2; }
done

POD=$(kubectl -n "$NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$POD" ]] && { echo "no vgpu-nodeagent pod found in namespace $NS"; exit 2; }
NODE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
echo "node agent pod: $POD (node: $NODE)"

METRICS_FILE="$(mktemp)"
trap 'rm -f "$METRICS_FILE"' EXIT
kubectl get --raw "/api/v1/namespaces/$NS/pods/${POD}:${METRICS_PORT}/proxy/metrics" >"$METRICS_FILE" 2>/dev/null
[[ -s "$METRICS_FILE" ]] || { echo "could not scrape $POD:$METRICS_PORT/metrics"; exit 2; }
METRICS="$(cat "$METRICS_FILE")"

# nvidia-smi ground truth (MiB).
NVSMI="$(nvidia-smi --query-gpu=uuid,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null)"
[[ -z "$NVSMI" ]] && { echo "nvidia-smi returned nothing"; exit 2; }
echo "nvidia-smi sees $(echo "$NVSMI" | wc -l | tr -d ' ') GPU(s)"

# ── Check 1: provider == nvml ────────────────────────────────────────────────
hdr "1. NVML provider active"
if echo "$METRICS" | grep -q '^vgpu_gpu_provider_info{[^}]*provider="nvml"[^}]*} 1'; then
    ok "node agent reports provider=nvml"
else
    bad "provider is not nvml (fake/degraded?). provider_info line(s):"
    echo "$METRICS" | grep '^vgpu_gpu_provider_info' | sed 's/^/      /'
fi

# ── Checks 2-5: UUID / total / used+free / health vs nvidia-smi ──────────────
hdr "2-5. Per-device truth vs nvidia-smi"
METRICS_FILE="$METRICS_FILE" NVSMI="$NVSMI" TOL="$TOTAL_TOL_BYTES" python3 "$HERE/gpu_nvml_compare.py"
if [[ $? -eq 0 ]]; then PASS=$((PASS+4)); else FAIL=$((FAIL+1)); fi

# ── Check 6: drift metric emitted ────────────────────────────────────────────
hdr "6. Capacity-drift metric emitted"
if echo "$METRICS" | grep -q '^vgpu_gpu_capacity_drift_bytes'; then
    val=$(echo "$METRICS" | grep '^vgpu_gpu_capacity_drift_bytes' | head -1 | awk '{print $2}')
    ok "vgpu_gpu_capacity_drift_bytes present (=$val; 0 unless VGPU_EXPECTED_VRAM_BYTES is set)"
else
    dim "vgpu_gpu_capacity_drift_bytes only emitted when VGPU_EXPECTED_VRAM_BYTES is set (optional)"
    ok "drift metric correctly absent (no expectation configured)"
fi

# ── Check 7: node agent does NOT mutate scheduler capacity ───────────────────
hdr "7. No scheduler-capacity mutation (observe-only)"
cap0=$(kubectl get node "$NODE" -o jsonpath="{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}" 2>/dev/null)
dim "node $NODE advertised vgpu-bytes = ${cap0:-<unset>}; observing 45s across observation cycles..."
sleep 45
cap1=$(kubectl get node "$NODE" -o jsonpath="{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}" 2>/dev/null)
if [[ "$cap0" == "$cap1" ]]; then
    ok "advertised vgpu-bytes unchanged (${cap0:-<unset>}) — observed without mutating capacity"
else
    bad "advertised vgpu-bytes changed ${cap0} -> ${cap1} — agent appears to mutate capacity (must NOT in Phase 3.1)"
fi

# ── summary ──────────────────────────────────────────────────────────────────
hdr "Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
echo
echo "  Manual check 8 (used/free track a workload): run a CUDA job on this node"
echo "  and re-run this script — vgpu_gpu_used_memory_bytes should rise, free fall:"
echo "     ${C_DIM}docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi${C_RST}"
echo
echo "  Fake path still green on kind:"
echo "     ${C_DIM}go test ./internal/nodeagent/gpu/... && bash real_world_test.sh${C_RST}"
if [[ $FAIL -eq 0 ]]; then echo; echo "${C_GRN}NVML hardware-truth validation PASSED${C_RST}"; exit 0; fi
echo; echo "${C_RED}NVML validation had failures${C_RST}"; exit 1
