#!/usr/bin/env bash
# validate-attribution-h100.sh — THE make-or-break test for the right-sizing thesis.
#
# Your whole product rests on one fact: the VRAM you measure per workload is
# accurate and SAFE enough to auto-shrink a request without ever OOM-killing the
# job. This proves (or breaks) it against a REAL PyTorch workload on a real GPU.
#
# It checks three things:
#   A. ACCURACY  — your peak ≈ what nvidia-smi says the process actually holds.
#   B. SAFETY    — your peak is NOT below what PyTorch reserved (if it were,
#                  autoResize would undersize → OOM). recommended = peak×1.15 must
#                  cover the true footprint.
#   C. ATTRIBUTION UNDER SHARING — two jobs on ONE GPU each get their OWN number,
#                  not swapped or merged. (The hard part a skeptic doubts.)
#
# Requires the full control plane (scripts/h100-control-plane.sh) on a real GPU node.
#
#   bash scripts/h100-control-plane.sh
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   bash scripts/validate-attribution-h100.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NS="${NS:-default}"
SYS_NS=vgpu-system
IMAGE="${IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;33m'; C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
note(){ echo "  • $*"; }
hdr() { echo; echo "${C_BLU}── $* ──${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi not found — run on the GPU node"; exit 2; }
kubectl -n "$SYS_NS" get deploy vgpu-controller >/dev/null 2>&1 \
    || { echo "control plane not deployed — run scripts/h100-control-plane.sh first"; exit 2; }

JOBS="attrib1 attribA attribB"
cleanup() {
    hdr "cleanup"
    for j in $JOBS; do kubectl delete vgpujob "$j" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; done
    echo "  test jobs deleted"
}
trap cleanup EXIT

# Make the node agent observe quickly so the test is fast (default is 30s).
hdr "speed up observation (VGPU_OBSERVE_INTERVAL=3s)"
kubectl set env daemonset/vgpu-nodeagent -n "$SYS_NS" VGPU_OBSERVE_INTERVAL=3s >/dev/null 2>&1
kubectl rollout status daemonset/vgpu-nodeagent -n "$SYS_NS" --timeout=120s >/dev/null 2>&1 && note "node agent observing every 3s"

# A PyTorch one-liner that allocates ~TARGET GiB of fp16, forces real allocation,
# then prints its OWN ground truth and holds. (allocated vs reserved: reserved is
# what PyTorch grabbed from the driver = the real footprint your tool must cover.)
workload_cmd() { # target_gib
    local g="$1"
    printf 'python -c "import torch,time; n=int(%s*1024**3//2); x=torch.empty(n,dtype=torch.float16,device=%s); x.normal_(); torch.cuda.synchronize(); print(%sGT_ALLOC_MIB=%%d%s%%(torch.cuda.max_memory_allocated()//1048576),flush=True); print(%sGT_RESERVED_MIB=%%d%s%%(torch.cuda.max_memory_reserved()//1048576),flush=True); time.sleep(3600)"' \
        "$g" "'cuda'" "'" "'" "'" "'"
}

submit_job() { # name target_gib request_gi
    scripts/vgpu submit --name "$1" --vram "$3" -n "$NS" --image "$IMAGE" \
        --command "$(workload_cmd "$2")" --runtime-class "$RUNTIME_CLASS" --wait 240 >/dev/null 2>&1
}

wait_running() { # name -> sets PODPHASE
    local p="$1-workload"
    for _ in $(seq 1 60); do
        PODPHASE=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$PODPHASE" == "Running" || "$PODPHASE" == "Succeeded" ]] && return
        [[ "$PODPHASE" == "Failed" ]] && return
        sleep 5
    done
}

gt_reserved_mib() { kubectl logs "$1-workload" -n "$NS" 2>/dev/null | grep -oE 'GT_RESERVED_MIB=[0-9]+' | tail -1 | cut -d= -f2; }
gt_alloc_mib()    { kubectl logs "$1-workload" -n "$NS" 2>/dev/null | grep -oE 'GT_ALLOC_MIB=[0-9]+'    | tail -1 | cut -d= -f2; }

