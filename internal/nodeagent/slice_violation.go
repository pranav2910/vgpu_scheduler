package nodeagent

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	sliceOveruseToleranceBytes  = int64(256) << 20
	sliceOveruseStreakThreshold = 3
	memoryViolationCondition    = "MemoryViolation"
	memoryViolationReason       = "ObservedGpuMemoryOveruse"
	// claimRefAnnotation mirrors webhook.VGPUClaimAnnotation — the claim a
	// workload pod is bound to. Duplicated here to avoid importing the webhook
	// package (and its admission-server deps) into the node agent.
	claimRefAnnotation = "infrastructure.pranav2910.com/claim-ref"
)

// SliceViolationDetector is Phase 3.4b: it attributes GPU-using processes to the
// VGPUSlice that owns them (PID → pod via /proc cgroup → claim-ref annotation →
// slice by ClaimRef) and MARKS slices whose workload sustainably exceeds their
// granted VRAM. Observe-and-mark only — it sets a MemoryViolation Condition,
// metrics, and an Event, but never evicts, throttles, or changes the phase.
type SliceViolationDetector struct {
	client    client.Client // cached: slices + condition writes
	apiReader client.Reader // direct: pod list by spec.nodeName
	nodeName  string
	provider  gpu.GPUProvider
	recorder  record.EventRecorder
	interval  time.Duration
	procRoot  string

	streak map[string]int  // sliceKey -> consecutive over-budget cycles
	active map[string]bool // sliceKey -> currently marked

	// Phase 3.4c soft enforcement.
	enforceMode    EnforcementMode                   // off | softwarn
	now            func() time.Time                  // injectable clock for the grace timer (defaults to time.Now)
	violationStart map[string]time.Time              // sliceKey -> when 3.4b flagged it (grace anchor)
	enforced       map[string]bool                   // sliceKey -> soft enforcement currently engaged
	stampedPods    map[string][]types.NamespacedName // sliceKey -> pods we labeled/annotated (for exact cleanup)
}

// NewSliceViolationDetector builds the detector. interval <= 0 defaults to 30s.
// mode selects the 3.4c enforcement ceiling (off | softwarn).
func NewSliceViolationDetector(c client.Client, apiReader client.Reader, nodeName string, provider gpu.GPUProvider, recorder record.EventRecorder, interval time.Duration, mode EnforcementMode) *SliceViolationDetector {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	return &SliceViolationDetector{
		client:         c,
		apiReader:      apiReader,
		nodeName:       nodeName,
		provider:       provider,
		recorder:       recorder,
		interval:       interval,
		procRoot:       "/proc",
		enforceMode:    mode,
		now:            time.Now,
		streak:         map[string]int{},
		active:         map[string]bool{},
		violationStart: map[string]time.Time{},
		enforced:       map[string]bool{},
		stampedPods:    map[string][]types.NamespacedName{},
	}
}

func (d *SliceViolationDetector) Start(ctx context.Context) error {
	telemetry.MemoryEnforcementMode.WithLabelValues(d.nodeName).Set(float64(d.enforceMode))
	log.Printf("[slice-violation] per-slice over-use detector started: node=%s interval=%s enforcement=%s (no eviction/throttle)",
		d.nodeName, d.interval, d.enforceMode.String())
	d.sweepOrphanStamps(ctx) // drop any soft-enforcement stamps left by a prior lifetime
	t := time.NewTicker(d.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
			if err := d.detectOnce(ctx); err != nil {
				log.Printf("[slice-violation] detect cycle error: %v", err)
			}
		}
	}
}

type sliceUsage struct {
	namespace string
	name      string
	grant     int64
	used      int64
	pods      []types.NamespacedName // pods attributed to this slice (3.4c stamp targets)
}

// addPod appends a pod to the slice's attributed set, de-duplicated (a pod can
// own several GPU processes on the same slice).
func (u *sliceUsage) addPod(nn types.NamespacedName) {
	for _, p := range u.pods {
		if p == nn {
			return
		}
	}
	u.pods = append(u.pods, nn)
}

func sliceKey(ns, name string) string { return ns + "/" + name }

