#!/usr/bin/env bash
# fix_vgpu_runtime_wiring.sh
# Fixes the remaining runtime-wiring gap:
#   1. Define SliceScheduler struct + NewSliceScheduler + bindToKubernetesAPI
#   2. Update reconciler signatures to satisfy reconcile.Reconciler interface
#   3. Add SetupWithManager to both reconcilers
#   4. Wire cmd/controller/main.go with real ctrl.NewControllerManagedBy calls
#   5. Wire cmd/scheduler/main.go with a real Pending-slice watch reconciler
#   6. Wire cmd/nodeagent/main.go with a real controller-runtime client + slice watch
#
# Run from the project root: bash fix_vgpu_runtime_wiring.sh
# Run fix_vgpu_scheduler.sh first if you haven't already.

set -euo pipefail

if [[ ! -f "go.mod" ]]; then
  echo "ERROR: Run from the vgpu-scheduler project root (where go.mod lives)."
  exit 1
fi

BACKUP_DIR=".fix_runtime_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local dest="$BACKUP_DIR/$f"
    mkdir -p "$(dirname "$dest")"
    cp "$f" "$dest"
  fi
}

echo "==> Backing up files to $BACKUP_DIR"
FILES_TO_TOUCH=(
  "internal/scheduler/plugin.go"
  "internal/controller/vgpuclaim_reconciler.go"
  "internal/controller/vgpuslice_reconciler.go"
  "cmd/controller/main.go"
  "cmd/scheduler/main.go"
  "cmd/nodeagent/main.go"
)
for f in "${FILES_TO_TOUCH[@]}"; do backup "$f"; done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> FIX A: internal/scheduler/plugin.go"
echo "    - Define SliceScheduler struct (was missing entirely)"
echo "    - Add NewSliceScheduler constructor"
echo "    - Add bindToKubernetesAPI (writes spec.nodeName to the Slice)"
echo "    - Keep existing Schedule() method intact"
# ─────────────────────────────────────────────────────────────────────────────
cat > internal/scheduler/plugin.go << 'EOF'
package scheduler

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// SliceScheduler is the stateful scheduling engine. It owns the in-memory
// VRAM cache and issues bind decisions to the Kubernetes API.
type SliceScheduler struct {
	Cache     *VRAMCache
	Reserver  *ReservationManager
	K8sClient client.Client
}

// NewSliceScheduler wires a cache, a reservation manager, and a K8s write client.
func NewSliceScheduler(cache *VRAMCache, k8sClient client.Client) *SliceScheduler {
	return &SliceScheduler{
		Cache:    cache,
		Reserver: NewReservationManager(cache, 30*time.Second),
		K8sClient: k8sClient,
	}
}

// Schedule runs one full scheduling cycle for a pending VGPUSlice.
// It filters nodes, scores them, speculatively reserves VRAM, and binds the
// winning node to the slice via the Kubernetes API.
func (s *SliceScheduler) Schedule(ctx context.Context, sliceUID string, reqBytes int64) (string, error) {
	log.Printf("Scheduling cycle started for Slice %s (req: %d bytes)", sliceUID, reqBytes)

	var validNodes []string
	for _, node := range s.Cache.ListNodes() {
		fits, _, _ := s.Cache.CanFit(node, reqBytes)
		if fits {
			validNodes = append(validNodes, node)
		}
	}

	if len(validNodes) == 0 {
		return "", fmt.Errorf("no node has sufficient VRAM for %d bytes", reqBytes)
	}

	scores := Score(s.Cache, validNodes, reqBytes)
	if len(scores) == 0 {
		return "", fmt.Errorf("scoring returned 0 candidates despite passing filter — cache inconsistency")
	}

	winningNode := scores[0].NodeName

	// Speculatively lock the VRAM. The defer guarantees rollback if anything
	// after this point fails before tx.Confirm() is called.
	tx, err := s.Reserver.Reserve(sliceUID, winningNode, reqBytes)
	if err != nil {
		return "", fmt.Errorf("speculative reserve failed: %w", err)
	}
	defer tx.RollbackIfNotConfirmed()

	// Write the binding to the Kubernetes API. This is the point of no return.
	if err := s.bindToKubernetesAPI(ctx, sliceUID, winningNode); err != nil {
		return "", fmt.Errorf("bind to Kubernetes API failed: %w", err)
	}

	tx.Confirm()
	log.Printf("Slice %s bound to node %s", sliceUID, winningNode)
	return winningNode, nil
}

