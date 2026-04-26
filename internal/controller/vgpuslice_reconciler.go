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
