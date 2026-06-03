package nodeagent

import (
	"context"
	"strconv"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func TestParseEnforcementMode(t *testing.T) {
	cases := map[string]EnforcementMode{
		"":         EnforcementSoftWarn, // default is non-destructive softwarn
		"softwarn": EnforcementSoftWarn,
		"SoftWarn": EnforcementSoftWarn,
		" warn ":   EnforcementSoftWarn,
		"off":      EnforcementOff,
		"none":     EnforcementOff,
		"observe":  EnforcementOff,
		"evict":    EnforcementSoftWarn, // hard modes are rejected → softwarn
		"throttle": EnforcementSoftWarn,
		"garbage":  EnforcementSoftWarn,
	}
	for in, want := range cases {
		if got := ParseEnforcementMode(in); got != want {
			t.Errorf("ParseEnforcementMode(%q) = %v, want %v", in, got, want)
		}
	}
}

// TestEnforce_SoftWarnStampsPodAfterGraceAndClearsOnRecovery is the core 3.4c
// state-machine test: within grace nothing is stamped; past grace the pod is
// labeled/annotated and the slice/job carry a MemoryEnforcement condition; on
// recovery every surface is reversed. The pod is never deleted or phase-changed.
func TestEnforce_SoftWarnStampsPodAfterGraceAndClearsOnRecovery(t *testing.T) {
	d, c := fixture(t, 12*giB) // 12 used vs 10 grant → 2 GiB over
	d.enforceMode = EnforcementSoftWarn
	clock := time.Unix(1_700_000_000, 0)
	d.now = func() time.Time { return clock }
	ctx := context.Background()

	// Drive past the 3.4b streak threshold → the slice becomes "violating",
	// anchoring the grace timer. Still within grace, so no enforcement yet.
	for i := 0; i < sliceOveruseStreakThreshold; i++ {
		if err := d.detectOnce(ctx); err != nil {
			t.Fatalf("detectOnce: %v", err)
		}
	}
	if podStamped(t, c, "wl") {
		t.Fatalf("pod must NOT be stamped within the grace period")
	}
	if got := testutil.ToFloat64(telemetry.MemoryEnforcementActive.WithLabelValues("node-a", "default", "slice-1")); got != 0 {
		t.Fatalf("enforcement_active = %v within grace, want 0", got)
	}

	// Advance past the grace period; the next cycle engages soft enforcement.
	clock = clock.Add(enforcementGracePeriod + time.Second)
	if err := d.detectOnce(ctx); err != nil {
		t.Fatalf("detectOnce: %v", err)
	}

	pod := getPod(t, c, "wl")
	if pod.Labels[podViolationLabel] != "true" {
		t.Fatalf("pod should carry the %s=true label, got %v", podViolationLabel, pod.Labels)
	}
	if pod.Annotations[podEnforcementAnno] != "SoftWarn" {
		t.Fatalf("pod should carry enforcement=SoftWarn, got %q", pod.Annotations[podEnforcementAnno])
	}
	if pod.Annotations[podExcessBytesAnno] != strconv.FormatInt(2*giB, 10) {
		t.Fatalf("excess annotation = %q, want %d", pod.Annotations[podExcessBytesAnno], 2*giB)
	}
	if pod.Annotations[podDeadlineAnno] == "" || pod.Annotations[podViolationSinceAnno] == "" {
		t.Fatalf("pod should carry violation-since + enforcement-deadline annotations")
	}
	if pod.Annotations[podEnforcementNoteAnno] == "" {
		t.Fatalf("pod should carry the explicit 'informational deadline' note annotation")
	}
	// The pod is untouched beyond metadata — never evicted / phase-changed.
	if pod.DeletionTimestamp != nil {
		t.Fatalf("soft enforcement must NOT delete the pod")
	}
	if !sliceEnforcementTrue(t, c, "slice-1") {
		t.Fatalf("slice MemoryEnforcement condition should be True after grace")
	}
	var job vgpuv1alpha1.VGPUJob
	if err := c.Get(ctx, types.NamespacedName{Namespace: "default", Name: "job-1"}, &job); err != nil {
		t.Fatal(err)
	}
	if !conditionTrue(job.Status.Conditions, memoryEnforcementCondition) {
		t.Fatalf("job should mirror MemoryEnforcement=True")
	}
	if got := testutil.ToFloat64(telemetry.MemoryEnforcementActive.WithLabelValues("node-a", "default", "slice-1")); got != 1 {
		t.Fatalf("enforcement_active = %v after grace, want 1", got)
	}

	// Recovery: usage drops within grant → next cycle reverses every surface.
	d.provider.(*stubProvider).procs[0].UsedMemoryBytes = 8 * giB
	clock = clock.Add(time.Minute)
	if err := d.detectOnce(ctx); err != nil {
		t.Fatalf("detectOnce: %v", err)
	}
	if podStamped(t, c, "wl") {
		t.Fatalf("pod surfaces must be cleared on recovery")
	}
	recovered := getPod(t, c, "wl")
	if recovered.Annotations[podEnforcementAnno] != "" || recovered.Annotations[podDeadlineAnno] != "" {
		t.Fatalf("enforcement annotations must be removed on recovery, got %v", recovered.Annotations)
	}
	// The unrelated claim-ref annotation must survive the cleanup.
	if recovered.Annotations[claimRefAnnotation] != "claim-1" {
		t.Fatalf("cleanup clobbered an unrelated annotation: %v", recovered.Annotations)
	}
	if sliceEnforcementTrue(t, c, "slice-1") {
		t.Fatalf("slice MemoryEnforcement should be False after recovery")
	}
	if got := testutil.ToFloat64(telemetry.MemoryEnforcementActive.WithLabelValues("node-a", "default", "slice-1")); got != 0 {
		t.Fatalf("enforcement_active = %v after recovery, want 0", got)
	}
}

// TestEnforce_OffModeDoesNotStampPod confirms mode=off keeps 3.4b marking but
// engages no enforcement surfaces (no pod mutation) regardless of grace.
func TestEnforce_OffModeDoesNotStampPod(t *testing.T) {
	d, c := fixture(t, 12*giB)
	d.enforceMode = EnforcementOff
	clock := time.Unix(1_700_000_000, 0)
	d.now = func() time.Time { return clock }
	ctx := context.Background()

	for i := 0; i < sliceOveruseStreakThreshold+1; i++ {
		clock = clock.Add(enforcementGracePeriod) // well past any grace
		if err := d.detectOnce(ctx); err != nil {
			t.Fatalf("detectOnce: %v", err)
		}
	}
	if podStamped(t, c, "wl") {
		t.Fatalf("off mode must never stamp pods")
	}
	// 3.4b marking is independent of enforcement mode and must still fire.
	if !sliceConditionTrue(t, c, "slice-1") {
		t.Fatalf("3.4b MemoryViolation should still mark with enforcement off")
	}
}

// podBlindClient wraps a client.Client but returns NotFound for Pod Gets — it
// simulates the node agent's CACHED client, which runs no Pod informer. All
// other reads and every write pass through. It guards the regression the A10
// E2E caught: pod stamping must read via the (direct) apiReader, not the cached
// client, or the over-using pod is never labeled/annotated on a real cluster.
type podBlindClient struct{ client.Client }

func (p podBlindClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	if _, ok := obj.(*corev1.Pod); ok {
		return apierrors.NewNotFound(schema.GroupResource{Resource: "pods"}, key.Name)
	}
	return p.Client.Get(ctx, key, obj, opts...)
}

// TestStampPod_ReadsViaAPIReaderNotCachedClient drives a violation past grace
// with a pod-blind cached client; the pod must still be stamped (proving the
// read goes through apiReader). Reverting stampPod to d.client.Get fails here.
func TestStampPod_ReadsViaAPIReaderNotCachedClient(t *testing.T) {
	d, c := fixture(t, 12*giB)
	d.client = podBlindClient{c} // cached client: cannot Get pods
	d.apiReader = c              // direct reader: can
	d.enforceMode = EnforcementSoftWarn
	clock := time.Unix(1_700_000_000, 0)
	d.now = func() time.Time { return clock }
	ctx := context.Background()

	for i := 0; i < sliceOveruseStreakThreshold; i++ {
		if err := d.detectOnce(ctx); err != nil {
			t.Fatalf("detectOnce: %v", err)
		}
	}
	clock = clock.Add(enforcementGracePeriod + time.Second)
	if err := d.detectOnce(ctx); err != nil {
		t.Fatalf("detectOnce: %v", err)
	}
	if !podStamped(t, c, "wl") {
		t.Fatalf("pod must be stamped via apiReader even when the cached client is pod-blind")
	}
}

func getPod(t *testing.T, c client.Client, name string) *corev1.Pod {
	t.Helper()
	var p corev1.Pod
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: name}, &p); err != nil {
		t.Fatal(err)
	}
	return &p
}

func podStamped(t *testing.T, c client.Client, name string) bool {
	t.Helper()
	return getPod(t, c, name).Labels[podViolationLabel] == "true"
}

func sliceEnforcementTrue(t *testing.T, c client.Client, name string) bool {
	t.Helper()
	var s vgpuv1alpha1.VGPUSlice
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: name}, &s); err != nil {
		t.Fatal(err)
	}
	return conditionTrue(s.Status.Conditions, memoryEnforcementCondition)
}
