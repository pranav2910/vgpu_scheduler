package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
	pq "github.com/pranav2910/vgpu-scheduler/internal/scheduler/priorityqueue"
	_ "github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/util/workqueue"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const vramResourceName corev1.ResourceName = "infrastructure.pranav2910.com/vgpu-bytes"

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
		Metrics:                metricsserver.Options{BindAddress: ":8081"},
		HealthProbeBindAddress: ":8082",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-scheduler-lock",
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	cache := scheduler.NewVRAMCache()
	sched := scheduler.NewSliceScheduler(cache, mgr.GetClient())
	// Layer 2 Phase 2.2a: wire VGPUQuota enforcement.
	sched.SetQuotaChecker(scheduler.NewQuotaChecker(mgr.GetClient()))

	// Layer 2 Phase 2.3: wire preemption.
	sched.SetPreemptor(scheduler.NewPreemptor(mgr.GetClient()))

	// gang-wiring fix applied: wire the GangBindingGate so Schedule()
	// actually consults gang state before binding.
	sched.GangGate = scheduler.NewGangBindingGate(mgr.GetClient())

	// Bug D fix: seed the cache as a Runnable so it fires AFTER the informer
	// cache has synced. Calling mgr.GetClient() before mgr.Start() blocks.
	if err := mgr.Add(&seedRunnable{client: mgr.GetClient(), cache: cache}); err != nil {
		log.Fatalf("adding cache-seed runnable: %v", err)
	}

	// Bug #3 fix: start the TTL reaper so expired speculative reservations
	// get rolled back.
	if err := mgr.Add(&ttlReaperRunnable{cache: cache, interval: 10 * time.Second}); err != nil {
		log.Fatalf("adding TTL reaper runnable: %v", err)
	}

	// Tier-aware priority queue (replaces controller-runtime's default FIFO).
	// Resolves a slice's tier by fetching its parent claim, defaulting to
	// BestEffort if the lookup fails.
	priorityFn := makePriorityFunc(mgr.GetClient())
	limiter := workqueue.DefaultTypedItemBasedRateLimiter[reconcile.Request]()
	priorityQueue := pq.New(
		func(req any) int { return priorityFn(req.(reconcile.Request)) },
		untypedLimiter(limiter),
	)

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		WithOptions(controller.Options{
			NewQueue: func(name string, _ workqueue.TypedRateLimiter[reconcile.Request]) workqueue.TypedRateLimitingInterface[reconcile.Request] {
				return &queueAdapter{q: priorityQueue}
			},
		}).
		Complete(&sliceSchedulingReconciler{sched: sched, client: mgr.GetClient(), tracked: make(map[types.NamespacedName]trackedSlice)}); err != nil {
		log.Fatalf("setting up slice scheduling reconciler: %v", err)
	}

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

// ─── Runnables ───────────────────────────────────────────────────────────────

type seedRunnable struct {
	client client.Client
	cache  *scheduler.VRAMCache
}

func (s *seedRunnable) Start(ctx context.Context) error {
	if err := seedCacheFromNodes(ctx, s.client, s.cache); err != nil {
		log.Printf("WARNING: seed from nodes failed: %v (cache will populate on reconcile)", err)
	}
	<-ctx.Done()
	return nil
}

type ttlReaperRunnable struct {
	cache    *scheduler.VRAMCache
	interval time.Duration
}

func (r *ttlReaperRunnable) Start(ctx context.Context) error {
	r.cache.StartTTLReaper(ctx, r.interval)
	<-ctx.Done()
	return nil
}

// ─── Slice scheduling reconciler ─────────────────────────────────────────────

type sliceSchedulingReconciler struct {
	sched  *scheduler.SliceScheduler
	client client.Client

	// tracked maps a slice's NamespacedName → its UID and bound node for slices
	// we've observed. On a delete event (Get → NotFound) the object is gone, so
	// this lets us release the slice's ENTIRE cache footprint (assumed,
	// confirmed, or allocated) immediately — rather than depending on observing
	// a Released phase (which a fast namespace delete can skip) or the TTL
	// reaper (assumed only). Without it, a deleted committed gang leaves ghost
	// allocated capacity that blocks a subsequent full-cluster request.
	mu      sync.Mutex
	tracked map[types.NamespacedName]trackedSlice
}

type trackedSlice struct {
	uid  string
	node string
}

// recordSlice remembers a live slice's UID and bound node so a later delete can
// release whatever cache footprint it held.
func (r *sliceSchedulingReconciler) recordSlice(nn types.NamespacedName, uid, node string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.tracked == nil {
		r.tracked = make(map[types.NamespacedName]trackedSlice)
	}
	r.tracked[nn] = trackedSlice{uid: uid, node: node}
}

