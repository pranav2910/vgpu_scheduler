package controller

// Batch B regression tests — committed gangs fail loud on child loss, and the
// job phase mapping is total + monotonic. Each test names the production
// failure it locks out.

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func gangRsvScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("AddToScheme: %v", err)
	}
	if err := corev1.AddToScheme(s); err != nil {
		t.Fatalf("AddToScheme(core): %v", err)
	}
	return s
}

// ── Fix: committed gang fails loud on child loss ─────────────────────────────

func TestDecideNextPhase_CommittedChildLossFailsLoud(t *testing.T) {
	r := &VGPUGangReservationReconciler{}
	rsv := &vgpuv1alpha1.VGPUGangReservation{
		Spec:   vgpuv1alpha1.VGPUGangReservationSpec{GangSize: 4},
		Status: vgpuv1alpha1.VGPUGangReservationStatus{Phase: vgpuv1alpha1.ReservationPhaseCommitted},
	}

	cases := []struct {
		name      string
		tally     sliceTally
		wantPhase vgpuv1alpha1.VGPUGangReservationPhase
		wantInRsn string
	}{
		{
			// kubectl delete of a child VGPUJob cascades: claim gone → missing.
			name:      "child claim deleted → Failed",
			tally:     sliceTally{committedSlots: 3, reservedSlots: 3, missingSlots: 1},
			wantPhase: vgpuv1alpha1.ReservationPhaseFailed,
			wantInRsn: "child lost after commit",
		},
		{
			// Slice deleted; claim reconciler regenerated a fresh Pending one.
			name:      "child slice regenerated (Pending) → Failed",
			tally:     sliceTally{committedSlots: 3, reservedSlots: 3, pendingSlots: 1},
			wantPhase: vgpuv1alpha1.ReservationPhaseFailed,
			wantInRsn: "child lost after commit",
		},
		{
			// External deletion mid-cascade.
			name:      "child mid-deletion → Failed",
			tally:     sliceTally{committedSlots: 3, reservedSlots: 3, tearingDownSlots: 1},
			wantPhase: vgpuv1alpha1.ReservationPhaseFailed,
			wantInRsn: "child lost after commit",
		},
		{
			// Healthy committed gang: stays Committed (the pre-fix machine got
			// this right; lock it).
			name:      "all committed → stays Committed",
			tally:     sliceTally{committedSlots: 4, reservedSlots: 4},
			wantPhase: vgpuv1alpha1.ReservationPhaseCommitted,
		},
		{
			// THE DEMOTION HAZARD: a lost slice recreated and re-scheduled makes
			// reservedSlots == gangSize while committed < gangSize. The generic
			// "all reserved → Reserved" check used to fire BEFORE the phase
			// switch, silently demoting Committed → Reserved → a later silent
			// "recovery" — the self-heal this machine deliberately rejects. A
			// Committed gang must never demote.
			name:      "regenerated slice re-scheduled → holds Committed, never demotes to Reserved",
			tally:     sliceTally{committedSlots: 3, reservedSlots: 4},
			wantPhase: vgpuv1alpha1.ReservationPhaseCommitted,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			phase, reason, _ := r.decideNextPhase(rsv, &tc.tally)
			if phase != tc.wantPhase {
				t.Fatalf("phase = %s (reason %q), want %s", phase, reason, tc.wantPhase)
			}
			if tc.wantInRsn != "" && !strings.Contains(reason, tc.wantInRsn) {
				t.Fatalf("reason = %q, want it to contain %q", reason, tc.wantInRsn)
			}
		})
	}

	// Pre-commit behavior unchanged: a Reserving gang with all slots reserved
	// still advances to Reserved.
	reserving := &vgpuv1alpha1.VGPUGangReservation{
		Spec:   vgpuv1alpha1.VGPUGangReservationSpec{GangSize: 4},
		Status: vgpuv1alpha1.VGPUGangReservationStatus{Phase: vgpuv1alpha1.ReservationPhaseReserving},
	}
	if phase, _, _ := r.decideNextPhase(reserving, &sliceTally{reservedSlots: 4}); phase != vgpuv1alpha1.ReservationPhaseReserved {
		t.Fatalf("Reserving with all reserved: got %s, want Reserved (pre-commit promotion must keep working)", phase)
	}
}

