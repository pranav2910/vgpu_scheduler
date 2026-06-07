package webhook

import (
	"context"
	"encoding/json"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

func jobValidatorScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatalf("clientgo scheme: %v", err)
	}
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("vgpu scheme: %v", err)
	}
	return s
}

func profileWith(name string, recommended int64, conf vgpuv1alpha1.ProfileConfidence) *vgpuv1alpha1.VGPUWorkloadProfile {
	return &vgpuv1alpha1.VGPUWorkloadProfile{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Status: vgpuv1alpha1.VGPUWorkloadProfileStatus{
			RecommendedVRAMBytes: recommended,
			Confidence:           conf,
		},
	}
}

func jobReq(t *testing.T, name string, requested int64, override bool) admission.Request {
	t.Helper()
	job := &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{
				Spec: vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: requested},
			},
		},
	}
	if override {
		job.Annotations = map[string]string{recommendation.OverrideAnnotation: "true"}
	}
	raw, err := json.Marshal(job)
	if err != nil {
		t.Fatalf("marshal job: %v", err)
	}
	return admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Create,
		Object:    runtime.RawExtension{Raw: raw},
	}}
}

func handlerWith(t *testing.T, mode recommendation.Mode, objs ...client.Object) *JobRecommendationValidator {
	s := jobValidatorScheme(t)
	c := fake.NewClientBuilder().WithScheme(s).WithObjects(objs...).Build()
	return NewJobRecommendationValidator(c, admission.NewDecoder(s), mode)
}

func TestJobValidator(t *testing.T) {
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
		wantAllow  bool
	}{
		{"requireOverride + High + undersized + no override → DENY", recommendation.RequireOverride, profileWith("w", rec24, hi), false, false},
		{"requireOverride + High + override → allow", recommendation.RequireOverride, profileWith("w", rec24, hi), true, true},
		{"requireOverride + Low + no override → allow (safety gate)", recommendation.RequireOverride, profileWith("w", rec24, lo), false, true},
		{"requireOverride + no profile → allow (fail-open, first run)", recommendation.RequireOverride, nil, false, true},
		{"recommendOnly never blocks", recommendation.RecommendOnly, profileWith("w", rec24, hi), false, true},
		{"warn never blocks", recommendation.Warn, profileWith("w", rec24, hi), false, true},
	}
	for _, c := range cases {
		var objs []client.Object
		if c.profile != nil {
			objs = append(objs, c.profile)
		}
		h := handlerWith(t, c.mode, objs...)
		resp := h.Handle(context.Background(), jobReq(t, "w", req16, c.override))
		if resp.Allowed != c.wantAllow {
			t.Errorf("%s: Allowed=%v, want %v (msg=%q)", c.name, resp.Allowed, c.wantAllow,
				resp.Result.Message)
		}
	}
}

// An adequately-sized request must be admitted even under requireOverride+High.
func TestJobValidator_AdequateRequestAllowed(t *testing.T) {
	const rec = int64(24_000_000_000)
	h := handlerWith(t, recommendation.RequireOverride, profileWith("w", rec, vgpuv1alpha1.ProfileConfidenceHigh))
	resp := h.Handle(context.Background(), jobReq(t, "w", rec, false))
	if !resp.Allowed {
		t.Errorf("adequately-sized request was denied: %q", resp.Result.Message)
	}
}
