package controller

import (
	"context"
	"fmt"
	"strconv"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Phase 3.6 — soft, feedback-aware scheduling. If a job's requested VRAM is below
// its workload profile's recommendation (at sufficient confidence), the system
// WARNS — an Underprovisioned condition, a recommended-vram-bytes annotation, an
// Event, and a metric — but never blocks admission, mutates the request, or
// changes the job phase. No profile (or low confidence) clears the advisory.
const (
	advisoryConditionType     = "Underprovisioned"
	recommendedVRAMAnnotation = "infrastructure.pranav2910.com/recommended-vram-bytes"
)

// reconcileAdvisory evaluates the job's request against its profile and reconciles
// the (non-blocking) advisory surfaces. Errors are returned so the cycle retries;
// a missing profile is not an error.
func (r *VGPUJobReconciler) reconcileAdvisory(ctx context.Context, job *vgpuv1alpha1.VGPUJob) error {
	requested := job.Spec.ClaimTemplate.Spec.RequestedVRAMBytes

	var prof vgpuv1alpha1.VGPUWorkloadProfile
	err := r.Client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: job.Name}, &prof)
	if err != nil && !errors.IsNotFound(err) {
		return err
	}

	advise := false
	var recommended int64
	if err == nil &&
		recommendation.ConfidentEnough(prof.Status.Confidence) &&
		recommendation.Undersized(requested, prof.Status.RecommendedVRAMBytes) {
		advise = true
		recommended = prof.Status.RecommendedVRAMBytes
	}
	overridden := job.Annotations[recommendation.OverrideAnnotation] == "true"

	key := types.NamespacedName{Namespace: job.Namespace, Name: job.Name}
	if err := r.setAdvisoryAnnotation(ctx, key, advise, recommended); err != nil {
		return err
	}
	if err := r.setAdvisoryCondition(ctx, key, advise, overridden, requested, recommended, prof.Status.Confidence); err != nil {
		return err
	}

	val := 0.0
	if advise {
		val = 1
	}
	telemetry.WorkloadUnderprovisioned.WithLabelValues(job.Namespace, job.Name).Set(val)
	return nil
}

// setAdvisoryAnnotation sets or removes the machine-readable recommended-VRAM
// annotation (metadata write), only when it actually changes.
func (r *VGPUJobReconciler) setAdvisoryAnnotation(ctx context.Context, key types.NamespacedName, advise bool, recommended int64) error {
	want := ""
	if advise {
		want = strconv.FormatInt(recommended, 10)
	}
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var j vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &j); err != nil {
			return client.IgnoreNotFound(err)
		}
		if j.Annotations[recommendedVRAMAnnotation] == want {
			return nil // no change
		}
		if want == "" {
			delete(j.Annotations, recommendedVRAMAnnotation)
		} else {
			if j.Annotations == nil {
				j.Annotations = map[string]string{}
			}
			j.Annotations[recommendedVRAMAnnotation] = want
		}
		return r.Client.Update(ctx, &j)
	})
}

// setAdvisoryCondition sets/clears the Underprovisioned condition (status write)
// and, in warn/requireOverride mode, emits a Warning Event on the False→True
// transition (recommendOnly stays silent). Never changes phase. When the request
// is undersized but the override annotation is set, the condition records that the
// undersize was intentional.
func (r *VGPUJobReconciler) setAdvisoryCondition(ctx context.Context, key types.NamespacedName, advise, overridden bool, requested, recommended int64, conf vgpuv1alpha1.ProfileConfidence) error {
	emitEvent := false
	if err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var j vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &j); err != nil {
			return client.IgnoreNotFound(err)
		}
		was := apimeta.IsStatusConditionTrue(j.Status.Conditions, advisoryConditionType)
		cond := metav1.Condition{
			Type:    advisoryConditionType,
			Status:  metav1.ConditionFalse,
			Reason:  "RequestCoversRecommendation",
			Message: "Requested VRAM covers the workload's observed peak (with headroom), or no confident profile yet.",
		}
		if advise {
			cond.Status = metav1.ConditionTrue
			cond.Reason = "RequestBelowRecommendation"
			cond.Message = fmt.Sprintf("Requested %d MiB but the workload profile recommends %d MiB (confidence %s) from observed peak — advisory only, not blocked.",
				requested>>20, recommended>>20, conf)
			if overridden {
				cond.Reason = "RequestBelowRecommendationOverridden"
				cond.Message = fmt.Sprintf("Requested %d MiB below the recommended %d MiB (confidence %s) — admitted by override annotation (running undersized intentionally).",
					requested>>20, recommended>>20, conf)
			}
		}
		// Skip the write if nothing changes (avoid status churn).
		if existing := apimeta.FindStatusCondition(j.Status.Conditions, advisoryConditionType); existing != nil &&
			existing.Status == cond.Status && existing.Reason == cond.Reason && existing.Message == cond.Message {
			return nil
		}
		apimeta.SetStatusCondition(&j.Status.Conditions, cond)
		if err := r.Client.Status().Update(ctx, &j); err != nil {
			return err
		}
		// recommendOnly is silent; warn/requireOverride emit the nudge. An
		// overridden request is the user's explicit choice — no event.
		emitEvent = advise && !was && !overridden && recommendation.EmitsEvent(r.RecommendationMode)
		return nil
	}); err != nil {
		return err
	}
	if emitEvent && r.Recorder != nil {
		ref := &vgpuv1alpha1.VGPUJob{ObjectMeta: metav1.ObjectMeta{Namespace: key.Namespace, Name: key.Name}}
		r.Recorder.Eventf(ref, corev1.EventTypeWarning, "UnderprovisionedRequest",
			"Requested %d MiB is below the profile's recommended %d MiB (confidence %s) — admitted anyway (advisory only).",
			requested>>20, recommended>>20, conf)
	}
	return nil
}
