package controller

import (
	"context"
	"fmt"
	"log"
	"strconv"

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

// VGPUGangJobReconciler is the top-level reconciler for gang scheduling. It:
//
//  1. Materializes N child VGPUJobs from the gang's PodTemplate (one per slot).
//     Each child has labels gang.vgpu.pranav2910.com/parent and /index, and
//     annotation gang.vgpu.pranav2910.com/gang.
//  2. Creates one VGPUGangReservation that owns the atomic-reserve state.
//  3. Mirrors the reservation's status into the gang's status.
//  4. On failure or completion, drives child teardown via OwnerReferences.
//
// The reconciler does NOT make scheduling decisions. The scheduler reads the
// reservation, drives Reserving → Reserved transitions, and the gang
// reconciler just observes and mirrors.
type VGPUGangJobReconciler struct {
	Client client.Client
	Scheme *runtime.Scheme
}

// SetupWithManager wires the gang reconciler with controller-runtime.
// We Own VGPUJob and VGPUGangReservation so deletion of either fires a
// gang reconcile (used for cascade-cleanup on rollback).
func (r *VGPUGangJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUGangJob{}).
		Owns(&vgpuv1alpha1.VGPUJob{}).
		Owns(&vgpuv1alpha1.VGPUGangReservation{}).
		Complete(r)
}

// reservationNameForGang is deterministic: gang "foo" → reservation "foo-rsv".
// Idempotency relies on this so we can recreate without races.
func reservationNameForGang(gangName string) string {
	return gangName + "-rsv"
}

// childJobName is deterministic per slot.
func childJobName(gangName string, idx int32) string {
	return fmt.Sprintf("%s-%d", gangName, idx)
}

func (r *VGPUGangJobReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var gang vgpuv1alpha1.VGPUGangJob
	if err := r.Client.Get(ctx, req.NamespacedName, &gang); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	// Deletion: cascade is handled by OwnerReferences. Nothing to do.
	if !gang.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// gang-job-recreation fix applied: if the reservation is in a terminal
	// phase (Failed or Released), don't re-create children that the
	// reservation reconciler's tearDownChildren is actively cleaning up.
	// Without this guard, deletion of a child VGPUJob fires a gang reconcile
	// (via Owns watch), ensureChildren sees the missing child, re-creates
	// it, tearDownChildren deletes it again — infinite loop.
	{
		rsvName := reservationNameForGang(gang.Name)
		var rsv vgpuv1alpha1.VGPUGangReservation
		if err := r.Client.Get(ctx, types.NamespacedName{
			Namespace: gang.Namespace, Name: rsvName,
		}, &rsv); err == nil {
			if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseFailed ||
				rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
				log.Printf("VGPUGangJob %s/%s: reservation in terminal phase %s — skipping child materialization",
					gang.Namespace, gang.Name, rsv.Status.Phase)
				// Still mirror status so the gang itself transitions to
				// Failed/Completed. Use updatePhase's existing logic.
				desired := vgpuv1alpha1.GangPhaseFailed
				if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
					desired = vgpuv1alpha1.GangPhaseFailed
				}
				return r.updatePhase(ctx, &gang, desired,
					"reservation terminated; no further child materialization",
					gang.Spec.GangSize, 0)
			}
		}
		// If err is NotFound or other, fall through — normal materialization
		// path will handle creating the reservation as needed.
	}

	// 1. Make sure all N child VGPUJobs exist.
	createdNow, totalExisting, err := r.ensureChildren(ctx, &gang)
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("ensuring children: %w", err)
	}
	if createdNow > 0 {
		log.Printf("VGPUGangJob %s/%s: created %d child(ren), %d/%d total",
			gang.Namespace, gang.Name, createdNow, totalExisting, gang.Spec.GangSize)
	}

	// 2. Make sure the VGPUGangReservation exists. We can only create it
	//    once all children exist, because the reservation spec carries
	//    the ChildClaims list.
	if totalExisting != gang.Spec.GangSize {
		// Still materializing.
		return r.updatePhase(ctx, &gang, vgpuv1alpha1.GangPhaseMaterializing,
			fmt.Sprintf("Created %d/%d children", totalExisting, gang.Spec.GangSize),
			totalExisting, 0)
	}

	rsvName := reservationNameForGang(gang.Name)
	var rsv vgpuv1alpha1.VGPUGangReservation
	err = r.Client.Get(ctx, types.NamespacedName{Namespace: gang.Namespace, Name: rsvName}, &rsv)
	switch {
	case errors.IsNotFound(err):
		if err := r.createReservation(ctx, &gang); err != nil {
			return reconcile.Result{}, fmt.Errorf("creating reservation: %w", err)
		}
		log.Printf("VGPUGangJob %s/%s: created reservation %s", gang.Namespace, gang.Name, rsvName)
		return r.updatePhase(ctx, &gang, vgpuv1alpha1.GangPhaseReserving,
			"Reservation created; awaiting scheduler", gang.Spec.GangSize, 0)
	case err != nil:
		return reconcile.Result{}, err
	}

	// 3. Mirror reservation status into gang status.
	gangPhase, msg := derivePhaseFromReservation(&rsv)
	if _, err := r.updatePhase(ctx, &gang, gangPhase, msg,
		gang.Spec.GangSize, rsv.Status.CommittedSlots); err != nil {
		return reconcile.Result{}, err
	}

	return reconcile.Result{}, nil
}

