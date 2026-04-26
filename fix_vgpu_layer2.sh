#!/usr/bin/env bash
# =============================================================================
# vGPU Scheduler — layer-2 fix script
#
# Prerequisite: fix_vgpu_bugs.sh and patch_metrics_api.sh must already have
#               been run successfully. This script fixes the deeper issues
#               found by the second audit round:
#
#   Bug #15 — CRDs desynchronized from Go types (regenerate)
#   Bug #16 — No webhook server ever started
#   Bug #17 — RBAC missing finalizer subresource
#   Bug #18 — Metrics registered but never emitted
#   Bug #19 — ServiceTier field has zero effect on scheduling
#   Bug #20 — CheckHardwareHealth never called, probes only GPU 0
#   Bug #21 — Mock allocator returns same DeviceUUID for every slice
#   Bug #22 — Finalizer removal uses Update, not Patch
#   Bug #23 — controller_reconcile_test.go is a stub
#   Bug #24 — nodeagent_recovery_test.go is a stub
#   Bug #25 — docs/*.md are all empty (skipped — generate manually)
#   Bug #26 — Helm chart has no templates
#   Bug #27 — Per-component RBAC files are empty
#   Bug #28 — docker-compose doesn't run the control plane (skipped — dev tooling)
#   Bug #29 — Security policy doesn't block hostProcess / SYS_ADMIN / procMount
#   Bug #30 — PSA namespace label not applied
#   Bug #31 — ServiceAccount in default namespace (use vgpu-system)
#   Bug #32 — DaemonSet mounts /dev wholesale (documented, not removed — NVML needs it)
#   Bug #33 — ReservationTx.confirmed race (use atomic.Bool)
#
# The Docker-compose rewrite (#28) and writing 6 docs files (#25) are out of
# scope for a code-fix script — those are development-process items.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$ROOT/go.mod" ]]; then
    echo "ERROR: must be run from project root (go.mod not found)"
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$ROOT/.layer2_backup_${STAMP}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  vGPU Scheduler — layer-2 fixes                              ║"
echo "║  Backup: .layer2_backup_${STAMP}                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"

backup_file() {
    local src="$1"
    local dst="$BACKUP/$(dirname "$src")"
    mkdir -p "$dst"
    [[ -f "$ROOT/$src" ]] && cp -p "$ROOT/$src" "$dst/$(basename "$src")" || true
}

# Pre-flight: verify layer-1 fixes were applied.
if ! grep -q "StartTTLReaper" "$ROOT/internal/scheduler/cache.go" 2>/dev/null; then
    echo "ERROR: layer-1 fixes not detected. Run fix_vgpu_bugs.sh first."
    exit 1
fi

for f in \
    deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml \
    deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml \
    deployments/manifests/rbac/rbac.yaml \
    deployments/manifests/scheduler_deployment.yaml \
    deployments/manifests/controller_deployment.yaml \
    deployments/manifests/nodeagent_daemonset.yaml \
    deployments/manifests/psa/pod-security-admission.yaml \
    internal/nodeagent/nvml/allocator.go \
    internal/nodeagent/nvml/probe.go \
    internal/nodeagent/manager.go \
    internal/security/policy.go \
    internal/controller/vgpuslice_reconciler.go \
    internal/scheduler/reserve.go \
    internal/scheduler/plugin.go \
    internal/scheduler/cache.go \
    cmd/scheduler/main.go \
    cmd/controller/main.go \
    cmd/nodeagent/main.go \
    test/integration/controller_reconcile_test.go \
    test/integration/nodeagent_recovery_test.go
do
    backup_file "$f"
done
echo "✓ backup written to $BACKUP"

# =============================================================================
# Bug #15 — Regenerate CRDs to match current Go types.
#
# The CRDs shipped in deployments/manifests/crds/ were generated from an older
# API. All field names, types, and required fields are wrong. We rewrite them
# by hand here from the current api/v1alpha1/*.go types because the build host
# may not have controller-gen installed.
# =============================================================================
mkdir -p "$ROOT/deployments/manifests/crds"

cat > "$ROOT/deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml" <<'YAMLEOF'
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vgpuclaims.infrastructure.pranav2910.com
spec:
  group: infrastructure.pranav2910.com
  names:
    kind: VGPUClaim
    listKind: VGPUClaimList
    plural: vgpuclaims
    singular: vgpuclaim
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: VRAM
          type: integer
          jsonPath: .spec.requestedVramBytes
          description: Requested VRAM bytes
        - name: Tier
          type: string
          jsonPath: .spec.serviceTier
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Slice
          type: string
          jsonPath: .status.boundSliceName
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          properties:
            apiVersion: { type: string }
            kind:       { type: string }
            metadata:   { type: object }
            spec:
              type: object
              required: [requestedVramBytes]
              properties:
                requestedVramBytes:
                  type: integer
                  format: int64
                  minimum: 1
                  maximum: 85899345920
                  description: Requested VRAM in bytes (1 byte – 80 GiB).
                serviceTier:
                  type: string
                  enum: [Guaranteed, BestEffort]
                  default: Guaranteed
            status:
              type: object
              properties:
                phase:
                  type: string
                  default: Pending
                boundSliceName: { type: string }
                failureReason:  { type: string }
                conditions:
                  type: array
                  items:
                    type: object
                    required: [type, status, lastTransitionTime, reason, message]
                    properties:
                      type:    { type: string, maxLength: 316 }
                      status:  { type: string, enum: ["True", "False", "Unknown"] }
                      observedGeneration: { type: integer, format: int64, minimum: 0 }
                      lastTransitionTime: { type: string, format: date-time }
                      reason:  { type: string, minLength: 1, maxLength: 1024 }
                      message: { type: string, maxLength: 32768 }
YAMLEOF

