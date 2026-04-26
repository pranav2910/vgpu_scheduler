package controller

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PatchClaimStatus safely patches the Claim status. Bug #37 fix — re-Gets the
// claim so the patch base reflects the authoritative server state rather than
// whatever the caller mutated in memory before calling this helper.
func PatchClaimStatus(ctx context.Context, k8sClient client.Client, claim *vgpuv1alpha1.VGPUClaim, mutateFn func()) error {
	key := types.NamespacedName{Namespace: claim.Namespace, Name: claim.Name}
	var fresh vgpuv1alpha1.VGPUClaim
	if err := k8sClient.Get(ctx, key, &fresh); err != nil {
		return fmt.Errorf("refreshing claim before status patch: %w", err)
	}
	// Preserve any status fields the caller set locally by copying them onto fresh.
	fresh.Status = claim.Status
	base := client.MergeFrom(fresh.DeepCopy())

	// Point the caller's object at the fresh copy so subsequent reads see
	// the updated resourceVersion after a successful patch.
	*claim = fresh

	mutateFn()
	if err := k8sClient.Status().Patch(ctx, claim, base); err != nil {
		return err
	}
	return nil
}

// PatchSliceStatus mirrors PatchClaimStatus for slices.
func PatchSliceStatus(ctx context.Context, k8sClient client.Client, slice *vgpuv1alpha1.VGPUSlice, mutateFn func()) error {
	key := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
	var fresh vgpuv1alpha1.VGPUSlice
	if err := k8sClient.Get(ctx, key, &fresh); err != nil {
		return fmt.Errorf("refreshing slice before status patch: %w", err)
	}
	fresh.Status = slice.Status
	base := client.MergeFrom(fresh.DeepCopy())
	*slice = fresh

	mutateFn()
	return k8sClient.Status().Patch(ctx, slice, base)
}
