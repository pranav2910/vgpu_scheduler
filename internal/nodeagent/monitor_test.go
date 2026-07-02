package nodeagent

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func TestParseRequestedMem(t *testing.T) {
	const GiB = int64(1024 * 1024 * 1024)
	cases := map[string]int64{
		"16Gi":        16 * GiB,
		"17179869184": 17179869184,         // quantity with no unit = bytes
		"16384":       16384 * 1024 * 1024, // bare int = MiB (Run:ai/KAI convention)
		"512Mi":       512 * 1024 * 1024,
		"":            0,
		"garbage":     0,
		"0":           0,
	}
	// "17179869184" is all-digits → treated as MiB by our rule. Adjust expectation:
	cases["17179869184"] = 17179869184 * 1024 * 1024
	for in, want := range cases {
		if got := parseRequestedMem(in); got != want {
			t.Errorf("parseRequestedMem(%q) = %d, want %d", in, got, want)
		}
	}
}

func pod(ns, name string, mut func(*corev1.Pod)) *corev1.Pod {
	p := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}}
	if mut != nil {
		mut(p)
	}
	return p
}

func TestRequestedVRAM(t *testing.T) {
	const GiB = int64(1024 * 1024 * 1024)
	card := 80 * GiB
	keys := defaultRequestAnnotationKeys

	// whole-GPU resource → N × card, source nvidia_gpu_limit
	wholeGPU := pod("default", "vanilla", func(p *corev1.Pod) {
		p.Spec.Containers = []corev1.Container{{
			Name: "c",
			Resources: corev1.ResourceRequirements{
				Limits: corev1.ResourceList{nvidiaGPUResource: resource.MustParse("1")},
			},
		}}
	})
	if b, src := requestedVRAM(wholeGPU, card, keys); b != card || src != "nvidia_gpu_limit" {
		t.Errorf("whole-GPU: got (%d,%s), want (%d,nvidia_gpu_limit)", b, src, card)
	}

	// annotation (KAI/Run:ai style, MiB) → source annotation
	annPod := pod("default", "kai", func(p *corev1.Pod) {
		p.Annotations = map[string]string{"run.ai/gpu-memory": "16384"} // 16 GiB in MiB
	})
	if b, src := requestedVRAM(annPod, card, keys); b != 16*GiB || src != "annotation" {
		t.Errorf("annotation: got (%d,%s), want (%d,annotation)", b, src, 16*GiB)
	}

	// our own requested-vram annotation → source vgpu_claim
	ours := pod("default", "ours", func(p *corev1.Pod) {
		p.Annotations = map[string]string{"infrastructure.pranav2910.com/requested-vram-bytes": "17179869184"}
	})
	// RAW BYTES for our key — it must NOT hit the bare-integer-is-MiB
	// convention (Gate-3 receipt regression: 16 GiB rendered as 16 EiB).
	if b, src := requestedVRAM(ours, card, keys); src != "vgpu_claim" || b != 16*GiB {
		t.Errorf("ours: got (%d,%s), want (%d,vgpu_claim)", b, src, 16*GiB)
	}

	// claim-ref only (no size) → vgpu_claim, 0 bytes (size lives in the CRD)
	claimOnly := pod("default", "claimonly", func(p *corev1.Pod) {
		p.Annotations = map[string]string{vgpuClaimRefAnnotation: "x-claim"}
	})
	if b, src := requestedVRAM(claimOnly, card, keys); b != 0 || src != "vgpu_claim" {
		t.Errorf("claim-only: got (%d,%s), want (0,vgpu_claim)", b, src)
	}

	// no GPU request at all → unknown, 0
	none := pod("default", "cpu-only", nil)
	if b, src := requestedVRAM(none, card, keys); b != 0 || src != "unknown" {
		t.Errorf("none: got (%d,%s), want (0,unknown)", b, src)
	}

	// custom annotation key honored
	custom := pod("default", "custom", func(p *corev1.Pod) {
		p.Annotations = map[string]string{"my.org/vram": "8Gi"}
	})
	if b, src := requestedVRAM(custom, card, []string{"my.org/vram"}); b != 8*GiB || src != "annotation" {
		t.Errorf("custom key: got (%d,%s), want (%d,annotation)", b, src, 8*GiB)
	}
}

// fakePodReader is a minimal client.Reader: the observer only ever List()s pods
// by node, so a canned list is enough (the field selector is irrelevant here).
type fakePodReader struct{ pods []corev1.Pod }

