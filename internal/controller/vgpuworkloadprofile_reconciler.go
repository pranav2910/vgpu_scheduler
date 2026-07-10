package controller

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/recommendation"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// Phase 3.5 — Runtime Feedback Engine. The controller is the SINGLE writer of
// VGPUWorkloadProfiles (it is leader-elected), so multi-node gang jobs whose
// slices live on different node agents aggregate without write contention. Node
// agents only record per-slice stats onto VGPUSlice.status; this reconciler rolls
// them up per workload. Observe-only: nothing here changes scheduling (3.6).
type VGPUWorkloadProfileReconciler struct {
	Client client.Client
}

func (r *VGPUWorkloadProfileReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUWorkloadProfile{}).
		// A slice's stats change → re-aggregate its workload's profile. Map the
		// slice back to its job via slice → claim → claim.JobRef.
		Watches(
			&vgpuv1alpha1.VGPUSlice{},
			handler.EnqueueRequestsFromMapFunc(r.sliceToProfile),
			builder.WithPredicates(predicate.ResourceVersionChangedPredicate{}),
		).
		Complete(r)
}

func (r *VGPUWorkloadProfileReconciler) sliceToProfile(ctx context.Context, obj client.Object) []reconcile.Request {
	slice, ok := obj.(*vgpuv1alpha1.VGPUSlice)
	if !ok || slice.Spec.ClaimRef == "" {
		return nil
	}
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil || claim.Spec.JobRef == "" {
		return nil // standalone slice (no parent job) → no workload profile
	}
	return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}}}
}

func (r *VGPUWorkloadProfileReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	agg, found, err := r.aggregate(ctx, req.Namespace, req.Name)
	if err != nil {
		return reconcile.Result{}, err
	}
	if !found {
		// No observable slices for this job right now. Profiles persist across
		// job re-runs, so leave any existing profile untouched.
		return reconcile.Result{}, nil
	}
	return reconcile.Result{}, r.upsert(ctx, req.Namespace, req.Name, agg)
}

// profileAgg is the per-workload roll-up of its slices' observations.
type profileAgg struct {
	requested    int64 // max per-slice grant
	peak         int64 // max observed peak across slices
	avg          int64 // max observed avg across slices
	observations int64 // max sample count across slices
	violations   int64 // summed across slices
	softWarns    int64
	evictions    int64
	slices       int
}

// aggregate rolls up every slice belonging to the named job (slice → claim →
// claim.JobRef). found=false means the job has no observable slices yet.
func (r *VGPUWorkloadProfileReconciler) aggregate(ctx context.Context, ns, jobName string) (profileAgg, bool, error) {
	var claims vgpuv1alpha1.VGPUClaimList
	if err := r.Client.List(ctx, &claims, client.InNamespace(ns)); err != nil {
		return profileAgg{}, false, fmt.Errorf("listing claims: %w", err)
	}
	claimSet := map[string]bool{}
	for i := range claims.Items {
		if claims.Items[i].Spec.JobRef == jobName {
			claimSet[claims.Items[i].Name] = true
		}
	}
	if len(claimSet) == 0 {
		return profileAgg{}, false, nil
	}

	var slices vgpuv1alpha1.VGPUSliceList
	if err := r.Client.List(ctx, &slices, client.InNamespace(ns)); err != nil {
		return profileAgg{}, false, fmt.Errorf("listing slices: %w", err)
	}
	var agg profileAgg
	for i := range slices.Items {
		s := &slices.Items[i]
		if !claimSet[s.Spec.ClaimRef] {
			continue
		}
		agg.slices++
		agg.requested = max64(agg.requested, s.Spec.RequestedVRAMBytes)
		agg.peak = max64(agg.peak, s.Status.PeakObservedVRAMBytes)
		agg.avg = max64(agg.avg, s.Status.AvgObservedVRAMBytes)
		agg.observations = max64(agg.observations, s.Status.Observations)
		agg.violations += s.Status.ViolationCount
		agg.softWarns += s.Status.SoftWarnCount
		agg.evictions += s.Status.EvictionCount
	}
	if agg.slices == 0 {
		return profileAgg{}, false, nil
	}
	return agg, true, nil
}

