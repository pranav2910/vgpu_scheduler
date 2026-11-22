package nodeagent

import (
	"context"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const nvidiaGPUResource = "nvidia.com/gpu"

// Annotation keys recognized (besides nvidia.com/gpu) when a pod expresses GPU
// memory directly. Extend via VGPU_REQUEST_ANNOTATION_KEY (comma-separated) to
// match whatever the cluster's scheduler uses (KAI, Run:ai, etc.).
var defaultRequestAnnotationKeys = []string{
	"infrastructure.pranav2910.com/requested-vram-bytes", // ours
	"gpu-memory",
	"run.ai/gpu-memory",
	"nvidia.com/gpu-memory",
}

const vgpuClaimRefAnnotation = "infrastructure.pranav2910.com/claim-ref"

// MonitorObserver is the read-only "GPU waste" wedge (VGPU_MODE=monitor). It runs
// BESIDE any scheduler (KAI / Volcano / vanilla): every interval it reads NVML
// truth and exports, per pod, requested-vs-actually-used VRAM — attributing real
// usage to the owning pod via PID → cgroup → pod. It performs NO allocation, NO
// CDI, NO admission/webhook, NO eviction, and requires NO CRDs. It only emits
// Prometheus metrics. Safe to drop into any cluster with `kubectl apply`.
type MonitorObserver struct {
	apiReader client.Reader // direct, uncached: pods by spec.nodeName (server-side selector)
	nodeName  string
	provider  gpu.GPUProvider
	interval  time.Duration
	procRoot  string // host /proc (requires hostPID); attribution reads /proc/<pid>/cgroup
	annKeys   []string
}

// NewMonitorObserver builds the observer. annKeys may be nil (defaults are used).
func NewMonitorObserver(apiReader client.Reader, nodeName string, provider gpu.GPUProvider, interval time.Duration, annKeys []string) *MonitorObserver {
	if len(annKeys) == 0 {
		annKeys = defaultRequestAnnotationKeys
	}
	if interval <= 0 {
		interval = 30 * time.Second
	}
	return &MonitorObserver{
		apiReader: apiReader, nodeName: nodeName, provider: provider,
		interval: interval, procRoot: "/proc", annKeys: annKeys,
	}
}

// Start runs the observe loop until ctx is cancelled (controller-runtime Runnable).
func (m *MonitorObserver) Start(ctx context.Context) error {
	log.Printf("[monitor] read-only GPU-waste observer on %s (interval=%s) — no scheduling, no mutation, no eviction, no CRDs",
		m.nodeName, m.interval)
	m.observe(ctx) // emit once immediately
	t := time.NewTicker(m.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
			m.observe(ctx)
		}
	}
}

// observe takes one snapshot: per-GPU truth, per-pod requested, per-pod used.
//
// It gathers EVERYTHING first and only then Resets + republishes the gauges.
// Resetting up front opened two wrong-number windows: a scrape landing between
// the Reset and the (NVML + API-server) fetches saw half a snapshot — requested
// without used renders as 100% phantom waste — and any fetch error after the
// Reset blanked the whole report for a full interval. A cycle is now atomic:
// on any fetch error the previous complete snapshot stays published (the error
// is logged), and a persistently failing provider publishes nothing rather
// than requested-only phantom waste.
func (m *MonitorObserver) observe(ctx context.Context) {
	// 1. Per-GPU truth, and the per-card total (for whole-GPU request conversion).
	devices, err := m.provider.ListDevices(ctx)
	if err != nil {
		log.Printf("[monitor] ListDevices: %v", err)
		return
	}
	var healthy []gpu.GPUDevice
	var cardTotal int64
	for _, d := range devices {
		if !d.Healthy {
			continue
		}
		healthy = append(healthy, d)
		if d.TotalMemoryBytes > cardTotal {
			cardTotal = d.TotalMemoryBytes
		}
	}

	// 2. Pods on this node (direct, server-side field selector — no cache/index).
	var pods corev1.PodList
	if err := m.apiReader.List(ctx, &pods, client.MatchingFields{"spec.nodeName": m.nodeName}); err != nil {
		log.Printf("[monitor] list pods: %v", err)
		return
	}
	type reqEntry struct {
		ns, name, src string
		bytes         int64
	}
	var reqs []reqEntry
	byUID := make(map[string]*corev1.Pod, len(pods.Items))
	for i := range pods.Items {
		p := &pods.Items[i]
		// Only a RUNNING pod can be wasting GPU memory right now. A Succeeded/Failed
		// pod (a job that already finished) or a Pending one (not yet started) still
		// carries its request in spec but holds no live GPU process — so counting it
		// would report 100% phantom waste for completed or queued workloads, which is
		// exactly the kind of wrong number that destroys trust in the report. Skip it.
		if p.Status.Phase != corev1.PodRunning {
			continue
		}
		byUID[string(p.UID)] = p
		if req, src := requestedVRAM(p, cardTotal, m.annKeys); req > 0 {
			reqs = append(reqs, reqEntry{p.Namespace, p.Name, src, req})
		}
	}

	// 3. Actual usage: NVML processes → owning pod (PID → cgroup → pod UID),
	//    summed per (pod, gpu).
	//
	// Snapshot SANDWICH against PID reuse: the kernel can recycle a PID between
	// the NVML snapshot and the /proc/<pid>/cgroup read, charging a dead GPU
	// process's VRAM to whichever pod inherited the PID. So: snapshot #1 →
	// resolve cgroups (the slow part) → snapshot #2, and attribute only
	// (PID, device) pairs present in BOTH, with #2's (fresher) bytes. A reused
	// PID is not on the GPU in snapshot #2, so the stale row drops for the
	// cycle; a process that started between snapshots is picked up next cycle.
	procs, err := m.provider.ListProcesses(ctx)
	if err != nil {
		log.Printf("[monitor] ListProcesses: %v", err)
		return
	}
	type pidDev struct {
		pid int
		dev string
	}
	resolved := make(map[pidDev]string, len(procs)) // → owning pod UID
	for _, pr := range procs {
		uid, err := podUIDForPID(m.procRoot, pr.PID)
		if err != nil || uid == "" {
			continue // not a pod's process (or /proc unreadable without hostPID)
		}
		resolved[pidDev{pr.PID, pr.DeviceUUID}] = uid
	}
	procs2, err := m.provider.ListProcesses(ctx)
	if err != nil {
		log.Printf("[monitor] ListProcesses (confirm): %v", err)
		return // failed cycle: previous complete snapshot stays published
	}
	type key struct{ uid, gpu string }
	used := map[key]int64{}
	for _, pr := range procs2 {
		uid, ok := resolved[pidDev{pr.PID, pr.DeviceUUID}]
		if !ok {
			continue // new since #1 (next cycle) or unresolvable
		}
		used[key{uid, pr.DeviceUUID}] += pr.UsedMemoryBytes
	}

	// 4. Every fetch succeeded — swap the snapshot in. Reset clears series for
	// pods/GPUs that vanished since last cycle; the Reset→Set window is now pure
	// in-memory loops (no I/O), so a concurrent scrape can no longer catch a
	// seconds-wide half-populated report.
	telemetry.MonitorPodRequestedVRAMBytes.Reset()
	telemetry.MonitorPodUsedVRAMBytes.Reset()
	telemetry.MonitorGPUTotalVRAMBytes.Reset()
	telemetry.MonitorGPUUsedVRAMBytes.Reset()
	telemetry.MonitorGPUFreeVRAMBytes.Reset()
	for _, d := range healthy {
		telemetry.MonitorGPUTotalVRAMBytes.WithLabelValues(m.nodeName, d.UUID).Set(float64(d.TotalMemoryBytes))
		telemetry.MonitorGPUUsedVRAMBytes.WithLabelValues(m.nodeName, d.UUID).Set(float64(d.UsedMemoryBytes))
		telemetry.MonitorGPUFreeVRAMBytes.WithLabelValues(m.nodeName, d.UUID).Set(float64(d.FreeMemoryBytes))
	}
	for _, r := range reqs {
		telemetry.MonitorPodRequestedVRAMBytes.WithLabelValues(r.ns, r.name, m.nodeName, r.src).Set(float64(r.bytes))
	}
	for k, b := range used {
		if p, ok := byUID[k.uid]; ok {
			telemetry.MonitorPodUsedVRAMBytes.WithLabelValues(p.Namespace, p.Name, m.nodeName, k.gpu).Set(float64(b))
		}
	}
}

