package controller

import (
	"context"
	"strconv"
	"strings"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/testutil"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func mkJob(name string, requested int64, phase vgpuv1alpha1.VGPUJobPhase) *vgpuv1alpha1.VGPUJob {
	return &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{
				Spec: vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: requested},
			},
		},
		Status: vgpuv1alpha1.VGPUJobStatus{Phase: phase},
	}
}

func mkProfile(name string, recommended, peak int64, conf vgpuv1alpha1.ProfileConfidence) *vgpuv1alpha1.VGPUWorkloadProfile {
	return &vgpuv1alpha1.VGPUWorkloadProfile{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Status: vgpuv1alpha1.VGPUWorkloadProfileStatus{
			RecommendedVRAMBytes:  recommended,
			PeakObservedVRAMBytes: peak,
			Confidence:            conf,
		},
	}
}

// advisoryReconciler runs in `warn` mode so the existing tests observe the
// Warning event (the pre-3.7 default behavior). recommendOnly suppresses events.
func advisoryReconciler(t *testing.T, objs ...client.Object) (*VGPUJobReconciler, client.Client, *record.FakeRecorder) {
	return advisoryReconcilerMode(t, recommendation.Warn, objs...)
}

func advisoryReconcilerMode(t *testing.T, mode recommendation.Mode, objs ...client.Object) (*VGPUJobReconciler, client.Client, *record.FakeRecorder) {
	t.Helper()
	c := fake.NewClientBuilder().WithScheme(profileScheme(t)).
		WithObjects(objs...).
		WithStatusSubresource(&vgpuv1alpha1.VGPUJob{}, &vgpuv1alpha1.VGPUWorkloadProfile{}).
		Build()
	rec := record.NewFakeRecorder(16)
	return &VGPUJobReconciler{Client: c, Recorder: rec, RecommendationMode: mode}, c, rec
}

func runAdvisory(t *testing.T, r *VGPUJobReconciler, c client.Client, job string) {
	t.Helper()
	var j vgpuv1alpha1.VGPUJob
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: job}, &j); err != nil {
		t.Fatal(err)
	}
	if err := r.reconcileAdvisory(context.Background(), &j); err != nil {
		t.Fatalf("reconcileAdvisory: %v", err)
	}
}

func getJob(t *testing.T, c client.Client, name string) *vgpuv1alpha1.VGPUJob {
	t.Helper()
	var j vgpuv1alpha1.VGPUJob
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: name}, &j); err != nil {
		t.Fatal(err)
	}
	return &j
}

func underprovisioned(j *vgpuv1alpha1.VGPUJob) bool {
	return apimeta.IsStatusConditionTrue(j.Status.Conditions, advisoryConditionType)
}

func TestAdvisory_FiresWhenUnderprovisionedAndConfident(t *testing.T) {
	r, c, rec := advisoryReconciler(t,
		mkJob("job1", 4*giB, vgpuv1alpha1.JobPhaseScheduled),
		mkProfile("job1", 10*giB, 9*giB, vgpuv1alpha1.ProfileConfidenceHigh),
	)
	runAdvisory(t, r, c, "job1")

	j := getJob(t, c, "job1")
	if !underprovisioned(j) {
		t.Fatalf("expected Underprovisioned=True")
	}
	if got := j.Annotations[recommendedVRAMAnnotation]; got != strconv.FormatInt(10*giB, 10) {
		t.Fatalf("annotation=%q want %d", got, 10*giB)
	}
	if got := testutil.ToFloat64(telemetry.WorkloadUnderprovisioned.WithLabelValues("default", "job1")); got != 1 {
		t.Fatalf("metric=%v want 1", got)
	}
	// NEVER blocks / changes phase.
	if j.Status.Phase != vgpuv1alpha1.JobPhaseScheduled {
		t.Fatalf("advisory changed job phase to %q — must be non-blocking", j.Status.Phase)
	}
	select {
	case e := <-rec.Events:
		if !strings.Contains(e, "UnderprovisionedRequest") {
			t.Fatalf("unexpected event: %q", e)
		}
	default:
		t.Fatalf("expected an UnderprovisionedRequest event")
	}
}

