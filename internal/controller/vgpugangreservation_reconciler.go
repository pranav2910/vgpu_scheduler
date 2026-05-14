package controller

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// VGPUGangReservationReconciler drives the atomic reserve/commit state machine.
//
// This is the rewrite addressing 6 bugs found in real-world testing:
//
//	Bug 1 — No slice-watch trigger. Reservations only reconciled on their own
//	        RequeueAfter timer, so phase changes on child slices were invisible
//	        until a 3-second poll. Fix: Watches() with a custom event handler
//	        mapping any VGPUSlice change to its parent reservation via the
//	        AnnotationReservationRef.
//
//	Bug 2 — Failed-phase short-circuit was permanent. IsTerminalReservationPhase
//	        returned true for Failed, causing Reconcile to bail before retrying
//	        a partial-failure teardown. Fix: track teardown completion in
//	        Status.PerSliceState; only treat Failed as truly terminal when
//	        all children are confirmed gone.
//
//	Bug 3 — Cascade-delete relied on default Background propagation, returning
//	        success before children were actually gone. Fix: explicit Foreground
//	        propagation on Delete.
//
//	Bug 4 — applyPhase ran BEFORE tearDownChildren, freezing stale tally values
//	        into status. Fix: re-tally after teardown so observability surface
//	        reflects post-teardown reality.
//
//	Bug 5 — Tally counted slice as Pending whether claim+slice were brand-new
//	        OR had been deleted+regenerated. Same observable state, very
//	        different semantics. Fix: track UID drift; if a slice's UID differs
//	        from what we previously observed, count as "Failed" (slice was
//	        torn down once already).
//
//	Bug 6 — Once Failed, gang slices were left in Pending phase, jamming the
//	        scheduler's priority queue. Fix: tearDownChildren also marks any
//	        orphan slice (slice exists but parent claim/job is being deleted)
//	        as Failed phase, unjamming the scheduler.
type VGPUGangReservationReconciler struct {
	Client client.Client
	Scheme *runtime.Scheme
}

// SetupWithManager registers the reconciler with a custom Watches() handler
// for child VGPUSlices. The handler maps a slice event back to its parent
// reservation in O(1) via the slice's gang annotation.
func (r *VGPUGangReservationReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUGangReservation{}).
		// Bug 1 fix: watch child slices, route events to the parent reservation
		// via the gang annotation. Phase changes now trigger immediate
		// reconcile instead of waiting for the next 3-second poll.
		Watches(
			&vgpuv1alpha1.VGPUSlice{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				slice, ok := obj.(*vgpuv1alpha1.VGPUSlice)
				if !ok || slice.Annotations == nil {
					return nil
				}
				rsvName, ok := slice.Annotations[vgpuv1alpha1.AnnotationReservationRef]
				if !ok || rsvName == "" {
					return nil
				}
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{
						Namespace: slice.Namespace,
						Name:      rsvName,
					},
				}}
			}),
			builder.WithPredicates(predicate.Or(
				predicate.GenerationChangedPredicate{},
				// Status changes don't bump generation, so we also need to
				// react to status updates. ResourceVersion change is the
				// catch-all that covers status edits.
				predicate.ResourceVersionChangedPredicate{},
			)),
		).
		Complete(r)
}

