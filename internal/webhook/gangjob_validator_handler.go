package webhook

import (
	"context"
	"fmt"
	"net/http"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// GangJobValidatorHandler adapts ValidateVGPUGangJob and ValidateGangJobUpdate
// to controller-runtime's admission.Handler interface.
//
// We split this into its own file (rather than appending to webhook_handlers.go)
// to keep the gang feature surface contained — easier to delete or feature-flag
// later if needed.
type GangJobValidatorHandler struct {
	decoder admission.Decoder
}

// NewGangJobValidatorHandler constructs a ready-to-register admission handler.
func NewGangJobValidatorHandler(decoder admission.Decoder) *GangJobValidatorHandler {
	return &GangJobValidatorHandler{decoder: decoder}
}

func (h *GangJobValidatorHandler) Handle(ctx context.Context, req admission.Request) admission.Response {
	gang := &vgpuv1alpha1.VGPUGangJob{}
	if err := h.decoder.Decode(req, gang); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	switch req.Operation {
	case "CREATE":
		if err := ValidateVGPUGangJob(ctx, gang); err != nil {
			return admission.Denied(err.Error())
		}
	case "UPDATE":
		oldGang := &vgpuv1alpha1.VGPUGangJob{}
		if err := h.decoder.DecodeRaw(req.OldObject, oldGang); err != nil {
			return admission.Errored(http.StatusBadRequest, err)
		}
		if err := ValidateVGPUGangJob(ctx, gang); err != nil {
			return admission.Denied(err.Error())
		}
		if err := ValidateGangJobUpdate(ctx, oldGang, gang); err != nil {
			return admission.Denied(err.Error())
		}
	default:
		return admission.Errored(http.StatusBadRequest,
			fmt.Errorf("unexpected operation: %s", req.Operation))
	}
	return admission.Allowed("")
}