// 3.7: recommendOnly (the new default) still sets the condition/annotation/metric
// but emits NO event.
func TestAdvisory_RecommendOnly_NoEvent(t *testing.T) {
	r, c, rec := advisoryReconcilerMode(t, recommendation.RecommendOnly,
		mkJob("job1", 4*giB, vgpuv1alpha1.JobPhaseScheduled),
		mkProfile("job1", 10*giB, 9*giB, vgpuv1alpha1.ProfileConfidenceHigh),
	)
	runAdvisory(t, r, c, "job1")
	if !underprovisioned(getJob(t, c, "job1")) {
		t.Fatal("recommendOnly still sets the Underprovisioned condition")
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("recommendOnly must emit NO event, got %q", e)
	default:
	}
}

// 3.7: an undersized request carrying the override annotation is still flagged,
// but the condition records it as an intentional override and emits no event.
func TestAdvisory_OverrideNoted(t *testing.T) {
	job := mkJob("job1", 4*giB, vgpuv1alpha1.JobPhaseScheduled)
	job.Annotations = map[string]string{recommendation.OverrideAnnotation: "true"}
	r, c, rec := advisoryReconcilerMode(t, recommendation.RequireOverride, job,
		mkProfile("job1", 10*giB, 9*giB, vgpuv1alpha1.ProfileConfidenceHigh))
	runAdvisory(t, r, c, "job1")

	cond := apimeta.FindStatusCondition(getJob(t, c, "job1").Status.Conditions, advisoryConditionType)
	if cond == nil || cond.Status != metav1.ConditionTrue {
		t.Fatal("expected Underprovisioned=True even with override")
	}
	if cond.Reason != "RequestBelowRecommendationOverridden" {
		t.Fatalf("expected overridden reason, got %q", cond.Reason)
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("override is the user's explicit choice — no event; got %q", e)
	default:
	}
}

func TestAdvisory_QuietWhenAdequate(t *testing.T) {
	r, c, _ := advisoryReconciler(t,
		mkJob("job1", 12*giB, vgpuv1alpha1.JobPhaseScheduled),
		mkProfile("job1", 10*giB, 9*giB, vgpuv1alpha1.ProfileConfidenceHigh),
	)
	runAdvisory(t, r, c, "job1")
	j := getJob(t, c, "job1")
	if underprovisioned(j) || j.Annotations[recommendedVRAMAnnotation] != "" {
		t.Fatalf("adequate request must not trigger the advisory")
	}
	if got := testutil.ToFloat64(telemetry.WorkloadUnderprovisioned.WithLabelValues("default", "job1")); got != 0 {
		t.Fatalf("metric=%v want 0", got)
	}
}

func TestAdvisory_QuietWhenLowConfidence(t *testing.T) {
	r, c, _ := advisoryReconciler(t,
		mkJob("job1", 4*giB, vgpuv1alpha1.JobPhaseScheduled),
		mkProfile("job1", 10*giB, 9*giB, vgpuv1alpha1.ProfileConfidenceLow),
	)
	runAdvisory(t, r, c, "job1")
	if underprovisioned(getJob(t, c, "job1")) {
		t.Fatalf("low-confidence recommendation must not trigger the advisory")
	}
}

func TestAdvisory_QuietWhenNoProfile(t *testing.T) {
	r, c, _ := advisoryReconciler(t, mkJob("job1", 4*giB, vgpuv1alpha1.JobPhaseScheduled))
	runAdvisory(t, r, c, "job1")
	if underprovisioned(getJob(t, c, "job1")) {
		t.Fatalf("no profile → no advisory")
	}
}

func TestAdvisory_ClearsWhenRequestRaised(t *testing.T) {
	r, c, _ := advisoryReconciler(t,
		mkJob("job1", 4*giB, vgpuv1alpha1.JobPhaseScheduled),
		mkProfile("job1", 10*giB, 9*giB, vgpuv1alpha1.ProfileConfidenceHigh),
	)
	runAdvisory(t, r, c, "job1")
	if !underprovisioned(getJob(t, c, "job1")) {
		t.Fatalf("setup: expected advisory to fire")
	}

	// Raise the request above the recommendation → advisory must clear.
	j := getJob(t, c, "job1")
	j.Spec.ClaimTemplate.Spec.RequestedVRAMBytes = 12 * giB
	if err := c.Update(context.Background(), j); err != nil {
		t.Fatal(err)
	}
	runAdvisory(t, r, c, "job1")

	cleared := getJob(t, c, "job1")
	if underprovisioned(cleared) || cleared.Annotations[recommendedVRAMAnnotation] != "" {
		t.Fatalf("advisory must clear when the request is raised")
	}
	if got := testutil.ToFloat64(telemetry.WorkloadUnderprovisioned.WithLabelValues("default", "job1")); got != 0 {
		t.Fatalf("metric=%v want 0 after clear", got)
	}
}