func (f *fakePodReader) List(_ context.Context, list client.ObjectList, _ ...client.ListOption) error {
	pl, ok := list.(*corev1.PodList)
	if !ok {
		return fmt.Errorf("fakePodReader: unexpected list type %T", list)
	}
	pl.Items = append([]corev1.Pod(nil), f.pods...)
	return nil
}

func (f *fakePodReader) Get(context.Context, client.ObjectKey, client.Object, ...client.GetOption) error {
	return fmt.Errorf("fakePodReader: Get not implemented")
}

// resetMonitorGauges isolates observe() tests from each other (the telemetry
// registry is package-global).
func resetMonitorGauges() {
	telemetry.MonitorPodRequestedVRAMBytes.Reset()
	telemetry.MonitorPodUsedVRAMBytes.Reset()
	telemetry.MonitorGPUTotalVRAMBytes.Reset()
	telemetry.MonitorGPUUsedVRAMBytes.Reset()
	telemetry.MonitorGPUFreeVRAMBytes.Reset()
}

// TestObserveSkipsNonRunningPods is the regression test for the missing pod-phase
// filter in observe(): a finished (Succeeded/Failed) or not-yet-started (Pending)
// pod still carries its request in spec but holds no live GPU process, so without
// the filter it shows up as 100% phantom waste. The report must count only RUNNING
// pods. (No GPU needed: an empty-but-working fake provider drives the loop.)
func TestObserveSkipsNonRunningPods(t *testing.T) {
	resetMonitorGauges()
	const GiB = int64(1024 * 1024 * 1024)
	mkpod := func(name string, phase corev1.PodPhase) corev1.Pod {
		return corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Namespace:   "default",
				Name:        name,
				Annotations: map[string]string{"gpu-memory": "16384"}, // 16 GiB (MiB convention)
			},
			Status: corev1.PodStatus{Phase: phase},
		}
	}
	reader := &fakePodReader{pods: []corev1.Pod{
		mkpod("running-pod", corev1.PodRunning),
		mkpod("succeeded-pod", corev1.PodSucceeded),
		mkpod("failed-pod", corev1.PodFailed),
		mkpod("pending-pod", corev1.PodPending),
	}}
	m := NewMonitorObserver(reader, "node1", gpu.NewFakeProvider(nil, nil), time.Second, nil)

	m.observe(context.Background())

	// Exactly one requested series — the Running pod. The three non-running pods
	// must NOT appear (else they read as 100% waste).
	if n := testutil.CollectAndCount(telemetry.MonitorPodRequestedVRAMBytes); n != 1 {
		t.Fatalf("requested series = %d, want 1 (only the Running pod; finished/pending pods must not be reported as waste)", n)
	}
	if got := testutil.ToFloat64(telemetry.MonitorPodRequestedVRAMBytes.WithLabelValues("default", "running-pod", "node1", "annotation")); got != float64(16*GiB) {
		t.Errorf("running-pod requested = %v, want %d", got, 16*GiB)
	}
}

// TestObservePIDReuseSandwich is the regression test for PID-reuse
// misattribution: a GPU process that exits between the NVML snapshot and the
// /proc cgroup read can have its PID recycled into ANOTHER pod's cgroup,
// charging the dead process's VRAM to the wrong pod. observe() now takes two
// NVML snapshots around the cgroup resolution and attributes only (PID,
// device) pairs present in both, with snapshot-2 bytes.
func TestObservePIDReuseSandwich(t *testing.T) {
	resetMonitorGauges()
	const GiB = int64(1024 * 1024 * 1024)

	// Synthetic host /proc: two pods' GPU processes.
	procRoot := t.TempDir()
	writeCgroup := func(pid int, uid string) {
		t.Helper()
		dir := procRoot + "/" + strconv.Itoa(pid)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		// systemd-driver cgroup v2 form; the parser normalizes _ back to -.
		line := "0::/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod" +
			strings.ReplaceAll(uid, "-", "_") + ".slice/cri-containerd-abc.scope\n"
		if err := os.WriteFile(dir+"/cgroup", []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	const uidA = "11111111-1111-1111-1111-111111111111"
	const uidB = "22222222-2222-2222-2222-222222222222"
	writeCgroup(101, uidA)
	writeCgroup(202, uidB)

	mkpod := func(name, uid string) corev1.Pod {
		return corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Namespace: "default", Name: name, UID: types.UID(uid),
				Annotations: map[string]string{"gpu-memory": "8192"},
			},
			Status: corev1.PodStatus{Phase: corev1.PodRunning},
		}
	}
	reader := &fakePodReader{pods: []corev1.Pod{mkpod("pod-a", uidA), mkpod("pod-b", uidB)}}

	dev := gpu.GPUDevice{UUID: "GPU-T", TotalMemoryBytes: 80 * GiB, FreeMemoryBytes: 80 * GiB, Healthy: true}
	// Snapshot #1: both processes on the GPU. Snapshot #2: pod-b's process
	// (202) exited — its PID may already belong to someone else — and pod-a's
	// usage moved 4 → 5 GiB (the fresher figure must win).
	provider := gpu.NewFakeProviderWithProcessSequence([]gpu.GPUDevice{dev},
		[]gpu.GPUProcess{
			{PID: 101, DeviceUUID: "GPU-T", UsedMemoryBytes: 4 * GiB},
			{PID: 202, DeviceUUID: "GPU-T", UsedMemoryBytes: 6 * GiB},
		},
		[]gpu.GPUProcess{
			{PID: 101, DeviceUUID: "GPU-T", UsedMemoryBytes: 5 * GiB},
		},
	)

	m := NewMonitorObserver(reader, "node1", provider, time.Second, nil)
	m.procRoot = procRoot
	m.observe(context.Background())

	// pod-a attributed with snapshot-2 bytes; pod-b (vanished PID) NOT charged.
	if got := testutil.ToFloat64(telemetry.MonitorPodUsedVRAMBytes.WithLabelValues("default", "pod-a", "node1", "GPU-T")); got != float64(5*GiB) {
		t.Errorf("pod-a used = %v, want %d (snapshot-2 bytes)", got, 5*GiB)
	}
	if n := testutil.CollectAndCount(telemetry.MonitorPodUsedVRAMBytes); n != 1 {
		t.Errorf("used series = %d, want 1 — a PID that vanished between snapshots must not be attributed (PID-reuse hazard)", n)
	}
}

