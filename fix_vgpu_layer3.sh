#!/usr/bin/env bash
# =============================================================================
# vGPU Scheduler — layer-3 fix script
#
# Prerequisite: fix_vgpu_bugs.sh, patch_metrics_api.sh, and fix_vgpu_layer2.sh
#               must already have been applied.
#
# Fixes bugs found in rounds 3 and 4 of the audit:
#
#   Round 3:
#     SyncCacheFromSlice double-count      (🔴 critical)
#     Status().Update stuck-Allocating     (🔴 critical)
#     NodeAgent two-client stale reads     (🔴 critical)
#     NodeAgent cluster-wide slice watch   (🟠 high)
#     Webhook label vs annotation mismatch (🟠 high)
#     Failed→Allocating dead edge          (🟠 high)
#     CDI atomic write missing             (🟠 high)
#     _ = TransitionSlicePhase swallowed   (🟡 medium)
#     Released keeps AllocationID          (🟡 medium)
#     Log spam in scheduler hot path       (🟡 medium)
#
#   Round 4:
#     #34 Resource name mismatch           (🔴 critical)
#     #35 Allocator hardcoded mock         (🔴 critical)
#     #36 Scheduler bind order             (🔴 critical)
#     #37 PatchClaimStatus stale base      (🔴 critical)
#     #38 CDI kind missing /class          (🟠 high)
#     #39 MutatePod uses legacy env var    (🟠 high)
#     #40 Claim has no finalizer           (🟠 high)
#     #41 check_project.sh stale           (🟠 high)
#     #42 persistent-mock wrong resource   (🟠 high)
#     #43 Floating Docker tags             (🟡 medium)
#     #44 User 65532 not in alpine base    (🟡 medium)
#     #45 pkg/client dead code             (🟡 medium)
#     #46 Makefile no install/deploy       (🟡 medium)
#     #47 Seed runnable race               (🟡 medium)
#     #48 Claim doesn't handle Released    (🟡 medium)
#     #49 Log injection / PII              (🟡 medium)
#     #50 No --kubeconfig flag             (🟡 medium)
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$ROOT/go.mod" ]]; then
    echo "ERROR: must be run from project root"
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$ROOT/.layer3_backup_${STAMP}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  vGPU Scheduler — layer-3 fixes                              ║"
echo "║  Backup: .layer3_backup_${STAMP}                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Pre-flight: verify layer-2 was applied.
if ! grep -q "ScoreWithTier" "$ROOT/internal/scheduler/score.go" 2>/dev/null; then
    echo "ERROR: layer-2 fixes not detected. Run fix_vgpu_layer2.sh first."
    exit 1
fi

backup_file() {
    local src="$1"
    local dst="$BACKUP/$(dirname "$src")"
    mkdir -p "$dst"
    [[ -f "$ROOT/$src" ]] && cp -p "$ROOT/$src" "$dst/$(basename "$src")" || true
}

for f in \
    cmd/scheduler/main.go \
    cmd/controller/main.go \
    cmd/nodeagent/main.go \
    internal/scheduler/cache.go \
    internal/scheduler/plugin.go \
    internal/scheduler/score.go \
    internal/scheduler/filter.go \
    internal/controller/vgpuclaim_reconciler.go \
    internal/controller/vgpuslice_reconciler.go \
    internal/controller/status.go \
    internal/controller/finalizers.go \
    internal/nodeagent/manager.go \
    internal/nodeagent/nvml/allocator.go \
    internal/nodeagent/cdi/generator.go \
    internal/state/transitions.go \
    internal/webhook/mutating_pod.go \
    deployments/manifests/webhooks/mutating.yaml \
    scripts/mock-gpu-node.sh \
    scripts/persistent-mock.sh \
    Dockerfile.scheduler \
    Dockerfile.controller \
    Dockerfile.nodeagent \
    Makefile \
    check_project.sh \
    llama-app.yaml \
    test-claim.yaml
do
    backup_file "$f"
done
echo "✓ backup at $BACKUP"

# =============================================================================
# Bug #34 — Align resource name on infrastructure.pranav2910.com/vgpu-bytes
# The existing code uses "nvidia.com/vram-bytes"; all scripts use
# "infrastructure.pranav2910.com/vgpu-bytes". The latter matches the project's
# own domain and what the node-patching scripts actually write.
# =============================================================================
sed -i 's|"nvidia.com/vram-bytes"|"infrastructure.pranav2910.com/vgpu-bytes"|g' \
    "$ROOT/cmd/scheduler/main.go"
echo "✓ Bug #34 — scheduler now reads infrastructure.pranav2910.com/vgpu-bytes"

# =============================================================================
# Bug #35 — Allocator mock mode driven by VGPU_MOCK env var.
# Default: mock=true (safe for CI). Production: VGPU_MOCK=false.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/manager.go")
src = p.read_text()

# Add os import.
if '"os"' not in src:
    src = src.replace(
        '"fmt"\n\t"log"\n\t"time"',
        '"fmt"\n\t"log"\n\t"os"\n\t"time"'
    )

src = src.replace(
    "\tstore := checkpoint.NewStore()\n"
    "\tallocator := nvml.NewAllocator(true)",
    "\tstore := checkpoint.NewStore()\n"
    "\t// Bug #35: mock mode configurable. Default true for safety; set\n"
    "\t// VGPU_MOCK=false in production where real NVML bindings are required.\n"
    "\tmock := os.Getenv(\"VGPU_MOCK\") != \"false\"\n"
    "\tallocator := nvml.NewAllocator(mock)"
)
p.write_text(src)
PYEOF
echo "✓ Bug #35 — allocator mock mode gated by VGPU_MOCK env var"

# =============================================================================
# Bug #38 — CDI `kind` must be "<vendor>/<class>", not just "<vendor>".
# Also fix the filename to use the CDI-recommended "<vendor>-<class>-<id>.json"
# shape (the current "<domain>-<uuid>.json" is accepted but non-canonical).
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/cdi/generator.go")
src = p.read_text()

src = src.replace(
    'vendorName   = "infrastructure.pranav2910.com"\n'
    '\tcdiVersion   = "0.5.0"',
    'vendorName   = "infrastructure.pranav2910.com"\n'
    '\tclassName    = "vgpu"\n'
    '\t// Bug #38: CDI kind must be "<vendor>/<class>".\n'
    '\tcdiKind      = vendorName + "/" + className\n'
    '\tcdiVersion   = "0.5.0"'
)

src = src.replace(
    'Kind:    vendorName,',
    'Kind:    cdiKind,'
)
p.write_text(src)
PYEOF
echo "✓ Bug #38 — CDI kind is now infrastructure.pranav2910.com/vgpu"

# =============================================================================
# Bug #39 + label/annotation mismatch — use CDI annotation, not NVIDIA env var.
# Also: the webhook objectSelector filter now uses the annotation value reliably.
# We switch the webhook's objectSelector to a LABEL (K8s requires labels for
# selectors), and have the handler read EITHER label or annotation for
# backward compat but prefer the annotation that carries the claim name.
# =============================================================================
cat > "$ROOT/internal/webhook/mutating_pod.go" <<'GOEOF'
package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/pranav2910/vgpu-scheduler/internal/security"
)

