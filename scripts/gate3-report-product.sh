#!/usr/bin/env bash
# ============================================================================
# gate3-report-product.sh — Gate 3 real-GPU receipt: the waste report as a
# product, proven against real NVML with MIXED workloads.
#
#   HOST=ubuntu@1.2.3.4 bash scripts/gate3-report-product.sh
#
# DoD (roadmap): works on vanilla pods AND VGPUJob pods · detects
# pod/namespace/node/GPU UUID · CSV/JSON match table · report values match
# NVML · uninstall leaves workloads untouched.
# ============================================================================
set -uo pipefail

HOST="${HOST:?set HOST=user@ip}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $HOST"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
EVID="artifacts/gate3-report-${SHA}"; mkdir -p "$EVID"
KC='export KUBECONFIG=$HOME/.kube/config; cd vgpu_scheduler'
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $*"; FAIL=$((FAIL+1)); }
say(){ echo; echo "── $* ──"; }

say "0. sync repo + full control plane (scheduler+controller+webhooks for the VGPUJob path)"
$SSH "$KC; git fetch -q origin && git reset -q --hard origin/main && git log --oneline -1" | tee "$EVID/00-repo.txt"
$SSH "$KC; bash scripts/h100-control-plane.sh" > "$EVID/00-bringup.log" 2>&1 \
    && ok "control plane up" || { bad "bring-up failed (see $EVID/00-bringup.log)"; echo "VERDICT: FAIL"; exit 1; }

say "1. install monitor beside the full stack"
$SSH "$KC; scripts/vgpu uninstall monitor >/dev/null 2>&1; scripts/vgpu install monitor" | tee "$EVID/01-install.txt"
grep -q "monitor is READY" "$EVID/01-install.txt" && ok "monitor READY" || bad "monitor install failed"

