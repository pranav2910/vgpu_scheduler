package nodeagent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// stubProvider is a GPUProvider that returns canned processes (the detector only
// calls ListProcesses). Tag-agnostic, so the test compiles under any build tag.
type stubProvider struct{ procs []gpu.GPUProcess }

func (s *stubProvider) Name() string                                              { return "stub" }
func (s *stubProvider) ListDevices(context.Context) ([]gpu.GPUDevice, error)      { return nil, nil }
func (s *stubProvider) GetDevice(context.Context, string) (*gpu.GPUDevice, error) { return nil, nil }
func (s *stubProvider) ListProcesses(context.Context) ([]gpu.GPUProcess, error)   { return s.procs, nil }
func (s *stubProvider) Shutdown() error                                           { return nil }

const testPodUID = "3f1e6b7c-1234-5678-9abc-def012345678"

// fixture builds a temp /proc, a fake client (pod + slice + claim + job), and a
// stub provider with a process attributed to the pod via cgroup.
func fixture(t *testing.T, procUsed int64) (*SliceViolationDetector, client.Client) {
	t.Helper()
	procRoot := t.TempDir()
	const pid = 4242
	dir := filepath.Join(procRoot, strconv.Itoa(pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	cgroup := "0::/kubepods.slice/kubepods-pod3f1e6b7c_1234_5678_9abc_def012345678.slice/cri-containerd-x.scope"
	if err := os.WriteFile(filepath.Join(dir, "cgroup"), []byte(cgroup), 0o644); err != nil {
		t.Fatal(err)
	}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "wl", Namespace: "default", UID: types.UID(testPodUID),
			Annotations: map[string]string{claimRefAnnotation: "claim-1"},
		},
		Spec: corev1.PodSpec{NodeName: "node-a"},
	}
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "slice-1", Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{NodeName: "node-a", ClaimRef: "claim-1", RequestedVRAMBytes: 10 * giB},
		Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: "Ready"},
	}
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "claim-1", Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUClaimSpec{JobRef: "job-1"},
	}
	job := &vgpuv1alpha1.VGPUJob{ObjectMeta: metav1.ObjectMeta{Name: "job-1", Namespace: "default"}}

	c := fake.NewClientBuilder().WithScheme(nodeAgentScheme(t)).
		WithObjects(pod, slice, claim, job).
		WithStatusSubresource(slice, job).
		WithIndex(&corev1.Pod{}, "spec.nodeName", func(o client.Object) []string {
			return []string{o.(*corev1.Pod).Spec.NodeName}
		}).Build()

	d := NewSliceViolationDetector(c, c, "node-a", &stubProvider{
		procs: []gpu.GPUProcess{{PID: pid, DeviceUUID: "g0", UsedMemoryBytes: procUsed}},
	}, nil, time.Second, EnforcementOff)
	d.procRoot = procRoot
	return d, c
}

func TestAttribute_ProcessToSliceViaClaimRef(t *testing.T) {
	d, _ := fixture(t, 12*giB)
	// The snapshot passed in must carry the device: attribute() confirms each
	// (PID, device) pair against a second provider snapshot (the PID-reuse
	// sandwich), and the fixture's stub reports this process on "g0".
	usage, err := d.attribute(context.Background(), []gpu.GPUProcess{{PID: 4242, DeviceUUID: "g0", UsedMemoryBytes: 12 * giB}})
	if err != nil {
		t.Fatalf("attribute: %v", err)
	}
	u, ok := usage[sliceKey("default", "slice-1")]
	if !ok {
		t.Fatalf("slice not in usage map: %v", usage)
	}
	if u.used != 12*giB || u.grant != 10*giB {
		t.Fatalf("attributed used=%d grant=%d, want 12Gi/10Gi", u.used, u.grant)
	}
}

func TestDetectOnce_MarksSliceAndJobAfterHysteresis(t *testing.T) {
	d, c := fixture(t, 12*giB) // 12 used vs 10 grant → 2 GiB over (beyond tolerance)
	ctx := context.Background()

	// Below the streak threshold → not yet marked.
	for i := 1; i < sliceOveruseStreakThreshold; i++ {
		if err := d.detectOnce(ctx); err != nil {
			t.Fatalf("detectOnce: %v", err)
		}
	}
	if sliceConditionTrue(t, c, "slice-1") {
		t.Fatalf("slice marked before reaching the streak threshold")
	}
	// The threshold cycle marks it.
	if err := d.detectOnce(ctx); err != nil {
		t.Fatalf("detectOnce: %v", err)
	}
	if !sliceConditionTrue(t, c, "slice-1") {
		t.Fatalf("slice should have MemoryViolation=True after %d cycles", sliceOveruseStreakThreshold)
	}
	// Parent job mirrors the violation.
	var job vgpuv1alpha1.VGPUJob
	if err := c.Get(ctx, types.NamespacedName{Namespace: "default", Name: "job-1"}, &job); err != nil {
		t.Fatal(err)
	}
	if !conditionTrue(job.Status.Conditions, memoryViolationCondition) {
		t.Fatalf("job should mirror MemoryViolation=True")
	}
	// Metric reflects active + excess (2 GiB).
	if got := testutil.ToFloat64(telemetry.SliceMemoryViolationActive.WithLabelValues("node-a", "default", "slice-1")); got != 1 {
		t.Fatalf("violation_active metric: got %v want 1", got)
	}
	if got := testutil.ToFloat64(telemetry.SliceMemoryViolationExcessBytes.WithLabelValues("node-a", "default", "slice-1")); got != float64(2*giB) {
		t.Fatalf("excess_bytes metric: got %v want %d", got, 2*giB)
	}
}

func TestDetectOnce_NoViolationWhenWithinGrant(t *testing.T) {
	d, c := fixture(t, 8*giB) // 8 used vs 10 grant → within budget
	ctx := context.Background()
	for i := 0; i < sliceOveruseStreakThreshold+1; i++ {
		if err := d.detectOnce(ctx); err != nil {
			t.Fatalf("detectOnce: %v", err)
		}
	}
	if sliceConditionTrue(t, c, "slice-1") {
		t.Fatalf("slice within grant must not be marked")
	}
}

func sliceConditionTrue(t *testing.T, c client.Client, name string) bool {
	t.Helper()
	var s vgpuv1alpha1.VGPUSlice
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: name}, &s); err != nil {
		t.Fatal(err)
	}
	return conditionTrue(s.Status.Conditions, memoryViolationCondition)
}

func conditionTrue(conds []metav1.Condition, typ string) bool {
	for _, c := range conds {
		if c.Type == typ {
			return c.Status == metav1.ConditionTrue
		}
	}
	return false
}
