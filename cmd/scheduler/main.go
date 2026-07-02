package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
	pq "github.com/pranav2910/vgpu-scheduler/internal/scheduler/priorityqueue"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
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
		// Release the lease on graceful shutdown so a hot standby takes over in
		// seconds instead of waiting out the full lease duration. Phase 3.3.
		LeaderElectionReleaseOnCancel: true,
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	cache := scheduler.NewVRAMCache()
	sched := scheduler.NewSliceScheduler(cache, mgr.GetClient())
	// Layer 2 Phase 2.2a: wire VGPUQuota enforcement. The checker reads the
	// informer for committed usage and the scheduler's own cache for in-flight
	// admissions the informer hasn't reflected yet (just-bound slices, held
	// gang reservations) — without the cache, a rapid burst can slip past
	// quota in the watch round-trip window.
	sched.SetQuotaChecker(scheduler.NewQuotaChecker(mgr.GetClient(), cache))

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

	// Cache JANITOR — level-based correction for the whole missed-release bug
	// class. Every release path is edge-triggered (a Released event, a delete
	// event); a missed edge leaks capacity forever (seen live: 12Gi of
	// allocated bytes surviving a churn-heavy soak with zero slices left).
	// The janitor periodically compares the cache's tracked slice UIDs against
	// a DIRECT API list (quorum read — an informer-lag absence must never
	// release a live hold) and forgets entries whose objects no longer exist,
	// loudly. Nonzero forgets = some edge was missed; the logged UIDs are the
	// breadcrumbs for root-causing it.
	if err := mgr.Add(&cacheJanitorRunnable{reader: mgr.GetAPIReader(), cache: cache, interval: 60 * time.Second}); err != nil {
		log.Fatalf("adding cache janitor runnable: %v", err)
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

	// Inventory-gauge collector: refreshes slice-phase / namespace / quota /
	// queue-depth gauges every 15s.
	if err := mgr.Add(&metricsCollectorRunnable{client: mgr.GetClient(), queue: priorityQueue, interval: 15 * time.Second}); err != nil {
		log.Fatalf("adding metrics collector runnable: %v", err)
	}

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

	// /healthz means "process alive". /readyz means "safe to hold scheduling
	// responsibility". Phase 3.3: the meaningful gate is that a leader must not
	// report Ready until its cache warm-up has completed — otherwise a freshly
	// promoted leader could be considered Ready while its cache still cold-starts
	// at free=capacity, the exact window the warm-up gate exists to close.
	//
	// A non-leader (hot standby) reports Ready: it is healthy and ready to take
	// over. Gating standby readiness on leadership would leave it permanently
	// NotReady, which breaks Deployment availability (rollout never completes).
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Fatalf("adding healthz check: %v", err)
	}
	elected := mgr.Elected()
	if err := mgr.AddReadyzCheck("readyz", func(_ *http.Request) error {
		select {
		case <-elected:
			// This replica is (or was) the leader: Ready only once warmed up.
			if !cache.IsSeeded() {
				return fmt.Errorf("leader cache warm-up in progress")
			}
			return nil
		default:
			// Not the leader: a healthy standby, ready to take over.
			return nil
		}
	}); err != nil {
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
	// Runnables start only after this instance wins leader election, so this is
	// a fair proxy for "actively scheduling".
	telemetry.LeaderActive.Set(1)
	start := time.Now()
	// Retry until seeding succeeds: an unseeded cache keeps the warm-up gate
	// closed (slices requeue on CacheNotReadyError), which is strictly safer
	// than opening the gate blind — that re-creates the restart over-admission
	// window the gate was built to close. Backoff is capped; leadership loss /
	// shutdown cancels ctx and exits the loop.
	for attempt := 1; ; attempt++ {
		err := seedCacheFromNodes(ctx, s.client, s.cache)
		if err == nil {
			break
		}
		wait := time.Duration(attempt) * time.Second
		if wait > 10*time.Second {
			wait = 10 * time.Second
		}
		log.Printf("WARNING: cache seeding attempt %d failed: %v — retrying in %v (scheduling stays gated until seeded)",
			attempt, err, wait)
		select {
		case <-ctx.Done():
			telemetry.LeaderActive.Set(0)
			return nil
		case <-time.After(wait):
		}
	}
	telemetry.CacheWarmupDuration.Set(time.Since(start).Seconds())
	telemetry.CacheWarmupComplete.Set(1)
	<-ctx.Done()
	telemetry.LeaderActive.Set(0)
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

// cacheJanitorRunnable is the level-based safety net under every edge-
// triggered release path: each sweep DIRECT-lists slices (quorum read — an
// informer-lag absence must never release a live hold) and forgets any cache
// entry whose slice no longer exists. Leader-gated like every runnable here.
type cacheJanitorRunnable struct {
	reader   client.Reader
	cache    *scheduler.VRAMCache
	interval time.Duration
}

func (j *cacheJanitorRunnable) Start(ctx context.Context) error {
	ticker := time.NewTicker(j.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			tracked := j.cache.TrackedSliceUIDs()
			if len(tracked) == 0 {
				continue
			}
			var slices vgpuv1alpha1.VGPUSliceList
			if err := j.reader.List(ctx, &slices); err != nil {
				log.Printf("[janitor] slice list failed (%v) — skipping sweep", err)
				continue
			}
			live := make(map[string]struct{}, len(slices.Items))
			for i := range slices.Items {
				live[string(slices.Items[i].UID)] = struct{}{}
			}
			for uid, node := range tracked {
				if _, ok := live[uid]; ok {
					continue
				}
				log.Printf("[janitor] cache entry for slice uid=%s (node %s) has no live object — forgetting (a release edge was missed; investigate via this uid)", uid, node)
				j.cache.ForgetSlice(uid, node)
				telemetry.CacheJanitorForgets.Inc()
			}
		}
	}
}