// releaseOnDelete reclaims a deleted slice's cache footprint immediately.
func (r *sliceSchedulingReconciler) releaseOnDelete(nn types.NamespacedName) {
	r.mu.Lock()
	t, ok := r.tracked[nn]
	delete(r.tracked, nn)
	r.mu.Unlock()
	if ok && t.uid != "" {
		r.sched.Cache.ForgetSlice(t.uid, t.node)
	}
}

func (r *sliceSchedulingReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.client.Get(ctx, req.NamespacedName, &slice); err != nil {
		if client.IgnoreNotFound(err) == nil {
			// Slice deleted — release its entire cache footprint now, instead of
			// leaving it for a Released-phase observation or the TTL reaper.
			r.releaseOnDelete(req.NamespacedName)
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}
	// Remember this slice's UID + bound node so a future delete can release
	// whatever it held.
	r.recordSlice(req.NamespacedName, string(slice.UID), slice.Spec.NodeName)

	phase := string(slice.Status.Phase)

	// Bug B fix: bridge NodeAgent hardware events into the scheduler cache.
	if slice.Spec.NodeName != "" && (phase == "Ready" || phase == "Released") {
		r.sched.SyncCacheFromSlice(
			string(slice.UID),
			slice.Spec.NodeName,
			phase,
			slice.Status.AllocatedBytes,
		)
	}

	// Only schedule Pending slices with no node yet.
	if phase != "" && phase != "Pending" {
		return reconcile.Result{}, nil
	}
	if slice.Spec.NodeName != "" {
		return reconcile.Result{}, nil
	}

	// Bug 6 fix: if this slice belongs to a gang whose reservation has Failed,
	// transition the slice to Failed phase immediately. Without this the slice
	// stays in Pending forever; the priority queue keeps re-enqueueing it; the
	// gang gate keeps rejecting it; capacity is held by ghost slices.
	if slice.Annotations != nil {
		if rsvName, ok := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]; ok && rsvName != "" {
			var rsv vgpuv1alpha1.VGPUGangReservation
			if err := r.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: rsvName}, &rsv); err == nil {
				if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseFailed ||
					rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
					log.Printf("[scheduler] Slice %s/%s belongs to dead gang reservation %s — marking Failed",
						slice.Namespace, slice.Name, rsvName)
					slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Failed")
					slice.Status.LastError = "gang reservation failed; this slot was orphaned"
					if err := r.client.Status().Update(ctx, &slice); err != nil {
						return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
					}
					return reconcile.Result{}, nil
				}
			}
		}
	}

	bestEffort := false
	// Resolve ServiceTier from the parent claim if present. Bug #19.
	if slice.Spec.ClaimRef != "" {
		var claim vgpuv1alpha1.VGPUClaim
		if err := r.client.Get(ctx, client.ObjectKey{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
			bestEffort = claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierBestEffort
		}
	}

	// HOLDBACK: BestEffort slices wait 2 seconds before their first scheduling
	// attempt. This gives any Guaranteed claim arriving in the same window
	// time to enter the priority queue and jump ahead. After 2s have passed
	// since the slice was created, scheduling proceeds normally.
	//
	// Without this, the scheduler is so fast (<1s per claim) that the priority
	// queue never holds 2+ items simultaneously, so priority ordering can't
	// matter. The holdback creates an artificial contention window.
	if bestEffort {
		const holdback = 2 * time.Second
		age := time.Since(slice.CreationTimestamp.Time)
		if age < holdback {
			remaining := holdback - age
			log.Printf("[holdback] BestEffort slice %s/%s waiting %v before scheduling",
				slice.Namespace, slice.Name, remaining.Round(100*time.Millisecond))
			return reconcile.Result{RequeueAfter: remaining}, nil
		}
	}

	_, err := r.sched.Schedule(ctx, req.NamespacedName, string(slice.UID), slice.Spec.RequestedVRAMBytes, bestEffort)
	if err != nil {
		// gang-wiring fix applied: a gang member that hit "deferred" is
		// waiting for siblings to reach Reserved. Retry quickly (500ms)
		// so up to ~120 retries fit within the 60s reservation deadline.
		// Other errors keep the existing 30s backoff.
		var gd *scheduler.GangDeferredError
		if errors.As(err, &gd) {
			return reconcile.Result{RequeueAfter: 500 * time.Millisecond}, nil
		}
		// Cache still warming up after a (re)start — retry quickly, don't back off.
		var cnr *scheduler.CacheNotReadyError
		if errors.As(err, &cnr) {
			return reconcile.Result{RequeueAfter: time.Second}, nil
		}
		log.Printf("Scheduling failed for Slice %s/%s: %v — will retry in 30s",
			slice.Namespace, slice.Name, err)
		return reconcile.Result{RequeueAfter: 30 * time.Second}, nil
	}
	return reconcile.Result{}, nil
}

