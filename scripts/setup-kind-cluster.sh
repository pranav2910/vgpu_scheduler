#!/usr/bin/env bash
# ============================================================================
# setup-kind-cluster.sh — one-command, idempotent bring-up of the vGPU
# scheduler on a local kind cluster.
#
# Replaces the 13-step manual runbook (architecture doc §11.1). Safe to re-run:
# every step checks current state and converges. Ordered so dependencies are
# satisfied (cert-manager before webhooks, node capacity before the scheduler
# seeds its cache, CRDs Established before workloads).
#
# Usage:
#   scripts/setup-kind-cluster.sh                 # full bring-up (builds images)
#   scripts/setup-kind-cluster.sh --skip-build    # reuse already-loaded images
#   scripts/setup-kind-cluster.sh --recreate      # delete + recreate the cluster
#   scripts/setup-kind-cluster.sh --cluster=foo   # use a different cluster name
#
# Run from the repo root.
# ============================================================================
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
CLUSTER="vgpu-test"
NAMESPACE="vgpu-system"
MANIFESTS="deployments/manifests"
VGPU_RESOURCE="infrastructure.pranav2910.com/vgpu-bytes"
VGPU_CAPACITY="85899345920"                 # 80 GiB mock GPU
CERT_MANAGER_VERSION="v1.15.3"
IMG_SCHEDULER="vgpu-scheduler:latest"
IMG_CONTROLLER="vgpu-controller:latest"
IMG_NODEAGENT="vgpu-nodeagent:latest"
SKIP_BUILD=0
RECREATE=0

for arg in "$@"; do
    case "$arg" in
        --skip-build)  SKIP_BUILD=1 ;;
        --recreate)    RECREATE=1 ;;
        --cluster=*)   CLUSTER="${arg#*=}" ;;
        --help|-h)     grep '^#' "$0" | sed 's/^# \?//' | head -20; exit 0 ;;
        *) echo "ERROR: unknown arg '$arg'" >&2; exit 1 ;;
    esac
done