say "2. MIXED workloads: a vanilla annotated pod (~6 GiB real use) + a VGPUJob (16Gi request)"
$SSH "$KC
  kubectl delete pod vanilla-burn --ignore-not-found >/dev/null 2>&1
  kubectl delete vgpujob viaclaim --ignore-not-found >/dev/null 2>&1; sleep 3
  cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: vanilla-burn, namespace: default, annotations: { gpu-memory: \"24000\" } }
spec:
  runtimeClassName: nvidia
  restartPolicy: Never
  containers:
  - name: w
    image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime
    command: [\"python\",\"-c\",\"import torch,time; x=torch.empty(int(6*1024**3)//2, dtype=torch.float16, device='cuda').normal_(); torch.cuda.synchronize(); print('holding ~6GiB', flush=True); time.sleep(900)\"]
    env: [ { name: NVIDIA_VISIBLE_DEVICES, value: all } ]
EOF
  scripts/vgpu submit --name viaclaim --vram 16Gi --image nvidia/cuda:12.4.1-base-ubuntu22.04 \
      --command 'sleep 900' --runtime-class nvidia --wait 180 | tail -3
  for i in \$(seq 1 60); do
    ph=\$(kubectl get pod vanilla-burn -o jsonpath='{.status.phase}' 2>/dev/null)
    [ \"\$ph\" = Running ] && break; sleep 4
  done
  echo vanilla-burn=\$(kubectl get pod vanilla-burn -o jsonpath='{.status.phase}')
  echo viaclaim=\$(kubectl get pod viaclaim-workload -o jsonpath='{.status.phase}')
  sleep 70   # two observe intervals so NVML samples both" | tee "$EVID/02-workloads.txt"
grep -q "vanilla-burn=Running" "$EVID/02-workloads.txt" && ok "vanilla pod Running" || bad "vanilla pod not Running"
grep -q "viaclaim=Running"     "$EVID/02-workloads.txt" && ok "VGPUJob pod Running"  || bad "VGPUJob pod not Running"

say "3. table: both pods attributed, with the right SOURCE for each path"
$SSH "$KC; scripts/vgpu report --price-per-gpu-hour 3.00" | tee "$EVID/03-table.txt"
grep -qE "default/vanilla-burn .* annotation" "$EVID/03-table.txt" && ok "vanilla pod attributed (source=annotation)" || bad "vanilla pod missing/wrong source"
grep -qE "default/viaclaim-workload .* vgpu_claim" "$EVID/03-table.txt" && ok "VGPUJob pod attributed (source=vgpu_claim)" || bad "VGPUJob pod missing/wrong source"
grep -q  "Top wasting pods" "$EVID/03-table.txt" && ok "top-wasters rendered" || bad "top-wasters missing"

say "4. NVML cross-check: report's used-bytes vs nvidia-smi ground truth (±1 GiB)"
$SSH "$KC
  RPT=\$(scripts/vgpu report -o csv | awk -F, '\$1!=\"_total_\" && \$1!=\"namespace\" {s+=\$7} END{printf \"%.0f\", s}')
  SMI=\$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits | awk '{s+=\$1} END{printf \"%.0f\", s*1048576}')
  echo report_used_bytes=\$RPT
  echo nvidiasmi_used_bytes=\$SMI
  DIFF=\$((RPT>SMI ? RPT-SMI : SMI-RPT))
  echo diff_bytes=\$DIFF
  [ \"\$DIFF\" -le 1073741824 ] && echo NVML_MATCH=yes || echo NVML_MATCH=no" | tee "$EVID/04-nvml.txt"
grep -q "NVML_MATCH=yes" "$EVID/04-nvml.txt" && ok "report used-bytes match nvidia-smi (±1 GiB)" || bad "report diverges from NVML ground truth"

say "5. CSV + JSON totals equal the table's (live, not just synthetic)"
$SSH "$KC
  T=\$(scripts/vgpu report | awk '/GPU memory requested/{print \$4}')
  C=\$(scripts/vgpu report -o csv | awk -F, '\$1==\"_total_\"{printf \"%.1f\", \$6/1073741824}')
  J=\$(scripts/vgpu report -o json | python3 -c 'import sys,json; print(round(json.load(sys.stdin)[\"totals\"][\"requested_bytes\"]/1073741824,1))')
  echo table=\$T csv=\$C json=\$J
  [ \"\$T\" = \"\$C\" ] && [ \"\$T\" = \"\$J\" ] && echo FORMATS_AGREE=yes || echo FORMATS_AGREE=no" | tee "$EVID/05-formats.txt"
grep -q "FORMATS_AGREE=yes" "$EVID/05-formats.txt" && ok "table = CSV = JSON (requested total)" || bad "formats disagree"

say "6. --filter-ns live + node/UUID columns populated"
$SSH "$KC
  scripts/vgpu report -o csv --filter-ns default | tee /tmp/f.csv | head -4
  # assert node+UUID on the row that HAS GPU usage (rows are waste-sorted, so
  # position varies; an idle pod legitimately has no UUID yet)
  awk -F, '\$2==\"vanilla-burn\" { print (\$3!=\"\" && \$4~/^GPU-/) ? \"NODE_UUID_OK=yes\" : \"NODE_UUID_OK=no\" }' /tmp/f.csv" | tee "$EVID/06-filter.txt"
grep -q "NODE_UUID_OK=yes" "$EVID/06-filter.txt" && ok "rows carry real node + GPU-UUID" || bad "node/UUID missing in live rows"

say "7. teardown workloads; uninstall monitor; workloads untouched"
$SSH "$KC
  scripts/vgpu uninstall monitor >/dev/null 2>&1 && echo UNINSTALL_OK=yes
  kubectl get pod vanilla-burn -o jsonpath='{.status.phase}'; echo ' <- vanilla survives uninstall'
  kubectl delete pod vanilla-burn --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete vgpujob viaclaim --ignore-not-found --wait=false >/dev/null 2>&1
  echo CLEANED=yes" | tee "$EVID/07-teardown.txt"
grep -q "UNINSTALL_OK=yes" "$EVID/07-teardown.txt" && ok "monitor uninstalled" || bad "uninstall failed"
grep -q "Running <- vanilla survives" "$EVID/07-teardown.txt" && ok "uninstall left workloads untouched" || bad "workload disturbed by uninstall"

echo
echo "════════════════════════════════════════════"
echo " GATE 3 REPORT-PRODUCT:  PASS=$PASS  FAIL=$FAIL"
echo " EVIDENCE_PATH=$EVID   COMMIT=$SHA"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 10 ]; then
  echo " FINAL_VERDICT=PASS"; exit 0
else
  echo " FINAL_VERDICT=FAIL — do NOT tag"; exit 1
fi