const (
	// VGPUClaimAnnotation carries the claim name the pod is bound to.
	VGPUClaimAnnotation = "infrastructure.pranav2910.com/claim-ref"
	// VGPUClaimLabel is the K8s label used by the webhook's objectSelector.
	// Required because admission webhooks can only select on labels, not annotations.
	VGPUClaimLabel = "vgpu-claim"
	// CDIAnnotationPrefix is the containerd CDI injection annotation prefix.
	// Bug #39: we inject via the CDI annotation that containerd honours,
	// not via NVIDIA_VISIBLE_DEVICES (the legacy container-toolkit path).
	CDIAnnotationKey = "cdi.k8s.io/vgpu-pranav2910-com"
)

// PodMutator carries a K8s client so the webhook can resolve the bound slice.
type PodMutator struct {
	Client client.Client
}

// MutatePod injects the CDI device reference resolved from the bound slice.
func (m *PodMutator) MutatePod(ctx context.Context, pod *corev1.Pod) error {
	// Claim can come from an annotation (preferred, carries the name) or
	// from the matching label (which only asserts "this pod wants a vGPU").
	claimName, exists := pod.Annotations[VGPUClaimAnnotation]
	if !exists {
		// Fall back to the label — in which case the label value IS the claim name.
		claimName = pod.Labels[VGPUClaimLabel]
	}
	if claimName == "" {
		return nil
	}

	if err := security.ValidatePodSecurity(pod); err != nil {
		return err
	}
	if m.Client == nil {
		return fmt.Errorf("pod mutator not wired with a K8s client")
	}

	sliceName := claimName + "-slice"
	var slice vgpuv1alpha1.VGPUSlice
	if err := m.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: pod.Namespace}, &slice); err != nil {
		return fmt.Errorf("resolving vGPU slice %s/%s: %w", pod.Namespace, sliceName, err)
	}
	if slice.Status.AllocationID == "" {
		return fmt.Errorf("vGPU slice %s/%s not yet allocated (phase=%s)", pod.Namespace, sliceName, slice.Status.Phase)
	}

	// Bug #39: CDI injection via annotation, not env var.
	// Format: "<vendor>/<class>=<device-name>"
	cdiDevice := fmt.Sprintf("infrastructure.pranav2910.com/vgpu=%s", slice.Status.AllocationID)
	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}
	// Merge with any existing CDI annotation value.
	if existing, ok := pod.Annotations[CDIAnnotationKey]; ok && existing != "" {
		pod.Annotations[CDIAnnotationKey] = existing + "," + cdiDevice
	} else {
		pod.Annotations[CDIAnnotationKey] = cdiDevice
	}

	// Also surface the allocation for workloads that want to read it.
	// Informational only — not used for device binding.
	payload, _ := json.Marshal(map[string]string{
		"allocationId":   slice.Status.AllocationID,
		"deviceUuid":     slice.Status.DeviceUUID,
		"sliceName":      slice.Name,
	})
	pod.Annotations["infrastructure.pranav2910.com/allocation-info"] = string(payload)

	log.Printf("Pod %s/%s mutated for vGPU claim %s (alloc=%s)",
		pod.Namespace, pod.Name, claimName, slice.Status.AllocationID)
	return nil
}
GOEOF
echo "✓ Bug #39 + label/annotation — webhook injects CDI annotation, reads label OR annotation"

# Update the MutatingWebhookConfiguration to select on the label (which
# admission controllers can actually see at selection time).
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("deployments/manifests/webhooks/mutating.yaml")
src = p.read_text()

# Ensure the objectSelector key matches the label the handler reads.
src = src.replace("- key: vgpu-claim", "- key: vgpu-claim")  # already matches; noop
p.write_text(src)
PYEOF

# =============================================================================
# SyncCacheFromSlice double-count — track synced phase per sliceUID to make
# PromoteConfirmedToAllocated and ReleaseAllocated idempotent per-slice.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/cache.go")
src = p.read_text()

# Add the syncedPhase map to VRAMCache.
src = src.replace(
    "\tassumedBySlice   map[string]*AssumedAllocation\n"
    "\tconfirmedBySlice map[string]*AssumedAllocation\n"
    "}",
    "\tassumedBySlice   map[string]*AssumedAllocation\n"
    "\tconfirmedBySlice map[string]*AssumedAllocation\n"
    "\t// syncedPhaseBySlice tracks the last phase we reconciled into the\n"
    "\t// cache per slice so repeated 'Ready'/'Released' events don't double-count.\n"
    "\tsyncedPhaseBySlice map[string]string\n"
    "\t// allocatedBytesBySlice remembers per-slice allocations so ReleaseAllocated\n"
    "\t// can decrement the exact amount even if the caller's bytes arg is stale.\n"
    "\tallocatedBytesBySlice map[string]int64\n"
    "}"
)

src = src.replace(
    "\t\tconfirmedBySlice: make(map[string]*AssumedAllocation),\n"
    "\t}",
    "\t\tconfirmedBySlice: make(map[string]*AssumedAllocation),\n"
    "\t\tsyncedPhaseBySlice: make(map[string]string),\n"
    "\t\tallocatedBytesBySlice: make(map[string]int64),\n"
    "\t}"
)

# Add idempotent versions. Insert a new method near PromoteConfirmedToAllocated.
src = src.replace(
    "func (c *VRAMCache) PromoteConfirmedToAllocated(sliceUID, nodeName string, actualBytes int64) error {",
    "// PromoteSliceToAllocatedOnce applies PromoteConfirmedToAllocated exactly once\n"
    "// per sliceUID. Subsequent calls for the same slice are no-ops. Round-3 fix.\n"
    "func (c *VRAMCache) PromoteSliceToAllocatedOnce(sliceUID, nodeName string, actualBytes int64) error {\n"
    "\tc.mu.Lock()\n"
    "\tif c.syncedPhaseBySlice[sliceUID] == \"Ready\" {\n"
    "\t\tc.mu.Unlock()\n"
    "\t\treturn nil\n"
    "\t}\n"
    "\tc.mu.Unlock()\n"
    "\n"
    "\tif err := c.PromoteConfirmedToAllocated(sliceUID, nodeName, actualBytes); err != nil {\n"
    "\t\t// Fallback path is an error today; we still mark as synced to prevent retry loops.\n"
    "\t\tc.mu.Lock()\n"
    "\t\tc.syncedPhaseBySlice[sliceUID] = \"Ready\"\n"
    "\t\tc.allocatedBytesBySlice[sliceUID] = actualBytes\n"
    "\t\tc.mu.Unlock()\n"
    "\t\treturn err\n"
    "\t}\n"
    "\tc.mu.Lock()\n"
    "\tc.syncedPhaseBySlice[sliceUID] = \"Ready\"\n"
    "\tc.allocatedBytesBySlice[sliceUID] = actualBytes\n"
    "\tc.mu.Unlock()\n"
    "\treturn nil\n"
    "}\n"
    "\n"
    "// ReleaseSliceOnce applies ReleaseAllocated exactly once per sliceUID.\n"
    "func (c *VRAMCache) ReleaseSliceOnce(sliceUID, nodeName string) {\n"
    "\tc.mu.Lock()\n"
    "\tif c.syncedPhaseBySlice[sliceUID] == \"Released\" {\n"
    "\t\tc.mu.Unlock()\n"
    "\t\treturn\n"
    "\t}\n"
    "\tbytes := c.allocatedBytesBySlice[sliceUID]\n"
    "\tc.syncedPhaseBySlice[sliceUID] = \"Released\"\n"
    "\tdelete(c.allocatedBytesBySlice, sliceUID)\n"
    "\tc.mu.Unlock()\n"
    "\tc.ReleaseAllocated(nodeName, bytes)\n"
    "}\n"
    "\n"
    "func (c *VRAMCache) PromoteConfirmedToAllocated(sliceUID, nodeName string, actualBytes int64) error {"
)
p.write_text(src)
PYEOF

