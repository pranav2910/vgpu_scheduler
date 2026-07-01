#!/usr/bin/env bash
# soak-realworld.sh — "rush hour": a compressed day-in-the-life of a GPU
# cluster, on real hardware. Run ON the control-plane GPU node.
#
# For ROUNDS rounds (~2.5 min each), CONCURRENTLY and CONTINUOUSLY:
#   - real CUDA pods churn through the FULL stack (submit → schedule → CDI →
#     run → complete → delete), mixed sizes, overlapping rounds
#   - a gang forms and dissolves alongside the solo churn every round
#   - one deliberate OVER-USER runs the whole time (granted 2Gi, really
#     allocating ~4Gi) so the enforcement loop must detect → attribute →
#     soft-warn it on a live multi-GPU node
#   - halfway through, the scheduler LEADER is killed under churn
#
# End-state audit (each is a hard assertion):
#   every round completed · zero slices left · agent logs on EVERY node show
#   zero state violations and zero fragmentation failures · the over-user's
#   slice carries the MemoryViolation condition · a learned profile exists
#   with a real observed peak · scheduler gauges return to allocated=0 +
#   reserved=0 on every node.
#
#   export KUBECONFIG=$HOME/.kube/config
#   bash scripts/soak-realworld.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

GiB=$((1024*1024*1024))
NS="soak-$(date +%s)"
ROUNDS="${ROUNDS:-8}"
CUDA_IMG="${CUDA_IMG:-nvidia/cuda:12.4.1-base-ubuntu22.04}"
TORCH_IMG="${TORCH_IMG:-pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime}"

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
hdr(){ echo; echo "${C_BLU}── $* ──${C_RST}"; }
ok(){  echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad(){ echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }
dim(){ echo "  ${C_DIM}$*${C_RST}"; }

cleanup(){ hdr cleanup; kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1; dim "namespace drained"; }
trap cleanup EXIT

pod_job() { # name vram_gib sleep_s
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: $1, namespace: $NS }
spec:
  priority: 50
  workloadClass: Inference
  claimTemplate:
    spec: { requestedVramBytes: $(( $2 * GiB )), serviceTier: Guaranteed }
  podTemplate:
    spec:
      runtimeClassName: nvidia
      restartPolicy: Never
      containers:
      - name: w
        image: ${CUDA_IMG}
        command: ["sh","-c","nvidia-smi -L; sleep $3"]
EOF
}

gang() { # name size vram_gib
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: $1, namespace: $NS }
spec:
  gangSize: $2
  minAvailable: $2
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 90
  podTemplate:
    spec: { requestedVramBytes: $(( $3 * GiB )), serviceTier: Guaranteed }
EOF
}

hdr "rush hour: $ROUNDS rounds on $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes"
kubectl create namespace "$NS" >/dev/null

# The over-user: granted 2Gi, really allocates ~4Gi, lives the whole soak.
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: overuser, namespace: $NS }
spec:
  priority: 50
  workloadClass: Inference
  claimTemplate:
    spec: { requestedVramBytes: $(( 2 * GiB )), serviceTier: Guaranteed }
  podTemplate:
    spec:
      runtimeClassName: nvidia
      restartPolicy: Never
      containers:
      - name: w
        image: ${TORCH_IMG}
        command: ["python","-c","import torch,time; torch.empty(int(4*1024**3)//2,dtype=torch.float16,device='cuda').normal_(); torch.cuda.synchronize(); print('over-using',flush=True); time.sleep(1800)"]
EOF
dim "over-user submitted (2Gi granted, ~4Gi real use)"

