package controller

import (
	"context"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// VGPUQuotaReconciler refreshes status.usedVramBytes every 30s by walking
// all Ready slices in the quota's TargetNamespace.
type VGPUQuotaReconciler struct {
	Client client.Client
	Scheme *runtime.Scheme
}

// SetupWithManager registers the reconciler.
func (r *VGPUQuotaReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUQuota{}).
		Complete(r)
}

const quotaRefreshInterval = 30 * time.Second

func (r *VGPUQuotaReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var quota vgpuv1alpha1.VGPUQuota
	if err := r.Client.Get(ctx, req.NamespacedName, &quota); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	if !quota.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// Compute current usage by walking Ready slices in target namespace.
	used, err := r.computeUsage(ctx, quota.Spec.TargetNamespace)
	if err != nil {
		log.Printf("VGPUQuota %s: failed to compute usage: %v", quota.Name, err)
		return reconcile.Result{RequeueAfter: quotaRefreshInterval}, nil
	}

	// Patch status with retry-on-conflict.
	key := types.NamespacedName{Name: quota.Name}
	err = retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUQuota
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		fresh.Status.UsedVramBytes = used
		fresh.Status.LastUpdated = metav1.Now()
		return r.Client.Status().Update(ctx, &fresh)
	})
	if err != nil {
		log.Printf("VGPUQuota %s: status update failed: %v", quota.Name, err)
	} else {
		log.Printf("VGPUQuota %s: namespace=%s used=%d/%d bytes",
			quota.Name, quota.Spec.TargetNamespace, used, quota.Spec.MaxVramBytes)
	}

	// Requeue every 30s for periodic refresh.
	return reconcile.Result{RequeueAfter: quotaRefreshInterval}, nil
}

// computeUsage sums allocatedBytes across all Ready slices in the namespace.
func (r *VGPUQuotaReconciler) computeUsage(ctx context.Context, namespace string) (int64, error) {
	var slices vgpuv1alpha1.VGPUSliceList
	if err := r.Client.List(ctx, &slices, client.InNamespace(namespace)); err != nil {
		return 0, err
	}
	var total int64
	for _, s := range slices.Items {
		if s.Status.Phase == "Ready" {
			total += s.Status.AllocatedBytes
		}
	}
	return total, nil
}
