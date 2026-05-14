#!/usr/bin/env bash
# ============================================================================
# rollout_phase24a.sh — one-shot, idempotent, resumable rollout of Phase 2.4a.
#
# This is the master script. It chains the source installer with all the
# cluster-side steps (apply CRDs, build images, kind-load, restart, smoke test).
# Every phase is self-contained and idempotent; you can ^C at any step,
# fix the issue, and re-run from the top — completed phases will short-circuit.
#
# Phases:
#   1. Pre-flight       — verify go, docker, kubectl, kind, repo layout
#   2. Source install   — runs install_phase24a_gang.sh (copies + patches files)
#   3. Build            — go build ./... (catches any type errors)
#   4. Test (optional)  — go test ./... (skipped if --skip-tests)
#   5. Docker images    — make docker-build
#   6. Kind load        — push images into the kind cluster
#   7. Apply CRDs       — kubectl apply on the two new CRD manifests
#   8. Apply RBAC       — kubectl apply on the patched RBAC file
#   9. Restart pods     — rollout restart controller + scheduler
#  10. Wait for ready   — kubectl rollout status with timeout
#  11. Smoke test       — submit a 4-member gang and verify it transitions
#                         Materializing → Reserving → Running.
#
# Defaults:
#   --kind-cluster=vgpu-test
#   --namespace=vgpu-system
#   --skip-tests=false
#   --skip-smoke=false
#   --start-at=1                 # phase to start from (1-11)
#
# Usage:
#   bash rollout_phase24a.sh
#   bash rollout_phase24a.sh --kind-cluster=mycluster --skip-tests
#   bash rollout_phase24a.sh --start-at=7        # resume from CRD-apply
# ============================================================================

set -euo pipefail

KIND_CLUSTER="vgpu-test"
NAMESPACE="vgpu-system"
SKIP_TESTS=0
SKIP_SMOKE=0
START_AT=1

for arg in "$@"; do
    case "$arg" in
        --kind-cluster=*) KIND_CLUSTER="${arg#*=}" ;;
        --namespace=*)    NAMESPACE="${arg#*=}" ;;
        --skip-tests)     SKIP_TESTS=1 ;;
        --skip-smoke)     SKIP_SMOKE=1 ;;
        --start-at=*)     START_AT="${arg#*=}" ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//' | head -40
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg '$arg'. Use --help." >&2
            exit 1
            ;;
    esac
done

