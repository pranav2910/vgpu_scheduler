#!/usr/bin/env bash
# validate-monitor-report.sh — proves the monitor-mode "GPU waste report" logic
# against synthetic metrics. NO cluster, NO GPU required — it feeds `vgpu report`
# a fixture and asserts the join + waste math + price math + missing-request
# handling. (The live per-pod attribution is validated separately on a GPU node;
# its accuracy is proven by scripts/validate-attribution-*.sh.)
#
#   bash scripts/validate-monitor-report.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }

FIX="$(mktemp)"; trap 'rm -f "$FIX"' EXIT
cat > "$FIX" <<'EOF'
vgpu_monitor_gpu_total_vram_bytes{node="n1",gpu_uuid="GPU-aaa"} 8.5899345920e+10
vgpu_monitor_gpu_used_vram_bytes{node="n1",gpu_uuid="GPU-aaa"} 2.4696061952e+10
vgpu_monitor_gpu_free_vram_bytes{node="n1",gpu_uuid="GPU-aaa"} 6.1203283968e+10
vgpu_monitor_pod_requested_vram_bytes{namespace="default",pod="llama-train",node="n1",source="annotation"} 4.294967296e+10
vgpu_monitor_pod_used_vram_bytes{namespace="default",pod="llama-train",node="n1",gpu_uuid="GPU-aaa"} 1.7179869184e+10
vgpu_monitor_pod_requested_vram_bytes{namespace="default",pod="infer-x",node="n1",source="nvidia_gpu_limit"} 1.7179869184e+10
vgpu_monitor_pod_used_vram_bytes{namespace="default",pod="infer-x",node="n1",gpu_uuid="GPU-aaa"} 8.589934592e+09
vgpu_monitor_pod_requested_vram_bytes{namespace="default",pod="right-sized",node="n1",source="annotation"} 1.7179869184e+10
vgpu_monitor_pod_used_vram_bytes{namespace="default",pod="right-sized",node="n1",gpu_uuid="GPU-aaa"} 1.610612736e+10
vgpu_monitor_pod_used_vram_bytes{namespace="default",pod="mystery",node="n1",gpu_uuid="GPU-aaa"} 2.147483648e+09
EOF

echo; echo "${C_BLU}── vgpu report against synthetic monitor metrics ──${C_RST}"
OUT="$(scripts/vgpu report --metrics-file "$FIX" --price-per-gpu-hour 3.00 2>&1)"
echo "$OUT"
echo
echo "${C_BLU}── assertions ──${C_RST}"
has() { printf '%s' "$OUT" | grep -qiE "$1"; }

has 'Cluster GPU Waste Report'                         && ok "report renders" || bad "report did not render"
# join: llama-train requested 40, used 16, waste 24, util 40%
has 'llama-train +40\.0 GiB +16\.0 GiB +24\.0 GiB +40%' && ok "join + per-pod row correct (llama-train 40/16/24, 40%)" || bad "per-pod join wrong"
# source labels surfaced
has 'infer-x.*nvidia_gpu_limit'                        && ok "source label surfaced (nvidia_gpu_limit)" || bad "source label missing"
# waste math
has 'Estimated waste: +33\.0 GiB'                      && ok "waste math correct (33.0 GiB)" || bad "waste total wrong"
# utilization (used 41 / requested 72 = 56.9%)
has 'Utilization: +56\.9%'                             && ok "utilization correct (56.9%)" || bad "utilization wrong"
# price math: 33 GiB / 80 GiB card * \$3 * 730h = ~\$903
has 'Estimated waste/month: +\$903'                    && ok "price math correct (~\$903/mo @ \$3/GPU-hr)" || bad "price math wrong"
# missing-request handled cleanly (pod with usage but no requested)
has 'mystery.* +0%  unknown'                           && ok "missing request handled cleanly (mystery → unknown, no crash)" || bad "missing-request case mishandled"
# safety wording present
has 'Read-only'                                        && ok "read-only safety wording present" || bad "safety wording missing"
has 'estimated, not guaranteed'                        && ok "says ESTIMATED, not guaranteed savings" || bad "overclaims savings"

echo; echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}Monitor-mode report logic proven: join, waste, price, and missing-request handling all correct.${C_RST}"; exit 0; }
echo; echo "${C_RED}report validation had failures${C_RST}"; exit 1
