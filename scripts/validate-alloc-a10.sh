#!/usr/bin/env bash
# Data-plane proof — ISOLATED allocate → CDI → runtime-inject validation.
#
# Proves the irreducible last mile that turns "control plane that schedules
# slices" into "a pod actually runs on a shared GPU":
#
#   VGPUSlice on a real GPU node  →  node agent allocates a REAL GPU UUID
#   →  a CDI spec named by AllocationID  →  a pod carrying that CDI annotation
#      (+ runtimeClassName=nvidia) receives the GPU  →  nvidia-smi works inside it,
#      and the GPU UUID inside the pod matches the slice's deviceUuid.
#
# Deliberately ISOLATED — NO scheduler, controller, webhook, or cert-manager. We
# hand-create the slice and the CDI-annotated pod, so a failure points at exactly
# ONE layer (allocation, CDI generation, or containerd/NVIDIA-runtime injection),
# not the whole stack. Run the FULL submit→run flow only after this is green.
#
#   bash scripts/a10-bootstrap.sh          # builds + deploys the -tags nvml node agent (latest code)
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   bash scripts/validate-alloc-a10.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS="${NS:-default}"
AGENT_NS="${AGENT_NS:-vgpu-system}"
GRANT_BYTES="${GRANT_BYTES:-2147483648}"                  # 2 GiB — soft model, size is just recorded
SMI_IMAGE="${SMI_IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"
RUNTIME_CLASS="${RUNTIME_CLASS:-nvidia}"
SLICE=alloc-demo-slice; POD=alloc-demo-pod; CLAIM=alloc-demo-claim

C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗${C_RST} $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "── $* ──"; }

cleanup() {
    hdr "cleanup"
    kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete vgpuslice "$SLICE" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
    echo "  demo slice + pod deleted"
}
trap cleanup EXIT

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 2; }
AGENT=$(kubectl -n "$AGENT_NS" get pods -l app=vgpu-nodeagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$AGENT" ]] && { echo "no vgpu-nodeagent pod in $AGENT_NS — run scripts/a10-bootstrap.sh first"; exit 2; }
NODE=$(kubectl -n "$AGENT_NS" get pod "$AGENT" -o jsonpath='{.spec.nodeName}')
agent_exec() { kubectl exec -n "$AGENT_NS" "$AGENT" -- "$@" 2>/dev/null; }
scrape() { kubectl get --raw "/api/v1/namespaces/$AGENT_NS/pods/${AGENT}:8083/proxy/metrics" 2>/dev/null; }
if ! scrape | grep -q 'vgpu_gpu_provider_info{[^}]*provider="nvml"[^}]*} 1'; then
    echo "node agent is not running the NVML provider (fake/degraded). Re-run a10-bootstrap (it builds -tags nvml)."; exit 2
fi
echo "node agent: $AGENT on node $NODE (provider=nvml)"

# ── 1. create the slice and trigger allocation (no scheduler — we set Scheduled) ─
hdr "create slice + trigger allocation"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUSlice
metadata: { name: $SLICE, namespace: $NS }
spec: { claimRef: $CLAIM, nodeName: $NODE, requestedVramBytes: $GRANT_BYTES }
EOF
# Phase=Scheduled is the trigger the node agent's reconciler allocates on.
kubectl patch vgpuslice "$SLICE" -n "$NS" --subresource=status --type=merge \
    -p '{"status":{"phase":"Scheduled"}}' >/dev/null 2>&1
echo "  slice $SLICE created on $NODE, patched Scheduled"

hdr "wait for the node agent to allocate (phase → Ready)"
phase=""; alloc=""; uuid=""
for i in $(seq 1 30); do
    phase=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    alloc=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.allocationId}' 2>/dev/null)
    uuid=$(kubectl get vgpuslice "$SLICE" -n "$NS" -o jsonpath='{.status.deviceUuid}' 2>/dev/null)
    echo "  t=$((i*2))s  phase=${phase:-<none>}  alloc=${alloc:-<none>}  uuid=${uuid:-<none>}"
    [[ "$phase" == "Ready" && -n "$alloc" && -n "$uuid" ]] && break
    sleep 2
done

# ── 2. allocation assertions ─────────────────────────────────────────────────
hdr "allocation (node agent → real GPU)"
alloc_ok=1
[[ "$phase" == "Ready" ]] && ok "slice reached Ready" || { bad "slice not Ready (phase=${phase:-<none>})"; alloc_ok=0; }
[[ -n "$alloc" ]] && ok "allocationId present ($alloc)" || { bad "no allocationId"; alloc_ok=0; }
[[ -n "$uuid"  ]] && ok "deviceUuid present ($uuid)"   || { bad "no deviceUuid"; alloc_ok=0; }
[[ "$uuid" == GPU-* ]] && ok "deviceUuid is a GPU- UUID" || { bad "deviceUuid not GPU-* ('$uuid')"; alloc_ok=0; }
if [[ "$uuid" == GPU-MOCK* || "$uuid" == GPU-FAKE* ]]; then
    bad "deviceUuid is GPU-MOCK — the nvml allocator is NOT active. Re-run a10-bootstrap so the node agent is built -tags nvml."
    alloc_ok=0
else
    [[ "$uuid" == GPU-* ]] && ok "deviceUuid is REAL (not GPU-MOCK)"
fi