// ─── Node capacity reconciler ────────────────────────────────────────────────

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
		return reconcile.Result{}, nil
	}

	consumed := consumedVRAMOnNode(&node)
	r.cache.UpdateNode(node.Name, totalVRAM.Value(), consumed)
	// Phase 2.5a: record the node's topology zone from its label, if any.
	if zone := node.Labels[scheduler.TopologyZoneLabel]; zone != "" {
		r.cache.SetNodeZone(node.Name, zone)
	}
	log.Printf("Cache updated: node %s total=%d consumed=%d zone=%q",
		node.Name, totalVRAM.Value(), consumed, node.Labels[scheduler.TopologyZoneLabel])
	return reconcile.Result{}, nil
}

// consumedVRAMOnNode returns the VRAM already consumed by scheduled workloads
// using the extended resource. For extended resources, Kubernetes populates
// Allocatable = Capacity - consumed_by_pods (system-reserved does not apply),
// so Capacity - Allocatable is the pod consumption figure. Bug E clarification.
func consumedVRAMOnNode(node *corev1.Node) int64 {
	allocatable := node.Status.Allocatable[vramResourceName]
	capacity := node.Status.Capacity[vramResourceName]
	consumed := capacity.Value() - allocatable.Value()
	if consumed < 0 {
		return 0
	}
	return consumed
}

// seedCacheFromNodes pre-populates the VRAM cache at startup: first node
// capacity, then the consumption of every already-bound slice. It marks the
// cache seeded at the end (always — even if the slice list degrades — so a
// transient API hiccup can't permanently wedge scheduling; the lazy reconcile
// path + TTL reaper still converge). Until seeded, Schedule() defers placement,
// which is what prevents over-admission on a scheduler restart.
func seedCacheFromNodes(ctx context.Context, k8sClient client.Client, cache *scheduler.VRAMCache) error {
	defer cache.MarkSeeded()

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
		consumed := consumedVRAMOnNode(node)
		cache.UpdateNode(node.Name, totalVRAM.Value(), consumed)
		if zone := node.Labels[scheduler.TopologyZoneLabel]; zone != "" {
			cache.SetNodeZone(node.Name, zone)
		}
		log.Printf("Seeded cache: node %s total=%d consumed=%d zone=%q",
			node.Name, totalVRAM.Value(), consumed, node.Labels[scheduler.TopologyZoneLabel])
	}

	// Re-account already-bound slices so a restarted scheduler knows true
	// consumption before it places anything. Without this, the cache cold-starts
	// at free=capacity and can over-admit until the reconciler lazily catches up.
	var sliceList vgpuv1alpha1.VGPUSliceList
	if err := k8sClient.List(ctx, &sliceList); err != nil {
		log.Printf("WARNING: seeding slices failed: %v (cache may briefly under-count until reconcile)", err)
		return nil
	}
	reaccounted := 0
	for i := range sliceList.Items {
		sl := &sliceList.Items[i]
		if sl.Spec.NodeName == "" {
			continue
		}
		switch string(sl.Status.Phase) {
		case "Scheduled", "Allocating", "Ready":
			bytes := sl.Status.AllocatedBytes
			if bytes <= 0 {
				bytes = sl.Spec.RequestedVRAMBytes // not yet allocated; reserve its ask
			}
			// Idempotent; the restart-fallback path applies the allocation
			// directly and returns a benign "not confirmed" error we ignore.
			_ = cache.PromoteSliceToAllocatedOnce(string(sl.UID), sl.Spec.NodeName, bytes)
			reaccounted++
		}
	}
	log.Printf("Seeded cache: re-accounted %d bound slice(s) into consumption", reaccounted)
	return nil
}

// ─── Priority queue plumbing ────────────────────────────────────────────────