# our tool's measured peak (VGPUWorkloadProfile), in MiB
our_peak_mib() {
    local b; b=$(kubectl get vgpuworkloadprofile "$1" -n "$NS" -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
    [[ -n "$b" && "$b" -gt 0 ]] 2>/dev/null && echo $(( b / 1048576 )) || echo ""
}

# wait until our profile has a non-zero peak (node agent observed the job)
wait_for_profile_peak() { # name -> echoes peak MiB (or empty)
    local m=""
    for _ in $(seq 1 30); do
        m=$(our_peak_mib "$1"); [[ -n "$m" && "$m" -gt 0 ]] && { echo "$m"; return; }
        sleep 3
    done
    echo ""
}

# host-side nvidia-smi: the largest per-process used_memory currently on the card
# (the node agent reads this same NVML number — so it's the external "truth").
smi_max_proc_mib() {
    nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null \
        | tr -dc '0-9\n' | sort -n | tail -1
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE A — accuracy + safety on a single ~18 GiB job
# ════════════════════════════════════════════════════════════════════════════
hdr "A. single job — is your number accurate AND safe?"
note "submitting a PyTorch job that really uses ~18 GiB (asks for 24Gi)…"
submit_job attrib1 18 24Gi
wait_running attrib1
[[ "$PODPHASE" == "Running" ]] || { bad "workload pod did not run (phase=${PODPHASE:-none}); cannot measure"; echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

note "workload running; reading its own ground truth + nvidia-smi + your tool…"
sleep 8
SMI_PROC=$(smi_max_proc_mib)                         # what the GPU says the process holds
GT_RES=$(gt_reserved_mib attrib1)                    # what PyTorch reserved (real footprint)
GT_ALLOC=$(gt_alloc_mib attrib1)                     # live tensors only (a lower bound)
OUR=$(wait_for_profile_peak attrib1)                 # what YOUR tool measured

echo
note "PyTorch allocated (tensors):   ${GT_ALLOC:-?} MiB"
note "PyTorch reserved  (footprint): ${GT_RES:-?} MiB   <- your number must cover this"
note "nvidia-smi process (the truth):${SMI_PROC:-?} MiB"
note "YOUR tool measured (peak):     ${OUR:-?} MiB"
echo

if [[ -z "$OUR" ]]; then
    bad "your tool reported NO peak for this workload — attribution is BROKEN (NVML returned nothing for the process). This is the #1 risk; fix before anything else."
elif [[ -z "$GT_RES" || -z "$SMI_PROC" ]]; then
    bad "could not read ground truth (pod logs / nvidia-smi). Re-run; check the pod logged GT_RESERVED_MIB."
else
    # A1 ACCURACY: our peak vs nvidia-smi process (same NVML source → should be tight)
    diff=$(( OUR > SMI_PROC ? OUR - SMI_PROC : SMI_PROC - OUR ))
    pct=$(( SMI_PROC > 0 ? diff * 100 / SMI_PROC : 999 ))
    [[ "$pct" -le 8 ]] && ok "ACCURATE: your peak is within ${pct}% of nvidia-smi's process memory" \
                       || bad "INACCURATE: your peak is ${pct}% off nvidia-smi (${OUR} vs ${SMI_PROC} MiB) — attribution is reading the wrong number"
    # A2 SAFETY: our peak must be >= what PyTorch reserved (else autoResize undersizes → OOM)
    if [[ "$OUR" -ge "$GT_RES" ]]; then
        ok "SAFE: your peak (${OUR}) ≥ PyTorch reserved (${GT_RES}) — you capture the real footprint"
        rec=$(( OUR * 115 / 100 ))
        [[ "$rec" -ge "$SMI_PROC" ]] && ok "autoResize target (peak×1.15 = ${rec} MiB) covers the true footprint — re-running at it would FIT" \
                                     || bad "autoResize target ${rec} < true ${SMI_PROC} — would still OOM"
    else
        bad "DANGER: your peak (${OUR}) < PyTorch reserved (${GT_RES}) — you UNDER-measure. autoResize would shrink below what the job needs → OOM. This breaks the thesis until fixed."
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PHASE B — attribution under sharing (the hard part)
# ════════════════════════════════════════════════════════════════════════════
hdr "B. two jobs on ONE GPU — do you give each its OWN number (not swapped/merged)?"
note "submitting A≈10 GiB and B≈30 GiB on the same card…"
submit_job attribA 10 14Gi
submit_job attribB 30 34Gi
wait_running attribA; wait_running attribB
PA=$(wait_for_profile_peak attribA); PB=$(wait_for_profile_peak attribB)
RA=$(gt_reserved_mib attribA);       RB=$(gt_reserved_mib attribB)

echo
note "job A: PyTorch reserved ${RA:-?} MiB   ·   YOUR tool ${PA:-?} MiB"
note "job B: PyTorch reserved ${RB:-?} MiB   ·   YOUR tool ${PB:-?} MiB"
echo
if [[ -z "$PA" || -z "$PB" || -z "$RA" || -z "$RB" ]]; then
    bad "missing a number — could not compare (check both pods ran + logged GT_RESERVED + both profiles exist)"
else
    # each profile must match ITS OWN job (within ~20%), and A must be clearly < B
    closeA=$(( (PA > RA ? PA-RA : RA-PA) * 100 / (RA>0?RA:1) ))
    closeB=$(( (PB > RB ? PB-RB : RB-PB) * 100 / (RB>0?RB:1) ))
    [[ "$closeA" -le 20 ]] && ok "job A attributed to A (${PA}≈${RA} MiB, ${closeA}% off)" || bad "job A mis-attributed (${PA} vs its own ${RA})"
    [[ "$closeB" -le 20 ]] && ok "job B attributed to B (${PB}≈${RB} MiB, ${closeB}% off)" || bad "job B mis-attributed (${PB} vs its own ${RB})"
    [[ "$PA" -lt "$PB" ]] && ok "the two jobs are told apart (A < B, matching 10 < 30 GiB) — not swapped, not merged" \
                          || bad "jobs NOT distinguished (A=${PA} not < B=${PB}) — attribution merges/swaps tenants under sharing"
fi

# restore default observation interval
kubectl set env daemonset/vgpu-nodeagent -n "$SYS_NS" VGPU_OBSERVE_INTERVAL- >/dev/null 2>&1

hdr "verdict"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Attribution is accurate, safe, and per-tenant under sharing.${C_RST}"
    echo "${C_GRN}→ The right-sizing/autoResize thesis holds on real hardware. This is the fact the whole strategy rests on.${C_RST}"
    exit 0
fi
echo; echo "${C_YEL}Attribution did NOT fully pass. This is the make-or-break — read the ✗ lines above.${C_RST}"
echo "${C_YEL}If your number is below the real footprint or merges tenants, fix THAT before building anything else.${C_RST}"
exit 1