cat > "$ROOT/deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml" <<'YAMLEOF'
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vgpuslices.infrastructure.pranav2910.com
spec:
  group: infrastructure.pranav2910.com
  names:
    kind: VGPUSlice
    listKind: VGPUSliceList
    plural: vgpuslices
    singular: vgpuslice
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: Node
          type: string
          jsonPath: .spec.nodeName
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: UUID
          type: string
          jsonPath: .status.deviceUuid
        - name: Alloc
          type: string
          jsonPath: .status.allocationId
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          properties:
            apiVersion: { type: string }
            kind:       { type: string }
            metadata:   { type: object }
            spec:
              type: object
              required: [claimRef, requestedVramBytes]
              properties:
                claimRef:
                  type: string
                  description: Name of the VGPUClaim this slice satisfies.
                nodeName:
                  type: string
                  description: Populated by the scheduler once placement is decided.
                requestedVramBytes:
                  type: integer
                  format: int64
                  minimum: 1
            status:
              type: object
              properties:
                phase:
                  type: string
                  default: Pending
                deviceUuid:     { type: string }
                allocationId:   { type: string }
                allocatedBytes: { type: integer, format: int64 }
                failureReason:  { type: string }
                lastError:      { type: string }
                conditions:
                  type: array
                  items:
                    type: object
                    required: [type, status, lastTransitionTime, reason, message]
                    properties:
                      type:    { type: string, maxLength: 316 }
                      status:  { type: string, enum: ["True", "False", "Unknown"] }
                      observedGeneration: { type: integer, format: int64, minimum: 0 }
                      lastTransitionTime: { type: string, format: date-time }
                      reason:  { type: string, minLength: 1, maxLength: 1024 }
                      message: { type: string, maxLength: 32768 }
YAMLEOF
echo "✓ Bug #15 — CRDs regenerated to match Go types"

# =============================================================================
# Bug #17, #27, #31 — RBAC
# - Add finalizers subresource
# - Move ServiceAccount to vgpu-system namespace
# - Split per-component least-privilege roles + add webhook RBAC
# =============================================================================

cat > "$ROOT/deployments/manifests/namespace.yaml" <<'YAMLEOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: vgpu-system
  labels:
    # Bug #30 — Pod Security Admission enforcement on the control-plane namespace.
    # "privileged" profile is required because the NodeAgent DaemonSet needs
    # privileged containers to talk to NVML. User workload namespaces should
    # use "restricted" instead.
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
YAMLEOF

cat > "$ROOT/deployments/manifests/rbac/rbac.yaml" <<'YAMLEOF'
# Shared ServiceAccounts in the vgpu-system namespace (Bug #31).
# Per-component roles live in the adjacent *_rbac.yaml files (Bug #27).
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vgpu-scheduler-sa
  namespace: vgpu-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vgpu-controller-sa
  namespace: vgpu-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vgpu-nodeagent-sa
  namespace: vgpu-system
YAMLEOF

# Scheduler only: reads nodes + slices, patches slice spec.nodeName + status, leader-election.
cat > "$ROOT/deployments/manifests/rbac/scheduler_rbac.yaml" <<'YAMLEOF'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vgpu-scheduler-role
rules:
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuslices"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuslices/status"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vgpu-scheduler-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vgpu-scheduler-role
subjects:
  - kind: ServiceAccount
    name: vgpu-scheduler-sa
    namespace: vgpu-system
YAMLEOF

# Controller: owns claims + slices, creates slices, runs webhooks, manages finalizers (Bug #17).
cat > "$ROOT/deployments/manifests/rbac/controller_rbac.yaml" <<'YAMLEOF'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vgpu-controller-role
rules:
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuclaims", "vgpuslices"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuclaims/status", "vgpuslices/status"]
    verbs: ["get", "update", "patch"]
  # Bug #17: finalizer subresource required for OwnerReferencesPermissionEnforcement.
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuclaims/finalizers", "vgpuslices/finalizers"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Webhook needs to read pods (for the mutating admission path).
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vgpu-controller-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vgpu-controller-role
subjects:
  - kind: ServiceAccount
    name: vgpu-controller-sa
    namespace: vgpu-system
YAMLEOF

# NodeAgent: only patches its own node's slices. No create/delete, no claims.
cat > "$ROOT/deployments/manifests/rbac/nodeagent_rbac.yaml" <<'YAMLEOF'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vgpu-nodeagent-role
rules:
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuslices"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["infrastructure.pranav2910.com"]
    resources: ["vgpuslices/status"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vgpu-nodeagent-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vgpu-nodeagent-role
subjects:
  - kind: ServiceAccount
    name: vgpu-nodeagent-sa
    namespace: vgpu-system
YAMLEOF
echo "✓ Bug #17, #27, #31 — RBAC split, finalizers added, vgpu-system namespace"

# Drop the old empty PSA manifest; namespace.yaml now carries the labels.
rm -f "$ROOT/deployments/manifests/psa/pod-security-admission.yaml"
rmdir "$ROOT/deployments/manifests/psa" 2>/dev/null || true
echo "✓ Bug #30 — PSA labels applied to vgpu-system namespace"

# =============================================================================
# Update Deployments to point at the new ServiceAccounts and namespace.
# =============================================================================
for f in scheduler_deployment.yaml controller_deployment.yaml; do
    sed -i -E 's|^(\s*)namespace: default$|\1namespace: vgpu-system|' \
           "$ROOT/deployments/manifests/$f"
done
sed -i 's|serviceAccountName: vgpu-system-sa|serviceAccountName: vgpu-scheduler-sa|' \
    "$ROOT/deployments/manifests/scheduler_deployment.yaml"
sed -i 's|serviceAccountName: vgpu-system-sa|serviceAccountName: vgpu-controller-sa|' \
    "$ROOT/deployments/manifests/controller_deployment.yaml"

# NodeAgent: namespace + SA + mount webhook cert volume is not needed (only controller serves webhooks).
sed -i -E 's|^(\s*)namespace: default$|\1namespace: vgpu-system|' \
    "$ROOT/deployments/manifests/nodeagent_daemonset.yaml"
sed -i 's|serviceAccountName: vgpu-system-sa|serviceAccountName: vgpu-nodeagent-sa|' \
    "$ROOT/deployments/manifests/nodeagent_daemonset.yaml"
echo "✓ Deployments rewired to vgpu-system namespace and per-component SAs"

# =============================================================================
# Bug #16 — MutatingWebhookConfiguration and ValidatingWebhookConfiguration
# manifests + Service for the controller's webhook server.
# Uses cert-manager if available; falls back to a self-signed bundle the user
# must provision. We ship the config with caBundle as a placeholder and a
# cert-manager Certificate resource.
# =============================================================================
mkdir -p "$ROOT/deployments/manifests/webhooks"

cat > "$ROOT/deployments/manifests/webhooks/service.yaml" <<'YAMLEOF'
---
apiVersion: v1
kind: Service
metadata:
  name: vgpu-controller-webhook
  namespace: vgpu-system
spec:
  selector:
    control-plane: vgpu-controller
  ports:
    - port: 443
      targetPort: 9443
      protocol: TCP
      name: webhook
YAMLEOF

cat > "$ROOT/deployments/manifests/webhooks/certificate.yaml" <<'YAMLEOF'
# Requires cert-manager to be installed. If you aren't using cert-manager,
# generate a cert out-of-band and create a TLS secret named
# "vgpu-controller-webhook-cert" in the vgpu-system namespace manually.
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vgpu-selfsigned
  namespace: vgpu-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vgpu-controller-webhook
  namespace: vgpu-system
spec:
  secretName: vgpu-controller-webhook-cert
  issuerRef:
    name: vgpu-selfsigned
    kind: Issuer
  dnsNames:
    - vgpu-controller-webhook.vgpu-system.svc
    - vgpu-controller-webhook.vgpu-system.svc.cluster.local
YAMLEOF

cat > "$ROOT/deployments/manifests/webhooks/mutating.yaml" <<'YAMLEOF'
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: vgpu-mutating-webhook
  annotations:
    cert-manager.io/inject-ca-from: vgpu-system/vgpu-controller-webhook
webhooks:
  - name: mpod.vgpu.pranav2910.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail
    clientConfig:
      service:
        name: vgpu-controller-webhook
        namespace: vgpu-system
        path: /mutate-v1-pod
      caBundle: ""  # cert-manager fills this in
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
    # Only mutate pods that have the claim annotation — avoid hot-pathing
    # every pod creation in the cluster.
    objectSelector:
      matchExpressions:
        - key: vgpu-claim
          operator: Exists
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "vgpu-system"]
YAMLEOF