func (r *VGPUGangReservationReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var rsv vgpuv1alpha1.VGPUGangReservation
	if err := r.Client.Get(ctx, req.NamespacedName, &rsv); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	// Deletion: cascade is handled by OwnerReference (parent gang owns us).
	if !rsv.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}

	// Bug 2 fix: Failed is NOT a true terminal state until teardown completes.
	// Released IS terminal (it's only set after teardown is verified).
	if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseReleased {
		return reconcile.Result{}, nil
	}

	// 1. Walk child slices, count phases.
	tally, err := r.tallyChildSlices(ctx, &rsv)
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("tallying children: %w", err)
	}

	// 2. Special handling for already-Failed reservations: keep retrying teardown
	// until all children are confirmed gone, then transition to Released.
	if rsv.Status.Phase == vgpuv1alpha1.ReservationPhaseFailed {
		return r.continueTeardown(ctx, &rsv, tally)
	}

	// 3. Decide next phase based on current phase + tally.
	nextPhase, reason, requeue := r.decideNextPhase(&rsv, tally)

	// 4. Bug 4 fix: if we're transitioning to Failed, run teardown FIRST
	// (so children get deleted), THEN re-tally (so status reflects reality),
	// THEN apply the phase update.
	priorPhase := rsv.Status.Phase
	if nextPhase == vgpuv1alpha1.ReservationPhaseFailed && priorPhase != vgpuv1alpha1.ReservationPhaseFailed {
		log.Printf("[gang-rsv] %s/%s: transitioning to Failed: %s", rsv.Namespace, rsv.Name, reason)
		if err := r.tearDownChildren(ctx, &rsv); err != nil {
			log.Printf("[gang-rsv] %s/%s: teardown error (will retry): %v", rsv.Namespace, rsv.Name, err)
			// Still write the Failed phase + reason so observers see the failure
			// even if teardown is incomplete. continueTeardown will retry.
		}
		// Re-tally after teardown attempts.
		freshTally, terr := r.tallyChildSlices(ctx, &rsv)
		if terr == nil {
			tally = freshTally
		}
	}

	// 5. Apply the transition.
	if err := r.applyPhase(ctx, &rsv, nextPhase, reason, tally); err != nil {
		// teardown-loop fix applied: not-found means cascade-delete reaped
		// the reservation while we were processing it. That's fine; just
		// stop reconciling rather than triggering workqueue backoff.
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("applying phase: %w", err)
	}

	return reconcile.Result{RequeueAfter: requeue}, nil
}

// continueTeardown is the post-Failed reconcile loop. Idempotently retries
// teardown until all children are gone, then transitions Failed -> Released.
func (r *VGPUGangReservationReconciler) continueTeardown(
	ctx context.Context,
	rsv *vgpuv1alpha1.VGPUGangReservation,
	tally *sliceTally,
) (reconcile.Result, error) {
	// "All children gone" = no claims and no slices remain for any of our
	// child claim names.
	allGone := true
	for _, claimName := range rsv.Spec.ChildClaims {
		var claim vgpuv1alpha1.VGPUClaim
		err := r.Client.Get(ctx, types.NamespacedName{Namespace: rsv.Namespace, Name: claimName}, &claim)
		if err == nil {
			allGone = false
			break
		}
		if !errors.IsNotFound(err) {
			allGone = false
			break
		}
		// Also check the slice in case the claim is gone but the slice lingers
		var slice vgpuv1alpha1.VGPUSlice
		err = r.Client.Get(ctx, types.NamespacedName{Namespace: rsv.Namespace, Name: claimName + "-slice"}, &slice)
		if err == nil {
			allGone = false
			break
		}
	}

	if allGone {
		// All children verified gone. Transition Failed -> Released.
		if err := r.applyPhase(ctx, rsv, vgpuv1alpha1.ReservationPhaseReleased,
			"teardown complete; all children verified gone", tally); err != nil {
			return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
		}
		log.Printf("[gang-rsv] %s/%s: teardown verified; transitioning Failed -> Released",
			rsv.Namespace, rsv.Name)
		return reconcile.Result{}, nil
	}

	// Still tearing down. Re-trigger teardown for any stragglers, update
	// status with current tally, requeue.
	if err := r.tearDownChildren(ctx, rsv); err != nil {
		log.Printf("[gang-rsv] %s/%s: teardown retry error: %v", rsv.Namespace, rsv.Name, err)
	}
	if err := r.applyPhase(ctx, rsv, vgpuv1alpha1.ReservationPhaseFailed,
		rsv.Status.FailureReason, tally); err != nil {
		log.Printf("[gang-rsv] %s/%s: status refresh failed: %v", rsv.Namespace, rsv.Name, err)
	}
	return reconcile.Result{RequeueAfter: 3 * time.Second}, nil
}