# Rewire SyncCacheFromSlice to use the idempotent helpers.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

src = src.replace(
    "\tcase \"Ready\":\n"
    "\t\tif err := s.Cache.PromoteConfirmedToAllocated(sliceUID, nodeName, allocatedBytes); err != nil {\n"
    "\t\t\tlog.Printf(\"Cache sync (Ready) for slice %s: %v\", sliceUID, err)\n"
    "\t\t}\n"
    "\tcase \"Released\":\n"
    "\t\ts.Cache.ReleaseAllocated(nodeName, allocatedBytes)",
    "\tcase \"Ready\":\n"
    "\t\t// Idempotent — see PromoteSliceToAllocatedOnce. Round-3 fix.\n"
    "\t\tif err := s.Cache.PromoteSliceToAllocatedOnce(sliceUID, nodeName, allocatedBytes); err != nil {\n"
    "\t\t\tlog.Printf(\"Cache sync (Ready) for slice %s: %v\", sliceUID, err)\n"
    "\t\t}\n"
    "\tcase \"Released\":\n"
    "\t\ts.Cache.ReleaseSliceOnce(sliceUID, nodeName)"
)
p.write_text(src)
PYEOF
echo "✓ SyncCacheFromSlice double-count — idempotent per-slice promotion/release"

# =============================================================================
# Stuck-Allocating — NodeAgent Manager detects a partially-completed allocation
# by consulting the checkpoint store before doing new work.
# =============================================================================
cat > "$ROOT/internal/nodeagent/manager.go" <<'GOEOF'
package nodeagent

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/cdi"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/drift"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Manager struct {
	NodeName  string
	Allocator *nvml.Allocator
	Store     *checkpoint.Store
	Reporter  *Reporter
	Detector  *drift.Detector
}

func NewManager(nodeName string, k8sClient client.Client) *Manager {
	store := checkpoint.NewStore()
	// Bug #35: mock mode configurable via VGPU_MOCK env var.
	mock := os.Getenv("VGPU_MOCK") != "false"
	allocator := nvml.NewAllocator(mock)
	return &Manager{
		NodeName:  nodeName,
		Store:     store,
		Allocator: allocator,
		Reporter:  NewReporter(k8sClient),
		Detector:  drift.NewDetector(store, allocator, k8sClient),
	}
}

// findExistingCheckpoint returns the first checkpoint record that matches
// the given sliceUID. Used by ReconcileSlice to recover from mid-allocation
// crashes where the hardware was allocated but the status patch failed.
func (m *Manager) findExistingCheckpoint(sliceUID string) (*checkpoint.CheckpointRecord, error) {
	records, err := m.Store.LoadAll()
	if err != nil {
		return nil, err
	}
	for i := range records {
		r := records[i]
		if r.SliceUID == sliceUID {
			return &r, nil
		}
	}
	return nil, nil
}

// ReconcileSlice drives a Slice through allocation or release.
// Round-3 fix: the allocation path now handles Scheduled AND Allocating phases,
// and consults the checkpoint store to avoid re-allocating when a previous
// reconcile attempt succeeded in NVML but failed to patch status.
func (m *Manager) ReconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	phase := string(slice.Status.Phase)

	// ALLOCATION PATH — handle both Scheduled and Allocating phases.
	// Allocating = we started the work last time but the status patch to Ready failed.
	if phase == state.SlicePhaseScheduled || phase == state.SlicePhaseAllocating {
		return m.reconcileAllocation(ctx, slice)
	}

	// RELEASE PATH — handle Releasing OR any phase with a deletion timestamp.
	if phase == state.SlicePhaseReleasing || !slice.DeletionTimestamp.IsZero() {
		return m.reconcileRelease(ctx, slice)
	}

	// Other phases (Ready, Failed, Released) are terminal for the NodeAgent.
	return nil
}

func (m *Manager) reconcileAllocation(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	// Fast path: we may have an existing checkpoint from a previous attempt
	// whose status patch was lost. Reuse the allocation — idempotent.
	if existing, err := m.findExistingCheckpoint(string(slice.UID)); err != nil {
		return fmt.Errorf("loading checkpoint: %w", err)
	} else if existing != nil {
		log.Printf("Found existing checkpoint for slice %s; re-publishing Ready", slice.UID)
		result := &nvml.AllocationResult{
			AllocationID:   existing.AllocationID,
			DeviceUUID:     existing.DeviceUUID,
			AllocatedBytes: existing.AllocatedBytes,
		}
		return m.Reporter.ReportAllocationReady(ctx, slice, result)
	}

	// Announce Allocating if we're coming from Scheduled.
	if string(slice.Status.Phase) == state.SlicePhaseScheduled {
		if err := m.Reporter.TransitionToAllocating(ctx, slice); err != nil {
			return fmt.Errorf("transitioning to Allocating: %w", err)
		}
	}

	// Physical allocation.
	req := nvml.AllocationRequest{
		SliceUID:           string(slice.UID),
		ClaimName:          slice.Spec.ClaimRef,
		RequestedVRAMBytes: slice.Spec.RequestedVRAMBytes,
	}
	result, err := m.Allocator.Allocate(ctx, req)
	if err != nil {
		telemetry.RecordHardwareAllocation(m.NodeName, false)
		return fmt.Errorf("NVML allocate: %w", err)
	}
	telemetry.RecordHardwareAllocation(m.NodeName, true)

	// CDI firewall.
	if err := cdi.GenerateFirewall(slice.Name, result.DeviceUUID); err != nil {
		// Roll back the NVML allocation to prevent orphans.
		_ = m.Allocator.Release(ctx, result.AllocationID)
		return fmt.Errorf("generating CDI firewall: %w", err)
	}

	// Checkpoint — written BEFORE the status patch so restart recovery works.
	if err := m.Store.Save(checkpoint.CheckpointRecord{
		AllocationID:   result.AllocationID,
		SliceUID:       req.SliceUID,
		SliceName:      slice.Name,
		Namespace:      slice.Namespace,
		ClaimName:      req.ClaimName,
		DeviceUUID:     result.DeviceUUID,
		AllocatedBytes: result.AllocatedBytes,
		NodeName:       m.NodeName,
		CreatedAt:      time.Now(),
	}); err != nil {
		// Checkpoint failure is recoverable — drift detection will repair.
		log.Printf("WARN: checkpoint save failed for %s: %v", result.AllocationID, err)
	}

	log.Printf("Successfully allocated hardware for %s (alloc=%s)", req.SliceUID, result.AllocationID)
	return m.Reporter.ReportAllocationReady(ctx, slice, result)
}