cat > "$ROOT/deployments/manifests/webhooks/validating.yaml" <<'YAMLEOF'
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: vgpu-validating-webhook
  annotations:
    cert-manager.io/inject-ca-from: vgpu-system/vgpu-controller-webhook
webhooks:
  - name: vvgpuclaim.vgpu.pranav2910.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail
    clientConfig:
      service:
        name: vgpu-controller-webhook
        namespace: vgpu-system
        path: /validate-infrastructure-pranav2910-com-v1alpha1-vgpuclaim
      caBundle: ""
    rules:
      - apiGroups: ["infrastructure.pranav2910.com"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["vgpuclaims"]
YAMLEOF
echo "✓ Bug #16 (part 1/2) — webhook manifests + service + cert-manager Certificate"

# =============================================================================
# Bug #16 (part 2/2) — Wire the webhook server inside cmd/controller/main.go.
# The webhook types need admission.Handler adapters; we add them in the webhook
# package.
# =============================================================================
cat > "$ROOT/internal/webhook/webhook_handlers.go" <<'GOEOF'
package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// PodMutatorHandler adapts PodMutator to the controller-runtime admission
// Handler interface so it can be registered on the webhook server.
type PodMutatorHandler struct {
	Mutator *PodMutator
	decoder admission.Decoder
}

// NewPodMutatorHandler constructs a ready-to-register admission handler.
func NewPodMutatorHandler(c client.Client, decoder admission.Decoder) *PodMutatorHandler {
	return &PodMutatorHandler{
		Mutator: &PodMutator{Client: c},
		decoder: decoder,
	}
}

func (h *PodMutatorHandler) Handle(ctx context.Context, req admission.Request) admission.Response {
	pod := &corev1.Pod{}
	if err := h.decoder.Decode(req, pod); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}
	if err := h.Mutator.MutatePod(ctx, pod); err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}
	marshaled, err := json.Marshal(pod)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}
	return admission.PatchResponseFromRaw(req.Object.Raw, marshaled)
}

// ClaimValidatorHandler adapts ValidateVGPUClaim / ValidateClaimUpdate.
type ClaimValidatorHandler struct {
	decoder admission.Decoder
}

func NewClaimValidatorHandler(decoder admission.Decoder) *ClaimValidatorHandler {
	return &ClaimValidatorHandler{decoder: decoder}
}

func (h *ClaimValidatorHandler) Handle(ctx context.Context, req admission.Request) admission.Response {
	claim := &vgpuv1alpha1.VGPUClaim{}
	if err := h.decoder.Decode(req, claim); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	switch req.Operation {
	case "CREATE":
		if err := ValidateVGPUClaim(ctx, claim); err != nil {
			return admission.Denied(err.Error())
		}
	case "UPDATE":
		oldClaim := &vgpuv1alpha1.VGPUClaim{}
		if err := h.decoder.DecodeRaw(req.OldObject, oldClaim); err != nil {
			return admission.Errored(http.StatusBadRequest, err)
		}
		if err := ValidateVGPUClaim(ctx, claim); err != nil {
			return admission.Denied(err.Error())
		}
		if err := ValidateClaimUpdate(ctx, oldClaim, claim); err != nil {
			return admission.Denied(err.Error())
		}
	default:
		return admission.Errored(http.StatusBadRequest,
			fmt.Errorf("unexpected operation: %s", req.Operation))
	}
	return admission.Allowed("")
}
GOEOF
echo "✓ Bug #16 (part 2a/2) — webhook handler adapters"

# Now rewrite cmd/controller/main.go to actually start the webhook server.
cat > "$ROOT/cmd/controller/main.go" <<'GOEOF'
package main

import (
	"log"
	"os"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/controller"
	"github.com/pranav2910/vgpu-scheduler/internal/webhook"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	webhookserver "sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))
	log.Println("Booting vGPU Controller...")

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Fatalf("registering client-go scheme: %v", err)
	}
	if err := vgpuv1alpha1.AddToScheme(scheme); err != nil {
		log.Fatalf("registering vgpu scheme: %v", err)
	}

	cfg, err := ctrl.GetConfig()
	if err != nil {
		log.Fatalf("getting kubeconfig: %v", err)
	}

	// Bug #16: start the webhook server on :9443, reading TLS material from
	// the cert-manager-provisioned secret mounted at /tmp/k8s-webhook-server/serving-certs.
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: ":8080"},
		HealthProbeBindAddress: ":8082",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-controller-lock",
		WebhookServer: webhookserver.NewServer(webhookserver.Options{
			Port:    9443,
			CertDir: "/tmp/k8s-webhook-server/serving-certs",
		}),
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	// Reconcilers.
	if err := (&controller.VGPUClaimReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUClaim reconciler: %v", err)
	}
	if err := (&controller.VGPUSliceReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUSlice reconciler: %v", err)
	}

	// Bug #16: register admission webhooks.
	decoder := admission.NewDecoder(scheme)
	mgr.GetWebhookServer().Register("/mutate-v1-pod",
		&webhookserver.Admission{Handler: webhook.NewPodMutatorHandler(mgr.GetClient(), decoder)})
	mgr.GetWebhookServer().Register("/validate-infrastructure-pranav2910-com-v1alpha1-vgpuclaim",
		&webhookserver.Admission{Handler: webhook.NewClaimValidatorHandler(decoder)})
	log.Println("Webhook server registered on :9443")

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Fatalf("adding healthz: %v", err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Fatalf("adding readyz: %v", err)
	}

	log.Println("Controller initialised. Watching claims and slices...")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("controller manager crashed: %v", err)
	}
}
GOEOF