// committedFixture builds a Committed 2-gang: reservation + both claims +
// both Ready slices (+ child jobs so teardown has something to delete).
func committedFixture(ns string) []client.Object {
	mkClaim := func(name string) *vgpuv1alpha1.VGPUClaim {
		return &vgpuv1alpha1.VGPUClaim{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns}}
	}
	mkSlice := func(name string) *vgpuv1alpha1.VGPUSlice {
		return &vgpuv1alpha1.VGPUSlice{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
			Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase("Ready")},
		}
	}
	mkJob := func(name string) *vgpuv1alpha1.VGPUJob {
		return &vgpuv1alpha1.VGPUJob{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns}}
	}
	rsv := &vgpuv1alpha1.VGPUGangReservation{
		ObjectMeta: metav1.ObjectMeta{Name: "g-rsv", Namespace: ns},
		Spec: vgpuv1alpha1.VGPUGangReservationSpec{
			GangSize:    2,
			ChildClaims: []string{"g-0-claim", "g-1-claim"},
		},
		Status: vgpuv1alpha1.VGPUGangReservationStatus{Phase: vgpuv1alpha1.ReservationPhaseCommitted},
	}
	return []client.Object{
		rsv,
		mkJob("g-0"), mkJob("g-1"),
		mkClaim("g-0-claim"), mkClaim("g-1-claim"),
		mkSlice("g-0-claim-slice"), mkSlice("g-1-claim-slice"),
	}
}

func TestReconcile_ChildLossConfirmedByDirectRead(t *testing.T) {
	// Informer AND direct reader agree the child is gone → the reservation
	// fails loud and tears down the survivor.
	s := gangRsvScheme(t)
	objs := committedFixture("ns1")
	// Drop child 1's claim + slice + job entirely (deleted out from under us).
	var kept []client.Object
	for _, o := range objs {
		if strings.HasPrefix(o.GetName(), "g-1") {
			continue
		}
		kept = append(kept, o)
	}
	cl := fake.NewClientBuilder().WithScheme(s).
		WithStatusSubresource(&vgpuv1alpha1.VGPUGangReservation{}, &vgpuv1alpha1.VGPUSlice{}).
		WithObjects(kept...).Build()
	r := &VGPUGangReservationReconciler{Client: cl, Scheme: s, APIReader: cl}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Namespace: "ns1", Name: "g-rsv"},
	}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	var rsv vgpuv1alpha1.VGPUGangReservation
	if err := cl.Get(context.Background(), types.NamespacedName{Namespace: "ns1", Name: "g-rsv"}, &rsv); err != nil {
		t.Fatalf("get rsv: %v", err)
	}
	if rsv.Status.Phase != vgpuv1alpha1.ReservationPhaseFailed {
		t.Fatalf("phase = %s, want Failed (child loss must fail loud, not sit Committed forever)", rsv.Status.Phase)
	}
	if !strings.Contains(rsv.Status.FailureReason, "child lost after commit") {
		t.Fatalf("failureReason = %q, want child-lost reason", rsv.Status.FailureReason)
	}
	// The surviving child job must be getting torn down (deleted by teardown).
	var survivor vgpuv1alpha1.VGPUJob
	err := cl.Get(context.Background(), types.NamespacedName{Namespace: "ns1", Name: "g-0"}, &survivor)
	if err == nil && survivor.DeletionTimestamp.IsZero() {
		t.Fatalf("surviving child g-0 was not torn down after the gang failed")
	}
}

