package main

import (
	"context"
	"log"
	"os"
	"strconv"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
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

	cfg, err := ctrl.GetConfig()
	if err != nil {
		log.Fatalf("getting kubeconfig: %v", err)
	}

	// Single cached client lives inside ctrlMgr — no separate direct client.
	ctrlMgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:         scheme,
		Metrics:        metricsserver.Options{BindAddress: ":8083"}, // Phase 3.1: expose GPU + data-plane metrics
		LeaderElection: false,
	})
	if err != nil {
		log.Fatalf("creating controller manager: %v", err)
	}

	// Build tag is the single source of truth for "is real hardware present":
	// default build → mock allocator + fake GPU provider; -tags nvml → real both.
	mock := !gpu.RealBuild

	// Manager wires allocation, CDI, checkpoint, reporter, drift. Uses the
	// SAME client the reconciler uses — fixes the stale-read race.
	mgr := nodeagent.NewManager(nodeName, ctrlMgr.GetClient(), mock)

	// Phase 3.1: GPU hardware-truth observation. Read-only — discovers GPUs,
	// reports VRAM/health via metrics, and surfaces drift. Never writes node
	// capacity or enforces limits. A provider init failure (driver/lib/perms)
	// degrades to a provider that reports the error each cycle; the agent stays
	// up either way.
	gpuProvider, gerr := gpu.NewProvider()
	if gerr != nil {
		log.Printf("[gpu] provider init failed (%v) — running in degraded observation mode", gerr)
		gpuProvider = gpu.NewDegradedProvider(gerr)
	}
	// Optional: scheduler-assumed capacity for drift (no Node read / RBAC needed).
	expectedVRAM := int64(0)
	if v := os.Getenv("VGPU_EXPECTED_VRAM_BYTES"); v != "" {
		if n, perr := strconv.ParseInt(v, 10, 64); perr == nil {
			expectedVRAM = n
		}
	}
	gpuCollector := gpu.NewCollector(gpuProvider, nodeName, 30*time.Second, expectedVRAM)
	if err := ctrlMgr.Add(gpuCollector); err != nil {
		log.Fatalf("adding GPU observation collector: %v", err)
	}

	// Phase 3.4a: observe-only over-use detection. Compares observed GPU
	// process-used VRAM against the VRAM granted to bound slices and surfaces
	// sustained over-use via metrics + a Node Event. No eviction or throttling.
	detector := nodeagent.NewViolationDetector(
		ctrlMgr.GetClient(), nodeName, gpuCollector.Inventory(),
		ctrlMgr.GetEventRecorderFor("vgpu-nodeagent"), 30*time.Second)
	if err := ctrlMgr.Add(detector); err != nil {
		log.Fatalf("adding over-use detector: %v", err)
	}

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