// ensureChildren creates any missing child VGPUJobs. Returns (createdThisCall,
// totalExisting, error). Idempotent: re-running after partial creation picks
// up where we left off.
func (r *VGPUGangJobReconciler) ensureChildren(ctx context.Context, gang *vgpuv1alpha1.VGPUGangJob) (int32, int32, error) {
	var created, existing int32
	for i := int32(0); i < gang.Spec.GangSize; i++ {
		name := childJobName(gang.Name, i)
		var existingJob vgpuv1alpha1.VGPUJob
		err := r.Client.Get(ctx, types.NamespacedName{Namespace: gang.Namespace, Name: name}, &existingJob)
		if err == nil {
			existing++
			continue
		}
		if !errors.IsNotFound(err) {
			return created, existing, err
		}

		// Build child VGPUJob.
		child := &vgpuv1alpha1.VGPUJob{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: gang.Namespace,
				Labels: map[string]string{
					vgpuv1alpha1.LabelGangParent: gang.Name,
					vgpuv1alpha1.LabelGangIndex:  strconv.Itoa(int(i)),
				},
				Annotations: map[string]string{
					vgpuv1alpha1.AnnotationGangRef:        gang.Name,
					vgpuv1alpha1.AnnotationReservationRef: reservationNameForGang(gang.Name),
				},
			},
			Spec: vgpuv1alpha1.VGPUJobSpec{
				Priority:               gang.Spec.Priority,
				WorkloadClass:          gang.Spec.WorkloadClass,
				Preemptible:            gang.Spec.Preemptible,
				PreemptionGraceSeconds: copyInt32Ptr(gang.Spec.PreemptionGraceSeconds),
				ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{
					Spec: gang.Spec.PodTemplate.Spec,
				},
			},
		}

		if err := controllerutil.SetControllerReference(gang, child, r.Scheme); err != nil {
			return created, existing, fmt.Errorf("setting child owner ref (idx %d): %w", i, err)
		}

		if err := r.Client.Create(ctx, child); err != nil {
			if errors.IsAlreadyExists(err) {
				// Race with another reconcile — count as existing.
				existing++
				continue
			}
			return created, existing, fmt.Errorf("creating child %d: %w", i, err)
		}
		created++
		existing++
	}
	return created, existing, nil
}

