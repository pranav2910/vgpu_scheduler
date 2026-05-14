package controller

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"time"
)

type VGPUClaimReconciler struct {
	Client client.Client
}

func (r *VGPUClaimReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUClaim{}).
		// Bug fix: watch derived slices so a slice deletion fires a claim
		// reconcile, allowing handleClaimDelete to remove the claim
		// finalizer once its slice is gone. Without this, the claim
		// orphans forever with claim-cleanup finalizer stuck.
		Owns(&vgpuv1alpha1.VGPUSlice{}).
		Complete(r)
}

func (r *VGPUClaimReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, req.NamespacedName, &claim); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUClaim: %w", err)
	}

	if err := r.reconcileClaim(ctx, &claim); err != nil {
		return reconcile.Result{}, err
	}

	// Safety: if claim is mid-delete and still has its finalizer, requeue
	// after 5s. The Owns(&VGPUSlice{}) watch should already fire on slice
	// deletion, but this is a belt-and-suspenders cover for any edge case
	// where the slice was already gone before our watch was active.
	if !claim.DeletionTimestamp.IsZero() {
		hasFinalizer := false
		for _, f := range claim.Finalizers {
			if f == ClaimFinalizerName {
				hasFinalizer = true
				break
			}
		}
		if hasFinalizer {
			return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
		}
	}

	return reconcile.Result{}, nil
}

func (r *VGPUClaimReconciler) reconcileClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {
	// Bug #40: claim finalizer. Claim sticks around until its slice has fully released.
	if !claim.DeletionTimestamp.IsZero() {
		return r.handleClaimDelete(ctx, claim)
	}
	if EnsureFinalizer(claim, ClaimFinalizerName) {
		return r.Client.Update(ctx, claim)
	}

	slice, err := r.ensureSliceExists(ctx, claim)
	if err != nil {
		return fmt.Errorf("ensuring slice exists: %w", err)
	}

	return r.syncClaimStatusFromSlice(ctx, claim, slice)
}

func (r *VGPUClaimReconciler) ensureSliceExists(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) (*vgpuv1alpha1.VGPUSlice, error) {
	sliceName := claim.Name + "-slice"

	var existing vgpuv1alpha1.VGPUSlice
	err := r.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: claim.Namespace}, &existing)
	if err == nil {
		return &existing, nil
	}
	if !errors.IsNotFound(err) {
		return nil, fmt.Errorf("fetching existing slice: %w", err)
	}

	// Bug #7 fix: include Controller=true and BlockOwnerDeletion=true on the
	// OwnerReference so Kubernetes GC propagates correctly and the claim
	// cannot vanish before the slice's finalizer runs.
	truePtr := true
	// gang-wiring fix applied: propagate gang annotations from Claim to Slice.
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:        sliceName,
			Namespace:   claim.Namespace,
			Annotations: FilterGangAnnotations(claim.Annotations),
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion:         vgpuv1alpha1.GroupVersion.String(),
					Kind:               "VGPUClaim",
					Name:               claim.Name,
					UID:                claim.UID,
					Controller:         &truePtr,
					BlockOwnerDeletion: &truePtr,
				},
			},
		},
		Spec: vgpuv1alpha1.VGPUSliceSpec{
			ClaimRef:           claim.Name,
			RequestedVRAMBytes: claim.Spec.RequestedVRAMBytes,
		},
	}

	if err := r.Client.Create(ctx, slice); err != nil {
		return nil, fmt.Errorf("creating VGPUSlice: %w", err)
	}
	return slice, nil
}

// handleClaimDelete removes the claim finalizer only after every derived
// slice has been deleted. Slices own their own release lifecycle via
// SliceFinalizerName. Bug #40 fix.
func (r *VGPUClaimReconciler) handleClaimDelete(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {
	sliceName := claim.Name + "-slice"
	var slice vgpuv1alpha1.VGPUSlice
	err := r.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: claim.Namespace}, &slice)
	if err == nil {
		// Slice still exists — delete it and wait for the next reconcile.
		if slice.DeletionTimestamp.IsZero() {
			if err := r.Client.Delete(ctx, &slice); err != nil && !errors.IsNotFound(err) {
				return fmt.Errorf("deleting bound slice: %w", err)
			}
		}
		return nil // requeue naturally via slice deletion event
	}
	if !errors.IsNotFound(err) {
		return fmt.Errorf("checking bound slice: %w", err)
	}
	// Slice gone — safe to remove the claim's finalizer.
	// retry-on-conflict: the claim may have been mutated by another
	// controller (status sync, kubectl edits, etc.) between our cached
	// read and the Update. A fresh Get each attempt avoids stale
	// resourceVersion conflicts.
	key := types.NamespacedName{Namespace: claim.Namespace, Name: claim.Name}
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUClaim
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			if errors.IsNotFound(err) {
				return nil // already gone
			}
			return err
		}
		if !RemoveFinalizer(&fresh, ClaimFinalizerName) {
			return nil // finalizer already removed
		}
		return r.Client.Update(ctx, &fresh)
	})
}

func (r *VGPUClaimReconciler) syncClaimStatusFromSlice(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim, slice *vgpuv1alpha1.VGPUSlice) error {
	return PatchClaimStatus(ctx, r.Client, claim, func() {
		claim.Status.BoundSliceName = slice.Name

		// Bug #48: distinguish Releasing/Released from early Pending.
		switch string(slice.Status.Phase) {
		case state.SlicePhaseReady:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseBound)
		case state.SlicePhaseFailed:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseFailed)
			claim.Status.FailureReason = slice.Status.FailureReason
		case state.SlicePhaseReleasing, state.SlicePhaseReleased:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseDeleting)
		case state.SlicePhaseScheduled, state.SlicePhaseAllocating:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhaseScheduled)
		default:
			claim.Status.Phase = vgpuv1alpha1.VGPUClaimPhase(state.ClaimPhasePending)
		}
	})
}