// metricsCollectorRunnable periodically refreshes the inventory-style gauges
// that can't be maintained incrementally: slice counts by phase, per-namespace
// allocated bytes, configured quota bytes, and the work-queue depth. A List
// every interval is cheap and keeps these series fresh without coupling them
// to the hot scheduling path.
type metricsCollectorRunnable struct {
	client   client.Client
	queue    interface{ Len() int }
	interval time.Duration
}

func (m *metricsCollectorRunnable) Start(ctx context.Context) error {
	t := time.NewTicker(m.interval)
	defer t.Stop()
	for {
		m.collect(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

func (m *metricsCollectorRunnable) collect(ctx context.Context) {
	if m.queue != nil {
		telemetry.QueueDepth.Set(float64(m.queue.Len()))
	}

	var slices vgpuv1alpha1.VGPUSliceList
	if err := m.client.List(ctx, &slices); err == nil {
		byPhase := map[string]int{}
		nsAllocated := map[string]int64{}
		for i := range slices.Items {
			sl := &slices.Items[i]
			phase := string(sl.Status.Phase)
			if phase == "" {
				phase = "Pending"
			}
			byPhase[phase]++
			if sl.Status.AllocatedBytes > 0 {
				nsAllocated[sl.Namespace] += sl.Status.AllocatedBytes
			}
		}
		// Reset first so phases/namespaces that dropped to zero don't linger.
		telemetry.SlicesByPhase.Reset()
		for phase, n := range byPhase {
			telemetry.SlicesByPhase.WithLabelValues(phase).Set(float64(n))
		}
		telemetry.NamespaceAllocatedBytes.Reset()
		for ns, bytes := range nsAllocated {
			telemetry.NamespaceAllocatedBytes.WithLabelValues(ns).Set(float64(bytes))
		}
	}

	var quotas vgpuv1alpha1.VGPUQuotaList
	if err := m.client.List(ctx, &quotas); err == nil {
		telemetry.NamespaceQuotaBytes.Reset()
		for i := range quotas.Items {
			q := &quotas.Items[i]
			telemetry.NamespaceQuotaBytes.WithLabelValues(q.Spec.TargetNamespace).Set(float64(q.Spec.MaxVramBytes))
		}
	}
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
	uid   string
	node  string
	phase string
}

// recordSlice remembers a live slice's UID, bound node, and last-seen phase so
// (a) a later delete can release whatever cache footprint it held, and (b) we
// can emit Ready/Failed transition counters exactly once per transition. We
// only count a transition when we have a prior phase for the slice, so a
// scheduler restart re-observing already-Ready slices doesn't inflate counts.
func (r *sliceSchedulingReconciler) recordSlice(nn types.NamespacedName, uid, node, phase string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.tracked == nil {
		r.tracked = make(map[types.NamespacedName]trackedSlice)
	}
	if prev, ok := r.tracked[nn]; ok {
		if prev.uid != "" && prev.uid != uid {
			// Same name, NEW UID: the slice was deleted and recreated before the
			// delete's reconcile ran (the workqueue coalesces both events into one
			// key, and Get now sees the new object — NotFound never fires for the
			// old one, so releaseOnDelete never would). Release the old UID's
			// footprint here or it stays in the cache as ghost allocated capacity
			// until a scheduler restart.
			r.sched.Cache.ForgetSlice(prev.uid, prev.node)
		} else if prev.phase != phase {
			switch phase {
			case "Ready":
				telemetry.SliceReady.Inc()
			case "Failed":
				telemetry.SliceFailed.WithLabelValues("scheduling").Inc()
			}
		}
	}
	r.tracked[nn] = trackedSlice{uid: uid, node: node, phase: phase}
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
	// Remember this slice's UID + bound node + phase so a future delete can
	// release whatever it held and so Ready/Failed transitions get counted.
	r.recordSlice(req.NamespacedName, string(slice.UID), slice.Spec.NodeName, string(slice.Status.Phase))

	phase := string(slice.Status.Phase)

	// Bug B fix: bridge NodeAgent hardware events into the scheduler cache.
	if slice.Spec.NodeName != "" && (phase == "Ready" || phase == "Released" || phase == "Failed") {
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
		telemetry.ReconcileErrors.Inc()
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
		if client.IgnoreNotFound(err) == nil {
			// Node deleted — drop it from the candidate set NOW. Leaving it in
			// the cache makes a ghost node with full free capacity that wins
			// placement once real nodes fill up; slices bound to it hang in
			// Scheduled forever (no kubelet, no node agent).
			r.cache.RemoveNode(req.Name)
			log.Printf("Cache updated: node %s deleted — removed from candidate set", req.Name)
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	totalVRAM, ok := node.Status.Capacity[vramResourceName]
	if !ok {
		return reconcile.Result{}, nil
	}

	consumed := consumedVRAMOnNode(&node)
	isNewToCache := !r.cache.HasNode(node.Name)
	r.cache.UpdateNode(node.Name, totalVRAM.Value(), consumed)
	// Sweep S3: a node (re-)entering the candidate set arrives with allocated=0
	// (no kubelet bookkeeping for the extended resource) while its Ready slices
	// still physically hold VRAM. A node FLAP generates zero slice events, so
	// nothing re-promoted them — the node sat at free=total (over-admission
	// window) until an incidental slice write, minutes or unbounded. Re-walk
	// this node's Ready slices NOW and re-charge each exactly once.
	if isNewToCache {
		var slices vgpuv1alpha1.VGPUSliceList
		if err := r.client.List(ctx, &slices); err != nil {
			// The node is registered but not yet re-charged — retry the whole
			// reconcile rather than leave the over-admission window open.
			return reconcile.Result{}, fmt.Errorf("listing slices to re-charge node %s: %w", node.Name, err)
		}
		recharged := 0
		for i := range slices.Items {
			sl := &slices.Items[i]
			if sl.Spec.NodeName != node.Name || string(sl.Status.Phase) != "Ready" || sl.Status.AllocatedBytes <= 0 {
				continue
			}
			_ = r.cache.PromoteSliceToAllocatedOnce(string(sl.UID), node.Name, sl.Status.AllocatedBytes)
			recharged++
		}
		if recharged > 0 {
			log.Printf("Cache updated: node %s (re-)registered — re-charged %d Ready slice(s)", node.Name, recharged)
		}
	}
	// Gate NEW placements on node readiness: a NotReady node keeps its existing
	// accounting (workloads may still be running) but stops being a candidate
	// (CanFit/AssumeSlice refuse unhealthy nodes). Without this, the Healthy
	// flag was never set by anything and the unhealthy-rejection path was dead.
	r.cache.SetNodeHealth(node.Name, nodeIsReady(&node))
	// Phase 2.5a: record the node's topology zone from its label, if any.
	if zone := node.Labels[scheduler.TopologyZoneLabel]; zone != "" {
		r.cache.SetNodeZone(node.Name, zone)
	}
	log.Printf("Cache updated: node %s total=%d consumed=%d ready=%t zone=%q",
		node.Name, totalVRAM.Value(), consumed, nodeIsReady(&node), node.Labels[scheduler.TopologyZoneLabel])
	return reconcile.Result{}, nil
}

// nodeIsReady reports whether the node's Ready condition is True.
func nodeIsReady(node *corev1.Node) bool {
	for _, c := range node.Status.Conditions {
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
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
// cache seeded ONLY when the node list (and so the slice re-accounting pass)
// actually ran: a node-List failure returns WITHOUT seeding, because opening
// the warm-up gate with zero known consumption is exactly the restart
// over-admission the gate exists to prevent — the caller retries. The slice
// list degrading stays fail-open (logged; the lazy reconcile path + TTL reaper
// converge), since by then capacity is at least populated.
// Until seeded, Schedule() defers placement.
func seedCacheFromNodes(ctx context.Context, k8sClient client.Client, cache *scheduler.VRAMCache) error {
	var nodeList corev1.NodeList
	if err := k8sClient.List(ctx, &nodeList); err != nil {
		return fmt.Errorf("listing nodes: %w", err)
	}
	defer cache.MarkSeeded()

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
