package controller

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
		// Resolve the owning Job ONCE: needed both for the grace period and, on
		// expiry, to evict its workload pod and mark it terminal. A transient
		// lookup failure retries — it must not read as "no owner" (sweep S4).
		job, jerr := r.resolveOwnerJob(ctx, &slice)
		if jerr != nil {
			return reconcile.Result{}, fmt.Errorf("resolving preempted slice's owner job: %w", jerr)
		}
		grace := 30 * time.Second
		if job != nil && job.Spec.PreemptionGraceSeconds != nil && *job.Spec.PreemptionGraceSeconds > 0 {
			grace = time.Duration(*job.Spec.PreemptionGraceSeconds) * time.Second
		}
		var since time.Time
		var preemptMsg string
		for _, c := range slice.Status.Conditions {
			if c.Type == "Preempting" {
				since = c.LastTransitionTime.Time
				preemptMsg = c.Message
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
		// Grace expired. BEFORE releasing the slice (which frees the VRAM the
		// scheduler immediately re-sells), evict the victim's workload pod and mark
		// its Job preempted. Without this, the pod keeps physically using a GPU
		// whose memory was just handed to the higher-priority requester
		// (double-booked VRAM → OOM), and the Job reconciler would recreate it.
		// Mirrors the enforcement-evict contract in vgpujob_reconciler.go.
		if job != nil {
			if err := r.evictPreemptedWorkload(ctx, job, preemptMsg); err != nil {
				// Do NOT fall through to Releasing (sweep S4): once the slice
				// leaves Preempting this branch never runs again, so a one-shot
				// failure here left the victim pod running on VRAM the
				// scheduler was already re-selling (double-booked GPU), with
				// the Preempted condition possibly never stamped. Eviction is
				// idempotent — return the error and retry until it lands.
				return reconcile.Result{}, fmt.Errorf("evicting preempted workload (will retry; slice stays Preempting): %w", err)
			}
		}
		// Releasing, NOT Released: stamping Released directly skipped the node
		// agent entirely (its release path triggers on Releasing/deletion only),
		// so the victim's CDI file, NVML allocation, and checkpoint were never
		// torn down — while the scheduler, seeing "Released", freed the bytes
		// and re-sold capacity the hardware still held. Routing through
		// Releasing runs the same teardown as deletion; the agent confirms
		// Released (and zeroes the allocation fields, honoring the Released
		// invariant) only after the hardware is actually free.
		log.Printf("[preempting] %s/%s grace expired -> Releasing (node agent tears down, then confirms Released)",
			slice.Namespace, slice.Name)
		slice.Status.Phase = state.SlicePhaseReleasing
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

// resolveOwnerJob walks slice → claim → job.
// It returns (nil, nil) when the slice genuinely has no owning
// job (no refs, or the chain's objects are gone) and (nil, err) on a TRANSIENT
// lookup failure. The distinction matters (sweep S4): the Preempting path used
// a nil-only signature, so a throttled Get at grace expiry read as "no owner"
// — the victim pod was never evicted, never retried, and its Preempted
// condition was never stamped, while the slice released and the scheduler
// re-sold VRAM the pod was still using.
func (r *VGPUSliceReconciler) resolveOwnerJob(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) (*vgpuv1alpha1.VGPUJob, error) {
	if slice.Spec.ClaimRef == "" {
		return nil, nil
	}
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: slice.Spec.ClaimRef}, &claim); err != nil {
		return nil, client.IgnoreNotFound(err)
	}
	if claim.Spec.JobRef == "" {
		return nil, nil
	}
	var job vgpuv1alpha1.VGPUJob
	if err := r.Client.Get(ctx, types.NamespacedName{Namespace: slice.Namespace, Name: claim.Spec.JobRef}, &job); err != nil {
		return nil, client.IgnoreNotFound(err)
	}
	return &job, nil
}

// evictPreemptedWorkload completes a preemption: it stamps the Preempted
// condition on the owning Job (so the Job reconciler marks it terminal and won't
// recreate the pod — see jobPreempted in vgpujob_reconciler.go) and then deletes
// the workload pod so it stops using the GPU memory the scheduler is reselling.
// Order matters: stamp the condition FIRST, so the Owns(Pod) delete event finds
// it already set.
func (r *VGPUSliceReconciler) evictPreemptedWorkload(ctx context.Context, job *vgpuv1alpha1.VGPUJob, msg string) error {
	if msg == "" {
		msg = "Preempted for higher-priority work."
	}
	key := types.NamespacedName{Namespace: job.Namespace, Name: job.Name}
	if err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUJob
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return client.IgnoreNotFound(err)
		}
		apimeta.SetStatusCondition(&fresh.Status.Conditions, metav1.Condition{
			Type:    preemptedConditionType,
			Status:  metav1.ConditionTrue,
			Reason:  preemptedReason,
			Message: msg,
		})
		return r.Client.Status().Update(ctx, &fresh)
	}); err != nil {
		return fmt.Errorf("stamping Preempted condition: %w", err)
	}
	// Delete the workload pod (best-effort; the Job reconciler honors the
	// condition regardless once the pod is gone).
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: job.Namespace, Name: workloadPodName(job.Name)}}
	if err := r.Client.Delete(ctx, pod); err != nil && !errors.IsNotFound(err) {
		return fmt.Errorf("deleting preempted workload pod: %w", err)
	}
	return nil
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
