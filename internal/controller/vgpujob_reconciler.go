package controller

import (
	"context"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// VGPUJobReconciler manages the lifecycle of VGPUJob resources.
// In Phase 2.1a it ensures each Job has a corresponding VGPUClaim materialized
// from claimTemplate, and mirrors the claim's status into the Job's phase.
type VGPUJobReconciler struct {
	Client client.Client
	Scheme *runtime.Scheme
}

// SetupWithManager registers the reconciler with the controller manager.
func (r *VGPUJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUJob{}).
		Owns(&vgpuv1alpha1.VGPUClaim{}).
		Complete(r)
}

// claimNameForJob is deterministic so we can find/recreate without races.
func claimNameForJob(jobName string) string {
	return jobName + "-claim"
}

func (r *VGPUJobReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var job vgpuv1alpha1.VGPUJob
	if err := r.Client.Get(ctx, req.NamespacedName, &job); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	// Job is being deleted: OwnerReferences handle cascade. Nothing to do.
	if !job.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// 1. Ensure a Claim exists for this Job.
	claimName := claimNameForJob(job.Name)
	var claim vgpuv1alpha1.VGPUClaim
	err := r.Client.Get(ctx, types.NamespacedName{Namespace: job.Namespace, Name: claimName}, &claim)
	switch {
	case errors.IsNotFound(err):
		if err := r.createClaim(ctx, &job); err != nil {
			return reconcile.Result{}, fmt.Errorf("creating claim: %w", err)
		}
		log.Printf("VGPUJob %s/%s: created claim %s", job.Namespace, job.Name, claimName)
		return r.updatePhase(ctx, &job, vgpuv1alpha1.JobPhaseClaimCreated, "VGPUClaim materialized from template")
	case err != nil:
		return reconcile.Result{}, err
	}

	// 2. Mirror Claim/Slice phase into Job phase.
	desired, msg := derivePhaseFromClaim(&claim)
	if job.Status.Phase != desired || job.Status.ClaimRef != claimName {
		if _, err := r.updatePhase(ctx, &job, desired, msg); err != nil {
			return reconcile.Result{}, err
		}
	}

	return reconcile.Result{}, nil
}

// createClaim materializes the VGPUClaim from the Job's claimTemplate and
// sets OwnerReference for cascade-delete. JobRef is stamped in spec for
// the scheduler to walk back to the Job during scoring.
func (r *VGPUJobReconciler) createClaim(ctx context.Context, job *vgpuv1alpha1.VGPUJob) error {
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      claimNameForJob(job.Name),
			Namespace: job.Namespace,
		},
		Spec: job.Spec.ClaimTemplate.Spec,
	}
	// Stamp JobRef so scheduler can resolve priority/class.
	claim.Spec.JobRef = job.Name

	if err := controllerutil.SetControllerReference(job, claim, r.Scheme); err != nil {
		return fmt.Errorf("setting owner reference: %w", err)
	}

	return r.Client.Create(ctx, claim)
}

// derivePhaseFromClaim collapses claim+slice state into the Job's phase.
func derivePhaseFromClaim(claim *vgpuv1alpha1.VGPUClaim) (vgpuv1alpha1.VGPUJobPhase, string) {
	switch claim.Status.Phase {
	case "Bound":
		// Claim is Bound but Slice could still be in any state.
		// Treat Bound as "Scheduled" — the actual workload running is Phase 2.1b.
		return vgpuv1alpha1.JobPhaseScheduled, "Slice scheduled and ready"
	case "Pending", "":
		return vgpuv1alpha1.JobPhaseClaimCreated, "Awaiting scheduler"
	case "Failed":
		return vgpuv1alpha1.JobPhaseFailed, "Claim entered Failed phase"
	case "Released":
		return vgpuv1alpha1.JobPhaseCompleted, "Claim released"
	default:
		return vgpuv1alpha1.JobPhaseClaimCreated, fmt.Sprintf("Claim in phase %s", claim.Status.Phase)
	}
}

// updatePhase patches Job status with retry-on-conflict so concurrent updates
// (e.g. from a webhook) don't drop our changes.
func (r *VGPUJobReconciler) updatePhase(ctx context.Context, job *vgpuv1alpha1.VGPUJob, phase vgpuv1alpha1.VGPUJobPhase, msg string) (reconcile.Result, error) {
	key := types.NamespacedName{Namespace: job.Namespace, Name: job.Name}
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		fresh.Status.Phase = phase
		fresh.Status.Message = msg
		fresh.Status.ClaimRef = claimNameForJob(fresh.Name)
		return r.Client.Status().Update(ctx, &fresh)
	})
	return reconcile.Result{}, err
}