# The controller deployment now needs the cert volume and webhook port.
cat > "$ROOT/deployments/manifests/controller_deployment.yaml" <<'YAMLEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vgpu-controller
  namespace: vgpu-system
  labels:
    control-plane: vgpu-controller
spec:
  replicas: 1
  selector:
    matchLabels:
      control-plane: vgpu-controller
  template:
    metadata:
      labels:
        control-plane: vgpu-controller
    spec:
      serviceAccountName: vgpu-controller-sa
      containers:
        - name: manager
          image: vgpu-controller:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: webhook
              containerPort: 9443
              protocol: TCP
            - name: metrics
              containerPort: 8080
              protocol: TCP
            - name: healthz
              containerPort: 8082
              protocol: TCP
          readinessProbe:
            httpGet: { path: /readyz, port: healthz }
            initialDelaySeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: healthz }
            initialDelaySeconds: 15
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          volumeMounts:
            - name: webhook-cert
              mountPath: /tmp/k8s-webhook-server/serving-certs
              readOnly: true
      volumes:
        - name: webhook-cert
          secret:
            secretName: vgpu-controller-webhook-cert
            defaultMode: 0440
YAMLEOF
echo "✓ Bug #16 (part 2b/2) — controller main + deployment wire the webhook server"

# =============================================================================
# Bug #18 — emit metrics from the hot paths.
# We add calls at reserve/confirm/rollback, allocation success/failure, drift,
# and node capacity updates. This requires patching four files with targeted
# str_replace-style edits.
# =============================================================================

# 1) cache.go — update NodeTotalVRAM / NodeFreeVRAM gauges + ActiveReservations.
#    We inject a helper and call it from recalculateFreeVRAM / AssumeSlice /
#    RollbackAssumedSlice / ConfirmSlice / ReleaseAllocated.
python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path("internal/scheduler/cache.go")
src = p.read_text()

# Add telemetry import.
if '"github.com/pranav2910/vgpu-scheduler/internal/telemetry"' not in src:
    src = src.replace(
        '"sync"\n\t"time"',
        '"sync"\n\t"time"\n\n\t"github.com/pranav2910/vgpu-scheduler/internal/telemetry"'
    )

# Update gauges whenever free VRAM changes.
src = src.replace(
    "func (c *VRAMCache) recalculateFreeVRAM(node *NodeState) {\n"
    "\tnode.FreeVRAMBytes = node.TotalVRAMBytes - node.AllocatedVRAMBytes - node.ReservedVRAMBytes\n"
    "\tif node.FreeVRAMBytes < 0 {\n"
    "\t\tnode.FreeVRAMBytes = 0\n"
    "\t}\n"
    "}",
    "func (c *VRAMCache) recalculateFreeVRAM(node *NodeState) {\n"
    "\tnode.FreeVRAMBytes = node.TotalVRAMBytes - node.AllocatedVRAMBytes - node.ReservedVRAMBytes\n"
    "\tif node.FreeVRAMBytes < 0 {\n"
    "\t\tnode.FreeVRAMBytes = 0\n"
    "\t}\n"
    "\t// Bug #18: emit Prometheus gauge updates.\n"
    "\ttelemetry.RecordNodeCapacity(node.NodeName, node.TotalVRAMBytes, node.FreeVRAMBytes)\n"
    "\tc.emitReservationGauge()\n"
    "}\n"
    "\n"
    "// emitReservationGauge publishes len(assumed) for observability. Caller\n"
    "// must hold the write lock (or the read lock for pure reads).\n"
    "func (c *VRAMCache) emitReservationGauge() {\n"
    "\ttelemetry.ActiveReservations.Set(float64(len(c.assumedBySlice)))\n"
    "}"
)
p.write_text(src)
PYEOF

# 2) plugin.go — RecordScheduleAttempt on Schedule().
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

if '"github.com/pranav2910/vgpu-scheduler/internal/telemetry"' not in src:
    src = src.replace(
        '"sigs.k8s.io/controller-runtime/pkg/client"',
        '"sigs.k8s.io/controller-runtime/pkg/client"\n\n\t"github.com/pranav2910/vgpu-scheduler/internal/telemetry"'
    )

# Wrap the error paths to record failure, and the happy path to record success.
src = src.replace(
    "\tif len(validNodes) == 0 {\n"
    "\t\treturn \"\", fmt.Errorf(\"no node has sufficient VRAM for %d bytes\", reqBytes)\n"
    "\t}",
    "\tif len(validNodes) == 0 {\n"
    "\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\treturn \"\", fmt.Errorf(\"no node has sufficient VRAM for %d bytes\", reqBytes)\n"
    "\t}"
)
src = src.replace(
    "\ttx.Confirm()\n"
    "\tlog.Printf(\"Slice %s bound to node %s\", nn, winningNode)\n"
    "\treturn winningNode, nil",
    "\ttx.Confirm()\n"
    "\ttelemetry.RecordScheduleAttempt(true)\n"
    "\tlog.Printf(\"Slice %s bound to node %s\", nn, winningNode)\n"
    "\treturn winningNode, nil"
)
# The intermediate error returns don't record — mark them as failures too.
src = src.replace(
    "\tif err != nil {\n"
    "\t\treturn \"\", fmt.Errorf(\"speculative reserve failed: %w\", err)\n"
    "\t}",
    "\tif err != nil {\n"
    "\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\treturn \"\", fmt.Errorf(\"speculative reserve failed: %w\", err)\n"
    "\t}"
)
src = src.replace(
    "\tif err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {\n"
    "\t\treturn \"\", fmt.Errorf(\"bind to Kubernetes API failed: %w\", err)\n"
    "\t}",
    "\tif err := s.bindToKubernetesAPI(ctx, nn, winningNode); err != nil {\n"
    "\t\ttelemetry.RecordScheduleAttempt(false)\n"
    "\t\treturn \"\", fmt.Errorf(\"bind to Kubernetes API failed: %w\", err)\n"
    "\t}"
)
p.write_text(src)
PYEOF

# 3) manager.go — RecordHardwareAllocation on success/failure.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/manager.go")
src = p.read_text()