// bindToKubernetesAPI patches spec.nodeName on the VGPUSlice so the NodeAgent
// on the winning node knows to start hardware allocation. It also transitions
// the phase to Scheduled via a status patch.
func (s *SliceScheduler) bindToKubernetesAPI(ctx context.Context, sliceUID, nodeName string) error {
	// Locate the slice by UID — list and filter since K8s Get requires a name.
	var sliceList vgpuv1alpha1.VGPUSliceList
	if err := s.K8sClient.List(ctx, &sliceList); err != nil {
		return fmt.Errorf("listing slices: %w", err)
	}

	var target *vgpuv1alpha1.VGPUSlice
	for i := range sliceList.Items {
		if string(sliceList.Items[i].UID) == sliceUID {
			target = &sliceList.Items[i]
			break
		}
	}
	if target == nil {
		return fmt.Errorf("slice UID %s not found in API — may have been deleted", sliceUID)
	}

	// 1. Spec patch — set nodeName (triggers NodeAgent watch).
	base := client.MergeFrom(target.DeepCopy())
	target.Spec.NodeName = nodeName
	if err := s.K8sClient.Patch(ctx, target, base); err != nil {
		return fmt.Errorf("patching spec.nodeName: %w", err)
	}

	// 2. Status patch — advance phase to Scheduled.
	statusBase := client.MergeFrom(target.DeepCopy())
	target.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Scheduled")
	if err := s.K8sClient.Status().Patch(ctx, target, statusBase); err != nil {
		return fmt.Errorf("patching status.phase to Scheduled: %w", err)
	}

	return nil
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> FIX B: internal/controller/vgpuclaim_reconciler.go"
echo "    - Implement reconcile.Reconciler interface (ctx, reconcile.Request) → (Result, error)"
echo "    - Add SetupWithManager for clean controller-manager registration"
echo "    - Complete ensureSliceExists: query K8s before creating to stay idempotent"
# ─────────────────────────────────────────────────────────────────────────────
cat > internal/controller/vgpuclaim_reconciler.go << 'EOF'
package controller

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type VGPUClaimReconciler struct {
	Client client.Client
}

// SetupWithManager registers this reconciler with the controller-manager so it
// receives reconcile events every time a VGPUClaim is created, updated, or deleted.
func (r *VGPUClaimReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUClaim{}).
		Complete(r)
}

// Reconcile satisfies reconcile.Reconciler. It is called by controller-runtime
// whenever a VGPUClaim changes. The Request carries the namespaced name of the
// object that changed — we fetch the latest version from the API before acting.
func (r *VGPUClaimReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, req.NamespacedName, &claim); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil // claim already deleted — nothing to do
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUClaim: %w", err)
	}

	if err := r.reconcileClaim(ctx, &claim); err != nil {
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}

// reconcileClaim contains the actual business logic, accepting a fully populated object.
func (r *VGPUClaimReconciler) reconcileClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {
	// If the Claim is being deleted, the Slice reconciler handles cleanup.
	if !claim.DeletionTimestamp.IsZero() {
		return nil
	}

	// Ensure exactly one VGPUSlice exists for this Claim.
	slice, err := r.ensureSliceExists(ctx, claim)
	if err != nil {
		return fmt.Errorf("ensuring slice exists: %w", err)
	}

	// Mirror the Slice's observed state back to the Claim's status.
	return r.syncClaimStatusFromSlice(ctx, claim, slice)
}

// ensureSliceExists is idempotent: it returns the existing Slice if one already
// exists, or creates a new one if not.
func (r *VGPUClaimReconciler) ensureSliceExists(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) (*vgpuv1alpha1.VGPUSlice, error) {
	sliceName := claim.Name + "-slice"

	// Check whether the slice already exists.
	var existing vgpuv1alpha1.VGPUSlice
	err := r.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: claim.Namespace}, &existing)
	if err == nil {
		return &existing, nil // already exists — return it
	}
	if !errors.IsNotFound(err) {
		return nil, fmt.Errorf("fetching existing slice: %w", err)
	}

	// Slice does not exist — create it.
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:      sliceName,
			Namespace: claim.Namespace,
			// Set the Claim as the owner so Kubernetes garbage-collects the Slice
			// automatically if the Claim is force-deleted without our finalizer.
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion: vgpuv1alpha1.GroupVersion.String(),
					Kind:       "VGPUClaim",
					Name:       claim.Name,
					UID:        claim.UID,
				},
			},
		},
		Spec: vgpuv1alpha1.VGPUSliceSpec{
			ClaimRef:           claim.Name,
			RequestedVRAMBytes: claim.Spec.RequestedVRAMBytes,
		},
	}

	if err := r.Client.Create(ctx, slice); err != nil {
		return nil, fmt.Errorf("creating VGPUSlice: %w", err)
	}
	return slice, nil
}

