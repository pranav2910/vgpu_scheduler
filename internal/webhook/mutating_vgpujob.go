package webhook

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// JobAutoResizer implements Phase 3.7b: in `autoResize` mode it RAISES an
// under-provisioned VGPUJob's requested VRAM up to its learned recommendation
// (capped at fleet max) at CREATE, so the whole downstream chain (claim → slice →
// scheduler) sees one consistent, right-sized request. It stamps audit annotations
// so the change is never silent; the controller turns those into a condition+event.
//
// Like the 3.7a validator it is FAIL-OPEN: any uncertainty (wrong mode, no profile,
// lookup error, override present, already adequate) returns the object UNCHANGED.
// It NEVER lowers a request.
type JobAutoResizer struct {
	client  client.Client
	decoder admission.Decoder
	mode    recommendation.Mode
}

func NewJobAutoResizer(c client.Client, decoder admission.Decoder, mode recommendation.Mode) *JobAutoResizer {
	return &JobAutoResizer{client: c, decoder: decoder, mode: mode}
}

func (h *JobAutoResizer) Handle(ctx context.Context, req admission.Request) admission.Response {
	if h.mode != recommendation.AutoResize {
		return admission.Allowed("")
	}
	if req.Operation != admissionCreate {
		return admission.Allowed("") // resize at creation only
	}

	job := &vgpuv1alpha1.VGPUJob{}
	if err := h.decoder.Decode(req, job); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}
	requested := job.Spec.ClaimTemplate.Spec.RequestedVRAMBytes
	if requested <= 0 {
		return admission.Allowed("")
	}
	hasOverride := job.Annotations[recommendation.OverrideAnnotation] == "true"

	// Fail-open profile lookup.
	var prof vgpuv1alpha1.VGPUWorkloadProfile
	if err := h.client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: job.Name}, &prof); err != nil {
		if apierrors.IsNotFound(err) {
			return admission.Allowed("") // first run — nothing learned yet
		}
		return admission.Allowed("recommendation profile unavailable; admitted unchanged (fail-open)")
	}

	recommended := prof.Status.RecommendedVRAMBytes
	newReq, resized, capped := recommendation.ResizeTarget(requested, recommended, recommendation.FleetMaxBytes,
		prof.Status.Confidence, hasOverride)
	if !resized {
		return admission.Allowed("")
	}

	// Mutate the request + stamp the audit trail.
	job.Spec.ClaimTemplate.Spec.RequestedVRAMBytes = newReq
	if job.Annotations == nil {
		job.Annotations = map[string]string{}
	}
	job.Annotations[recommendation.OriginalVRAMAnnotation] = strconv.FormatInt(requested, 10)
	job.Annotations[recommendation.AutoResizedVRAMAnnotation] = strconv.FormatInt(newReq, 10)
	job.Annotations[recommendation.AutoResizedAnnotation] = "true"
	if capped {
		// Record the UNCAPPED recommendation so the controller can tell the user
		// exactly how far over a single card their workload is.
		job.Annotations[recommendation.AutoResizeCappedAnnotation] = strconv.FormatInt(recommended, 10)
		telemetry.RecommendationAutoResizeCappedTotal.WithLabelValues(job.Namespace).Inc()
	}
	telemetry.RecommendationAutoResizesTotal.WithLabelValues(job.Namespace).Inc()

	mutated, err := json.Marshal(job)
	if err != nil {
		// Marshalling our own object should never fail; fail-open if it somehow does.
		return admission.Allowed("autoResize marshal failed; admitted unchanged (fail-open)")
	}
	return admission.PatchResponseFromRaw(req.Object.Raw, mutated)
}
