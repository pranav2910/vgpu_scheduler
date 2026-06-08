package webhook

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
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
		name       string
		mode       recommendation.Mode
		profile    *vgpuv1alpha1.VGPUWorkloadProfile
		override   bool
		wantPatch  bool
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
