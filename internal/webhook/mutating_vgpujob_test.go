package webhook

import (
	"context"
	"testing"

	"encoding/json"
	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/testutil"
	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

func resizerWith(t *testing.T, mode recommendation.Mode, objs ...client.Object) *JobAutoResizer {
	s := jobValidatorScheme(t)
	c := fake.NewClientBuilder().WithScheme(s).WithObjects(objs...).Build()
	return NewJobAutoResizer(c, admission.NewDecoder(s), mode)
}

// A resize emits a JSON patch; a no-op admits with no patch.
func TestJobAutoResizer(t *testing.T) {
	const (
		req16 = int64(16_000_000_000)
		rec24 = int64(24_000_000_000)
	)
	hi := vgpuv1alpha1.ProfileConfidenceHigh
	lo := vgpuv1alpha1.ProfileConfidenceLow

	cases := []struct {
		name      string
		mode      recommendation.Mode
		profile   *vgpuv1alpha1.VGPUWorkloadProfile
		override  bool
		wantPatch bool
	}{
		{"autoResize + High + undersized → PATCH", recommendation.AutoResize, profileWith("w", rec24, hi), false, true},
		{"autoResize + override → no patch", recommendation.AutoResize, profileWith("w", rec24, hi), true, false},
		{"autoResize + Low → no patch (safety gate)", recommendation.AutoResize, profileWith("w", rec24, lo), false, false},
		{"autoResize + no profile → no patch (fail-open)", recommendation.AutoResize, nil, false, false},
		{"recommendOnly → no patch (mode gate)", recommendation.RecommendOnly, profileWith("w", rec24, hi), false, false},
		{"requireOverride → no patch (mutation is autoResize-only)", recommendation.RequireOverride, profileWith("w", rec24, hi), false, false},
	}
	for _, c := range cases {
		var objs []client.Object
		if c.profile != nil {
			objs = append(objs, c.profile)
		}
		h := resizerWith(t, c.mode, objs...)
		resp := h.Handle(context.Background(), jobReq(t, "w", req16, c.override))
		if !resp.Allowed {
			t.Errorf("%s: autoResize must never deny (Allowed=false)", c.name)
		}
		gotPatch := len(resp.Patches) > 0
		if gotPatch != c.wantPatch {
			t.Errorf("%s: gotPatch=%v want %v (patches=%v)", c.name, gotPatch, c.wantPatch, resp.Patches)
		}
	}
}

// A request already at fleet max is never lowered, even if the profile recommends more.
func TestJobAutoResizer_NeverLowersAtCap(t *testing.T) {
	h := resizerWith(t, recommendation.AutoResize,
		profileWith("w", 96_000_000_000, vgpuv1alpha1.ProfileConfidenceHigh))
	resp := h.Handle(context.Background(), jobReq(t, "w", recommendation.FleetMaxBytes, false))
	if len(resp.Patches) != 0 {
		t.Errorf("a request already at fleet max must not be mutated, got patches=%v", resp.Patches)
	}
}

// Find #8 (2026-07-09): a labeled counter born AT its first increment is
// invisible to increase()/rate() — the dashboard showed "autoResizes (24h): 0"
// right after a real, annotated auto-resize. The webhooks must therefore birth
// the per-namespace series at 0 on every decoded CREATE, before any increment.
func TestCounterSeriesBornAtZero(t *testing.T) {
	const ns = "birth-ns" // unique: other tests already birthed "default"
	job := &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: "birthling", Namespace: ns},
		Spec: vgpuv1alpha1.VGPUJobSpec{ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{
			Spec: vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: 1_000_000_000},
		}},
	}
	raw, err := json.Marshal(job)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Create, Object: runtime.RawExtension{Raw: raw}}}

	before := testutil.CollectAndCount(telemetry.RecommendationAutoResizesTotal)
	h := resizerWith(t, recommendation.AutoResize) // no profile → fail-open, NO resize
	resp := h.Handle(context.Background(), req)
	if !resp.Allowed || len(resp.Patches) > 0 {
		t.Fatalf("expected fail-open no-op admission, got allowed=%v patches=%v", resp.Allowed, resp.Patches)
	}
	after := testutil.CollectAndCount(telemetry.RecommendationAutoResizesTotal)
	if after != before+1 {
		t.Fatalf("expected the namespace's counter series to be BORN at 0 by the no-op admission (series %d -> %d)", before, after)
	}
	if v := testutil.ToFloat64(telemetry.RecommendationAutoResizesTotal.WithLabelValues(ns)); v != 0 {
		t.Fatalf("newborn series must be 0 (no resize happened), got %v", v)
	}
}