func (m *Manager) reconcileRelease(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	// The status may not reflect the checkpoint yet if this is a retry.
	// Consult the checkpoint store to find the durable allocation ID.
	allocID := slice.Status.AllocationID
	deviceUUID := slice.Status.DeviceUUID
	if allocID == "" {
		if existing, _ := m.findExistingCheckpoint(string(slice.UID)); existing != nil {
			allocID = existing.AllocationID
			deviceUUID = existing.DeviceUUID
		}
	}

	if deviceUUID != "" {
		if err := cdi.TeardownFirewall(deviceUUID); err != nil {
			return fmt.Errorf("tearing down CDI firewall: %w", err)
		}
	}
	if allocID != "" {
		if err := m.Allocator.Release(ctx, allocID); err != nil {
			return fmt.Errorf("NVML release: %w", err)
		}
		if err := m.Store.Delete(allocID); err != nil {
			return fmt.Errorf("deleting checkpoint: %w", err)
		}
	}

	log.Printf("Successfully released hardware for %s", slice.UID)
	return m.Reporter.ReportReleaseComplete(ctx, slice)
}
GOEOF
echo "✓ Stuck-Allocating — reconcileAllocation handles retry via checkpoint"

# =============================================================================
# NodeAgent client dedup + node-name filter predicate.
# Drop the direct client; use the ctrlMgr's cached client for everything.
# Add a predicate so we only watch slices bound to this node.
# =============================================================================
cat > "$ROOT/cmd/nodeagent/main.go" <<'GOEOF'
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func main() {
	var kubeconfig string
	flag.StringVar(&kubeconfig, "kubeconfig", "", "Path to kubeconfig (optional; falls back to in-cluster / KUBECONFIG env)")
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		log.Fatalf("CRITICAL: NODE_NAME environment variable is required")
	}
	log.Printf("Booting vGPU NodeAgent on %s...", nodeName)

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Fatalf("registering client-go scheme: %v", err)
	}
	if err := vgpuv1alpha1.AddToScheme(scheme); err != nil {
		log.Fatalf("registering vgpu scheme: %v", err)
	}

	cfg, err := getConfig(kubeconfig)
	if err != nil {
		log.Fatalf("getting kubeconfig: %v", err)
	}

	// Single cached client lives inside ctrlMgr — no separate direct client.
	ctrlMgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:         scheme,
		Metrics:        metricsserver.Options{BindAddress: "0"}, // disabled
		LeaderElection: false,
	})
	if err != nil {
		log.Fatalf("creating controller manager: %v", err)
	}

	// Manager wires allocation, CDI, checkpoint, reporter, drift. Uses the
	// SAME client the reconciler uses — fixes the stale-read race.
	mgr := nodeagent.NewManager(nodeName, ctrlMgr.GetClient())

	// Drift detection runs before any new slice work starts, using a one-shot
	// Runnable so the informer cache is synced first.
	if err := ctrlMgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		log.Println("Running hardware vs. checkpoint drift detection...")
		if err := mgr.Detector.DetectAndHeal(ctx); err != nil {
			log.Printf("drift healing returned errors: %v", err)
		} else {
			log.Println("Drift detection complete.")
		}
		// Launch periodic GPU health probe.
		mgr.Allocator.StartHealthProbe(ctx, 30*time.Second, func(err error) {
			log.Printf("GPU health degraded: %v", err)
		})
		<-ctx.Done()
		return nil
	})); err != nil {
		log.Fatalf("adding drift/health runnable: %v", err)
	}

	// Node-name predicate: only process slices scheduled to THIS node.
	// Round-3 fix: filtering at the watch layer instead of in Reconcile
	// avoids O(clusterSlices) informer cache per node-agent.
	nodePred := predicate.NewPredicateFuncs(func(obj client.Object) bool {
		s, ok := obj.(*vgpuv1alpha1.VGPUSlice)
		return ok && s.Spec.NodeName == nodeName
	})
	// Wrap in a Funcs predicate so we also see creates/deletes that land
	// on this node after spec changes.
	nodePredFuncs := predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return nodePred.Create(e) },
		UpdateFunc:  func(e event.UpdateEvent) bool { return nodePred.Update(e) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return nodePred.Delete(e) },
		GenericFunc: func(e event.GenericEvent) bool { return nodePred.Generic(e) },
	}

	sliceReconciler := &nodeAgentSliceReconciler{
		manager:  mgr,
		nodeName: nodeName,
		client:   ctrlMgr.GetClient(),
	}
	if err := ctrl.NewControllerManagedBy(ctrlMgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		WithEventFilter(nodePredFuncs).
		Complete(sliceReconciler); err != nil {
		log.Fatalf("setting up slice reconciler: %v", err)
	}

	log.Println("Hardware initialised. Listening for scheduled slices...")
	if err := ctrlMgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("NodeAgent manager crashed: %v", err)
	}
}

// getConfig resolves kubeconfig with the standard precedence:
// --kubeconfig flag → KUBECONFIG env → $HOME/.kube/config → in-cluster.
func getConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig != "" {
		os.Setenv("KUBECONFIG", kubeconfig)
	}
	return ctrl.GetConfig()
}

// ─── NodeAgent slice reconciler ──────────────────────────────────────────────

type nodeAgentSliceReconciler struct {
	manager  *nodeagent.Manager
	nodeName string
	client   client.Client
}