// syncClaimStatusFromSlice maps the Slice's system phase to the user-visible Claim phase.
func (r *VGPUClaimReconciler) syncClaimStatusFromSlice(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim, slice *vgpuv1alpha1.VGPUSlice) error {
	return PatchClaimStatus(ctx, r.Client, claim, func() {
		claim.Status.BoundSliceName = slice.Name

		switch string(slice.Status.Phase) {
		case state.SlicePhaseReady:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseBound)
		case state.SlicePhaseFailed:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseFailed)
			claim.Status.FailureReason = slice.Status.FailureReason
		default:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhasePending)
		}
	})
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> FIX C: internal/controller/vgpuslice_reconciler.go"
echo "    - Implement reconcile.Reconciler interface"
echo "    - Add SetupWithManager"
echo "    - Fix string(phase) comparisons in handleDelete"
# ─────────────────────────────────────────────────────────────────────────────
cat > internal/controller/vgpuslice_reconciler.go << 'EOF'
package controller

import (
	"context"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type VGPUSliceReconciler struct {
	Client client.Client
}

// SetupWithManager registers this reconciler with the controller-manager.
func (r *VGPUSliceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(r)
}

// Reconcile satisfies reconcile.Reconciler.
func (r *VGPUSliceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.Client.Get(ctx, req.NamespacedName, &slice); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUSlice: %w", err)
	}

	if err := r.reconcileSlice(ctx, &slice); err != nil {
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}

func (r *VGPUSliceReconciler) reconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	// DELETION PATH — handle finalizer and signal NodeAgent.
	if !slice.DeletionTimestamp.IsZero() {
		return r.handleDelete(ctx, slice)
	}

	// CREATION PATH — add our finalizer so Kubernetes cannot GC the object
	// before the NodeAgent has freed the hardware.
	if EnsureFinalizer(slice, SliceFinalizerName) {
		return r.Client.Update(ctx, slice)
	}

	// All other state transitions are owned by the Scheduler and NodeAgent;
	// the controller only watches and reacts to what they report.
	return nil
}

func (r *VGPUSliceReconciler) handleDelete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	log.Printf("Deletion triggered for Slice %s", slice.Name)

	currentPhase := string(slice.Status.Phase)

	// Step A: If the NodeAgent hasn't started teardown yet, request it by
	// transitioning the phase. The NodeAgent watches for Releasing and acts.
	if currentPhase != state.SlicePhaseReleasing && currentPhase != state.SlicePhaseReleased {
		patchErr := PatchSliceStatus(ctx, r.Client, slice, func() {
			_ = state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "", "Deletion requested")
		})
		if patchErr != nil {
			return patchErr
		}
		// Return a sentinel error so controller-runtime requeues this object.
		// We will re-enter here after the NodeAgent updates the phase to Released.
		return fmt.Errorf("requeue: waiting for NodeAgent to confirm hardware release")
	}

	// Step B: NodeAgent confirmed the hardware is freed — remove our finalizer
	// so Kubernetes can proceed with object deletion.
	if currentPhase == state.SlicePhaseReleased {
		log.Printf("Hardware freed. Removing finalizer from Slice %s", slice.Name)
		if RemoveFinalizer(slice, SliceFinalizerName) {
			return r.Client.Update(ctx, slice)
		}
	}

	return nil
}

// Ensure VGPUSliceReconciler satisfies the interface at compile time.
var _ reconcile.Reconciler = &VGPUSliceReconciler{}

// Ensure VGPUClaimReconciler satisfies the interface at compile time.
var _ reconcile.Reconciler = &VGPUClaimReconciler{}
EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> FIX D: cmd/controller/main.go"
echo "    - Replace dead-code reconciler creation with SetupWithManager calls"
echo "    - Register scheme, add health checks"
# ─────────────────────────────────────────────────────────────────────────────
cat > cmd/controller/main.go << 'EOF'
package main