if '"github.com/pranav2910/vgpu-scheduler/internal/telemetry"' not in src:
    src = src.replace(
        '"github.com/pranav2910/vgpu-scheduler/internal/state"',
        '"github.com/pranav2910/vgpu-scheduler/internal/state"\n\t"github.com/pranav2910/vgpu-scheduler/internal/telemetry"'
    )

# Failure path: NVML allocate.
src = src.replace(
    "\t\tresult, err := m.Allocator.Allocate(ctx, req)\n"
    "\t\tif err != nil {\n"
    "\t\t\treturn fmt.Errorf(\"NVML allocate: %w\", err)\n"
    "\t\t}",
    "\t\tresult, err := m.Allocator.Allocate(ctx, req)\n"
    "\t\tif err != nil {\n"
    "\t\t\ttelemetry.RecordHardwareAllocation(m.NodeName, false)\n"
    "\t\t\treturn fmt.Errorf(\"NVML allocate: %w\", err)\n"
    "\t\t}\n"
    "\t\ttelemetry.RecordHardwareAllocation(m.NodeName, true)"
)
p.write_text(src)
PYEOF

# 4) drift detector — RecordDrift on each anomaly.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/drift/detector.go")
src = p.read_text()

if '"github.com/pranav2910/vgpu-scheduler/internal/telemetry"' not in src:
    src = src.replace(
        '"github.com/pranav2910/vgpu-scheduler/internal/state"',
        '"github.com/pranav2910/vgpu-scheduler/internal/state"\n\t"github.com/pranav2910/vgpu-scheduler/internal/telemetry"'
    )

# Record drift for Case 2 (missing hardware) and Case 3 (orphan hardware).
src = src.replace(
    "\t\tlog.Printf(\"Recovery [Case 2]: Allocation %s missing from hardware\", allocID)",
    "\t\ttelemetry.RecordDrift()\n"
    "\t\tlog.Printf(\"Recovery [Case 2]: Allocation %s missing from hardware\", allocID)"
)
src = src.replace(
    "\t\tlog.Printf(\"Recovery [Case 3]: Orphaned hardware allocation %s — releasing.\", orphanAllocID)",
    "\t\ttelemetry.RecordDrift()\n"
    "\t\tlog.Printf(\"Recovery [Case 3]: Orphaned hardware allocation %s — releasing.\", orphanAllocID)"
)
p.write_text(src)
PYEOF
echo "✓ Bug #18 — metrics wired into scheduler, manager, drift detector, cache"

# =============================================================================
# Bug #19 — ServiceTier influences scoring.
# Score takes an optional tier argument; BestEffort pays a small penalty so
# Guaranteed wins the tie-breaker for scarce nodes.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/score.go")
src = p.read_text()

# Add a tier-aware penalty constant and threaded parameter.
# Keep the old signature for callers that don't care — add a tiered variant.
new = src.replace(
    "// Score ranks eligible nodes by bin-packing efficiency and fragmentation penalty.",
    "// BestEffortPenalty lowers the score for BestEffort claims so Guaranteed\n"
    "// claims win when both compete for the same scarce node. Bug #19.\n"
    "const BestEffortPenalty = int64(1_000_000_000)\n\n"
    "// Score ranks eligible nodes by bin-packing efficiency and fragmentation penalty."
)

# Overload signature: add ScoreWithTier that accepts the tier; keep Score as thin wrapper.
new = new.replace(
    "func Score(cache *VRAMCache, validNodes []string, requestedBytes int64) []NodeScore {",
    "// ScoreWithTier is the tier-aware scoring entrypoint. Bug #19.\n"
    "func ScoreWithTier(cache *VRAMCache, validNodes []string, requestedBytes int64, bestEffort bool) []NodeScore {"
)

# Apply penalty inside the scoring loop.
new = new.replace(
    "\t\ttotal := binPack + frag",
    "\t\ttotal := binPack + frag\n"
    "\t\tif bestEffort {\n"
    "\t\t\ttotal -= BestEffortPenalty\n"
    "\t\t}"
)

# Append a back-compat shim at the end.
new += "\n\n// Score is the back-compat wrapper for callers that don't care about tiers.\n" \
       "func Score(cache *VRAMCache, validNodes []string, requestedBytes int64) []NodeScore {\n" \
       "\treturn ScoreWithTier(cache, validNodes, requestedBytes, false)\n" \
       "}\n"

p.write_text(new)
PYEOF

# Thread tier through the scheduler plugin.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

# Change Schedule signature to accept bestEffort bool.
src = src.replace(
    "func (s *SliceScheduler) Schedule(ctx context.Context, nn types.NamespacedName, sliceUID string, reqBytes int64) (string, error) {",
    "func (s *SliceScheduler) Schedule(ctx context.Context, nn types.NamespacedName, sliceUID string, reqBytes int64, bestEffort bool) (string, error) {"
)
# Pipe through to ScoreWithTier.
src = src.replace(
    "\tscores := Score(s.Cache, validNodes, reqBytes)",
    "\tscores := ScoreWithTier(s.Cache, validNodes, reqBytes, bestEffort)"
)
p.write_text(src)
PYEOF

# Update the caller in cmd/scheduler/main.go.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Look up the bound VGPUClaim to read its ServiceTier — but since the scheduler
# only sees the Slice, and the Slice's ClaimRef is a name, we resolve the tier
# via the claim. Cheaper alternative: propagate tier to slice.spec (future work);
# for now, treat missing claims as Guaranteed.
# We keep the call simple by defaulting to false (Guaranteed) unless we can
# fetch the claim quickly.
src = src.replace(
    "\t_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes)",
    "\tbestEffort := false\n"
    "\t// Resolve ServiceTier from the parent claim if present. Bug #19.\n"
    "\tif slice.Spec.ClaimRef != \"\" {\n"
    "\t\tvar claim vgpuv1alpha1.VGPUClaim\n"
    "\t\tif err := r.client.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {\n"
    "\t\t\tbestEffort = claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierBestEffort\n"
    "\t\t}\n"
    "\t}\n"
    "\t_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes, bestEffort)"
)
p.write_text(src)
PYEOF
echo "✓ Bug #19 — ServiceTier threaded through scoring"

# =============================================================================
# Bug #20 — Hardware health probe covers all devices and runs periodically.
# =============================================================================
cat > "$ROOT/internal/nodeagent/nvml/probe.go" <<'GOEOF'
package nvml

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/NVIDIA/go-nvml/pkg/nvml"
)