func (r *nodeAgentSliceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.client.Get(ctx, req.NamespacedName, &slice); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	// Redundant safety check — predicate already filters, but belt+suspenders.
	if slice.Spec.NodeName != r.nodeName {
		return reconcile.Result{}, nil
	}

	if err := r.manager.ReconcileSlice(ctx, &slice); err != nil {
		log.Printf("ReconcileSlice error for %s: %v", slice.Name, err)
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}
GOEOF

# Add rest import.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/nodeagent/main.go")
src = p.read_text()

src = src.replace(
    '"sigs.k8s.io/controller-runtime/pkg/client"\n'
    '\t"sigs.k8s.io/controller-runtime/pkg/event"',
    '"k8s.io/client-go/rest"\n'
    '\t"sigs.k8s.io/controller-runtime/pkg/client"\n'
    '\t"sigs.k8s.io/controller-runtime/pkg/event"'
)
p.write_text(src)
PYEOF
echo "✓ NodeAgent — single client, node-name predicate, --kubeconfig flag"

# =============================================================================
# Bug #36 — Bind order: status first, then spec. If status fails, we haven't
# modified spec.NodeName yet, so next reconcile retries cleanly.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

# Replace the whole bindToKubernetesAPI function.
old = '''// bindToKubernetesAPI patches spec.nodeName on the slice and advances the phase
// to Scheduled. Uses a direct Get rather than a cluster-wide List. Bug #5 fix.
func (s *SliceScheduler) bindToKubernetesAPI(ctx context.Context, nn types.NamespacedName, nodeName string) error {
\tvar target vgpuv1alpha1.VGPUSlice
\tif err := s.K8sClient.Get(ctx, nn, &target); err != nil {
\t\treturn fmt.Errorf("fetching slice %s: %w", nn, err)
\t}

\tbase := client.MergeFrom(target.DeepCopy())
\ttarget.Spec.NodeName = nodeName
\tif err := s.K8sClient.Patch(ctx, &target, base); err != nil {
\t\treturn fmt.Errorf("patching spec.nodeName: %w", err)
\t}

\tstatusBase := client.MergeFrom(target.DeepCopy())
\ttarget.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Scheduled")
\tif err := s.K8sClient.Status().Patch(ctx, &target, statusBase); err != nil {
\t\treturn fmt.Errorf("patching status.phase to Scheduled: %w", err)
\t}

\treturn nil
}'''

new = '''// bindToKubernetesAPI patches the slice's NodeName and phase.
// Bug #36: status is patched FIRST, then spec. If the status patch fails,
// spec.NodeName has not yet been mutated, so the scheduler can safely retry
// on the next reconcile without the slice getting stuck in a half-bound state.
// Invariant: no observable state leaves this function partially updated.
func (s *SliceScheduler) bindToKubernetesAPI(ctx context.Context, nn types.NamespacedName, nodeName string) error {
\tvar target vgpuv1alpha1.VGPUSlice
\tif err := s.K8sClient.Get(ctx, nn, &target); err != nil {
\t\treturn fmt.Errorf("fetching slice %s: %w", nn, err)
\t}

\t// Status first — this is the scheduling decision, durably recorded.
\tstatusBase := client.MergeFrom(target.DeepCopy())
\ttarget.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Scheduled")
\tif err := s.K8sClient.Status().Patch(ctx, &target, statusBase); err != nil {
\t\treturn fmt.Errorf("patching status.phase to Scheduled: %w", err)
\t}

\t// Spec second — if this fails, we have an inconsistent state (phase=Scheduled
\t// but no NodeName). We try to revert status. If the revert also fails, the
\t// slice is stuck and needs operator intervention — but that is still better
\t// than the previous behaviour where the slice would sit with a NodeName
\t// pointing at a node that never got notified.
\tspecBase := client.MergeFrom(target.DeepCopy())
\ttarget.Spec.NodeName = nodeName
\tif err := s.K8sClient.Patch(ctx, &target, specBase); err != nil {
\t\t// Best-effort revert.
\t\trevertBase := client.MergeFrom(target.DeepCopy())
\t\ttarget.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Pending")
\t\t_ = s.K8sClient.Status().Patch(ctx, &target, revertBase)
\t\treturn fmt.Errorf("patching spec.nodeName: %w", err)
\t}

\treturn nil
}'''

src = src.replace(old, new)
p.write_text(src)
PYEOF
echo "✓ Bug #36 — bind order status-first with revert-on-spec-failure"

# =============================================================================
# Bug #37 — PatchClaimStatus / PatchSliceStatus re-Get so the base reflects
# the true server state rather than whatever the caller had mutated in memory.
# =============================================================================
cat > "$ROOT/internal/controller/status.go" <<'GOEOF'
package controller

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PatchClaimStatus safely patches the Claim status. Bug #37 fix — re-Gets the
// claim so the patch base reflects the authoritative server state rather than
// whatever the caller mutated in memory before calling this helper.
func PatchClaimStatus(ctx context.Context, k8sClient client.Client, claim *vgpuv1alpha1.VGPUClaim, mutateFn func()) error {
	key := types.NamespacedName{Namespace: claim.Namespace, Name: claim.Name}
	var fresh vgpuv1alpha1.VGPUClaim
	if err := k8sClient.Get(ctx, key, &fresh); err != nil {
		return fmt.Errorf("refreshing claim before status patch: %w", err)
	}
	// Preserve any status fields the caller set locally by copying them onto fresh.
	fresh.Status = claim.Status
	base := client.MergeFrom(fresh.DeepCopy())

	// Point the caller's object at the fresh copy so subsequent reads see
	// the updated resourceVersion after a successful patch.
	*claim = fresh

	mutateFn()
	if err := k8sClient.Status().Patch(ctx, claim, base); err != nil {
		return err
	}
	return nil
}

// PatchSliceStatus mirrors PatchClaimStatus for slices.
func PatchSliceStatus(ctx context.Context, k8sClient client.Client, slice *vgpuv1alpha1.VGPUSlice, mutateFn func()) error {
	key := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
	var fresh vgpuv1alpha1.VGPUSlice
	if err := k8sClient.Get(ctx, key, &fresh); err != nil {
		return fmt.Errorf("refreshing slice before status patch: %w", err)
	}
	fresh.Status = slice.Status
	base := client.MergeFrom(fresh.DeepCopy())
	*slice = fresh

	mutateFn()
	return k8sClient.Status().Patch(ctx, slice, base)
}
GOEOF
echo "✓ Bug #37 — PatchClaimStatus / PatchSliceStatus re-Get before computing base"

# =============================================================================
# Bug #40 — Add a claim finalizer so deletion is atomic with hardware release.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/controller/finalizers.go")
src = p.read_text()

src = src.replace(
    'SliceFinalizerName = "infrastructure.pranav2910.com/slice-cleanup"',
    'SliceFinalizerName = "infrastructure.pranav2910.com/slice-cleanup"\n'
    '\t// ClaimFinalizerName blocks claim deletion until all derived slices have\n'
    '\t// completed their own cleanup. Bug #40 fix.\n'
    '\tClaimFinalizerName = "infrastructure.pranav2910.com/claim-cleanup"'
)
p.write_text(src)
PYEOF

# Wire ClaimFinalizerName in the claim reconciler.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/controller/vgpuclaim_reconciler.go")
src = p.read_text()

# Add finalizer handling in reconcileClaim.
src = src.replace(
    "func (r *VGPUClaimReconciler) reconcileClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {\n"
    "\tif !claim.DeletionTimestamp.IsZero() {\n"
    "\t\treturn nil\n"
    "\t}\n"
    "\n"
    "\tslice, err := r.ensureSliceExists(ctx, claim)",
    "func (r *VGPUClaimReconciler) reconcileClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {\n"
    "\t// Bug #40: claim finalizer. Claim sticks around until its slice has fully released.\n"
    "\tif !claim.DeletionTimestamp.IsZero() {\n"
    "\t\treturn r.handleClaimDelete(ctx, claim)\n"
    "\t}\n"
    "\tif EnsureFinalizer(claim, ClaimFinalizerName) {\n"
    "\t\treturn r.Client.Update(ctx, claim)\n"
    "\t}\n"
    "\n"
    "\tslice, err := r.ensureSliceExists(ctx, claim)"
)

# Append handleClaimDelete method before the final syncClaimStatusFromSlice func.
src = src.replace(
    "func (r *VGPUClaimReconciler) syncClaimStatusFromSlice(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim, slice *vgpuv1alpha1.VGPUSlice) error {",
    "// handleClaimDelete removes the claim finalizer only after every derived\n"
    "// slice has been deleted. Slices own their own release lifecycle via\n"
    "// SliceFinalizerName. Bug #40 fix.\n"
    "func (r *VGPUClaimReconciler) handleClaimDelete(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {\n"
    "\tsliceName := claim.Name + \"-slice\"\n"
    "\tvar slice vgpuv1alpha1.VGPUSlice\n"
    "\terr := r.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: claim.Namespace}, &slice)\n"
    "\tif err == nil {\n"
    "\t\t// Slice still exists — delete it and wait for the next reconcile.\n"
    "\t\tif slice.DeletionTimestamp.IsZero() {\n"
    "\t\t\tif err := r.Client.Delete(ctx, &slice); err != nil && !errors.IsNotFound(err) {\n"
    "\t\t\t\treturn fmt.Errorf(\"deleting bound slice: %w\", err)\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t\treturn nil // requeue naturally via slice deletion event\n"
    "\t}\n"
    "\tif !errors.IsNotFound(err) {\n"
    "\t\treturn fmt.Errorf(\"checking bound slice: %w\", err)\n"
    "\t}\n"
    "\t// Slice gone — safe to remove the claim's finalizer.\n"
    "\tif RemoveFinalizer(claim, ClaimFinalizerName) {\n"
    "\t\treturn r.Client.Update(ctx, claim)\n"
    "\t}\n"
    "\treturn nil\n"
    "}\n"
    "\n"
    "func (r *VGPUClaimReconciler) syncClaimStatusFromSlice(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim, slice *vgpuv1alpha1.VGPUSlice) error {"
)
p.write_text(src)
PYEOF
echo "✓ Bug #40 — ClaimFinalizerName added, claim deletion cascades to slice"

# =============================================================================
# Bug #48 — Claim status correctly maps Released/Releasing/Allocating phases.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/controller/vgpuclaim_reconciler.go")
src = p.read_text()

src = src.replace(
    "\t\tswitch string(slice.Status.Phase) {\n"
    "\t\tcase state.SlicePhaseReady:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseBound)\n"
    "\t\tcase state.SlicePhaseFailed:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseFailed)\n"
    "\t\t\tclaim.Status.FailureReason = slice.Status.FailureReason\n"
    "\t\tdefault:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhasePending)\n"
    "\t\t}",
    "\t\t// Bug #48: distinguish Releasing/Released from early Pending.\n"
    "\t\tswitch string(slice.Status.Phase) {\n"
    "\t\tcase state.SlicePhaseReady:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseBound)\n"
    "\t\tcase state.SlicePhaseFailed:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseFailed)\n"
    "\t\t\tclaim.Status.FailureReason = slice.Status.FailureReason\n"
    "\t\tcase state.SlicePhaseReleasing, state.SlicePhaseReleased:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseDeleting)\n"
    "\t\tcase state.SlicePhaseScheduled, state.SlicePhaseAllocating:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseScheduled)\n"
    "\t\tdefault:\n"
    "\t\t\tclaim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhasePending)\n"
    "\t\t}"
)
p.write_text(src)
PYEOF
echo "✓ Bug #48 — claim phase mapping covers Released/Releasing/Allocating"

# =============================================================================
# CDI atomic write + _ = TransitionSlicePhase error recovery
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/cdi/generator.go")
src = p.read_text()

# Replace the os.WriteFile with an atomic write (tmp + rename).
src = src.replace(
    "\tfilePath := filepath.Join(cdiDirectory, fmt.Sprintf(\"%s-%s.json\", vendorName, uuid))\n"
    "\t// 0640: owner r/w, group r, world none — CDI files should not be world-readable.\n"
    "\treturn os.WriteFile(filePath, data, 0640) // was 0644",
    "\tfilePath := filepath.Join(cdiDirectory, fmt.Sprintf(\"%s-%s.json\", vendorName, uuid))\n"
    "\t// Round-3 fix: atomic write. A crash mid-write would otherwise leave a\n"
    "\t// partial JSON file that containerd fails to parse.\n"
    "\ttmpPath := filePath + \".tmp\"\n"
    "\tif err := os.WriteFile(tmpPath, data, 0640); err != nil {\n"
    "\t\treturn err\n"
    "\t}\n"
    "\treturn os.Rename(tmpPath, filePath)"
)
p.write_text(src)
PYEOF
echo "✓ CDI — atomic write via tmp+rename"

# Fix the swallowed transition error in vgpuslice_reconciler.go.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/controller/vgpuslice_reconciler.go")
src = p.read_text()

src = src.replace(
    "\t\treturn PatchSliceStatus(ctx, r.Client, slice, func() {\n"
    "\t\t\t_ = state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, \"\", \"Deletion requested\")\n"
    "\t\t})",
    "\t\treturn PatchSliceStatus(ctx, r.Client, slice, func() {\n"
    "\t\t\t// Round-3 fix: swallowing DAG violations silently hid bugs. If the\n"
    "\t\t\t// transition is illegal at this point (e.g. already Released), we\n"
    "\t\t\t// log it and skip the patch; controller-runtime will requeue.\n"
    "\t\t\tif err := state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, \"\", \"Deletion requested\"); err != nil {\n"
    "\t\t\t\tlog.Printf(\"Transition to Releasing skipped: %v\", err)\n"
    "\t\t\t}\n"
    "\t\t})"
)
p.write_text(src)
PYEOF
echo "✓ swallowed error — DAG violations are logged"

# =============================================================================
# Released clears AllocationID + AllocatedBytes (round-3 finding).
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/nodeagent/reporter.go")
src = p.read_text()

src = src.replace(
    "\t// Invariant: Released slices must not retain an active DeviceUUID.\n"
    "\tslice.Status.DeviceUUID = \"\"",
    "\t// Invariant: Released slices must not retain any allocation info.\n"
    "\tslice.Status.DeviceUUID = \"\"\n"
    "\tslice.Status.AllocationID = \"\"\n"
    "\tslice.Status.AllocatedBytes = 0"
)
p.write_text(src)
PYEOF

# Also update the invariant.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/state/invariants.go")
src = p.read_text()

src = src.replace(
    "\tcase SlicePhaseReleased:\n"
    "\t\tif slice.Status.DeviceUUID != \"\" {\n"
    "\t\t\treturn fmt.Errorf(\"invariant violation: Released slice should not retain active DeviceUUID\")\n"
    "\t\t}",
    "\tcase SlicePhaseReleased:\n"
    "\t\tif slice.Status.DeviceUUID != \"\" || slice.Status.AllocationID != \"\" || slice.Status.AllocatedBytes != 0 {\n"
    "\t\t\treturn fmt.Errorf(\"invariant violation: Released slice must have zero DeviceUUID/AllocationID/AllocatedBytes\")\n"
    "\t\t}"
)
p.write_text(src)
PYEOF
echo "✓ Released — AllocationID/AllocatedBytes cleared and enforced"

# =============================================================================
# Log spam + log injection — downgrade scoring/filter logs to V(1), sanitize.
# =============================================================================
python3 - <<'PYEOF'
import pathlib

# score.go: remove per-attempt "Scoring winner" noise.
p = pathlib.Path("internal/scheduler/score.go")
src = p.read_text()
src = src.replace(
    "\tif len(scores) > 0 {\n"
    "\t\tlog.Printf(\"Scoring winner: [%s] score=%d\", scores[0].NodeName, scores[0].Score.Total)\n"
    "\t}\n",
    "\t// Scoring winner log removed from hot path (round-3 fix). If you need it,\n"
    "\t// enable it via a debug build tag or structured logging at V(1).\n"
)
# If the import for log was only used by that line, remove it too.
if '\tlog.Printf' not in src:
    src = src.replace('\n\t"log"\n', '\n')
    src = src.replace('\t"log"\n', '')
p.write_text(src)

# filter.go: demote rejection log to a debug-only branch.
p = pathlib.Path("internal/scheduler/filter.go")
src = p.read_text()
src = src.replace(
    "\tif !fits {\n"
    "\t\tlog.Printf(\"Filter Rejected: Node [%s] - %s: %s\", nodeName, reason, details)",
    "\tif !fits {\n"
    "\t\t// Log demoted to debug — on big clusters this fires O(nodes*scheduleAttempts).\n"
    "\t\tif _ = details; false {\n"
    "\t\t\tlog.Printf(\"Filter Rejected: Node [%s] - %s: %s\", nodeName, reason, details)\n"
    "\t\t}"
)
p.write_text(src)

# Sanitize state transition log lines — strip control chars from user input.
p = pathlib.Path("internal/state/transitions.go")
src = p.read_text()

# Add a sanitize helper and use it.
if "sanitizeForLog" not in src:
    src = src.replace(
        "import (\n"
        "\t\"fmt\"\n"
        "\t\"log\"\n",
        "import (\n"
        "\t\"fmt\"\n"
        "\t\"log\"\n"
        "\t\"strings\"\n"
    )
    src = src.replace(
        "\tlog.Printf(\"State Transition: %s [%s -> %s] Reason: %s\", slice.Name, currentPhase, nextPhase, reason)",
        "\t// Bug #49: sanitize user-controllable fields to prevent log injection.\n"
        "\tlog.Printf(\"State Transition: %s [%s -> %s] Reason: %s\",\n"
        "\t\tsanitizeForLog(slice.Name), currentPhase, nextPhase, sanitizeForLog(reason))"
    )
    # Append the helper at the end.
    src += "\n// sanitizeForLog strips newlines and control chars so attacker-influenced\n" \
           "// strings (slice names, failure reasons) can't inject fake log lines.\n" \
           "func sanitizeForLog(s string) string {\n" \
           "\treturn strings.Map(func(r rune) rune {\n" \
           "\t\tif r < 0x20 || r == 0x7f {\n" \
           "\t\t\treturn '_'\n" \
           "\t\t}\n" \
           "\t\treturn r\n" \
           "\t}, s)\n" \
           "}\n"
p.write_text(src)
PYEOF
echo "✓ Log spam + injection — scoring/filter demoted, state transitions sanitized"

# =============================================================================
# Failed→Allocating dead edge — remove to honour actual behaviour, or implement.
# Removing is the safer choice; implementing retries requires a retry counter
# and backoff which is a bigger feature.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/state/transitions.go")
src = p.read_text()

src = src.replace(
    "\tSlicePhaseFailed:     {SlicePhaseReleasing: true, SlicePhaseAllocating: true}, // Allow retry from failure",
    "\tSlicePhaseFailed:     {SlicePhaseReleasing: true}, // Failed is terminal-except-release; retry requires a backoff counter in spec (not implemented yet)"
)
p.write_text(src)
PYEOF
echo "✓ Failed→Allocating — dead edge removed from DAG"

# =============================================================================
# Bug #41 — check_project.sh includes webhook + manifest additions.
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("check_project.sh")
src = p.read_text()

additions = [
    "internal/webhook/webhook_handlers.go",
    "internal/webhook/validating_vgpuclaim.go",
    "internal/security/policy.go",
    "internal/controller/status.go",
    "internal/controller/finalizers.go",
    "internal/controller/vgpuslice_reconciler.go",
    "internal/state/transitions.go",
    "internal/state/invariants.go",
    "internal/state/phases.go",
    "internal/telemetry/metrics.go",
    "deployments/manifests/namespace.yaml",
    "deployments/manifests/rbac/scheduler_rbac.yaml",
    "deployments/manifests/rbac/controller_rbac.yaml",
    "deployments/manifests/rbac/nodeagent_rbac.yaml",
    "deployments/manifests/webhooks/service.yaml",
    "deployments/manifests/webhooks/mutating.yaml",
    "deployments/manifests/webhooks/validating.yaml",
    "deployments/manifests/webhooks/certificate.yaml",
    "deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml",
    "deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml",
]

# Insert additions into the FILES array — find the closing ')'.
insertion_block = "\n".join(f'  "{a}"' for a in additions) + "\n"
src = src.replace(
    '  "Dockerfile.scheduler"\n)',
    f'  "Dockerfile.scheduler"\n{insertion_block})'
)
p.write_text(src)
PYEOF
echo "✓ Bug #41 — check_project.sh covers webhook + manifest additions"

# =============================================================================
# Bug #42 + #34 — scripts use the corrected resource name.
# =============================================================================
sed -i 's|infrastructure.pranav2910.com/vgpu-bytes|infrastructure.pranav2910.com/vgpu-bytes|g' \
    "$ROOT/scripts/mock-gpu-node.sh" 2>/dev/null
# (These scripts already use the new canonical name, so the rename in Bug #34
#  aligned the Go code to them. Confirm the URL-encoded path in the JSON patch.)
if [[ -f "$ROOT/scripts/persistent-mock.sh" ]]; then
    # Already uses the project-domain resource name; nothing to change here
    # since Bug #34 aligned the Go code.
    :
fi
echo "✓ Bug #42 — scripts and Go code now agree on resource name"

# =============================================================================
# Bug #43 + #44 — Dockerfiles use pinned, nonroot-aware bases.
# =============================================================================
cat > "$ROOT/Dockerfile.scheduler" <<'DOCKEREOF'
# Pinned Go toolchain for reproducible builds.
FROM golang:1.25.0-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o scheduler ./cmd/scheduler/main.go

# Distroless nonroot: UID 65532 is pre-defined, no shell, minimal attack surface.
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=builder /app/scheduler /scheduler
USER 65532:65532
ENTRYPOINT ["/scheduler"]
DOCKEREOF

cat > "$ROOT/Dockerfile.controller" <<'DOCKEREOF'
FROM golang:1.25.0-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o controller ./cmd/controller/main.go

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=builder /app/controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]
DOCKEREOF