import (
	"log"
	"os"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/controller"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func main() {
	// Use structured zap logging so controller-runtime's internal events are
	// captured alongside our log lines.
	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))

	log.Println("Booting vGPU Controller Manager...")

	// Register our CRD types plus the core k8s types the controller touches.
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

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		MetricsBindAddress:     ":8083",
		HealthProbeBindAddress: ":8084",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-controller-lock",
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	// Wire the VGPUClaim reconciler — watches VGPUClaim objects and ensures a
	// matching VGPUSlice exists for each one, mirroring slice state back to the
	// claim status.
	if err := (&controller.VGPUClaimReconciler{
		Client: mgr.GetClient(),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUClaim reconciler: %v", err)
	}

	// Wire the VGPUSlice reconciler — manages finalizers and orchestrates the
	// deletion lifecycle (signalling the NodeAgent, waiting for Released phase,
	// then removing the finalizer).
	if err := (&controller.VGPUSliceReconciler{
		Client: mgr.GetClient(),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUSlice reconciler: %v", err)
	}

	// Liveness/readiness probes for Kubernetes health checks.
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Fatalf("adding healthz check: %v", err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Fatalf("adding readyz check: %v", err)
	}

	log.Println("Controllers registered. Starting manager...")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("controller manager crashed: %v", err)
	}
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> FIX E: cmd/scheduler/main.go"
echo "    - Wire a real SliceReconciler that watches Pending VGPUSlices and calls Schedule"
echo "    - Seed the VRAMCache from live Node objects on startup"
echo "    - Add health checks"
# ─────────────────────────────────────────────────────────────────────────────
cat > cmd/scheduler/main.go << 'EOF'
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
	_ "github.com/pranav2910/vgpu-scheduler/internal/telemetry" // init Prometheus metrics
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// vramResourceName is the extended resource key that GPU nodes advertise.
// Adjust this to match whatever the device-plugin reports on your cluster.
const vramResourceName corev1.ResourceName = "nvidia.com/vram-bytes"

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))

	log.Println("Booting vGPU Scheduler...")

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

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		MetricsBindAddress:     ":8081",
		HealthProbeBindAddress: ":8082",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-scheduler-lock",
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	// Build the scheduling engine — needs the client for bind calls.
	cache := scheduler.NewVRAMCache()
	sched := scheduler.NewSliceScheduler(cache, mgr.GetClient())

	// Seed the cache from live Node objects so the scheduler has real capacity
	// data before the first reconcile event fires.
	if err := seedCacheFromNodes(context.Background(), mgr.GetClient(), cache); err != nil {
		log.Printf("WARNING: could not seed node cache on startup: %v", err)
		// Not fatal — the cache will populate as Nodes reconcile.
	}

	// Wire the slice scheduling reconciler. It watches for Pending VGPUSlices
	// (spec.nodeName == "") and drives them through one scheduling cycle.
	if err := ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(&sliceSchedulingReconciler{sched: sched, client: mgr.GetClient()}); err != nil {
		log.Fatalf("setting up slice scheduling reconciler: %v", err)
	}

	// Wire a node-watch reconciler to keep the VRAM cache current as nodes
	// join, leave, or have their capacity changed by the device-plugin.
	if err := ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Node{}).
		Complete(&nodeCapacityReconciler{cache: cache, client: mgr.GetClient()}); err != nil {
		log.Fatalf("setting up node capacity reconciler: %v", err)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Fatalf("adding healthz check: %v", err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Fatalf("adding readyz check: %v", err)
	}

	log.Println("Scheduler initialised. Listening for Pending slices...")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("scheduler manager crashed: %v", err)
	}
}

// ─── Slice scheduling reconciler ─────────────────────────────────────────────

// sliceSchedulingReconciler watches VGPUSlices. When it finds one that is
// Pending and has no node assignment yet, it drives it through a single
// scheduling cycle. Slices in any other phase (being handled by the NodeAgent
// or controller) are ignored.
type sliceSchedulingReconciler struct {
	sched  *scheduler.SliceScheduler
	client client.Client
}

func (r *sliceSchedulingReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.client.Get(ctx, req.NamespacedName, &slice); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	// Only act on Pending slices with no node assigned yet.
	phase := string(slice.Status.Phase)
	if phase != "" && phase != "Pending" {
		return reconcile.Result{}, nil
	}
	if slice.Spec.NodeName != "" {
		return reconcile.Result{}, nil // already bound
	}

	_, err := r.sched.Schedule(ctx, string(slice.UID), slice.Spec.RequestedVRAMBytes)
	if err != nil {
		// Log the failure but do not propagate — controller-runtime would
		// requeue indefinitely. Instead, return nil and let the next Slice
		// change event (e.g. NodeAgent reporting capacity) trigger a re-check.
		log.Printf("Scheduling failed for Slice %s/%s: %v", slice.Namespace, slice.Name, err)
		return reconcile.Result{}, nil
	}
	return reconcile.Result{}, nil
}

