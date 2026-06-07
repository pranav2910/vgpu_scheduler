package webhook

import (
	"context"
	"fmt"
	"net/http"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// JobRecommendationValidator enforces Phase 3.7 `requireOverride` at admission: it
// rejects CREATE of an under-provisioned VGPUJob (relative to its learned
// VGPUWorkloadProfile) unless the job carries the override annotation. In every
// other mode it admits everything — the controller surfaces the advisory instead.
//
// It is deliberately FAIL-OPEN: a missing profile, a lookup error, or anything it
// is unsure about results in admission. Recommendation enforcement must never
// globally block job submission (that is why its webhook config is failurePolicy:
// Ignore, and why the handler itself never errors a request closed). It only ever
// blocks on a confident (Medium+) profile with an undersized, un-overridden request.
type JobRecommendationValidator struct {
	client  client.Client
	decoder admission.Decoder
	mode    recommendation.Mode
}

// NewJobRecommendationValidator builds the handler. The mode is fixed at startup
// from VGPU_RECOMMENDATION_MODE (changing it is a controller restart).
func NewJobRecommendationValidator(c client.Client, decoder admission.Decoder, mode recommendation.Mode) *JobRecommendationValidator {
	return &JobRecommendationValidator{client: c, decoder: decoder, mode: mode}
}

func (h *JobRecommendationValidator) Handle(ctx context.Context, req admission.Request) admission.Response {
	// Only requireOverride can ever reject; recommendOnly/warn are advisory-only.
	if h.mode != recommendation.RequireOverride {
		return admission.Allowed("")
	}
	if req.Operation != admissionCreate {
		return admission.Allowed("") // enforce at creation only
	}

	job := &vgpuv1alpha1.VGPUJob{}
	if err := h.decoder.Decode(req, job); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}
	requested := job.Spec.ClaimTemplate.Spec.RequestedVRAMBytes
	if requested <= 0 {
		return admission.Allowed("") // VRAM bounds are the claim validator's job
	}

	// Look up this workload's learned profile. Fail OPEN on any uncertainty.
	var prof vgpuv1alpha1.VGPUWorkloadProfile
	if err := h.client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: job.Name}, &prof); err != nil {
		if apierrors.IsNotFound(err) {
			return admission.Allowed("") // first run — nothing learned yet
		}
		// Lookup failed — admit rather than block submission cluster-wide.
		return admission.Allowed("recommendation profile unavailable; admitted (fail-open)")
	}

	recommended := prof.Status.RecommendedVRAMBytes
	hasOverride := job.Annotations[recommendation.OverrideAnnotation] == "true"

	if recommendation.Blocks(h.mode, requested, recommended, prof.Status.Confidence, hasOverride) {
		telemetry.RecommendationRejectionsTotal.WithLabelValues(job.Namespace).Inc()
		return admission.Denied(fmt.Sprintf(
			"requested %d MiB is below this workload's recommended %d MiB (confidence %s, from observed peak). "+
				"Raise the request, or set annotation %s=\"true\" to run undersized.",
			requested>>20, recommended>>20, prof.Status.Confidence, recommendation.OverrideAnnotation))
	}

	// Admitted-but-undersized via override → record it (the controller stamps the
	// condition note).
	if hasOverride && recommendation.ConfidentEnough(prof.Status.Confidence) &&
		recommendation.Undersized(requested, recommended) {
		telemetry.RecommendationOverridesTotal.WithLabelValues(job.Namespace).Inc()
		return admission.Allowed("under-provisioned request admitted by override annotation")
	}
	return admission.Allowed("")
}

// admissionCreate matches admission.Request.Operation for CREATE without importing
// the admissionv1 package just for the constant.
const admissionCreate = "CREATE"