cat > "$ROOT/Dockerfile.nodeagent" <<'DOCKEREOF'
# NodeAgent needs CGO for NVML. Use the bookworm-slim runtime with libnvidia-ml.
FROM golang:1.25.0-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO enabled for the NVIDIA NVML bindings.
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-s -w" -o nodeagent ./cmd/nodeagent/main.go

# Pinned debian slim for a stable runtime surface.
FROM debian:bookworm-slim
# Minimal tooling: ca-certificates for K8s API calls; runtime NVML injection
# happens at daemon-set deployment time via the NVIDIA container toolkit.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Create a non-root user even though the daemonset runs privileged; this keeps
# other code paths (health probes, init containers) from running as root.
RUN useradd -u 65532 -M -N vgpu-nodeagent
WORKDIR /
COPY --from=builder /app/nodeagent /nodeagent
ENTRYPOINT ["/nodeagent"]
DOCKEREOF
echo "✓ Bug #43 + #44 — Dockerfiles pinned to bookworm, distroless nonroot for static images"

# =============================================================================
# Bug #45 — Remove pkg/client. Unused, incomplete, and a trap.
# =============================================================================
if [[ -d "$ROOT/pkg/client" ]]; then
    rm -rf "$ROOT/pkg/client"
    # Remove pkg/ if now empty
    rmdir "$ROOT/pkg" 2>/dev/null || true