// ─── Node capacity reconciler ────────────────────────────────────────────────

// nodeCapacityReconciler keeps the in-memory VRAMCache consistent with the
// live set of GPU-capable Nodes reported by the device-plugin.
type nodeCapacityReconciler struct {
	cache  *scheduler.VRAMCache
	client client.Client
}

func (r *nodeCapacityReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var node corev1.Node
	if err := r.client.Get(ctx, req.NamespacedName, &node); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	totalVRAM, ok := node.Status.Capacity[vramResourceName]
	if !ok {
		// Node has no VRAM resource — not a GPU node; skip.
		return reconcile.Result{}, nil
	}

	allocatedVRAM := allocatedVRAMOnNode(&node)
	r.cache.UpdateNode(node.Name, totalVRAM.Value(), allocatedVRAM)
	log.Printf("Cache updated: node %s total=%d allocated=%d", node.Name, totalVRAM.Value(), allocatedVRAM)
	return reconcile.Result{}, nil
}

// allocatedVRAMOnNode sums the allocatable VRAM already consumed by workloads
// using the extended resource on this node.
func allocatedVRAMOnNode(node *corev1.Node) int64 {
	allocated := node.Status.Allocatable[vramResourceName]
	total := node.Status.Capacity[vramResourceName]
	free := allocated.Value()
	used := total.Value() - free
	if used < 0 {
		return 0
	}
	return used
}

// seedCacheFromNodes pre-populates the VRAM cache at startup by listing all
// Nodes and calling UpdateNode for any that advertise the VRAM resource.
func seedCacheFromNodes(ctx context.Context, k8sClient client.Client, cache *scheduler.VRAMCache) error {
	var nodeList corev1.NodeList
	if err := k8sClient.List(ctx, &nodeList); err != nil {
		return fmt.Errorf("listing nodes: %w", err)
	}

	for i := range nodeList.Items {
		node := &nodeList.Items[i]
		totalVRAM, ok := node.Status.Capacity[vramResourceName]
		if !ok {
			continue
		}
		allocatedVRAM := allocatedVRAMOnNode(node)
		cache.UpdateNode(node.Name, totalVRAM.Value(), allocatedVRAM)
		log.Printf("Seeded cache: node %s total=%d allocated=%d",
			node.Name, totalVRAM.Value(), allocatedVRAM)
	}

	// Suppress unused import in case resource.Quantity methods aren't called elsewhere.
	_ = resource.MustParse("0")
	return nil
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> FIX F: cmd/nodeagent/main.go"
echo "    - Build a real controller-runtime client"
echo "    - Wire a VGPUSlice watch reconciler that calls manager.ReconcileSlice"
echo "    - Run drift detection with a real K8s client"
# ─────────────────────────────────────────────────────────────────────────────
cat > cmd/nodeagent/main.go << 'EOF'
package main

import (
	"context"
	"log"
	"os"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		log.Fatalf("CRITICAL: NODE_NAME environment variable is required")
	}

	log.Printf("Booting vGPU NodeAgent on %s...", nodeName)

	// Register schemes so the controller-runtime client can decode our CRD types.
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

	// Build a direct client (not cache-backed) for the drift detector so it
	// reads fresh state from the API server rather than a potentially stale cache.
	directClient, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		log.Fatalf("building K8s client: %v", err)
	}

	// Wire up the NodeAgent manager — drift detection now gets a real client.
	mgr := nodeagent.NewManager(nodeName, directClient)

	// Run drift detection synchronously at boot before accepting any new work.
	// This ensures hardware and checkpoint state are reconciled before we start
	// processing new slice events.
	log.Println("Running hardware vs. checkpoint drift detection...")
	if err := mgr.Detector.DetectAndHeal(context.Background()); err != nil {
		log.Fatalf("Drift healing failed: %v", err)
	}
	log.Println("Drift detection complete.")

	// Now set up a controller-manager for the watch loop.
	ctrlMgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:             scheme,
		MetricsBindAddress: "0", // disabled — the scheduler owns metrics on :8081
		// No leader election: each NodeAgent is authoritative for its own node only.
		LeaderElection: false,
	})
	if err != nil {
		log.Fatalf("creating controller manager: %v", err)
	}

	// Wire the slice reconciler: watches VGPUSlices where spec.nodeName matches
	// this node and drives hardware allocation / release through the NodeAgent.
	sliceReconciler := &nodeAgentSliceReconciler{
		manager:  mgr,
		nodeName: nodeName,
		client:   ctrlMgr.GetClient(),
	}
	if err := ctrl.NewControllerManagedBy(ctrlMgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(sliceReconciler); err != nil {
		log.Fatalf("setting up slice reconciler: %v", err)
	}

	log.Println("Hardware initialised. Listening for scheduled slices...")
	if err := ctrlMgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("NodeAgent manager crashed: %v", err)
	}
}