// makePriorityFunc returns a function that resolves a request's priority
// based on the parent VGPUClaim's ServiceTier. The lookup is best-effort:
// transient errors default to BestEffort, which means the slice will simply
// be processed in FIFO order with other BestEffort claims.
func makePriorityFunc(c client.Client) func(reconcile.Request) int {
	return func(req reconcile.Request) int {
		// Generous timeout — we want to actually fetch the claim, not
		// punt to BestEffort because of a 200ms budget.
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()

		var slice vgpuv1alpha1.VGPUSlice
		if err := c.Get(ctx, req.NamespacedName, &slice); err != nil {
			log.Printf("[priorityFn] %s/%s: slice Get failed (%v) → BestEffort", req.Namespace, req.Name, err)
			return pq.PriorityBestEffort
		}
		if slice.Spec.ClaimRef == "" {
			log.Printf("[priorityFn] %s/%s: empty ClaimRef → BestEffort", req.Namespace, req.Name)
			return pq.PriorityBestEffort
		}

		var claim vgpuv1alpha1.VGPUClaim
		if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil {
			log.Printf("[priorityFn] %s/%s: claim Get failed (%v) → BestEffort", req.Namespace, req.Name, err)
			return pq.PriorityBestEffort
		}
		// Layer 2 Phase 2.1a: if the Claim is owned by a VGPUJob, the Job's
		// priority overrides the tier-based default. Higher priority always wins.
		basePriority := pq.PriorityBestEffort
		if claim.Spec.ServiceTier == vgpuv1alpha1.ServiceTierGuaranteed {
			basePriority = pq.PriorityGuaranteed
		}

		if claim.Spec.JobRef != "" {
			var job vgpuv1alpha1.VGPUJob
			if err := c.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err != nil {
				log.Printf("[priorityFn] %s/%s: jobRef=%s but Job Get failed: %v — falling back to tier",
					req.Namespace, req.Name, claim.Spec.JobRef, err)
			} else {
				// Map Job.spec.priority (0-1000) to a queue priority.
				// Anything >= 500 outranks Guaranteed; below acts as
				// fine-grained ordering within tiers.
				jobPriority := int(job.Spec.Priority)
				log.Printf("[priorityFn] %s/%s: jobRef=%s job.priority=%d basePriority=%d",
					req.Namespace, req.Name, claim.Spec.JobRef, jobPriority, basePriority)
				if jobPriority > basePriority {
					log.Printf("[priorityFn] %s/%s: job=%s priority=%d (overrides tier)",
						req.Namespace, req.Name, job.Name, jobPriority)
					return jobPriority
				}
			}
		}

		// Layer 2 Phase 2.2a: bounded wait-time aging.
		// Older pending slices gain priority over time so they don't get
		// permanently starved. +1 priority per 30 seconds waited, capped at +50.
		age := time.Since(slice.CreationTimestamp.Time)
		agingBonus := int(age.Seconds() / 30)
		if agingBonus > 50 {
			agingBonus = 50
		}
		finalPriority := basePriority + agingBonus

		if basePriority == pq.PriorityGuaranteed {
			log.Printf("[priorityFn] %s/%s: tier=Guaranteed base=%d aging=%d → priority=%d",
				req.Namespace, req.Name, basePriority, agingBonus, finalPriority)
		} else {
			log.Printf("[priorityFn] %s/%s: tier=BestEffort base=%d aging=%d → priority=%d",
				req.Namespace, req.Name, basePriority, agingBonus, finalPriority)
		}
		return finalPriority
	}
}

// untypedLimiter wraps a typed rate-limiter so the priority queue (which is
// type-erased on `any`) can use it.
func untypedLimiter(typed workqueue.TypedRateLimiter[reconcile.Request]) workqueue.TypedRateLimiter[any] {
	return &typedToAnyLimiter{typed: typed}
}

type typedToAnyLimiter struct {
	typed workqueue.TypedRateLimiter[reconcile.Request]
}

func (a *typedToAnyLimiter) When(item any) time.Duration {
	if r, ok := item.(reconcile.Request); ok {
		return a.typed.When(r)
	}
	return 0
}
func (a *typedToAnyLimiter) Forget(item any) {
	if r, ok := item.(reconcile.Request); ok {
		a.typed.Forget(r)
	}
}
func (a *typedToAnyLimiter) NumRequeues(item any) int {
	if r, ok := item.(reconcile.Request); ok {
		return a.typed.NumRequeues(r)
	}
	return 0
}

// queueAdapter wraps our priority queue into the typed workqueue interface
// that controller-runtime expects. The conversions are zero-cost — the
// underlying queue is already type-erased.
type queueAdapter struct {
	q *pq.Queue
}

func (a *queueAdapter) Add(item reconcile.Request) { a.q.Add(item) }
func (a *queueAdapter) Len() int                   { return a.q.Len() }
func (a *queueAdapter) Get() (item reconcile.Request, shutdown bool) {
	got, shut := a.q.Get()
	if shut || got == nil {
		return reconcile.Request{}, true
	}
	return got.(reconcile.Request), false
}
func (a *queueAdapter) Done(item reconcile.Request) { a.q.Done(item) }
func (a *queueAdapter) ShutDown()                   { a.q.ShutDown() }
func (a *queueAdapter) ShutDownWithDrain()          { a.q.ShutDownWithDrain() }
func (a *queueAdapter) ShuttingDown() bool          { return a.q.ShuttingDown() }
func (a *queueAdapter) AddAfter(item reconcile.Request, after time.Duration) {
	a.q.AddAfter(item, after)
}
func (a *queueAdapter) AddRateLimited(item reconcile.Request)  { a.q.AddRateLimited(item) }
func (a *queueAdapter) Forget(item reconcile.Request)          { a.q.Forget(item) }
func (a *queueAdapter) NumRequeues(item reconcile.Request) int { return a.q.NumRequeues(item) }

// suppress unused-import warnings if the helpers are added but unused.
var _ = fmt.Sprintf