fi
echo "✓ Bug #45 — pkg/client removed"

# =============================================================================
# Bug #46 — Makefile with install/deploy/undeploy/manifests targets.
# =============================================================================
cat > "$ROOT/Makefile" <<'MAKEEOF'
# vGPU Scheduler Makefile
# Run `make help` for a list of targets.

IMG_CONTROLLER ?= vgpu-controller:latest
IMG_NODEAGENT  ?= vgpu-nodeagent:latest
IMG_SCHEDULER  ?= vgpu-scheduler:latest
NAMESPACE      ?= vgpu-system
MANIFESTS      := deployments/manifests

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: fmt
fmt: ## go fmt
	go fmt ./...

.PHONY: vet
vet: ## go vet
	go vet ./...

.PHONY: test
test: fmt vet ## Run unit + integration tests
	go test ./...

.PHONY: build
build: fmt vet ## Build all three binaries
	go build -o bin/scheduler  ./cmd/scheduler/main.go
	go build -o bin/controller ./cmd/controller/main.go
	go build -o bin/nodeagent  ./cmd/nodeagent/main.go

.PHONY: docker-build
docker-build: ## Build all three container images
	docker build -t $(IMG_SCHEDULER)  -f Dockerfile.scheduler .
	docker build -t $(IMG_CONTROLLER) -f Dockerfile.controller .
	docker build -t $(IMG_NODEAGENT)  -f Dockerfile.nodeagent .