// ─── NodeAgent slice reconciler ──────────────────────────────────────────────

// nodeAgentSliceReconciler watches VGPUSlices and calls manager.ReconcileSlice
// for any slice that has been scheduled to this node (spec.nodeName == nodeName).
// Slices belonging to other nodes are silently skipped.
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

	// Only handle slices assigned to this node.
	if slice.Spec.NodeName != r.nodeName {
		return reconcile.Result{}, nil
	}

	if err := r.manager.ReconcileSlice(ctx, &slice); err != nil {
		log.Printf("ReconcileSlice error for %s: %v", slice.Name, err)
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Removing unused 'os' import from scheduler main (if resource import also unused)"
# The resource import in scheduler/main.go is only there to suppress the unused
# import from seedCacheFromNodes. Let's verify go vet would be happy by checking
# that resource.MustParse("0") compiles — it will, it's just a no-op guard.
echo "    (resource.MustParse guard already in seedCacheFromNodes — no change needed)"

echo ""
echo "========================================================================"
echo " Runtime wiring fixes applied. Summary:"
echo "========================================================================"
echo ""
echo "  Scheduler engine"
echo "  [A]  internal/scheduler/plugin.go"
echo "       - SliceScheduler struct defined (was missing)"
echo "       - NewSliceScheduler(cache, k8sClient) constructor added"
echo "       - bindToKubernetesAPI patches spec.nodeName + status.phase=Scheduled"
echo ""
echo "  Controller reconcilers"
echo "  [B]  internal/controller/vgpuclaim_reconciler.go"
echo "       - reconcile.Reconciler interface satisfied (Request → Result, error)"
echo "       - SetupWithManager added"
echo "       - ensureSliceExists is now idempotent (Get-then-Create with OwnerRef)"
echo "  [C]  internal/controller/vgpuslice_reconciler.go"
echo "       - reconcile.Reconciler interface satisfied"
echo "       - SetupWithManager added"
echo "       - Compile-time interface assertions added for both reconcilers"
echo ""
echo "  Binary entrypoints — now fully wired"
echo "  [D]  cmd/controller/main.go"
echo "       - Registers VGPUClaim + VGPUSlice schemes"
echo "       - Calls SetupWithManager for both reconcilers (was dead-code creation)"
echo "       - Adds /healthz and /readyz probes"
echo "  [E]  cmd/scheduler/main.go"
echo "       - sliceSchedulingReconciler watches Pending VGPUSlices → calls Schedule"
echo "       - nodeCapacityReconciler watches Nodes → keeps VRAMCache live"
echo "       - seedCacheFromNodes pre-populates cache at startup"
echo "       - Adds /healthz and /readyz probes"
echo "  [F]  cmd/nodeagent/main.go"
echo "       - Builds a real direct controller-runtime K8s client (no nil)"
echo "       - Drift detection runs with the real client"
echo "       - nodeAgentSliceReconciler watches VGPUSlices scoped to this node"
echo "       - Calls manager.ReconcileSlice for allocation and release events"
echo ""
echo "  Remaining manual steps:"
echo "  - controller-gen regeneration (run after any api/v1alpha1 type changes):"
echo "    controller-gen object:headerFile=hack/boilerplate.go.txt paths=./api/..."
echo "  - RBAC: update deployments/manifests/rbac/rbac.yaml to grant the"
echo "    scheduler 'patch' on VGPUSlices and list/watch on Nodes."
echo "  - The vramResourceName constant in cmd/scheduler/main.go"
echo "    ('nvidia.com/vram-bytes') must match what your device-plugin advertises."
echo ""
echo "  Backups saved to: $BACKUP_DIR"
echo "========================================================================"