func (d *SliceViolationDetector) detectOnce(ctx context.Context) error {
	procs, err := d.provider.ListProcesses(ctx)
	if err != nil {
		return nil // degraded/fake: nothing to attribute
	}
	usage, err := d.attribute(ctx, procs)
	if err != nil {
		return err
	}

	// Reset per-slice gauges so vanished slices' series disappear.
	telemetry.SliceMemoryViolationActive.Reset()
	telemetry.SliceMemoryViolationExcessBytes.Reset()
	telemetry.MemoryEnforcementActive.Reset()

	seen := make(map[string]bool, len(usage))
	for key, u := range usage {
		seen[key] = true
		onset, cleared, excess, violating := d.evaluate(key, u.used, u.grant)
		telemetry.SliceMemoryViolationActive.WithLabelValues(d.nodeName, u.namespace, u.name).Set(boolToFloat01(violating))
		telemetry.SliceMemoryViolationExcessBytes.WithLabelValues(d.nodeName, u.namespace, u.name).Set(float64(excess))
		if onset {
			telemetry.SliceMemoryViolationsTotal.WithLabelValues(d.nodeName, u.namespace, u.name, memoryViolationReason).Inc()
			d.mark(ctx, u, excess, true)
		} else if cleared {
			d.mark(ctx, u, 0, false)
		}
		// Phase 3.4c: drive the grace-gated soft-enforcement state machine.
		d.enforce(ctx, u, excess, violating)
	}
	// Prune state for slices no longer present (deleted/unbound).
	for key := range d.active {
		if !seen[key] {
			delete(d.active, key)
			delete(d.streak, key)
		}
	}
	// 3.4c: clean enforcement state (and un-stamp pods) for vanished slices.
	for key := range d.enforced {
		if !seen[key] {
			d.cleanupEnforcement(ctx, key)
		}
	}
	for key := range d.violationStart {
		if !seen[key] {
			delete(d.violationStart, key)
		}
	}
	return nil
}

// evaluate applies tolerance + hysteresis to one slice. Pure aside from the
// per-slice streak/active maps, so it is directly unit-testable.
func (d *SliceViolationDetector) evaluate(key string, used, grant int64) (onset, cleared bool, excess int64, violating bool) {
	if used > grant {
		excess = used - grant
	}
	if used-grant > sliceOveruseToleranceBytes {
		d.streak[key]++
	} else {
		d.streak[key] = 0
	}
	violating = d.streak[key] >= sliceOveruseStreakThreshold
	was := d.active[key]
	d.active[key] = violating
	onset = violating && !was
	cleared = !violating && was
	return onset, cleared, excess, violating
}

// attribute maps GPU processes to the slices that own them and returns per-slice
// usage for every active bound slice on the node (used defaults to 0).
func (d *SliceViolationDetector) attribute(ctx context.Context, procs []gpu.GPUProcess) (map[string]*sliceUsage, error) {
	// 1. Active bound slices on this node, indexed by (namespace, claimRef).
	var slices vgpuv1alpha1.VGPUSliceList
	if err := d.client.List(ctx, &slices); err != nil {
		return nil, fmt.Errorf("listing slices: %w", err)
	}
	byKey := map[string]*sliceUsage{}
	byClaim := map[string]*sliceUsage{} // "ns/claimRef" -> usage
	for i := range slices.Items {
		s := &slices.Items[i]
		if s.Spec.NodeName != d.nodeName {
			continue
		}
		switch string(s.Status.Phase) {
		case "", "Pending", "Released", "Failed":
			continue
		}
		u := &sliceUsage{namespace: s.Namespace, name: s.Name, grant: s.Spec.RequestedVRAMBytes}
		byKey[sliceKey(s.Namespace, s.Name)] = u
		if s.Spec.ClaimRef != "" {
			byClaim[s.Namespace+"/"+s.Spec.ClaimRef] = u
		}
	}

	// 2. Pods on this node, indexed by UID → (namespace, claimRef annotation).
	var pods corev1.PodList
	if err := d.apiReader.List(ctx, &pods, client.MatchingFields{"spec.nodeName": d.nodeName}); err != nil {
		return nil, fmt.Errorf("listing pods on node: %w", err)
	}
	type podRef struct{ namespace, name, claim string }
	byPodUID := map[string]podRef{}
	for i := range pods.Items {
		p := &pods.Items[i]
		claim := p.Annotations[claimRefAnnotation]
		if claim == "" {
			continue
		}
		byPodUID[string(p.UID)] = podRef{namespace: p.Namespace, name: p.Name, claim: claim}
	}

	// 3. Attribute each process to its slice via cgroup → pod → claim → slice.
	for _, proc := range procs {
		uid, err := podUIDForPID(d.procRoot, proc.PID)
		if err != nil || uid == "" {
			continue // not a pod process, or unreadable
		}
		ref, ok := byPodUID[uid]
		if !ok {
			continue
		}
		if u, ok := byClaim[ref.namespace+"/"+ref.claim]; ok {
			u.used += proc.UsedMemoryBytes
			u.addPod(types.NamespacedName{Namespace: ref.namespace, Name: ref.name})
		}
	}
	return byKey, nil
}

