package controller

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const giB = int64(1) << 30

func profileScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func mkClaim(name, job string) *vgpuv1alpha1.VGPUClaim {
	return &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUClaimSpec{JobRef: job},
	}
}

// mkStatSlice builds a slice already carrying node-agent runtime stats.
func mkStatSlice(name, claim string, req, peak, avg, obs, viol, warn, evict int64) *vgpuv1alpha1.VGPUSlice {
	return &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{ClaimRef: claim, RequestedVRAMBytes: req},
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase:                 "Ready",
			PeakObservedVRAMBytes: peak,
			AvgObservedVRAMBytes:  avg,
			Observations:          obs,
			ViolationCount:        viol,
			SoftWarnCount:         warn,
			EvictionCount:         evict,
		},
	}
}

func buildReconciler(t *testing.T, objs ...client.Object) (*VGPUWorkloadProfileReconciler, client.Client) {
	t.Helper()
	c := fake.NewClientBuilder().WithScheme(profileScheme(t)).
		WithObjects(objs...).
		WithStatusSubresource(&vgpuv1alpha1.VGPUWorkloadProfile{}, &vgpuv1alpha1.VGPUSlice{}).
		Build()
	return &VGPUWorkloadProfileReconciler{Client: c}, c
}

func reconcileJob(t *testing.T, r *VGPUWorkloadProfileReconciler, job string) {
	t.Helper()
	if _, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Namespace: "default", Name: job},
	}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
}

func getProfile(t *testing.T, c client.Client, name string) *vgpuv1alpha1.VGPUWorkloadProfile {
	t.Helper()
	var p vgpuv1alpha1.VGPUWorkloadProfile
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: name}, &p); err != nil {
		t.Fatalf("get profile %s: %v", name, err)
	}
	return &p
}

func TestProfile_AggregatesAndRecommends(t *testing.T) {
	// Requested 4 GiB, peaks at 9 GiB, 150 samples → under-provisioned.
	r, c := buildReconciler(t,
		mkClaim("c1", "job1"),
		mkStatSlice("c1-slice", "c1", 4*giB, 9*giB, 7*giB, 150, 37, 37, 4),
	)
	reconcileJob(t, r, "job1")

	p := getProfile(t, c, "job1")
	if p.Status.RequestedVRAMBytes != 4*giB || p.Status.PeakObservedVRAMBytes != 9*giB {
		t.Fatalf("requested=%d peak=%d, want 4Gi/9Gi", p.Status.RequestedVRAMBytes, p.Status.PeakObservedVRAMBytes)
	}
	if want := vgpuv1alpha1.RecommendedVRAMBytes(9 * giB); p.Status.RecommendedVRAMBytes != want {
		t.Fatalf("recommended=%d want %d", p.Status.RecommendedVRAMBytes, want)
	}
	if p.Status.EvictionCount != 4 || p.Status.ViolationCount != 37 {
		t.Fatalf("counts evict=%d viol=%d, want 4/37", p.Status.EvictionCount, p.Status.ViolationCount)
	}
	// First sighting: the peak just appeared (grew from 0), so confidence is held
	// at Medium even with 150 samples until the peak proves stable.
	if p.Status.Confidence != vgpuv1alpha1.ProfileConfidenceMedium {
		t.Fatalf("confidence=%v want Medium on first aggregation", p.Status.Confidence)
	}
	if !apimeta.IsStatusConditionTrue(p.Status.Conditions, "Underprovisioned") {
		t.Fatalf("expected Underprovisioned=True (requested 4Gi << recommended)")
	}
}

func TestProfile_ConfidenceHighAfterPeakStable(t *testing.T) {
	r, c := buildReconciler(t,
		mkClaim("c1", "job1"),
		mkStatSlice("c1-slice", "c1", 4*giB, 9*giB, 7*giB, 150, 0, 0, 0),
	)
	reconcileJob(t, r, "job1") // first: peak discovered → Medium
	if got := getProfile(t, c, "job1").Status.Confidence; got != vgpuv1alpha1.ProfileConfidenceMedium {
		t.Fatalf("confidence=%v want Medium after first reconcile", got)
	}
	reconcileJob(t, r, "job1") // second: peak unchanged → stable → High
	if got := getProfile(t, c, "job1").Status.Confidence; got != vgpuv1alpha1.ProfileConfidenceHigh {
		t.Fatalf("confidence=%v want High after peak stabilized", got)
	}
}