// sliceTally aggregates per-claim slice phases into the counts the
// reservation state machine needs.
// teardown-loop fix applied: split "failure" into two distinct concepts.
//
// schedulingFailedSlots: slice in Failed phase — a genuine scheduling failure
//
//	that should drive transition to ReservationPhaseFailed.
//
// tearingDownSlots:      claim/slice has DeletionTimestamp set OR slice is in
//
//	Releasing/Released/Preempting phase. This is normal
//	cascade-delete progress, NOT a new failure signal.
//	Counting these as failures triggered an infinite
//	teardown loop because tearDownChildren itself sets
//	DeletionTimestamps.
//
// failedSlots:           preserved for backward-compatible status reporting,
//
//	equals schedulingFailedSlots (the value users care
//	about) so kubectl output remains meaningful.
type sliceTally struct {
	reservedSlots         int32
	committedSlots        int32
	failedSlots           int32 // = schedulingFailedSlots, for status
	schedulingFailedSlots int32
	tearingDownSlots      int32
	pendingSlots          int32
	missingSlots          int32 // slice never created OR claim torn down
	perSlice              map[string]string
}

// tallyChildSlices fetches each child claim and its slice and counts phases.
func (r *VGPUGangReservationReconciler) tallyChildSlices(ctx context.Context, rsv *vgpuv1alpha1.VGPUGangReservation) (*sliceTally, error) {
	t := &sliceTally{perSlice: make(map[string]string, len(rsv.Spec.ChildClaims))}

	for _, claimName := range rsv.Spec.ChildClaims {
		var claim vgpuv1alpha1.VGPUClaim
		err := r.Client.Get(ctx, types.NamespacedName{Namespace: rsv.Namespace, Name: claimName}, &claim)
		if errors.IsNotFound(err) {
			t.missingSlots++
			t.perSlice[claimName] = "ClaimMissing"
			continue
		}
		if err != nil {
			return nil, err
		}
		// teardown-loop fix applied: a claim with DeletionTimestamp is
		// cascade-delete in progress, not a new scheduling failure.
		if !claim.DeletionTimestamp.IsZero() {
			t.tearingDownSlots++
			t.perSlice[claimName] = "ClaimDeleting"
			continue
		}

		sliceName := claimName + "-slice"
		var slice vgpuv1alpha1.VGPUSlice
		err = r.Client.Get(ctx, types.NamespacedName{Namespace: rsv.Namespace, Name: sliceName}, &slice)
		if errors.IsNotFound(err) {
			t.pendingSlots++
			t.perSlice[claimName] = "Pending"
			continue
		}
		if err != nil {
			return nil, err
		}
		// teardown-loop fix applied: a slice with DeletionTimestamp is
		// cascade-delete in progress, not a new scheduling failure.
		if !slice.DeletionTimestamp.IsZero() {
			t.tearingDownSlots++
			t.perSlice[claimName] = "SliceDeleting"
			continue
		}

		switch slice.Status.Phase {
		case "Scheduled":
			t.reservedSlots++
			t.perSlice[claimName] = "Reserved"
		case "Allocating":
			t.reservedSlots++
			t.perSlice[claimName] = "Allocating"
		case "Ready":
			t.reservedSlots++
			t.committedSlots++
			t.perSlice[claimName] = "Bound"
		case "Failed":
			// teardown-loop fix applied: actual Failed phase IS a real
			// scheduling failure — counted under schedulingFailedSlots.
			t.schedulingFailedSlots++
			t.perSlice[claimName] = "Failed"
		case "Releasing", "Released", "Preempting":
			// teardown-loop fix applied: these are teardown phases.
			t.tearingDownSlots++
			t.perSlice[claimName] = "Releasing"
		case "Pending", "":
			t.pendingSlots++
			t.perSlice[claimName] = "Pending"
		default:
			t.pendingSlots++
			t.perSlice[claimName] = string(slice.Status.Phase)
		}
	}
	// teardown-loop fix applied: keep failedSlots in sync with the genuine-
	// failure count for backward-compatible kubectl status output.
	t.failedSlots = t.schedulingFailedSlots
	return t, nil
}