C_BLU=$'\033[1;34m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_RED=$'\033[1;31m'; C_RST=$'\033[0m'

phase() {
    local n=$1 name=$2
    if [[ $START_AT -gt $n ]]; then
        echo "${C_YEL}[skip phase $n]${C_RST} $name (--start-at=$START_AT)"
        return 1
    fi
    echo
    echo "${C_BLU}═══ Phase $n: $name ═══${C_RST}"
    return 0
}

ok()    { echo "  ${C_GRN}✓${C_RST} $*"; }
warn()  { echo "  ${C_YEL}!${C_RST} $*"; }
die()   { echo "  ${C_RED}✗${C_RST} $*" >&2; exit 1; }

# ============================================================================
# Phase 1 — Pre-flight
# ============================================================================
if phase 1 "Pre-flight checks"; then
    [[ -f go.mod ]] || die "must run from repo root (no go.mod here)"
    [[ -d cmd/controller ]] || die "no cmd/controller — wrong directory?"
    [[ -f phase24a_bundle/install_phase24a_gang.sh ]] \
        || die "phase24a_bundle/ not present next to repo. Unzip phase24a_bundle.tar.gz first."

    for tool in go docker kubectl kind; do
        command -v $tool >/dev/null 2>&1 || die "$tool not on PATH"
    done
    ok "tools: go, docker, kubectl, kind"

    if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
        die "kind cluster '${KIND_CLUSTER}' does not exist. Create with: kind create cluster --name ${KIND_CLUSTER}"
    fi
    ok "kind cluster '${KIND_CLUSTER}' is up"

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        die "namespace '$NAMESPACE' missing — run 'make install' once before rollout"
    fi
    ok "namespace '$NAMESPACE' exists"
fi

# ============================================================================
# Phase 2 — Source install (idempotent — short-circuits if sentinel present)
# ============================================================================
if phase 2 "Source install (install_phase24a_gang.sh)"; then
    cp phase24a_bundle/install_phase24a_gang.sh ./install_phase24a_gang.sh
    chmod +x install_phase24a_gang.sh
    if bash install_phase24a_gang.sh; then
        ok "source install complete"
    else
        die "source install failed; backups at *.bak.<ts>"
    fi
fi

# ============================================================================
# Phase 3 — go build
# ============================================================================
if phase 3 "go build ./..."; then
    if go build ./... 2>&1; then
        ok "build clean"
    else
        die "go build failed — fix before continuing"
    fi
fi

# ============================================================================
# Phase 4 — go test (optional)
# ============================================================================
if phase 4 "go test ./..."; then
    if [[ $SKIP_TESTS -eq 1 ]]; then
        warn "skipped (--skip-tests)"
    else
        if go test ./... 2>&1 | tail -30; then
            ok "tests passed"
        else
            warn "tests reported failures — review and decide whether to continue"
            warn "(re-run with --start-at=5 to skip tests and continue)"
            exit 1
        fi
    fi
fi

# ============================================================================
# Phase 5 — Docker images
# ============================================================================
if phase 5 "Build container images"; then
    if make docker-build 2>&1 | tail -20; then
        ok "images built: vgpu-controller:latest, vgpu-scheduler:latest, vgpu-nodeagent:latest"
    else
        die "docker build failed"
    fi
fi

# ============================================================================
# Phase 6 — Kind load
# ============================================================================
if phase 6 "Load images into kind"; then
    for img in vgpu-controller:latest vgpu-scheduler:latest vgpu-nodeagent:latest; do
        if kind load docker-image "$img" --name "$KIND_CLUSTER"; then
            ok "loaded $img"
        else
            die "kind load failed for $img"
        fi
    done
fi

# ============================================================================
# Phase 7 — Apply CRDs
# ============================================================================
if phase 7 "Apply Phase 2.4a CRDs"; then
    kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangjobs.yaml
    kubectl apply -f deployments/manifests/crds/infrastructure.pranav2910.com_vgpugangreservations.yaml
    # Wait for CRDs to become Established (so subsequent kubectl gets work).
    kubectl wait --for=condition=Established \
        crd/vgpugangjobs.infrastructure.pranav2910.com \
        crd/vgpugangreservations.infrastructure.pranav2910.com \
        --timeout=30s
    ok "CRDs applied and Established"
fi

# ============================================================================
# Phase 8 — Apply RBAC
# ============================================================================
if phase 8 "Apply patched RBAC"; then
    kubectl apply -f deployments/manifests/rbac/controller_rbac.yaml
    ok "RBAC applied"
fi

# ============================================================================
# Phase 9 — Restart controller + scheduler
# ============================================================================
if phase 9 "Restart controller + scheduler"; then
    kubectl rollout restart -n "$NAMESPACE" deployment/vgpu-controller
    kubectl rollout restart -n "$NAMESPACE" deployment/vgpu-scheduler
    ok "rollout restart issued"
fi

# ============================================================================
# Phase 10 — Wait for rollout to complete
# ============================================================================
if phase 10 "Wait for rollout"; then
    kubectl rollout status -n "$NAMESPACE" deployment/vgpu-controller --timeout=120s \
        || die "vgpu-controller rollout failed"
    kubectl rollout status -n "$NAMESPACE" deployment/vgpu-scheduler  --timeout=120s \
        || die "vgpu-scheduler rollout failed"
    ok "all deployments Ready"
fi

# ============================================================================
# Phase 11 — Smoke test: submit a gang, verify Materializing → Running
# ============================================================================
if phase 11 "Smoke test (4-member gang)"; then
    if [[ $SKIP_SMOKE -eq 1 ]]; then
        warn "skipped (--skip-smoke)"
    else
        SMOKE_NS="phase24a-smoke-$(date +%s)"
        kubectl create namespace "$SMOKE_NS"

        cleanup_smoke() {
            kubectl delete namespace "$SMOKE_NS" --wait=false 2>/dev/null || true
        }
        trap cleanup_smoke EXIT

        cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata:
  name: smoke-gang
  namespace: $SMOKE_NS
spec:
  gangSize: 4
  minAvailable: 4
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 60
  podTemplate:
    spec:
      requestedVramBytes: 21474836480
      serviceTier: Guaranteed
EOF

        ok "submitted gang smoke-gang in namespace $SMOKE_NS"
        echo
        echo "  Watching for Materializing → Reserving → Running (max 90s)..."

        deadline=$(( $(date +%s) + 90 ))
        last_phase=""
        phase=""; running=""; while [[ $(date +%s) -lt $deadline ]]; do
            phase=$(kubectl get vgpugangjob smoke-gang -n "$SMOKE_NS" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            running=$(kubectl get vgpugangjob smoke-gang -n "$SMOKE_NS" \
                -o jsonpath='{.status.childrenRunning}' 2>/dev/null || echo "0")

            if [[ "$phase" != "$last_phase" ]]; then
                echo "    phase=$phase running=$running"
                last_phase="$phase"
            fi

            if [[ "$phase" == "Running" && "$running" == "4" ]]; then
                ok "smoke test PASSED — gang is Running with 4/4 children"
                echo
                echo "  ${C_GRN}Reservation observability surface:${C_RST}"
                kubectl get vgpugangreservation -n "$SMOKE_NS" smoke-gang-rsv \
                    -o yaml | sed 's/^/    /'
                echo
                cleanup_smoke
                trap - EXIT
                break
            fi

            if [[ "$phase" == "Failed" ]]; then
                echo
                warn "gang reached Failed phase. Diagnostic:"
                kubectl describe vgpugangjob smoke-gang -n "$SMOKE_NS" | sed 's/^/    /'
                kubectl get vgpugangreservation -n "$SMOKE_NS" smoke-gang-rsv \
                    -o yaml | sed 's/^/    /'
                die "smoke test FAILED — gang did not converge"
            fi

            sleep 3
        done

        if [[ "$phase" != "Running" ]]; then
            warn "timeout: gang final phase=$phase running=$running"
            kubectl describe vgpugangjob smoke-gang -n "$SMOKE_NS" | sed 's/^/    /'
            die "smoke test FAILED — gang did not reach Running within 90s"
        fi
    fi
fi

# ============================================================================
# Done
# ============================================================================
echo
echo "${C_GRN}════════════════════════════════════════════════════════════${C_RST}"
echo "${C_GRN}✅ Phase 2.4a rollout complete${C_RST}"
echo "${C_GRN}════════════════════════════════════════════════════════════${C_RST}"
echo
echo "Try a custom gang now:"
echo "  kubectl apply -f - <<EOF"
echo "  apiVersion: infrastructure.pranav2910.com/v1alpha1"
echo "  kind: VGPUGangJob"
echo "  metadata: { name: my-gang, namespace: default }"
echo "  spec:"
echo "    gangSize: 4"
echo "    minAvailable: 4"
echo "    podTemplate:"
echo "      spec: { requestedVramBytes: 21474836480 }"
echo "  EOF"
echo
echo "Inspect the reservation (your observability wedge):"
echo "  kubectl get vgpugangreservation -A"
echo "  kubectl describe vgpugangreservation <name>"
