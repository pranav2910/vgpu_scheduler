package controller

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type VGPUSliceReconciler struct {
	Client client.Client
}

func (r *VGPUSliceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUSlice{}).
		Complete(r)
}

func (r *VGPUSliceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := r.Client.Get(ctx, req.NamespacedName, &slice); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUSlice: %w", err)
	}

	// Layer 2 Phase 2.3: Preempting phase has its own lifecycle.
	// Honour per-Job grace period (default 30s, configurable up to 3600s),
	// then transition to Released so existing cleanup runs.
	if string(slice.Status.Phase) == "Preempting" {
		grace := 30 * time.Second
		if slice.Spec.ClaimRef != "" {
			var claim vgpuv1alpha1.VGPUClaim
			if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err == nil {
				if claim.Spec.JobRef != "" {
					var job vgpuv1alpha1.VGPUJob
					if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err == nil {
						if job.Spec.PreemptionGraceSeconds != nil && *job.Spec.PreemptionGraceSeconds > 0 {
							grace = time.Duration(*job.Spec.PreemptionGraceSeconds) * time.Second
						}
					}
				}
			}
		}
		var since time.Time
		for _, c := range slice.Status.Conditions {
			if c.Type == "Preempting" {
				since = c.LastTransitionTime.Time
				break
			}
		}
		if since.IsZero() {
			since = time.Now()
		}
		elapsed := time.Since(since)
		if elapsed < grace {
			remaining := grace - elapsed
			log.Printf("[preempting] %s/%s grace remaining %v", slice.Namespace, slice.Name, remaining.Round(time.Second))
			return reconcile.Result{RequeueAfter: remaining}, nil
		}
		log.Printf("[preempting] %s/%s grace expired -> Released", slice.Namespace, slice.Name)
		slice.Status.Phase = state.SlicePhaseReleased
		if err := r.Client.Status().Update(ctx, &slice); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{Requeue: true}, nil
	}

	if err := r.reconcileSlice(ctx, &slice); err != nil {
		return reconcile.Result{}, err
	}

	// Bug #6 fix: if the slice is mid-delete and the NodeAgent hasn't confirmed
	// Released yet, politely re-check every 5s instead of returning a sentinel
	// error that would trigger exponential back-off.
	if !slice.DeletionTimestamp.IsZero() && string(slice.Status.Phase) != state.SlicePhaseReleased {
		return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
	}
	return reconcile.Result{}, nil
}

func (r *VGPUSliceReconciler) reconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	if !slice.DeletionTimestamp.IsZero() {
		return r.handleDelete(ctx, slice)
	}

	if EnsureFinalizer(slice, SliceFinalizerName) {
		key := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
		return retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var fresh vgpuv1alpha1.VGPUSlice
			if err := r.Client.Get(ctx, key, &fresh); err != nil {
				return err
			}
			if !EnsureFinalizer(&fresh, SliceFinalizerName) {
				return nil
			}
			return r.Client.Update(ctx, &fresh)
		})
	}

	return nil
}

func (r *VGPUSliceReconciler) handleDelete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	log.Printf("Deletion triggered for Slice %s", slice.Name)

	currentPhase := string(slice.Status.Phase)

	// releasing-orphan fix applied: extended "neverBound" to also catch
	// slices stuck in Releasing/Scheduled phases with no AllocationID.
	// These slices were bound (assigned a nodeName) but the NodeAgent
	// never allocated hardware for them — either because the gang failed
	// at deadline and tearDown deleted the slice before NodeAgent
	// processed it, or because something else interrupted the bind →
	// allocate transition. The NodeAgent doesn't know about these slices,
	// so it never advances Releasing → Released. Without this fix, every
	// failed-gang test run leaks slices that hold finalizers forever.
	//
	// Safe to remove the finalizer directly: no hardware was allocated
	// (AllocationID == ""), so there is nothing for the NodeAgent to free.
	neverBound := slice.Status.AllocationID == "" &&
		(currentPhase == state.SlicePhasePending ||
			currentPhase == "" ||
			currentPhase == state.SlicePhaseReleasing ||
			currentPhase == state.SlicePhaseScheduled)
	if neverBound {
		log.Printf("Slice %s never bound; removing finalizer directly", slice.Name)
		key := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
		return retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var fresh vgpuv1alpha1.VGPUSlice
			if err := r.Client.Get(ctx, key, &fresh); err != nil {
				return err
			}
			if !RemoveFinalizer(&fresh, SliceFinalizerName) {
				return nil
			}
			return r.Client.Update(ctx, &fresh)
		})
	}

	if currentPhase != state.SlicePhaseReleasing && currentPhase != state.SlicePhaseReleased {
		return PatchSliceStatus(ctx, r.Client, slice, func() {
			// Round-3 fix: swallowing DAG violations silently hid bugs. If the
			// transition is illegal at this point (e.g. already Released), we
			// log it and skip the patch; controller-runtime will requeue.
			if err := state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "", "Deletion requested"); err != nil {
				log.Printf("Transition to Releasing skipped: %v", err)
			}
		})
	}

	if currentPhase == state.SlicePhaseReleased {
		log.Printf("Hardware freed. Removing finalizer from Slice %s", slice.Name)
		// Bug #22: retry on 409 conflict. NodeAgent status patches race with
		// this finalizer removal; a stale read blows up the Update.
		key := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
		return retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var fresh vgpuv1alpha1.VGPUSlice
			if err := r.Client.Get(ctx, key, &fresh); err != nil {
				return err
			}
			if !RemoveFinalizer(&fresh, SliceFinalizerName) {
				return nil
			}
			return r.Client.Update(ctx, &fresh)
		})
	}

	// Currently Releasing — nothing to do until the NodeAgent patches the
	// status to Released. The parent Reconcile returns RequeueAfter.
	return nil
}

var _ reconcile.Reconciler = &VGPUSliceReconciler{}
var _ reconcile.Reconciler = &VGPUClaimReconciler{}