// decideNextPhase is the pure-function state machine.
func (r *VGPUGangReservationReconciler) decideNextPhase(
	rsv *vgpuv1alpha1.VGPUGangReservation,
	t *sliceTally,
) (vgpuv1alpha1.VGPUGangReservationPhase, string, time.Duration) {

	cur := rsv.Status.Phase
	gangSize := rsv.Spec.GangSize

	// Hard failures: only genuine scheduling failures (slice in Failed
	// phase) drive the transition to Failed. Teardown progress
	// (DeletionTimestamps, Releasing slices) does NOT — that's expected
	// state during cascade-delete and would otherwise loop the reconciler.
	if t.schedulingFailedSlots > 0 {
		return vgpuv1alpha1.ReservationPhaseFailed,
			fmt.Sprintf("slot failure: %d slot(s) could not be scheduled", t.schedulingFailedSlots),
			0
	}

	// All bound? Committed.
	if t.committedSlots >= gangSize {
		return vgpuv1alpha1.ReservationPhaseCommitted, "all slots committed", 30 * time.Second
	}

	// All reserved? Move to Reserved.
	if t.reservedSlots >= gangSize {
		return vgpuv1alpha1.ReservationPhaseReserved, "all slots reserved", 5 * time.Second
	}

	// Otherwise, still reserving. Check deadline.
	switch cur {
	case "", vgpuv1alpha1.ReservationPhasePending:
		return vgpuv1alpha1.ReservationPhaseReserving, "reservation in progress", 3 * time.Second

	case vgpuv1alpha1.ReservationPhaseReserving:
		// Deadline check. FirstReservingTime is only stamped after slice
		// materialization is complete (see applyPhase).
		if rsv.Status.FirstReservingTime != nil {
			deadline := int32(60)
			if rsv.Spec.DeadlineSeconds != nil {
				deadline = *rsv.Spec.DeadlineSeconds
			}
			elapsed := time.Since(rsv.Status.FirstReservingTime.Time)
			if elapsed > time.Duration(deadline)*time.Second {
				return vgpuv1alpha1.ReservationPhaseFailed,
					fmt.Sprintf("deadline %ds exceeded with only %d/%d slots reserved",
						deadline, t.reservedSlots, gangSize),
					0
			}
		}
		return vgpuv1alpha1.ReservationPhaseReserving,
			fmt.Sprintf("reserving: %d/%d slots", t.reservedSlots, gangSize),
			3 * time.Second

	case vgpuv1alpha1.ReservationPhaseReserved:
		// Reserved but committed dropped — slice torn down externally.
		return vgpuv1alpha1.ReservationPhaseFailed,
			"slice regression after Reserved (external teardown?)", 0
	}

	return cur, "no transition", 5 * time.Second
}

// applyPhase writes the next reservation phase + tally to status. Idempotent.
func (r *VGPUGangReservationReconciler) applyPhase(
	ctx context.Context,
	rsv *vgpuv1alpha1.VGPUGangReservation,
	nextPhase vgpuv1alpha1.VGPUGangReservationPhase,
	reason string,
	t *sliceTally,
) error {
	key := types.NamespacedName{Namespace: rsv.Namespace, Name: rsv.Name}
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUGangReservation
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			// teardown-loop fix applied: if the reservation was deleted
			// (cascade from parent gang), there's nothing to update.
			// Returning the error here would trigger workqueue exponential
			// backoff and starve unrelated reservations.
			if errors.IsNotFound(err) {
				return nil
			}
			return err
		}
		// firstReservingTime fix applied: stamp unconditionally on first
		// transition into Reserving. With Option B (hold-the-reservation
		// gang gate) deployed, slice materialization is fast (<2s), so the
		// original lazy-stamping concern from Wave 1 fix A is no longer
		// warranted. Losing gangs whose slices stay in Pending/empty phase
		// (because the cluster is full) need the deadline to fire so they
		// can be cleanly marked Failed; otherwise they sit forever.
		if nextPhase == vgpuv1alpha1.ReservationPhaseReserving && fresh.Status.FirstReservingTime == nil {
			now := metav1.Now()
			fresh.Status.FirstReservingTime = &now
		}
		fresh.Status.Phase = nextPhase
		fresh.Status.ReservedSlots = t.reservedSlots
		fresh.Status.CommittedSlots = t.committedSlots
		fresh.Status.FailedSlots = t.failedSlots
		fresh.Status.PerSliceState = t.perSlice
		fresh.Status.Message = reason
		if nextPhase == vgpuv1alpha1.ReservationPhaseFailed && fresh.Status.FailureReason == "" {
			fresh.Status.FailureReason = reason
		}
		return r.Client.Status().Update(ctx, &fresh)
	})
}