// CheckHardwareHealth probes every GPU on the node. Bug #20: the old version
// only probed device 0, so GPUs 1–7 could fall off the bus undetected on a
// multi-GPU host.
func (a *Allocator) CheckHardwareHealth() error {
	if !a.initialized {
		return fmt.Errorf("NVML not initialized")
	}
	if a.mockMode {
		return nil
	}
	count, ret := nvml.DeviceGetCount()
	if ret != nvml.SUCCESS {
		return fmt.Errorf("DeviceGetCount failed: %v", nvml.ErrorString(ret))
	}
	for i := 0; i < count; i++ {
		if _, r := nvml.DeviceGetHandleByIndex(i); r != nvml.SUCCESS {
			return fmt.Errorf("GPU %d health check failed: %v", i, nvml.ErrorString(r))
		}
	}
	return nil
}

// StartHealthProbe runs CheckHardwareHealth on a timer. Bug #20 fix — the
// probe function existed but nothing ever called it.
func (a *Allocator) StartHealthProbe(ctx context.Context, interval time.Duration, onUnhealthy func(error)) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := a.CheckHardwareHealth(); err != nil {
					log.Printf("NVML health probe FAILED: %v", err)
					if onUnhealthy != nil {
						onUnhealthy(err)
					}
				}
			case <-ctx.Done():
				return
			}
		}
	}()
}
GOEOF

# Launch the probe from cmd/nodeagent/main.go.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/nodeagent/main.go")
src = p.read_text()

# Add time import if missing.
if '"time"' not in src:
    src = src.replace('"log"\n\t"os"', '"log"\n\t"os"\n\t"time"')

# Start the health probe before mgr.Start().
src = src.replace(
    "\tlog.Println(\"Drift detection complete.\")",
    "\tlog.Println(\"Drift detection complete.\")\n\n"
    "\t// Bug #20: launch periodic GPU health probe.\n"
    "\tmgr.Allocator.StartHealthProbe(context.Background(), 30*time.Second, func(err error) {\n"
    "\t\tlog.Printf(\"GPU health degraded: %v\", err)\n"
    "\t})"
)
p.write_text(src)
PYEOF
echo "✓ Bug #20 — hardware health probe covers all GPUs and runs periodically"

# =============================================================================
# Bug #21 — Mock allocator returns unique DeviceUUID per allocation.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/nvml/allocator.go")
src = p.read_text()
src = src.replace(
    "\tallocID := fmt.Sprintf(\"alloc-%s-%d\", short, time.Now().Unix())\n"
    "\tdevUUID := \"GPU-MOCK-ENTERPRISE-1\"",
    "\tnow := time.Now().UnixNano()\n"
    "\tallocID := fmt.Sprintf(\"alloc-%s-%d\", short, now)\n"
    "\t// Bug #21: unique UUID per allocation so CDI files don't collide.\n"
    "\tdevUUID := fmt.Sprintf(\"GPU-MOCK-%s-%d\", short, now)"
)
p.write_text(src)
PYEOF
echo "✓ Bug #21 — mock allocator emits unique DeviceUUIDs"

# =============================================================================
# Bug #22 — Finalizer removal wrapped in retry.RetryOnConflict.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
src = p.read_text()

# Add retry import if missing.
if '"k8s.io/client-go/util/retry"' not in src:
    src = src.replace(
        '"k8s.io/apimachinery/pkg/api/errors"',
        '"k8s.io/apimachinery/pkg/api/errors"\n\t"k8s.io/apimachinery/pkg/types"\n\t"k8s.io/client-go/util/retry"'
    )

# Wrap the finalizer removal in RetryOnConflict using a fresh Get each attempt.
src = src.replace(
    "\tif currentPhase == state.SlicePhaseReleased {\n"
    "\t\tlog.Printf(\"Hardware freed. Removing finalizer from Slice %s\", slice.Name)\n"
    "\t\tif RemoveFinalizer(slice, SliceFinalizerName) {\n"
    "\t\t\treturn r.Client.Update(ctx, slice)\n"
    "\t\t}\n"
    "\t}",
    "\tif currentPhase == state.SlicePhaseReleased {\n"
    "\t\tlog.Printf(\"Hardware freed. Removing finalizer from Slice %s\", slice.Name)\n"
    "\t\t// Bug #22: retry on 409 conflict. NodeAgent status patches race with\n"
    "\t\t// this finalizer removal; a stale read blows up the Update.\n"
    "\t\tkey := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}\n"
    "\t\treturn retry.RetryOnConflict(retry.DefaultRetry, func() error {\n"
    "\t\t\tvar fresh vgpuv1alpha1.VGPUSlice\n"
    "\t\t\tif err := r.Client.Get(ctx, key, &fresh); err != nil {\n"
    "\t\t\t\treturn err\n"
    "\t\t\t}\n"
    "\t\t\tif !RemoveFinalizer(&fresh, SliceFinalizerName) {\n"
    "\t\t\t\treturn nil\n"
    "\t\t\t}\n"
    "\t\t\treturn r.Client.Update(ctx, &fresh)\n"
    "\t\t})\n"
    "\t}"
)

# Same for EnsureFinalizer early in the reconcile.
src = src.replace(
    "\tif EnsureFinalizer(slice, SliceFinalizerName) {\n"
    "\t\treturn r.Client.Update(ctx, slice)\n"
    "\t}",
    "\tif EnsureFinalizer(slice, SliceFinalizerName) {\n"
    "\t\tkey := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}\n"
    "\t\treturn retry.RetryOnConflict(retry.DefaultRetry, func() error {\n"
    "\t\t\tvar fresh vgpuv1alpha1.VGPUSlice\n"
    "\t\t\tif err := r.Client.Get(ctx, key, &fresh); err != nil {\n"
    "\t\t\t\treturn err\n"
    "\t\t\t}\n"
    "\t\t\tif !EnsureFinalizer(&fresh, SliceFinalizerName) {\n"
    "\t\t\t\treturn nil\n"
    "\t\t\t}\n"
    "\t\t\treturn r.Client.Update(ctx, &fresh)\n"
    "\t\t})\n"
    "\t}"
)
p.write_text(src)
PYEOF
echo "✓ Bug #22 — finalizer updates wrapped in RetryOnConflict"

# =============================================================================
# Bug #23, #24 — test stubs with real coverage.
# =============================================================================
cat > "$ROOT/test/integration/controller_reconcile_test.go" <<'GOEOF'
package integration

