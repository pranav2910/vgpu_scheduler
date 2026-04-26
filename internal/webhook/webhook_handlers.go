package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// PodMutatorHandler adapts PodMutator to the controller-runtime admission
// Handler interface so it can be registered on the webhook server.
type PodMutatorHandler struct {
	Mutator *PodMutator
	decoder admission.Decoder
}

// NewPodMutatorHandler constructs a ready-to-register admission handler.
func NewPodMutatorHandler(c client.Client, decoder admission.Decoder) *PodMutatorHandler {
	return &PodMutatorHandler{
		Mutator: &PodMutator{Client: c},
		decoder: decoder,
	}
}

func (h *PodMutatorHandler) Handle(ctx context.Context, req admission.Request) admission.Response {
	pod := &corev1.Pod{}
	if err := h.decoder.Decode(req, pod); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}
	if err := h.Mutator.MutatePod(ctx, pod); err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}
	marshaled, err := json.Marshal(pod)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}
	return admission.PatchResponseFromRaw(req.Object.Raw, marshaled)
}

// ClaimValidatorHandler adapts ValidateVGPUClaim / ValidateClaimUpdate.
type ClaimValidatorHandler struct {
	decoder admission.Decoder
}

func NewClaimValidatorHandler(decoder admission.Decoder) *ClaimValidatorHandler {
	return &ClaimValidatorHandler{decoder: decoder}
}

func (h *ClaimValidatorHandler) Handle(ctx context.Context, req admission.Request) admission.Response {
	claim := &vgpuv1alpha1.VGPUClaim{}
	if err := h.decoder.Decode(req, claim); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	switch req.Operation {
	case "CREATE":
		if err := ValidateVGPUClaim(ctx, claim); err != nil {
			return admission.Denied(err.Error())
		}
	case "UPDATE":
		oldClaim := &vgpuv1alpha1.VGPUClaim{}
		if err := h.decoder.DecodeRaw(req.OldObject, oldClaim); err != nil {
			return admission.Errored(http.StatusBadRequest, err)
		}
		if err := ValidateVGPUClaim(ctx, claim); err != nil {
			return admission.Denied(err.Error())
		}
		if err := ValidateClaimUpdate(ctx, oldClaim, claim); err != nil {
			return admission.Denied(err.Error())
		}
	default:
		return admission.Errored(http.StatusBadRequest,
			fmt.Errorf("unexpected operation: %s", req.Operation))
	}
	return admission.Allowed("")
}