# ── 3. CDI spec on the node (read via the agent, which mounts /var/run/cdi) ───
# The spec file is keyed by ALLOCATION ID (one independent file per slice), not
# by GPU UUID — every slice on a node shares the physical GPU's UUID, and a
# uuid-named file meant slice B's spec overwrote slice A's (and releasing one
# slice revoked them all). The device name inside still matches what the
# mutating webhook requests.
hdr "CDI spec on the node"
CDI_FILE="/var/run/cdi/infrastructure.pranav2910.com-${alloc}.json"
cdi_json="$(agent_exec cat "$CDI_FILE")"
if [[ -n "$cdi_json" ]]; then
    ok "CDI spec written: $CDI_FILE"
    devname=$(printf '%s' "$cdi_json" | grep -oE '"name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"name":[[:space:]]*"//; s/"$//')
    [[ "$devname" == "$alloc" ]] \
        && ok "CDI device name == allocationId ($devname)" \
        || bad "CDI device name '$devname' != allocationId '$alloc' (the #3 mismatch — rebuild the node agent)"
    printf '%s' "$cdi_json" | grep -q "NVIDIA_VISIBLE_DEVICES=${uuid}" \
        && ok "CDI spec injects NVIDIA_VISIBLE_DEVICES=$uuid" \
        || bad "CDI spec does not reference the real UUID"
else
    bad "no CDI spec at $CDI_FILE (node agent did not write it)"
fi

# ── 4. pod with the CDI annotation + nvidia runtimeClass ──────────────────────
hdr "pod with CDI annotation + runtimeClassName=$RUNTIME_CLASS"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  annotations:
    # Exactly what the mutating webhook would inject — tested here by hand to
    # isolate the data plane from the admission path.
    cdi.k8s.io/vgpu-pranav2910-com: "infrastructure.pranav2910.com/vgpu=$alloc"
spec:
  nodeName: $NODE
  runtimeClassName: ${RUNTIME_CLASS}
  restartPolicy: Never
  containers:
  - name: smi
    image: $SMI_IMAGE
    command: ["bash","-c","nvidia-smi -L || true; sleep 600"]
EOF
echo "  waiting for the pod to start (image pull can take a minute)..."
podphase=""
for i in $(seq 1 60); do
    podphase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$podphase" == "Running" || "$podphase" == "Succeeded" ]] && break
    [[ "$podphase" == "Failed" ]] && { echo "  pod Failed:"; kubectl logs "$POD" -n "$NS" 2>/dev/null | tail -5; break; }
    sleep 5
done

hdr "GPU injected into the pod?"
inject_ok=1
[[ "$podphase" == "Running" || "$podphase" == "Succeeded" ]] && ok "pod started ($podphase)" || { bad "pod did not start (phase=${podphase:-<none>})"; inject_ok=0; }
poduuid=$(kubectl exec "$POD" -n "$NS" -- nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | tr -d '\r' | head -1)
if [[ -n "$poduuid" ]]; then
    ok "nvidia-smi works INSIDE the pod (sees $poduuid)"
    [[ "$poduuid" == "$uuid" ]] \
        && ok "pod's GPU UUID matches slice.status.deviceUuid — real shared-GPU access proven" \
        || bad "pod GPU UUID '$poduuid' != slice deviceUuid '$uuid'"
else
    bad "nvidia-smi failed inside the pod — containerd/NVIDIA runtime did NOT inject the GPU"
    inject_ok=0
fi

# ── verdict ───────────────────────────────────────────────────────────────────
hdr "summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo; echo "${C_GRN}Data plane proven: allocate → CDI → inject works on real hardware.${C_RST}"
    echo "  Next milestone: VGPUJob → pod auto-runs with GPU (the full webhook path)."
    exit 0
fi
echo; echo "${C_RED}validation had failures${C_RST}"
if [[ "$alloc_ok" == "1" && "$inject_ok" == "0" ]]; then
    cat <<TIP

${C_DIM}Diagnosis: allocation + the CDI spec are CORRECT — the gap is purely runtime
injection. The CDI annotation did not result in the GPU being injected. Likely:
  1. containerd CDI is disabled in this k3s. Check the containerd config has
     'enable_cdi = true' (k3s: /var/lib/rancher/k3s/agent/etc/containerd/config.toml),
     restart k3s, and re-run.
  2. Or the runtime needs device-nodes in the CDI spec (not just the env). Confirm
     the NVIDIA runtime acts on NVIDIA_VISIBLE_DEVICES via CDI on this node.

Isolate further — does a DIRECT env pod (bypassing CDI) get the GPU? If THIS works,
the GPU UUID + nvidia runtime are fine and the gap is strictly containerd-CDI:
  kubectl run smi-env --image=$SMI_IMAGE --restart=Never \\
    --overrides='{"spec":{"nodeName":"$NODE","runtimeClassName":"$RUNTIME_CLASS",
      "containers":[{"name":"smi","image":"$SMI_IMAGE","command":["bash","-c","nvidia-smi -L; sleep 60"],
      "env":[{"name":"NVIDIA_VISIBLE_DEVICES","value":"$uuid"}]}]}}' \\
    -n $NS && sleep 20 && kubectl exec smi-env -n $NS -- nvidia-smi -L; kubectl delete pod smi-env -n $NS${C_RST}
TIP
fi
exit 1
