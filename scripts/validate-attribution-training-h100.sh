#!/usr/bin/env bash
# validate-attribution-training-h100.sh — the HARD attribution case.
#
# The static test (validate-attribution-h100.sh) used one torch.empty() alloc, where
# PyTorch's reserved == allocated — so it could not tell whether we measure the real
# footprint or just live tensors. This runs a REAL training loop (model + Adam +
# forward/backward over many steps) so the caching allocator RESERVES MUCH MORE than
# it ALLOCATES and memory fragments — exactly the regime a skeptic says makes
# attribution unreliable.
#
# The discriminating question:
#   Does your measured peak track RESERVED (the true footprint, the big number),
#   not just ALLOCATED (live tensors, the small number)?
# If your number ≈ allocated, autoResize would undersize a real training job → OOM.
#
#   bash scripts/h100-control-plane.sh
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   bash scripts/validate-attribution-training-h100.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NS="${NS:-default}"; SYS_NS=vgpu-system
IMAGE="${IMAGE:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
NAME=traintest

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok(){ echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
note(){ echo "  • $*"; }
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "run on the GPU node"; exit 2; }
kubectl -n "$SYS_NS" get deploy vgpu-controller >/dev/null 2>&1 || { echo "control plane not up — run scripts/h100-control-plane.sh"; exit 2; }

cleanup(){ hdr cleanup; kubectl delete vgpujob "$NAME" vgpuworkloadprofile "$NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
           kubectl set env daemonset/vgpu-nodeagent -n "$SYS_NS" VGPU_OBSERVE_INTERVAL- >/dev/null 2>&1 || true; echo "  done"; }
trap cleanup EXIT

hdr "speed up observation (3s)"
kubectl set env daemonset/vgpu-nodeagent -n "$SYS_NS" VGPU_OBSERVE_INTERVAL=3s >/dev/null 2>&1
kubectl rollout status daemonset/vgpu-nodeagent -n "$SYS_NS" --timeout=120s >/dev/null 2>&1 && note "observing every 3s"