COMPLETED=0
for r in $(seq 1 "$ROUNDS"); do
    sizes=(2 3 5 3)
    for j in a b c d; do
        idx=$(( (r + $(printf '%d' "'$j")) % 4 ))
        pod_job "r${r}${j}" "${sizes[$idx]}" 90
    done
    gang "g${r}" 4 3

    # Wait for the round's gang to commit (solo pods progress in parallel).
    deadline_ok=0
    for _ in $(seq 1 30); do
        ph=$(kubectl get vgpugangreservation -n "$NS" "g${r}-rsv" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$ph" == "Committed" ]] && { deadline_ok=1; break; }
        sleep 4
    done
    [[ $deadline_ok -eq 1 ]] || { bad "round $r: gang never committed"; kubectl get vgpugangreservation,vgpuslice -n "$NS" | head; break; }

    # Mid-soak: kill the scheduler LEADER under churn.
    if [[ "$r" -eq $((ROUNDS/2)) ]]; then
        HOLDER=$(kubectl get lease -n vgpu-system vgpu-scheduler-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | cut -d_ -f1)
        if [[ -n "$HOLDER" ]]; then
            kubectl delete pod -n vgpu-system "$HOLDER" --wait=false >/dev/null 2>&1
            dim "round $r: killed scheduler leader $HOLDER under churn"
        fi
    fi

    # Churn: the round's gang dissolves; pods from two rounds ago get deleted
    # (their 90s sleeps are done — exercising completed-pod teardown too).
    kubectl delete vgpugangjob "g${r}" -n "$NS" --wait=false >/dev/null 2>&1
    if [[ "$r" -ge 3 ]]; then
        old=$((r-2))
        for j in a b c d; do kubectl delete vgpujob "r${old}${j}" -n "$NS" --wait=false >/dev/null 2>&1; done
    fi
    COMPLETED=$((COMPLETED+1))
    dim "round $r/$ROUNDS done (gang committed + dissolved, solo churn rolling)"
done

hdr "audit"
[[ "$COMPLETED" == "$ROUNDS" ]] && ok "all $ROUNDS rounds completed" || bad "completed $COMPLETED/$ROUNDS rounds"

# Enforcement: the over-user's slice must carry MemoryViolation (softwarn).
VIOL=0
for _ in $(seq 1 30); do
    kubectl get vgpuslice overuser-claim-slice -n "$NS" -o yaml 2>/dev/null | grep -q "MemoryViolation" && { VIOL=1; break; }
    sleep 5
done
[[ $VIOL -eq 1 ]] && ok "enforcement live on multi-GPU: over-user marked MemoryViolation (granted 2Gi, used ~4Gi)" \
    || bad "over-user never marked Violating"

# Feedback loop: a learned profile with a real peak.
PEAK=$(kubectl get vgpuworkloadprofile overuser -n "$NS" -o jsonpath='{.status.peakObservedVramBytes}' 2>/dev/null)
[[ -n "$PEAK" && "$PEAK" -gt $((3*GiB)) ]] && ok "feedback loop live: profile peak $(awk "BEGIN{printf \"%.1f\", $PEAK/1073741824}")Gi (> granted 2Gi)" \
    || bad "no usable profile (peak='$PEAK')"

# Drain everything, then the books must balance.
kubectl delete namespace "$NS" --wait=true >/dev/null 2>&1
trap - EXIT
LEFT=$(kubectl get vgpuslice -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ "$LEFT" == "0" ]] && ok "zero slices left cluster-wide" || bad "$LEFT slices left"

# Audit SCOPED to this soak's objects — an agent's log may legitimately carry
# intentional failures from other suites (the multigpu validator's own
# fragmentation test once tripped this as a false positive).
SOAK_RE="(r[0-9]+[abcd]|g[0-9]+-[0-9]+|overuser)-claim-slice"
for AG in $(kubectl get pods -n vgpu-system -l app=vgpu-nodeagent -o jsonpath='{.items[*].metadata.name}'); do
    V=$(kubectl logs -n vgpu-system "$AG" 2>/dev/null | grep "FATAL STATE VIOLATION" | grep -cE "$SOAK_RE")
    F=$(kubectl logs -n vgpu-system "$AG" 2>/dev/null | grep "FAILED LOUD" | grep -c "$NS/")
    W=$(kubectl logs -n vgpu-system "$AG" 2>/dev/null | grep "wedge recovery" | grep -cE "$SOAK_RE")
    [[ "$V" == "0" && "$F" == "0" ]] && ok "agent $AG clean for this soak (violations=0 frag=0 wedge-recoveries=$W)" \
        || bad "agent $AG: soak violations=$V frag=$F"
done

# Gauges must return to zero — allow up to ~100s for the cache janitor's
# level-based sweep to correct any missed release edge (its whole job).
GAUGE_BAD=""
for _ in $(seq 1 20); do
    GAUGE_BAD=""
    for p in $(kubectl get pods -n vgpu-system -o name | grep scheduler); do
        NZ=$(kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/${p#pod/}:8081/proxy/metrics" 2>/dev/null \
            | awk '/^vgpu_node_(allocated|reserved)_bytes/ && $2+0 != 0 {print}' | head -2)
        [[ -n "$NZ" ]] && GAUGE_BAD="$NZ"
    done
    [[ -z "$GAUGE_BAD" ]] && break
    sleep 5
done
[[ -z "$GAUGE_BAD" ]] && ok "scheduler gauges back to baseline (allocated=0, reserved=0 on every node)" \
    || bad "capacity gauges not back to zero even after a janitor sweep: $GAUGE_BAD"
JF=""
for p in $(kubectl get pods -n vgpu-system -o name | grep scheduler); do
    v=$(kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/${p#pod/}:8081/proxy/metrics" 2>/dev/null \
        | awk '/^vgpu_scheduler_cache_janitor_forgets_total/ {print $2}')
    [[ -n "$v" && "$v" != "0" ]] && JF="$v"
done
[[ -n "$JF" ]] && dim "note: janitor forgot $JF entr(ies) — a release edge was missed and self-healed; uids are in the scheduler log"

echo; echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Rush hour survived: continuous real workloads + gangs + over-use enforcement + a leader kill, books balanced to zero.${C_RST}"
    exit 0
fi
echo; echo "${C_RED}rush-hour soak FAILED${C_RST}"; exit 1