// mark sets/clears the MemoryViolation Condition on the slice (and mirrors a
// summary onto the parent VGPUJob), and emits an Event on onset. The slice stays
// in its current phase — a violation is a condition, never termination.
func (d *SliceViolationDetector) mark(ctx context.Context, u *sliceUsage, excess int64, violating bool) {
	status := metav1.ConditionFalse
	msg := "GPU memory usage within granted VRAM"
	if violating {
		status = metav1.ConditionTrue
		msg = fmt.Sprintf("Observed GPU memory usage exceeded allocated VRAM by %d MiB for ~%ds (observe-only, no eviction)",
			excess>>20, sliceOveruseStreakThreshold*int(d.interval.Seconds()))
	}
	cond := metav1.Condition{
		Type:               memoryViolationCondition,
		Status:             status,
		Reason:             memoryViolationReason,
		Message:            msg,
		LastTransitionTime: metav1.Now(),
	}

	var slice vgpuv1alpha1.VGPUSlice
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: u.namespace, Name: u.name}, &slice); err != nil {
		return
	}
	slice.Status.Conditions = upsertNodeCondition(slice.Status.Conditions, cond)
	if err := d.client.Status().Update(ctx, &slice); err != nil {
		log.Printf("[slice-violation] update slice %s/%s condition: %v", u.namespace, u.name, err)
		return
	}
	d.mirrorToJob(ctx, &slice, violating)

	if violating && d.recorder != nil {
		d.recorder.Eventf(&slice, corev1.EventTypeWarning, memoryViolationCondition, "%s", msg)
	}
	log.Printf("[slice-violation] slice %s/%s MemoryViolation=%v (excess=%d MiB) — observe-only",
		u.namespace, u.name, violating, excess>>20)
}

// mirrorToJob writes a summary MemoryViolation condition onto the slice's parent
// VGPUJob (slice → claim.JobRef → job).
func (d *SliceViolationDetector) mirrorToJob(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice, violating bool) {
	if slice.Spec.ClaimRef == "" {
		return
	}
	var claim vgpuv1alpha1.VGPUClaim
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil || claim.Spec.JobRef == "" {
		return
	}
	var job vgpuv1alpha1.VGPUJob
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err != nil {
		return
	}
	status := metav1.ConditionFalse
	msg := "No child slice is violating GPU memory policy"
	if violating {
		status = metav1.ConditionTrue
		msg = "One or more child slices are violating GPU memory policy (observe-only)"
	}
	job.Status.Conditions = upsertNodeCondition(job.Status.Conditions, metav1.Condition{
		Type:               memoryViolationCondition,
		Status:             status,
		Reason:             "ChildSliceViolation",
		Message:            msg,
		LastTransitionTime: metav1.Now(),
	})
	if err := d.client.Status().Update(ctx, &job); err != nil {
		log.Printf("[slice-violation] mirror condition to job %s/%s: %v", job.Namespace, job.Name, err)
	}
}

// upsertNodeCondition replaces an existing condition of the same type or appends
// it (local copy — the scheduler package has its own).
func upsertNodeCondition(conds []metav1.Condition, c metav1.Condition) []metav1.Condition {
	for i := range conds {
		if conds[i].Type == c.Type {
			// Preserve LastTransitionTime if the status did not change.
			if conds[i].Status == c.Status {
				c.LastTransitionTime = conds[i].LastTransitionTime
			}
			conds[i] = c
			return conds
		}
	}
	return append(conds, c)
}