// requestedVRAM derives how much GPU memory a pod asked for, and from where:
//
//	nvidia.com/gpu: N    → N whole cards (N × cardTotal)   source=nvidia_gpu_limit
//	<annotation key>     → parsed value                    source=annotation (or vgpu_claim for ours)
//	our claim-ref only   → unknown size                    source=vgpu_claim (0 bytes)
//	otherwise            → 0                                source=unknown
func requestedVRAM(p *corev1.Pod, cardTotal int64, annKeys []string) (int64, string) {
	// 1. Whole-GPU resource (limit, else request), summed across containers.
	var gpus int64
	for i := range p.Spec.Containers {
		r := p.Spec.Containers[i].Resources
		if q, ok := r.Limits[nvidiaGPUResource]; ok {
			gpus += q.Value()
		} else if q, ok := r.Requests[nvidiaGPUResource]; ok {
			gpus += q.Value()
		}
	}
	if gpus > 0 && cardTotal > 0 {
		return gpus * cardTotal, "nvidia_gpu_limit"
	}
	// 2a. Our own stamp is RAW BYTES by definition — the key name says so, and
	// the webhook writes strconv.FormatInt(bytes). It must NOT go through the
	// bare-integer-is-MiB convention below (Gate-3 receipt on the A10: a 16 GiB
	// grant rendered as "16777216.0 GiB" — bytes re-multiplied as MiB).
	if v, ok := p.Annotations["infrastructure.pranav2910.com/requested-vram-bytes"]; ok {
		if b, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil && b > 0 {
			return b, "vgpu_claim"
		}
	}
	// 2b. Annotation-based memory request (KAI / Run:ai / configured keys):
	// bare integers are MiB (their convention), unit-suffixed values are
	// Kubernetes quantities.
	for _, k := range annKeys {
		if v, ok := p.Annotations[k]; ok {
			if b := parseRequestedMem(v); b > 0 {
				return b, "annotation"
			}
		}
	}
	// 3. Our pod, but no explicit size on the pod (size lives in the CRD we don't read).
	if _, ok := p.Annotations[vgpuClaimRefAnnotation]; ok {
		return 0, "vgpu_claim"
	}
	return 0, "unknown"
}

// parseRequestedMem parses a GPU-memory annotation value. A bare integer is MiB
// (the Run:ai / KAI gpu-memory convention); anything with a unit is a Kubernetes
// quantity ("16Gi", "17179869184"). Returns bytes, or 0 if unparseable.
func parseRequestedMem(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if isAllDigits(s) {
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil || n <= 0 {
			return 0
		}
		return n * 1024 * 1024 // MiB
	}
	if q, err := resource.ParseQuantity(s); err == nil && q.Value() > 0 {
		return q.Value()
	}
	return 0
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