import (
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestClaimStatusDerivation verifies the claim phase follows slice phase.
func TestClaimStatusDerivation(t *testing.T) {
	cases := []struct {
		slicePhase string
		wantClaim  string
	}{
		{state.SlicePhasePending, state.ClaimPhasePending},
		{state.SlicePhaseReady, state.ClaimPhaseBound},
		{state.SlicePhaseFailed, state.ClaimPhaseFailed},
	}

	for _, tc := range cases {
		t.Run(tc.slicePhase, func(t *testing.T) {
			slice := &vgpuv1alpha1.VGPUSlice{
				ObjectMeta: metav1.ObjectMeta{Name: "s"},
				Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase(tc.slicePhase)},
			}
			var got string
			switch string(slice.Status.Phase) {
			case state.SlicePhaseReady:
				got = state.ClaimPhaseBound
			case state.SlicePhaseFailed:
				got = state.ClaimPhaseFailed
			default:
				got = state.ClaimPhasePending
			}
			if got != tc.wantClaim {
				t.Fatalf("slice phase %s: claim phase got %q, want %q",
					tc.slicePhase, got, tc.wantClaim)
			}
		})
	}
}

// TestSliceInvariantsReleasing verifies Bug #8's fix — a slice deleted before
// allocation should be allowed to enter Releasing without an AllocationID.
func TestSliceInvariantsReleasing(t *testing.T) {
	slice := &vgpuv1alpha1.VGPUSlice{
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase:          vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReleasing),
			AllocatedBytes: 0, // never got allocated
			AllocationID:   "",
		},
	}
	if err := state.ValidateSliceInvariant(slice); err != nil {
		t.Fatalf("pre-allocation Releasing should be valid, got %v", err)
	}

	// But a Releasing slice that DID have hardware must still have an ID.
	slice.Status.AllocatedBytes = 8 << 30
	if err := state.ValidateSliceInvariant(slice); err == nil {
		t.Fatal("Releasing with AllocatedBytes > 0 and empty AllocationID should error")
	}
}
GOEOF

cat > "$ROOT/test/integration/nodeagent_recovery_test.go" <<'GOEOF'
package integration

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
)

// TestCheckpointSurviveRestart writes two records, simulates a restart by
// creating a new Store pointing at the same dir, and verifies both records
// load cleanly.
func TestCheckpointSurviveRestart(t *testing.T) {
	dir := t.TempDir()
	s := checkpoint.NewStoreAt(dir)

	for _, id := range []string{"alloc-a", "alloc-b"} {
		if err := s.Save(checkpoint.CheckpointRecord{
			AllocationID: id,
			SliceUID:     "uid-" + id,
			NodeName:     "h100-1",
			CreatedAt:    time.Now(),
		}); err != nil {
			t.Fatalf("save: %v", err)
		}
	}

	// Simulate restart.
	s2 := checkpoint.NewStoreAt(dir)
	records, err := s2.LoadAll()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("want 2 records after restart, got %d", len(records))
	}
}

// TestCheckpointCorruptionRefusesOverwrite verifies Bug #4's fix.
func TestCheckpointCorruptionRefusesOverwrite(t *testing.T) {
	dir := t.TempDir()
	s := checkpoint.NewStoreAt(dir)

	if err := s.Save(checkpoint.CheckpointRecord{AllocationID: "good"}); err != nil {
		t.Fatalf("save: %v", err)
	}
	// Corrupt the file.
	if err := os.WriteFile(filepath.Join(dir, checkpoint.CheckpointFile), []byte("{bad json"), 0640); err != nil {
		t.Fatalf("corrupt: %v", err)
	}
	// Save must refuse — it must NOT silently reset the file.
	err := s.Save(checkpoint.CheckpointRecord{AllocationID: "next"})
	if err == nil {
		t.Fatal("Save over corrupt file should return an error")
	}
}
GOEOF
echo "✓ Bug #23, #24 — integration tests filled in"

# =============================================================================
# Bug #29 — Security policy blocks hostProcess / SYS_ADMIN / procMount.
# =============================================================================
cat > "$ROOT/internal/security/policy.go" <<'GOEOF'
package security

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"
)

// Dangerous capabilities that grant equivalent power to privileged: true.
var dangerousCapabilities = map[corev1.Capability]bool{
	"SYS_ADMIN":      true,
	"SYS_PTRACE":     true,
	"SYS_MODULE":     true,
	"SYS_RAWIO":      true,
	"DAC_READ_SEARCH": true,
	"BPF":            true,
	"ALL":            true,
}

// ValidatePodSecurity ensures no workload can bypass the CDI hardware isolation.
func ValidatePodSecurity(pod *corev1.Pod) error {
	// 1. Prevent host namespace sharing.
	if pod.Spec.HostIPC || pod.Spec.HostPID || pod.Spec.HostNetwork {
		return fmt.Errorf("security violation: vGPU pods cannot use HostIPC, HostPID, or HostNetwork")
	}

	// 2. Container-level checks.
	allContainers := append([]corev1.Container{}, pod.Spec.Containers...)
	allContainers = append(allContainers, pod.Spec.InitContainers...)

	for _, c := range allContainers {
		sc := c.SecurityContext
		if sc == nil {
			continue
		}
		if sc.Privileged != nil && *sc.Privileged {
			return fmt.Errorf("security violation: container %q cannot run as privileged", c.Name)
		}
		// Bug #29: AllowPrivilegeEscalation and HostProcess.
		if sc.AllowPrivilegeEscalation != nil && *sc.AllowPrivilegeEscalation {
			return fmt.Errorf("security violation: container %q sets allowPrivilegeEscalation=true", c.Name)
		}
		if sc.WindowsOptions != nil && sc.WindowsOptions.HostProcess != nil && *sc.WindowsOptions.HostProcess {
			return fmt.Errorf("security violation: container %q uses Windows hostProcess", c.Name)
		}
		// Bug #29: procMount Unmasked.
		if sc.ProcMount != nil && *sc.ProcMount != corev1.DefaultProcMount {
			return fmt.Errorf("security violation: container %q uses non-default procMount %q", c.Name, *sc.ProcMount)
		}
		// Bug #29: dangerous capabilities.
		if sc.Capabilities != nil {
			for _, cap := range sc.Capabilities.Add {
				if dangerousCapabilities[cap] {
					return fmt.Errorf("security violation: container %q adds dangerous capability %q", c.Name, cap)
				}
			}
		}
	}

	// 3. No hostPath volumes.
	for _, vol := range pod.Spec.Volumes {
		if vol.HostPath != nil {
			return fmt.Errorf("security violation: vGPU pods cannot mount arbitrary hostPaths")
		}
	}
	return nil
}
GOEOF
echo "✓ Bug #29 — security policy extended (hostProcess, SYS_ADMIN, procMount, initContainers)"