# ── Output helpers ────────────────────────────────────────────────────────────
BLU=$'\033[1;34m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'; RST=$'\033[0m'
step() { echo; echo "${BLU}▶ $*${RST}"; }
ok()   { echo "  ${GRN}✓${RST} $*"; }
warn() { echo "  ${YEL}!${RST} $*"; }
die()  { echo "  ${RED}✗ $*${RST}" >&2; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"
[[ -f go.mod ]] || die "run from repo root (go.mod not found)"
for t in docker kind kubectl; do command -v "$t" >/dev/null || die "$t not installed"; done
docker info >/dev/null 2>&1 || die "Docker daemon not running (start Docker Desktop / colima)"
ok "tools present, Docker daemon up"

# ── 1. kind cluster ───────────────────────────────────────────────────────────
step "kind cluster '$CLUSTER'"
if [[ $RECREATE -eq 1 ]] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    warn "deleting existing cluster (--recreate)"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
fi
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    ok "cluster already exists"
else
    kind create cluster --name "$CLUSTER" >/dev/null
    ok "cluster created"
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null 2>&1 || true
NODE=$(kubectl get nodes -o name | head -1 | sed 's|node/||')
[[ -n "$NODE" ]] || die "could not determine node name"
ok "node: $NODE"

# ── 2. Mock GPU capacity (before the scheduler starts, so it seeds correctly) ──
step "Advertise mock GPU capacity ($VGPU_CAPACITY bytes)"
cur=$(kubectl get node "$NODE" -o jsonpath="{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}" 2>/dev/null || true)
if [[ "$cur" == "$VGPU_CAPACITY" ]]; then
    ok "capacity already advertised"
else
    kubectl patch node "$NODE" --subresource=status --type=merge \
        -p "{\"status\":{\"capacity\":{\"${VGPU_RESOURCE}\":\"${VGPU_CAPACITY}\"},\"allocatable\":{\"${VGPU_RESOURCE}\":\"${VGPU_CAPACITY}\"}}}" >/dev/null
    ok "patched node capacity + allocatable"
fi

# ── 3. Build + load images ────────────────────────────────────────────────────
step "Container images"
if [[ $SKIP_BUILD -eq 1 ]]; then
    warn "--skip-build: reusing existing images"
else
    make docker-build >/dev/null || die "docker-build failed"
    ok "built 3 images"
fi
for img in "$IMG_SCHEDULER" "$IMG_CONTROLLER" "$IMG_NODEAGENT"; do
    kind load docker-image "$img" --name "$CLUSTER" >/dev/null 2>&1 || die "kind load $img failed"
done
ok "images loaded into kind"

# ── 4. cert-manager (required for webhook TLS) ────────────────────────────────
step "cert-manager $CERT_MANAGER_VERSION"
if kubectl get ns cert-manager >/dev/null 2>&1 && \
   kubectl get deploy -n cert-manager cert-manager-webhook >/dev/null 2>&1; then
    ok "already installed"
else
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
    ok "manifests applied"
fi
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment --all >/dev/null 2>&1 \
    || die "cert-manager did not become Available"
ok "cert-manager ready"

# ── 5. CRDs ───────────────────────────────────────────────────────────────────
step "CRDs"
kubectl apply -f "$MANIFESTS/crds/" >/dev/null
for crd in vgpuslices vgpuclaims vgpujobs vgpuquotas vgpugangjobs vgpugangreservations; do
    kubectl wait --for=condition=Established --timeout=60s \
        "crd/${crd}.infrastructure.pranav2910.com" >/dev/null 2>&1 \
        || die "CRD ${crd} not Established"
done
ok "6 CRDs Established"

# ── 6. Namespace ──────────────────────────────────────────────────────────────
step "Namespace"
kubectl apply -f "$MANIFESTS/namespace.yaml" >/dev/null
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace not created"
ok "namespace $NAMESPACE present"

# ── 7. RBAC ───────────────────────────────────────────────────────────────────
step "RBAC"
kubectl apply -f "$MANIFESTS/rbac/" >/dev/null
ok "applied"

# ── 8. Webhooks (Issuer, Certificate, Service, webhook configs) ───────────────
step "Webhooks + TLS certificate"
kubectl apply -f "$MANIFESTS/webhooks/" >/dev/null
kubectl wait --for=condition=Ready --timeout=120s \
    -n "$NAMESPACE" certificate/vgpu-controller-webhook >/dev/null 2>&1 \
    || die "webhook Certificate not Ready (cert-manager issue?)"
kubectl get secret -n "$NAMESPACE" vgpu-controller-webhook-cert >/dev/null 2>&1 \
    || die "webhook TLS secret not created"
ok "certificate issued, TLS secret present"

# ── 9. Workloads ──────────────────────────────────────────────────────────────
step "Deployments + daemonset"
kubectl apply -f "$MANIFESTS/scheduler_deployment.yaml" >/dev/null
kubectl apply -f "$MANIFESTS/controller_deployment.yaml" >/dev/null
kubectl apply -f "$MANIFESTS/nodeagent_daemonset.yaml" >/dev/null
ok "applied"

# ── 10. Roll out to the freshly-loaded images, wait for ready ─────────────────
step "Rollout"
# Force pods onto the just-loaded :latest images even if a prior pod is running.
kubectl rollout restart deployment/vgpu-scheduler deployment/vgpu-controller -n "$NAMESPACE" >/dev/null 2>&1 || true
kubectl rollout restart daemonset/vgpu-nodeagent -n "$NAMESPACE" >/dev/null 2>&1 || true
kubectl rollout status deployment/vgpu-controller -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 \
    || die "controller did not become ready"
kubectl rollout status deployment/vgpu-scheduler  -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 \
    || die "scheduler did not become ready"
ok "controller + scheduler ready"

# ── 11. Verify the scheduler seeded full capacity ─────────────────────────────
step "Verify scheduler cache seeded capacity"
seeded=""
for _ in $(seq 1 20); do
    seeded=$(kubectl logs -n "$NAMESPACE" deployment/vgpu-scheduler 2>/dev/null \
        | grep -E "Seeded cache.*total=${VGPU_CAPACITY}" | tail -1 || true)
    [[ -n "$seeded" ]] && break
    sleep 3
done
if [[ -n "$seeded" ]]; then
    ok "scheduler seeded: $(echo "$seeded" | sed 's/^.*Seeded/Seeded/')"
else
    warn "could not confirm seed line in logs (scheduler may still be acquiring leader lease)"
fi

echo
echo "${GRN}════════════════════════════════════════════════════════════${RST}"
echo "${GRN} vGPU scheduler is up on kind cluster '${CLUSTER}'.${RST}"
echo "${GRN}════════════════════════════════════════════════════════════${RST}"
echo "  Pods:        kubectl get pods -n ${NAMESPACE}"
echo "  Run tests:   bash real_world_test.sh"
echo "  Tear down:   kind delete cluster --name ${CLUSTER}"