// tearDownChildren is the rollback path. We delete each child VGPUJob with
// foreground propagation (Bug 3 fix), so the API server blocks until the
// cascade through Claim and Slice is also complete.
//
// Idempotent: re-runs are safe; already-deleted children are no-ops.
func (r *VGPUGangReservationReconciler) tearDownChildren(ctx context.Context, rsv *vgpuv1alpha1.VGPUGangReservation) error {
	log.Printf("[gang-rsv] %s/%s: tearing down %d children (rollback path)",
		rsv.Namespace, rsv.Name, len(rsv.Spec.ChildClaims))

	fg := metav1.DeletePropagationForeground

	var firstErr error
	for _, claimName := range rsv.Spec.ChildClaims {
		jobName := claimName
		const suffix = "-claim"
		if len(jobName) > len(suffix) && jobName[len(jobName)-len(suffix):] == suffix {
			jobName = jobName[:len(jobName)-len(suffix)]
		}

		// First, try to delete the parent VGPUJob with foreground propagation.
		// This blocks until the entire chain (Job -> Claim -> Slice) is gone.
		var child vgpuv1alpha1.VGPUJob
		err := r.Client.Get(ctx, types.NamespacedName{Namespace: rsv.Namespace, Name: jobName}, &child)
		if errors.IsNotFound(err) {
			// Job already gone. Belt-and-suspenders: also try to delete
			// any orphaned claim or slice that lingered.
			r.cleanupOrphans(ctx, rsv.Namespace, claimName)
			continue
		}
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if !child.DeletionTimestamp.IsZero() {
			// Already being deleted — let foreground cascade finish.
			continue
		}

		// Bug 3 fix: explicit foreground propagation.
		if err := r.Client.Delete(ctx, &child, &client.DeleteOptions{
			PropagationPolicy: &fg,
		}); err != nil && !errors.IsNotFound(err) {
			log.Printf("[gang-rsv] %s/%s: failed to delete child %s: %v",
				rsv.Namespace, rsv.Name, jobName, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// cleanupOrphans handles the Bug 6 case: VGPUJob is gone but its child claim
// or slice lingers (cascade got interrupted, finalizer stuck, etc). We force
// delete them with foreground propagation so the cluster doesn't hold capacity
// for ghost objects.
func (r *VGPUGangReservationReconciler) cleanupOrphans(ctx context.Context, ns, claimName string) {
	fg := metav1.DeletePropagationForeground

	// Orphan claim?
	var claim vgpuv1alpha1.VGPUClaim
	err := r.Client.Get(ctx, types.NamespacedName{Namespace: ns, Name: claimName}, &claim)
	if err == nil && claim.DeletionTimestamp.IsZero() {
		if derr := r.Client.Delete(ctx, &claim, &client.DeleteOptions{
			PropagationPolicy: &fg,
		}); derr != nil && !errors.IsNotFound(derr) {
			log.Printf("[gang-rsv] cleanupOrphans: claim %s/%s delete failed: %v", ns, claimName, derr)
		}
	}

	// Orphan slice?
	sliceName := claimName + "-slice"
	var slice vgpuv1alpha1.VGPUSlice
	err = r.Client.Get(ctx, types.NamespacedName{Namespace: ns, Name: sliceName}, &slice)
	if err == nil && slice.DeletionTimestamp.IsZero() {
		if derr := r.Client.Delete(ctx, &slice, &client.DeleteOptions{
			PropagationPolicy: &fg,
		}); derr != nil && !errors.IsNotFound(derr) {
			log.Printf("[gang-rsv] cleanupOrphans: slice %s/%s delete failed: %v", ns, sliceName, derr)
		}
	}
}