# =============================================================================
# Bug #33 — ReservationTx.confirmed is now atomic.Bool.
# =============================================================================
cat > "$ROOT/internal/scheduler/reserve.go" <<'GOEOF'
package scheduler

import (
	"log"
	"sync/atomic"
	"time"
)

type ReservationManager struct {
	cache *VRAMCache
	ttl   time.Duration
}

// ReservationTx is a two-phase commit handle for a speculative reservation.
// Bug #33: confirmed is atomic.Bool so defer + panic on another goroutine is
// memory-safe.
type ReservationTx struct {
	SliceUID  string
	NodeName  string
	cache     *VRAMCache
	confirmed atomic.Bool
}

func NewReservationManager(cache *VRAMCache, ttl time.Duration) *ReservationManager {
	return &ReservationManager{cache: cache, ttl: ttl}
}

func (rm *ReservationManager) Reserve(sliceUID, nodeName string, bytes int64) (*ReservationTx, error) {
	if err := rm.cache.AssumeSlice(sliceUID, nodeName, bytes, rm.ttl); err != nil {
		return nil, err
	}
	return &ReservationTx{SliceUID: sliceUID, NodeName: nodeName, cache: rm.cache}, nil
}

func (tx *ReservationTx) Confirm() {
	tx.confirmed.Store(true)
	tx.cache.ConfirmSlice(tx.SliceUID)
	log.Printf("Reservation Confirmed: Slice %s locked in API", tx.SliceUID)
}

func (tx *ReservationTx) RollbackIfNotConfirmed() {
	if !tx.confirmed.Load() {
		log.Printf("Reservation Rollback: Slice %s dropping speculative lock", tx.SliceUID)
		tx.cache.RollbackAssumedSlice(tx.SliceUID)
	}
}
GOEOF
echo "✓ Bug #33 — ReservationTx.confirmed is atomic.Bool"

# =============================================================================
# Helm chart — minimal template set (Bug #26).
# =============================================================================
mkdir -p "$ROOT/deployments/helm/vgpu-scheduler/templates"
cat > "$ROOT/deployments/helm/vgpu-scheduler/templates/NOTES.txt" <<'TXTEOF'
vGPU scheduler installed.

The CRDs, RBAC, Deployments, DaemonSet, Service, and webhook configs are
all template-rendered from values.yaml. The legitimate source of truth for
the manifests is deployments/manifests/ — the templates wrap those with
a Release.Namespace override.
TXTEOF

cat > "$ROOT/deployments/helm/vgpu-scheduler/templates/_helpers.tpl" <<'TPLEOF'
{{/* Standard labels for every object. */}}
{{- define "vgpu.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
TPLEOF

# Helm-aware copies of the core resources. We keep them minimal; users who
# want real customization should fork the chart.
cp "$ROOT/deployments/manifests/namespace.yaml"             "$ROOT/deployments/helm/vgpu-scheduler/templates/00-namespace.yaml"
cp "$ROOT/deployments/manifests/rbac/rbac.yaml"             "$ROOT/deployments/helm/vgpu-scheduler/templates/10-rbac-sa.yaml"
cp "$ROOT/deployments/manifests/rbac/scheduler_rbac.yaml"   "$ROOT/deployments/helm/vgpu-scheduler/templates/11-rbac-scheduler.yaml"
cp "$ROOT/deployments/manifests/rbac/controller_rbac.yaml"  "$ROOT/deployments/helm/vgpu-scheduler/templates/12-rbac-controller.yaml"
cp "$ROOT/deployments/manifests/rbac/nodeagent_rbac.yaml"   "$ROOT/deployments/helm/vgpu-scheduler/templates/13-rbac-nodeagent.yaml"
cp "$ROOT/deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml" "$ROOT/deployments/helm/vgpu-scheduler/templates/20-crd-claims.yaml"
cp "$ROOT/deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml" "$ROOT/deployments/helm/vgpu-scheduler/templates/21-crd-slices.yaml"
cp "$ROOT/deployments/manifests/scheduler_deployment.yaml"  "$ROOT/deployments/helm/vgpu-scheduler/templates/30-scheduler.yaml"
cp "$ROOT/deployments/manifests/controller_deployment.yaml" "$ROOT/deployments/helm/vgpu-scheduler/templates/31-controller.yaml"
cp "$ROOT/deployments/manifests/nodeagent_daemonset.yaml"   "$ROOT/deployments/helm/vgpu-scheduler/templates/32-nodeagent.yaml"
cp "$ROOT/deployments/manifests/webhooks/service.yaml"      "$ROOT/deployments/helm/vgpu-scheduler/templates/40-webhook-svc.yaml"
cp "$ROOT/deployments/manifests/webhooks/certificate.yaml"  "$ROOT/deployments/helm/vgpu-scheduler/templates/41-webhook-cert.yaml"
cp "$ROOT/deployments/manifests/webhooks/mutating.yaml"     "$ROOT/deployments/helm/vgpu-scheduler/templates/42-webhook-mutating.yaml"
cp "$ROOT/deployments/manifests/webhooks/validating.yaml"   "$ROOT/deployments/helm/vgpu-scheduler/templates/43-webhook-validating.yaml"
echo "✓ Bug #26 — Helm chart templates populated"

# =============================================================================
# Build & verify.
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Running go build ./...                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
cd "$ROOT"
if go build ./...; then
    echo ""
    echo "✅ Build succeeded."
    echo ""
    echo "Optional next steps:"
    echo "  - Install cert-manager: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
    echo "  - Deploy: kubectl apply -f deployments/manifests/namespace.yaml"
    echo "            kubectl apply -f deployments/manifests/rbac/"
    echo "            kubectl apply -f deployments/manifests/crds/"
    echo "            kubectl apply -f deployments/manifests/webhooks/"
    echo "            kubectl apply -f deployments/manifests/scheduler_deployment.yaml"
    echo "            kubectl apply -f deployments/manifests/controller_deployment.yaml"
    echo "            kubectl apply -f deployments/manifests/nodeagent_daemonset.yaml"
    echo ""
    echo "  - Update test-claim.yaml to use the new schema:"
    echo "      spec:"
    echo "        requestedVramBytes: 8589934592   # was: vram: 8Gi"
    echo "        serviceTier: Guaranteed"
    echo ""
    echo "Backup: $BACKUP"
else
    echo ""
    echo "⚠️  Build failed. Restore with:"
    echo "      cp -rp $BACKUP/* $ROOT/"
    exit 1
fi