// TestObserveAtomicSnapshot is the regression test for the reset-before-fetch
// window: observe() used to Reset all gauges and then do NVML + API-server I/O
// before re-populating, so (a) a failing cycle blanked the whole report for an
// interval and (b) a degraded provider published requested-only series, which
// the report renders as 100% phantom waste. Now a cycle is atomic: a failing
// fetch must leave the previous complete snapshot untouched, and a provider
// that never worked must publish nothing at all.
func TestObserveAtomicSnapshot(t *testing.T) {
	resetMonitorGauges()
	const GiB = int64(1024 * 1024 * 1024)
	running := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   "default",
			Name:        "keeper",
			Annotations: map[string]string{"gpu-memory": "8192"}, // 8 GiB
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
	reader := &fakePodReader{pods: []corev1.Pod{running}}
	dev := gpu.GPUDevice{UUID: "GPU-T", TotalMemoryBytes: 80 * GiB, FreeMemoryBytes: 80 * GiB, Healthy: true}

	// Cycle 1: working provider → snapshot published.
	good := NewMonitorObserver(reader, "node1", gpu.NewFakeProvider([]gpu.GPUDevice{dev}, nil), time.Second, nil)
	good.observe(context.Background())
	if n := testutil.CollectAndCount(telemetry.MonitorPodRequestedVRAMBytes); n != 1 {
		t.Fatalf("setup: requested series = %d, want 1", n)
	}

	// Cycle 2: provider fails → the previous snapshot must survive, not blank.
	bad := NewMonitorObserver(reader, "node1", gpu.NewFakeProvider([]gpu.GPUDevice{dev}, errors.New("nvml flake")), time.Second, nil)
	bad.observe(context.Background())
	if n := testutil.CollectAndCount(telemetry.MonitorPodRequestedVRAMBytes); n != 1 {
		t.Fatalf("after failing cycle: requested series = %d, want 1 (previous snapshot must survive a transient fetch error)", n)
	}
	if got := testutil.ToFloat64(telemetry.MonitorPodRequestedVRAMBytes.WithLabelValues("default", "keeper", "node1", "annotation")); got != float64(8*GiB) {
		t.Errorf("after failing cycle: requested = %v, want %d", got, 8*GiB)
	}
	if n := testutil.CollectAndCount(telemetry.MonitorGPUTotalVRAMBytes); n != 1 {
		t.Errorf("after failing cycle: gpu total series = %d, want 1", n)
	}

	// A provider that NEVER worked publishes nothing (no requested-only phantom).
	resetMonitorGauges()
	degraded := NewMonitorObserver(reader, "node1", gpu.NewDegradedProvider(errors.New("no driver")), time.Second, nil)
	degraded.observe(context.Background())
	if n := testutil.CollectAndCount(telemetry.MonitorPodRequestedVRAMBytes); n != 0 {
		t.Errorf("degraded provider: requested series = %d, want 0 (requested-only output renders as 100%% phantom waste)", n)
	}
}