# A REAL training loop as a one-liner expression (no for-statement so it stays a
# valid single line): 16x Linear(8192,8192) fp16 + Adam, 60 steps. The optimizer
# state + grads + activations + the caching allocator make reserved > allocated and
# fragment memory. It then prints its own ground truth and holds at peak.
TRAIN='python -c "import torch,time; d=8192; net=torch.nn.Sequential(*[torch.nn.Linear(d,d) for _ in range(16)]).cuda().half(); opt=torch.optim.Adam(net.parameters(),lr=1e-4); x=torch.randn(2048,d,device=DEV,dtype=torch.float16); [(opt.zero_grad(), net(x).sum().backward(), opt.step()) for _ in range(60)]; torch.cuda.synchronize(); print(QGT_ALLOC_MIB=%dQ%(torch.cuda.max_memory_allocated()//1048576),flush=True); print(QGT_RESERVED_MIB=%dQ%(torch.cuda.max_memory_reserved()//1048576),flush=True); time.sleep(3600)"'
TRAIN=${TRAIN//DEV/\'cuda\'}      # device='cuda'
TRAIN=${TRAIN//Q/\'}             # the %-format string single-quotes

hdr "submit a REAL training job (asks for 40Gi; uses far less — that's the point)"
scripts/vgpu submit --name "$NAME" --vram 40Gi -n "$NS" --image "$IMAGE" \
    --command "$TRAIN" --runtime-class "$RUNTIME_CLASS" --wait 300 >/tmp/train-submit.log 2>&1
kubectl get vgpujob "$NAME" -n "$NS" >/dev/null 2>&1 || { bad "submit failed: $(tail -1 /tmp/train-submit.log)"; echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

note "waiting for the training loop to run + report (image pull can take a minute)…"
PODPHASE=""
for _ in $(seq 1 80); do
    PODPHASE=$(kubectl get pod "$NAME-workload" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$PODPHASE" == "Running" || "$PODPHASE" == "Succeeded" ]] && break
    [[ "$PODPHASE" == "Failed" ]] && { kubectl logs "$NAME-workload" -n "$NS" 2>/dev/null | tail -8; break; }
    sleep 5
done
[[ "$PODPHASE" == "Running" || "$PODPHASE" == "Succeeded" ]] || { bad "training pod did not run (phase=${PODPHASE:-none})"; echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# wait for the ground-truth lines (training takes a few seconds after start)
GT_RES=""; for _ in $(seq 1 40); do
    GT_RES=$(kubectl logs "$NAME-workload" -n "$NS" 2>/dev/null | grep -oE 'GT_RESERVED_MIB=[0-9]+' | tail -1 | cut -d= -f2)
    [[ -n "$GT_RES" ]] && break; sleep 3
done
GT_ALLOC=$(kubectl logs "$NAME-workload" -n "$NS" 2>/dev/null | grep -oE 'GT_ALLOC_MIB=[0-9]+' | tail -1 | cut -d= -f2)

# Sample host nvidia-smi a few times, taking the max — but ONLY this pod's
# process, matched PID → /proc/<pid>/cgroup → pod UID (the same attribution
# the product does, measured independently). The old max-across-the-card form
# grabbed any other GPU process as "the truth" — e.g. a CUDA process from a
# previously-run validator still dying off — and flunked a correct
# measurement against the wrong baseline.
POD_UID=$(kubectl get pod "$NAME-workload" -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
others=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
[[ "${others:-0}" -gt 1 ]] && note "(${others} compute processes on the card — matching by pod PID, others ignored)"
SMI=0; for _ in $(seq 1 6); do
    m=0
    while IFS=, read -r pid mem; do
        pid=${pid//[^0-9]/}; mem=${mem//[^0-9]/}
        [[ -z "$pid" || -z "$mem" ]] && continue
        if grep -qE "pod(${POD_UID}|${POD_UID//-/_})" "/proc/$pid/cgroup" 2>/dev/null; then
            (( mem > m )) && m=$mem
        fi
    done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
    [[ -n "$m" && "$m" -gt "$SMI" ]] && SMI="$m"; sleep 2
done

# our tool's measured peak
OUR=""; for _ in $(seq 1 30); do
    b=$(kubectl get vgpuworkloadprofile "$NAME" -n "$NS" -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
    [[ -n "$b" && "$b" -gt 0 ]] 2>/dev/null && { OUR=$(( b / 1048576 )); break; }; sleep 3
done

hdr "the numbers (training — reserved should be clearly > allocated)"
note "PyTorch ALLOCATED (live tensors):  ${GT_ALLOC:-?} MiB   ← the small number"
note "PyTorch RESERVED  (real footprint):${GT_RES:-?} MiB   ← the big number; you must track THIS"
note "nvidia-smi process (the truth):    ${SMI:-?} MiB"
note "YOUR tool measured (peak):         ${OUR:-?} MiB"
echo

if [[ -z "$OUR" || -z "$GT_RES" || -z "$GT_ALLOC" || "$SMI" -eq 0 ]]; then
    bad "missing a number — could not compare (check the pod logged GT_RESERVED_MIB and nvidia-smi sees the process)"
else
    # Is this even the hard case? (reserved must exceed allocated, else no fragmentation to test)
    if [[ "$GT_RES" -le $(( GT_ALLOC + 256 )) ]]; then
        note "(note: reserved ≈ allocated here — fragmentation was mild; still checking accuracy/safety)"
    else
        ok "this IS the hard case: reserved (${GT_RES}) exceeds allocated (${GT_ALLOC}) by $(( GT_RES - GT_ALLOC )) MiB"
    fi
    # ACCURACY vs nvidia-smi
    d=$(( OUR > SMI ? OUR-SMI : SMI-OUR )); p=$(( SMI>0 ? d*100/SMI : 999 ))
    [[ "$p" -le 8 ]] && ok "ACCURATE: within ${p}% of nvidia-smi (${OUR} vs ${SMI} MiB)" || bad "INACCURATE: ${p}% off nvidia-smi"
    # THE DISCRIMINATOR: do we track reserved, not just allocated?
    if [[ "$OUR" -ge "$GT_RES" ]]; then
        ok "SAFE: your peak (${OUR}) ≥ RESERVED (${GT_RES}) — you track the real footprint, not just tensors"
        rec=$(( OUR*115/100 )); [[ "$rec" -ge "$SMI" ]] && ok "autoResize target (${rec}) covers the footprint — a real training job would FIT" || bad "autoResize target ${rec} < ${SMI} — would OOM"
    elif [[ "$OUR" -ge "$GT_ALLOC" && "$OUR" -lt "$GT_RES" ]]; then
        bad "DANGER: your peak (${OUR}) is below RESERVED (${GT_RES}) — you measured closer to live tensors than the reserved pool. autoResize would undersize a real training job → OOM. THIS is the skeptic's case; fix the measurement."
    else
        bad "your peak (${OUR}) is below even allocated (${GT_ALLOC}) — attribution is wrong"
    fi
fi

hdr verdict
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && { echo; echo "${C_GRN}Attribution holds under REAL training (fragmentation, reserved≫allocated). The skeptic's case is answered on hardware.${C_RST}"; exit 0; }
echo; echo "${C_RED}The hard case did NOT fully pass — read the ✗ lines. This is the most important thing to fix.${C_RST}"; exit 1
