#!/usr/bin/env bash
# ============================================================================
# kind-multinode-up.sh — bring up the vGPU scheduler on a MULTI-NODE kind
# cluster (1 control-plane + N GPU workers), for multi-node stress testing
# WITHOUT real GPUs. Each worker runs the node agent with the fake provider,
# so the full control plane (placement, gangs, per-node capacity, HA,
# node-loss) is exercised across real, separate Kubernetes nodes.
#
#   bash scripts/kind-multinode-up.sh                 # build + bring up
#   bash scripts/kind-multinode-up.sh --skip-build    # reuse loaded images
#   WORKERS=4 bash scripts/kind-multinode-up.sh       # N workers (default 3)
#
# Then: bash scripts/soak-multinode-kind.sh
# Tear down: kind delete cluster --name vgpu-multinode
# ============================================================================
set -euo pipefail

CLUSTER="${CLUSTER:-vgpu-multinode}"
NAMESPACE="vgpu-system"
MANIFESTS="deployments/manifests"
VGPU_RESOURCE="infrastructure.pranav2910.com/vgpu-bytes"
PERNODE_CAPACITY="85899345920"            # 80 GiB per worker (matches agent fake env)
CERT_MANAGER_VERSION="v1.15.3"
WORKERS="${WORKERS:-3}"
SKIP_BUILD=0; [[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

BLU=$'\033[1;34m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'; RST=$'\033[0m'
step(){ echo; echo "${BLU}▶ $*${RST}"; }
ok(){ echo "  ${GRN}✓${RST} $*"; }
warn(){ echo "  ${YEL}!${RST} $*"; }
die(){ echo "  ${RED}✗ $*${RST}" >&2; exit 1; }

[[ -f go.mod ]] || die "run from repo root"
for t in docker kind kubectl; do command -v "$t" >/dev/null || die "$t not installed"; done
docker info >/dev/null 2>&1 || die "Docker daemon not running"

step "kind cluster '$CLUSTER' (1 control-plane + $WORKERS workers)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    warn "cluster exists — deleting for a clean multi-node bring-up"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
fi
{
    echo "kind: Cluster"
    echo "apiVersion: kind.x-k8s.io/v1alpha4"
    echo "nodes:"
    echo "  - role: control-plane"
    for _ in $(seq 1 "$WORKERS"); do echo "  - role: worker"; done
} | kind create cluster --name "$CLUSTER" --config - >/dev/null
kubectl config use-context "kind-${CLUSTER}" >/dev/null 2>&1 || true
WNODES=()
while IFS= read -r n; do [[ -n "$n" ]] && WNODES+=("$n"); done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep worker)
[[ "${#WNODES[@]}" -eq "$WORKERS" ]] || die "expected $WORKERS workers, got ${#WNODES[@]}"
ok "cluster up: 1 control-plane + ${#WNODES[@]} workers"

step "Build + load images"
if [[ $SKIP_BUILD -eq 1 ]]; then warn "--skip-build"; else make docker-build >/dev/null || die "docker-build failed"; ok "built"; fi
for img in vgpu-scheduler:latest vgpu-controller:latest vgpu-nodeagent:latest; do
    kind load docker-image "$img" --name "$CLUSTER" >/dev/null 2>&1 || die "kind load $img failed"
done
ok "3 images loaded onto all nodes"

step "cert-manager $CERT_MANAGER_VERSION"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment --all >/dev/null 2>&1 || die "cert-manager not Available"
ok "cert-manager ready"

step "CRDs + namespace + RBAC + webhooks"
kubectl apply -f "$MANIFESTS/crds/" >/dev/null
for crd in vgpuslices vgpuclaims vgpujobs vgpuquotas vgpugangjobs vgpugangreservations; do
    kubectl wait --for=condition=Established --timeout=60s "crd/${crd}.infrastructure.pranav2910.com" >/dev/null 2>&1 || die "CRD ${crd} not Established"
done
kubectl apply -f "$MANIFESTS/namespace.yaml" >/dev/null
kubectl apply -f "$MANIFESTS/rbac/" >/dev/null
kubectl apply -f "$MANIFESTS/webhooks/" >/dev/null
kubectl wait --for=condition=Ready --timeout=120s -n "$NAMESPACE" certificate/vgpu-controller-webhook >/dev/null 2>&1 || die "webhook cert not Ready"
ok "CRDs Established, RBAC + webhooks applied, TLS issued"

step "Advertise GPU capacity on each WORKER ($((PERNODE_CAPACITY>>30)) GiB each)"
for n in "${WNODES[@]}"; do
    kubectl patch node "$n" --subresource=status --type=merge \
        -p "{\"status\":{\"capacity\":{\"${VGPU_RESOURCE}\":\"${PERNODE_CAPACITY}\"},\"allocatable\":{\"${VGPU_RESOURCE}\":\"${PERNODE_CAPACITY}\"}}}" >/dev/null
    ok "$n → $((PERNODE_CAPACITY>>30)) GiB"
done
echo "  cluster total: $(( WORKERS * (PERNODE_CAPACITY>>30) )) GiB across $WORKERS workers"

step "Deploy scheduler + controller + node agent"
kubectl apply -f "$MANIFESTS/scheduler_deployment.yaml" >/dev/null
kubectl apply -f "$MANIFESTS/controller_deployment.yaml" >/dev/null
kubectl apply -f "$MANIFESTS/nodeagent_daemonset.yaml" >/dev/null
kubectl rollout restart deployment/vgpu-scheduler deployment/vgpu-controller -n "$NAMESPACE" >/dev/null 2>&1 || true
kubectl rollout restart daemonset/vgpu-nodeagent -n "$NAMESPACE" >/dev/null 2>&1 || true
kubectl rollout status deployment/vgpu-controller -n "$NAMESPACE" --timeout=150s >/dev/null 2>&1 || die "controller not ready"
kubectl rollout status deployment/vgpu-scheduler  -n "$NAMESPACE" --timeout=150s >/dev/null 2>&1 || die "scheduler not ready"
kubectl rollout status daemonset/vgpu-nodeagent   -n "$NAMESPACE" --timeout=150s >/dev/null 2>&1 || die "node agents not ready"
AGENTS=$(kubectl get pods -n "$NAMESPACE" -l app=vgpu-nodeagent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ "$AGENTS" -eq "$WORKERS" ]] && ok "1 node agent per worker ($AGENTS/$WORKERS Running)" || warn "agents Running: $AGENTS/$WORKERS"

step "Verify scheduler seeded all $WORKERS nodes"
seeded=0
for _ in $(seq 1 20); do
    seeded=$(kubectl logs -n "$NAMESPACE" deployment/vgpu-scheduler 2>/dev/null | grep -c "Seeded cache: node" || true)
    [[ "$seeded" -ge "$WORKERS" ]] && break; sleep 3
done
[[ "$seeded" -ge "$WORKERS" ]] && ok "scheduler seeded $seeded node(s)" || warn "seed lines seen: $seeded (leader still warming?)"

echo; echo "${GRN}Multi-node kind cluster '$CLUSTER' is up ($WORKERS GPU workers).${RST}"
echo "  Stress it:  bash scripts/soak-multinode-kind.sh"
echo "  Tear down:  kind delete cluster --name $CLUSTER"