func TestReconcile_InformerStalenessDoesNotTearDown(t *testing.T) {
	// The informer says the child is gone, but the DIRECT read still sees it —
	// classic informer lag. The reservation must HOLD Committed: an absence
	// reported only by the cache never triggers teardown of live children.
	s := gangRsvScheme(t)
	full := committedFixture("ns2")
	var stale []client.Object
	for _, o := range full {
		if strings.HasPrefix(o.GetName(), "g-1") {
			continue // informer view: child 1 missing
		}
		stale = append(stale, o)
	}
	informer := fake.NewClientBuilder().WithScheme(s).
		WithStatusSubresource(&vgpuv1alpha1.VGPUGangReservation{}, &vgpuv1alpha1.VGPUSlice{}).
		WithObjects(stale...).Build()
	direct := fake.NewClientBuilder().WithScheme(s).
		WithObjects(committedFixture("ns2")...).Build() // direct view: all present
	r := &VGPUGangReservationReconciler{Client: informer, Scheme: s, APIReader: direct}

	res, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Namespace: "ns2", Name: "g-rsv"},
	})
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if res.RequeueAfter == 0 {
		t.Fatalf("expected a short requeue while holding Committed against a stale informer")
	}
	var rsv vgpuv1alpha1.VGPUGangReservation
	if err := informer.Get(context.Background(), types.NamespacedName{Namespace: "ns2", Name: "g-rsv"}, &rsv); err != nil {
		t.Fatalf("get rsv: %v", err)
	}
	if rsv.Status.Phase != vgpuv1alpha1.ReservationPhaseCommitted {
		t.Fatalf("phase = %s, want Committed (informer-only absence must not tear down live children)", rsv.Status.Phase)
	}
	// The survivor in the informer view must NOT have been deleted.
	var kept vgpuv1alpha1.VGPUJob
	if err := informer.Get(context.Background(), types.NamespacedName{Namespace: "ns2", Name: "g-0"}, &kept); err != nil {
		t.Fatalf("child g-0 was torn down on an unconfirmed (stale) absence: %v", err)
	}
}

// ── Fix: job phase mapping total + monotonic ─────────────────────────────────

func TestDerivePhaseFromClaim_TotalAndMonotonic(t *testing.T) {
	claimIn := func(phase string) *vgpuv1alpha1.VGPUClaim {
		return &vgpuv1alpha1.VGPUClaim{Status: vgpuv1alpha1.VGPUClaimStatus{Phase: vgpuv1alpha1.VGPUClaimPhase(phase)}}
	}

	cases := []struct {
		claim   string
		current vgpuv1alpha1.VGPUJobPhase
		want    vgpuv1alpha1.VGPUJobPhase
	}{
		// Forward progress maps normally.
		{"Pending", vgpuv1alpha1.JobPhasePending, vgpuv1alpha1.JobPhaseClaimCreated},
		{"Scheduled", vgpuv1alpha1.JobPhaseClaimCreated, vgpuv1alpha1.JobPhaseScheduled},
		{"Bound", vgpuv1alpha1.JobPhaseClaimCreated, vgpuv1alpha1.JobPhaseScheduled},
		// MONOTONIC: a claim flap must not drag an earned phase backwards.
		{"Pending", vgpuv1alpha1.JobPhaseScheduled, vgpuv1alpha1.JobPhaseScheduled},
		{"Scheduled", vgpuv1alpha1.JobPhaseRunning, vgpuv1alpha1.JobPhaseRunning},
		{"Pending", vgpuv1alpha1.JobPhasePodCreating, vgpuv1alpha1.JobPhasePodCreating},
		// Deleting (real claim-writer phase, used to fall to default →
		// ClaimCreated, regressing Scheduled jobs) keeps the current phase.
		{"Deleting", vgpuv1alpha1.JobPhaseScheduled, vgpuv1alpha1.JobPhaseScheduled},
		{"Deleting", vgpuv1alpha1.JobPhaseRunning, vgpuv1alpha1.JobPhaseRunning},
		// Unknown phases never guess backwards.
		{"SomethingNew", vgpuv1alpha1.JobPhaseScheduled, vgpuv1alpha1.JobPhaseScheduled},
		// Failure always surfaces over in-flight phases.
		{"Failed", vgpuv1alpha1.JobPhaseRunning, vgpuv1alpha1.JobPhaseFailed},
		{"Failed", vgpuv1alpha1.JobPhaseClaimCreated, vgpuv1alpha1.JobPhaseFailed},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprintf("claim=%s current=%s", tc.claim, tc.current), func(t *testing.T) {
			got, _ := derivePhaseFromClaim(claimIn(tc.claim), tc.current)
			if got != tc.want {
				t.Fatalf("derivePhaseFromClaim(%s, %s) = %s, want %s", tc.claim, tc.current, got, tc.want)
			}
		})
	}
}

// Guard against the suite hanging on the fake client's lack of real teardown
// timing — keep a generous overall budget visible.
var _ = time.Second