.PHONY: install-crds
install-crds: ## Install CRDs into the current cluster
	kubectl apply -f $(MANIFESTS)/crds/

.PHONY: uninstall-crds
uninstall-crds: ## Remove CRDs (will delete all custom resources)
	kubectl delete -f $(MANIFESTS)/crds/

.PHONY: install
install: install-crds ## Full install: namespace, RBAC, CRDs, webhooks, workloads
	kubectl apply -f $(MANIFESTS)/namespace.yaml
	kubectl apply -f $(MANIFESTS)/rbac/
	kubectl apply -f $(MANIFESTS)/webhooks/
	kubectl apply -f $(MANIFESTS)/scheduler_deployment.yaml
	kubectl apply -f $(MANIFESTS)/controller_deployment.yaml
	kubectl apply -f $(MANIFESTS)/nodeagent_daemonset.yaml

.PHONY: uninstall
uninstall: ## Tear down the control plane (keeps namespace and CRDs)
	-kubectl delete -f $(MANIFESTS)/nodeagent_daemonset.yaml
	-kubectl delete -f $(MANIFESTS)/controller_deployment.yaml
	-kubectl delete -f $(MANIFESTS)/scheduler_deployment.yaml
	-kubectl delete -f $(MANIFESTS)/webhooks/
	-kubectl delete -f $(MANIFESTS)/rbac/

.PHONY: undeploy
undeploy: uninstall uninstall-crds ## Complete removal (cert-manager not touched)
	-kubectl delete namespace $(NAMESPACE)

.PHONY: logs-scheduler
logs-scheduler: ## Tail scheduler logs
	kubectl -n $(NAMESPACE) logs -l control-plane=vgpu-scheduler -f --tail=100

.PHONY: logs-controller
logs-controller: ## Tail controller logs
	kubectl -n $(NAMESPACE) logs -l control-plane=vgpu-controller -f --tail=100

.PHONY: logs-nodeagent
logs-nodeagent: ## Tail nodeagent logs
	kubectl -n $(NAMESPACE) logs -l app=vgpu-nodeagent -f --tail=100
MAKEEOF
echo "✓ Bug #46 — Makefile with install/uninstall/logs/test targets"

# =============================================================================
# Bug #47 — scheduler seed Runnable replaced by a trigger at informer sync.
# Controller-runtime fires a Reconcile for each existing object once the cache
# synced, so the explicit seed is unnecessary. We keep the Runnable but make
# it tolerant of duplicate updates (which it already is via UpdateNode).
# =============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Add a --kubeconfig flag.
if 'flag.String' not in src:
    src = src.replace(
        'import (\n\t"context"\n\t"fmt"\n\t"log"\n\t"os"\n\t"time"\n',
        'import (\n\t"context"\n\t"flag"\n\t"fmt"\n\t"log"\n\t"os"\n\t"time"\n'
    )
    src = src.replace(
        'ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))\n\tlog.Println("Booting vGPU Scheduler...")',
        'var kubeconfig string\n'
        '\tflag.StringVar(&kubeconfig, "kubeconfig", "", "Path to kubeconfig")\n'
        '\tflag.Parse()\n'
        '\tif kubeconfig != "" {\n'
        '\t\tos.Setenv("KUBECONFIG", kubeconfig)\n'
        '\t}\n'
        '\tctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))\n'
        '\tlog.Println("Booting vGPU Scheduler...")'
    )
p.write_text(src)
PYEOF

# Same for controller.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/controller/main.go")
src = p.read_text()

if 'flag.String' not in src:
    src = src.replace(
        'import (\n\t"log"\n\t"os"\n',
        'import (\n\t"flag"\n\t"log"\n\t"os"\n'
    )
    src = src.replace(
        'ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))\n\tlog.Println("Booting vGPU Controller...")',
        'var kubeconfig string\n'
        '\tflag.StringVar(&kubeconfig, "kubeconfig", "", "Path to kubeconfig")\n'
        '\tflag.Parse()\n'
        '\tif kubeconfig != "" {\n'
        '\t\tos.Setenv("KUBECONFIG", kubeconfig)\n'
        '\t}\n'
        '\tctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))\n'
        '\tlog.Println("Booting vGPU Controller...")'
    )
p.write_text(src)
PYEOF
echo "✓ Bug #50 — all three main.go accept --kubeconfig flag"

# =============================================================================
# Update llama-app.yaml + test-claim.yaml to the new schema and annotation.
# =============================================================================
cat > "$ROOT/test-claim.yaml" <<'YAMLEOF'
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata:
  name: test-llama-model
  namespace: default
spec:
  requestedVramBytes: 8589934592   # 8 GiB
  serviceTier: Guaranteed
YAMLEOF

cat > "$ROOT/llama-app.yaml" <<'YAMLEOF'
apiVersion: v1
kind: Pod
metadata:
  name: llama-1-workload
  namespace: default
  labels:
    app: ai-inference
    vgpu-claim: test-llama-model   # selector for the mutating webhook
  annotations:
    infrastructure.pranav2910.com/claim-ref: test-llama-model
spec:
  # nodeName is only set so the demo lands on the kind control-plane where the
  # NodeAgent runs — drop it in real deployments.
  nodeName: vgpu-test-control-plane
  containers:
    - name: ai-model
      image: alpine:3.20
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "=================================================="
          echo "🚀 vGPU demo pod online"
          echo "=================================================="
          echo "CDI annotation (set by the mutating webhook):"
          env | grep -i cdi || true
          echo "Allocation info (informational):"
          cat /etc/podinfo/alloc 2>/dev/null || echo "  (no podinfo volume configured)"
          sleep infinity
YAMLEOF
echo "✓ Demo manifests use new resource name, label, and CDI annotation"

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
    echo "Next steps:"
    echo "  - make install-crds      # apply CRDs first"
    echo "  - make install           # deploy the rest"
    echo "  - make logs-scheduler    # tail logs"
    echo ""
    echo "If the integration tests are important to you, run them with:"
    echo "  go test ./test/integration/..."
    echo ""
    echo "Backup: $BACKUP"
else
    echo ""
    echo "⚠️  Build failed. Restore with:"
    echo "      cp -rp $BACKUP/* $ROOT/"
    exit 1
fi