// Adversarial: a gang job with several slices on (conceptually) different nodes.
func TestProfile_MultiSliceAggregation(t *testing.T) {
	r, c := buildReconciler(t,
		mkClaim("c1", "job1"), mkClaim("c2", "job1"),
		mkStatSlice("c1-slice", "c1", 2*giB, 5*giB, 4*giB, 80, 3, 3, 1),
		mkStatSlice("c2-slice", "c2", 2*giB, 9*giB, 6*giB, 120, 5, 5, 2),
		// a slice from a DIFFERENT job must not leak in
		mkClaim("other", "job2"),
		mkStatSlice("other-slice", "other", 2*giB, 20*giB, 18*giB, 999, 99, 99, 99),
	)
	reconcileJob(t, r, "job1")

	p := getProfile(t, c, "job1")
	if p.Status.PeakObservedVRAMBytes != 9*giB { // max across the two slices
		t.Fatalf("peak=%d want 9Gi (max of slices, not the other job)", p.Status.PeakObservedVRAMBytes)
	}
	if p.Status.Observations != 120 { // max sample count
		t.Fatalf("observations=%d want 120", p.Status.Observations)
	}
	if p.Status.EvictionCount != 3 { // summed: 1 + 2
		t.Fatalf("evictionCount=%d want 3 (summed across slices)", p.Status.EvictionCount)
	}
	if p.Status.ViolationCount != 8 { // summed: 3 + 5
		t.Fatalf("violationCount=%d want 8", p.Status.ViolationCount)
	}
}

// Adversarial: the profile must survive the job's slices disappearing (eviction
// / job deletion) — it persists for cross-run learning.
func TestProfile_SurvivesSliceDisappearance(t *testing.T) {
	r, c := buildReconciler(t,
		mkClaim("c1", "job1"),
		mkStatSlice("c1-slice", "c1", 4*giB, 9*giB, 7*giB, 150, 10, 10, 4),
	)
	reconcileJob(t, r, "job1")
	before := getProfile(t, c, "job1")
	if before.Status.EvictionCount != 4 {
		t.Fatalf("setup: evictionCount=%d want 4", before.Status.EvictionCount)
	}

	// Slices + claim gone (job torn down). Reconcile must NOT zero the profile.
	if err := c.DeleteAllOf(context.Background(), &vgpuv1alpha1.VGPUSlice{}, client.InNamespace("default")); err != nil {
		t.Fatal(err)
	}
	if err := c.DeleteAllOf(context.Background(), &vgpuv1alpha1.VGPUClaim{}, client.InNamespace("default")); err != nil {
		t.Fatal(err)
	}
	reconcileJob(t, r, "job1")

	after := getProfile(t, c, "job1")
	if after.Status.PeakObservedVRAMBytes != 9*giB || after.Status.EvictionCount != 4 {
		t.Fatalf("profile regressed after teardown: peak=%d evict=%d, want 9Gi/4",
			after.Status.PeakObservedVRAMBytes, after.Status.EvictionCount)
	}
}

// Adversarial: peak is monotonic — a later, lower observation (e.g. after a
// node-agent restart re-seeds lower) must not lower the recommendation.
func TestProfile_PeakIsMonotonic(t *testing.T) {
	r, c := buildReconciler(t,
		mkClaim("c1", "job1"),
		mkStatSlice("c1-slice", "c1", 4*giB, 9*giB, 7*giB, 150, 0, 0, 0),
	)
	reconcileJob(t, r, "job1")
	rec := getProfile(t, c, "job1").Status.RecommendedVRAMBytes

	// Slice now reports a LOWER peak (5 GiB).
	var s vgpuv1alpha1.VGPUSlice
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: "c1-slice"}, &s); err != nil {
		t.Fatal(err)
	}
	s.Status.PeakObservedVRAMBytes = 5 * giB
	if err := c.Status().Update(context.Background(), &s); err != nil {
		t.Fatal(err)
	}
	reconcileJob(t, r, "job1")

	p := getProfile(t, c, "job1")
	if p.Status.PeakObservedVRAMBytes != 9*giB || p.Status.RecommendedVRAMBytes != rec {
		t.Fatalf("peak regressed: peak=%d rec=%d, want 9Gi/%d", p.Status.PeakObservedVRAMBytes, p.Status.RecommendedVRAMBytes, rec)
	}
}

func TestProfile_NoProfileWhenNoStatsYet(t *testing.T) {
	// Claim exists but its slice has no observations and isn't even present.
	r, c := buildReconciler(t, mkClaim("c1", "job1"))
	reconcileJob(t, r, "job1")
	var p vgpuv1alpha1.VGPUWorkloadProfile
	err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: "job1"}, &p)
	if err == nil {
		t.Fatalf("no profile should be created before any slice observation exists")
	}
}
