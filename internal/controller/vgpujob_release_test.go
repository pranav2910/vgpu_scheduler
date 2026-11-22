package controller

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// Terminal jobs must RELEASE their VRAM grant (dogfood find, 2026-07-09): a
// Succeeded 45Gi job kept its claim/slice Ready and blocked a live 40Gi
// submit, while vanilla Kubernetes frees a terminal pod's devices. These lock
// the fix: terminal → claim deleted (cascade tears down the slice); repeat
// reconciles are idempotent; non-terminal jobs keep their claim untouched.

func jobRequest() reconcile.Request {
	return reconcile.Request{NamespacedName: types.NamespacedName{Namespace: "ns", Name: "j"}}
}

func claimGone(t *testing.T, r *VGPUJobReconciler) bool {
	t.Helper()
	var c vgpuv1alpha1.VGPUClaim
	err := r.Client.Get(context.Background(), types.NamespacedName{Namespace: "ns", Name: "j-claim"}, &c)
	if err != nil && !errors.IsNotFound(err) {
		t.Fatalf("unexpected error reading claim: %v", err)
	}
	return errors.IsNotFound(err)
}

func TestTerminalSucceededJobReleasesClaim(t *testing.T) {
	s := selfhealScheme(t)
	claim, slice := allocatedClaimAndSlice()
	r := newReconciler(s, podOwningJob(vgpuv1alpha1.JobPhaseSucceeded), claim, slice)

	if _, err := r.Reconcile(context.Background(), jobRequest()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if !claimGone(t, r) {
		t.Fatalf("Succeeded job's claim still exists — finished workload keeps pinning VRAM")
	}
	// Idempotent: a second pass over the terminal job must not error or recreate.
	if _, err := r.Reconcile(context.Background(), jobRequest()); err != nil {
		t.Fatalf("second reconcile after release: %v", err)
	}
	if !claimGone(t, r) {
		t.Fatalf("claim reappeared after release — terminal guard failed to hold")
	}
}

func TestTerminalFailedJobReleasesClaim(t *testing.T) {
	s := selfhealScheme(t)
	claim, slice := allocatedClaimAndSlice()
	r := newReconciler(s, podOwningJob(vgpuv1alpha1.JobPhaseFailed), claim, slice)

	if _, err := r.Reconcile(context.Background(), jobRequest()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if !claimGone(t, r) {
		t.Fatalf("Failed job's claim still exists — crashed workload keeps pinning VRAM")
	}
}

func TestTerminalJobWithClaimAlreadyGoneIsNoop(t *testing.T) {
	s := selfhealScheme(t)
	r := newReconciler(s, podOwningJob(vgpuv1alpha1.JobPhaseSucceeded))

	if _, err := r.Reconcile(context.Background(), jobRequest()); err != nil {
		t.Fatalf("reconcile with no claim must be a clean no-op, got: %v", err)
	}
}

func TestRunningJobKeepsClaim(t *testing.T) {
	s := selfhealScheme(t)
	claim, slice := allocatedClaimAndSlice()
	// Pure resource request (no podTemplate): Running-family phases must never
	// trigger a release — claim-only holds are a supported use case.
	job := podOwningJob(vgpuv1alpha1.JobPhaseScheduled)
	job.Spec.PodTemplate = nil
	r := newReconciler(s, job, claim, slice)

	if _, err := r.Reconcile(context.Background(), jobRequest()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if claimGone(t, r) {
		t.Fatalf("non-terminal job's claim was deleted — release fired too early")
	}
}