// upsert creates or updates the workload's profile from the aggregate. Every
// accumulated metric is monotonic (high-water) so it never regresses when slices
// churn or a job is re-run.
func (r *VGPUWorkloadProfileReconciler) upsert(ctx context.Context, ns, jobName string, agg profileAgg) error {
	key := types.NamespacedName{Namespace: ns, Name: jobName}
	var prof vgpuv1alpha1.VGPUWorkloadProfile
	err := r.Client.Get(ctx, key, &prof)
	switch {
	case errors.IsNotFound(err):
		prof = vgpuv1alpha1.VGPUWorkloadProfile{
			ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: jobName},
			Spec:       vgpuv1alpha1.VGPUWorkloadProfileSpec{WorkloadRef: jobName},
		}
		if cerr := r.Client.Create(ctx, &prof); cerr != nil {
			if !errors.IsAlreadyExists(cerr) {
				return fmt.Errorf("creating profile: %w", cerr)
			}
			if gerr := r.Client.Get(ctx, key, &prof); gerr != nil {
				return gerr
			}
		}
	case err != nil:
		return fmt.Errorf("fetching profile: %w", err)
	}

	// Peak (and the rest) are monotonic high-water marks.
	peakStable := agg.peak <= prof.Status.PeakObservedVRAMBytes
	st := &prof.Status
	st.RequestedVRAMBytes = agg.requested
	st.PeakObservedVRAMBytes = max64(st.PeakObservedVRAMBytes, agg.peak)
	st.AvgObservedVRAMBytes = agg.avg
	st.Observations = max64(st.Observations, agg.observations)
	st.ViolationCount = max64(st.ViolationCount, agg.violations)
	st.SoftWarnCount = max64(st.SoftWarnCount, agg.softWarns)
	st.EvictionCount = max64(st.EvictionCount, agg.evictions)
	st.RecommendedVRAMBytes = vgpuv1alpha1.RecommendedVRAMBytes(st.PeakObservedVRAMBytes)
	st.Confidence = vgpuv1alpha1.Confidence(st.Observations, peakStable)
	now := metav1.Now()
	st.LastUpdated = &now

	// Dogfood find #5: this used to be a raw `recommended > requested` — a 25 MiB
	// (0.2%) delta at Low confidence rendered "VERDICT UNDERPROVISIONED" telling
	// the user to request the size they had already requested. The verdict the
	// CLI shows must obey the SAME gates as enforcement (recommendation.Blocks):
	// Medium+ confidence AND undersized beyond the documented 10% tolerance —
	// one source of truth, so following the advice always clears the verdict.
	rawUnder := st.RecommendedVRAMBytes > st.RequestedVRAMBytes && st.RequestedVRAMBytes > 0
	under := rawUnder &&
		recommendation.ConfidentEnough(st.Confidence) &&
		recommendation.Undersized(st.RequestedVRAMBytes, st.RecommendedVRAMBytes)
	cond := metav1.Condition{Type: "Underprovisioned", Status: metav1.ConditionFalse, Reason: "WithinRecommendation", Message: "Requested VRAM covers the observed peak (with headroom)."}
	switch {
	case under:
		cond.Status = metav1.ConditionTrue
		cond.Reason = "BelowRecommendation"
		cond.Message = fmt.Sprintf("Requested %d MiB but observed peak recommends %d MiB (confidence %s).",
			st.RequestedVRAMBytes>>20, st.RecommendedVRAMBytes>>20, st.Confidence)
	case rawUnder && !recommendation.ConfidentEnough(st.Confidence):
		cond.Reason = "InsufficientConfidence"
		cond.Message = fmt.Sprintf("Requested %d MiB is below the current estimate (%d MiB), but confidence is %s — not advising yet.",
			st.RequestedVRAMBytes>>20, st.RecommendedVRAMBytes>>20, st.Confidence)
	case rawUnder:
		cond.Reason = "WithinTolerance"
		cond.Message = fmt.Sprintf("Requested %d MiB is within %d%% of the recommendation (%d MiB) — adequately sized.",
			st.RequestedVRAMBytes>>20, recommendation.TolerancePercent, st.RecommendedVRAMBytes>>20)
	}
	apimeta.SetStatusCondition(&st.Conditions, cond)

	if err := r.Client.Status().Update(ctx, &prof); err != nil {
		return err
	}
	telemetry.WorkloadPeakObservedVRAMBytes.WithLabelValues(ns, jobName).Set(float64(st.PeakObservedVRAMBytes))
	telemetry.WorkloadRecommendedVRAMBytes.WithLabelValues(ns, jobName).Set(float64(st.RecommendedVRAMBytes))
	telemetry.WorkloadProfileConfidence.WithLabelValues(ns, jobName).Set(confidenceLevel(st.Confidence))
	return nil
}

// confidenceLevel maps the confidence enum to a metric value (0/1/2).
func confidenceLevel(c vgpuv1alpha1.ProfileConfidence) float64 {
	switch c {
	case vgpuv1alpha1.ProfileConfidenceHigh:
		return 2
	case vgpuv1alpha1.ProfileConfidenceMedium:
		return 1
	default:
		return 0
	}
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