// createReservation creates the VGPUGangReservation that the scheduler reads.
// Owns the gang as parent so deletion cascades cleanly.
func (r *VGPUGangJobReconciler) createReservation(ctx context.Context, gang *vgpuv1alpha1.VGPUGangJob) error {
	childClaims := make([]string, gang.Spec.GangSize)
	for i := int32(0); i < gang.Spec.GangSize; i++ {
		// Child VGPUJob "<gang>-<i>" materializes claim "<gang>-<i>-claim"
		// (the existing JobReconciler appends "-claim").
		childClaims[i] = claimNameForJob(childJobName(gang.Name, i))
	}

	timeoutSecs := int32(60)
	if gang.Spec.ReservationTimeoutSeconds != nil {
		timeoutSecs = *gang.Spec.ReservationTimeoutSeconds
	}

	rsv := &vgpuv1alpha1.VGPUGangReservation{
		ObjectMeta: metav1.ObjectMeta{
			Name:      reservationNameForGang(gang.Name),
			Namespace: gang.Namespace,
			Labels: map[string]string{
				vgpuv1alpha1.LabelGangParent: gang.Name,
			},
		},
		Spec: vgpuv1alpha1.VGPUGangReservationSpec{
			GangRef:         gang.Name,
			GangSize:        gang.Spec.GangSize,
			ChildClaims:     childClaims,
			DeadlineSeconds: &timeoutSecs,
		},
	}
	if err := controllerutil.SetControllerReference(gang, rsv, r.Scheme); err != nil {
		return fmt.Errorf("setting owner ref: %w", err)
	}
	return r.Client.Create(ctx, rsv)
}

// derivePhaseFromReservation collapses reservation state into the gang's phase.
func derivePhaseFromReservation(rsv *vgpuv1alpha1.VGPUGangReservation) (vgpuv1alpha1.VGPUGangJobPhase, string) {
	switch rsv.Status.Phase {
	case vgpuv1alpha1.ReservationPhasePending, vgpuv1alpha1.ReservationPhaseReserving, "":
		return vgpuv1alpha1.GangPhaseReserving,
			fmt.Sprintf("Reserving slots: %d reserved, %d failed of %d",
				rsv.Status.ReservedSlots, rsv.Status.FailedSlots, rsv.Spec.GangSize)
	case vgpuv1alpha1.ReservationPhaseReserved:
		return vgpuv1alpha1.GangPhaseReserving, "All slots reserved; binding"
	case vgpuv1alpha1.ReservationPhaseCommitted:
		return vgpuv1alpha1.GangPhaseRunning, "All children running"
	case vgpuv1alpha1.ReservationPhaseFailed:
		return vgpuv1alpha1.GangPhaseFailed, rsv.Status.FailureReason
	case vgpuv1alpha1.ReservationPhaseReleased:
		return vgpuv1alpha1.GangPhaseCompleted, "Released"
	default:
		return vgpuv1alpha1.GangPhaseReserving, fmt.Sprintf("Unknown reservation phase: %s", rsv.Status.Phase)
	}
}

// updatePhase patches gang status with retry-on-conflict.
func (r *VGPUGangJobReconciler) updatePhase(
	ctx context.Context,
	gang *vgpuv1alpha1.VGPUGangJob,
	phase vgpuv1alpha1.VGPUGangJobPhase,
	msg string,
	childrenCreated int32,
	childrenRunning int32,
) (reconcile.Result, error) {
	key := types.NamespacedName{Namespace: gang.Namespace, Name: gang.Name}
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUGangJob
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		fresh.Status.Phase = phase
		fresh.Status.Message = msg
		fresh.Status.ChildrenCreated = childrenCreated
		fresh.Status.ChildrenRunning = childrenRunning
		fresh.Status.ReservationRef = reservationNameForGang(fresh.Name)
		return r.Client.Status().Update(ctx, &fresh)
	})
	return reconcile.Result{}, err
}

// copyInt32Ptr is a small helper to avoid pointer aliasing between gang and
// child specs.
func copyInt32Ptr(p *int32) *int32 {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}
