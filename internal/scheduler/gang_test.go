package scheduler

import (
	"context"
	"strconv"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// ── ordering helper ───────────────────────────────────────────────────────

// TestPickAdmissionHead_PriorityThenAgeThenName verifies the contended-set
// ordering that decides which gang claims a free admission slot.
func TestPickAdmissionHead_PriorityThenAgeThenName(t *testing.T) {
	now := time.Now()
	gate := NewGangBindingGate(nil)

	// Same age, different priority → highest priority wins.
	gate.cohorts = map[string]*gangCohort{
		"ns/low":  {gangSize: 2, priority: 1, createdAt: now},
		"ns/high": {gangSize: 2, priority: 9, createdAt: now},
		"ns/mid":  {gangSize: 2, priority: 5, createdAt: now},
	}
	if got := gate.pickAdmissionHeadLocked(now); got != "ns/high" {
		t.Fatalf("priority ordering: got %q, want ns/high", got)
	}

	// Equal priority → oldest (earliest createdAt) wins.
	gate.cohorts = map[string]*gangCohort{
		"ns/younger": {gangSize: 2, priority: 5, createdAt: now},
		"ns/older":   {gangSize: 2, priority: 5, createdAt: now.Add(-time.Minute)},
	}
	if got := gate.pickAdmissionHeadLocked(now); got != "ns/older" {
		t.Fatalf("age ordering: got %q, want ns/older", got)
	}

	// Equal priority and age → lexicographically smaller key wins.
	gate.cohorts = map[string]*gangCohort{
		"ns/bbb": {gangSize: 2, priority: 5, createdAt: now},
		"ns/aaa": {gangSize: 2, priority: 5, createdAt: now},
	}
	if got := gate.pickAdmissionHeadLocked(now); got != "ns/aaa" {
		t.Fatalf("name tiebreak: got %q, want ns/aaa", got)
	}

	// Released and backed-off cohorts are skipped.
	gate.cohorts = map[string]*gangCohort{
		"ns/done":    {gangSize: 2, priority: 9, createdAt: now, released: true},
		"ns/cooling": {gangSize: 2, priority: 8, createdAt: now},
		"ns/ready":   {gangSize: 2, priority: 1, createdAt: now},
	}
	gate.backoff = map[string]time.Time{"ns/cooling": now.Add(time.Minute)}
	if got := gate.pickAdmissionHeadLocked(now); got != "ns/ready" {
		t.Fatalf("skip released+backoff: got %q, want ns/ready", got)
	}

	// Backoff that has elapsed makes the cohort eligible again.
	gate.backoff = map[string]time.Time{"ns/cooling": now.Add(-time.Second)}
	if got := gate.pickAdmissionHeadLocked(now); got != "ns/cooling" {
		t.Fatalf("expired backoff: got %q, want ns/cooling", got)
	}
}

// ── serialized admission through the gate ─────────────────────────────────

func gangTestScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("AddToScheme: %v", err)
	}
	return s
}

func reservingRsv(name string, gangSize int32) *vgpuv1alpha1.VGPUGangReservation {
	return &vgpuv1alpha1.VGPUGangReservation{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUGangReservationSpec{GangSize: gangSize},
		Status:     vgpuv1alpha1.VGPUGangReservationStatus{Phase: vgpuv1alpha1.ReservationPhaseReserving},
	}
}

func gangSlice(name, rsvName string, priority int, uid string) *vgpuv1alpha1.VGPUSlice {
	return &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "default",
			UID:       types.UID(uid),
			Annotations: map[string]string{
				vgpuv1alpha1.AnnotationReservationRef: rsvName,
				vgpuv1alpha1.AnnotationGangPriority:   strconv.Itoa(priority),
			},
		},
	}
}

// TestGate_SerializedAdmission_OneGangAtATime is the liveness regression test:
// when two gangs contend, only the admitted gang holds capacity. The other
// gang is told to WAIT (release its reservation) until the first commits — so
// capacity is never fragmented across half-formed gangs. Admission is sticky:
// the first gang to claim the slot keeps it through quorum even though the
// second gang has higher priority (priority only orders the slot when free).
func TestGate_SerializedAdmission_OneGangAtATime(t *testing.T) {
	ctx := context.Background()
	c := fake.NewClientBuilder().
		WithScheme(gangTestScheme(t)).
		WithObjects(reservingRsv("rsv-g1", 2), reservingRsv("rsv-g2", 2)).
		Build()
	gate := NewGangBindingGate(c)

	check := func(s *vgpuv1alpha1.VGPUSlice) GangCheckResult {
		res, _, err := gate.CheckSliceWithCohort(ctx, s, "node-a", 10)
		if err != nil {
			t.Fatalf("gate error for %s: %v", s.Name, err)
		}
		return res
	}

	// g1's first slice arrives first → claims the admission slot, sub-quorum.
	if got := check(gangSlice("g1-0", "rsv-g1", 1, "u-g1-0")); got != GangBindDeferred {
		t.Fatalf("g1-0: got %v, want Deferred (admitted, holding)", got)
	}
	// g2's first slice arrives — higher priority, but g1 already holds the slot.
	if got := check(gangSlice("g2-0", "rsv-g2", 100, "u-g2-0")); got != GangBindWait {
		t.Fatalf("g2-0: got %v, want Wait (g1 holds the slot)", got)
	}
	// g1 reaches quorum → Allowed, and the slot frees.
	if got := check(gangSlice("g1-1", "rsv-g1", 1, "u-g1-1")); got != GangBindAllowed {
		t.Fatalf("g1-1: got %v, want Allowed (quorum)", got)
	}
	// Slot is free now → g2 finally gets admitted.
	if got := check(gangSlice("g2-0", "rsv-g2", 100, "u-g2-0")); got != GangBindDeferred {
		t.Fatalf("g2-0 retry: got %v, want Deferred (now admitted)", got)
	}
	if got := check(gangSlice("g2-1", "rsv-g2", 100, "u-g2-1")); got != GangBindAllowed {
		t.Fatalf("g2-1: got %v, want Allowed (quorum)", got)
	}
}

// TestGate_TerminalReservationFreesSlot verifies that if the admitting gang's
// reservation goes terminal (Failed/Released), the slot is freed immediately
// so a waiting gang is not blocked until the stall timeout.
func TestGate_TerminalReservationFreesSlot(t *testing.T) {
	ctx := context.Background()
	g1 := reservingRsv("rsv-g1", 2)
	c := fake.NewClientBuilder().
		WithScheme(gangTestScheme(t)).
		WithObjects(g1, reservingRsv("rsv-g2", 2)).
		Build()
	gate := NewGangBindingGate(c)

	// g1 claims the slot.
	if res, _, _ := gate.CheckSliceWithCohort(ctx, gangSlice("g1-0", "rsv-g1", 1, "u-g1-0"), "n", 10); res != GangBindDeferred {
		t.Fatalf("g1-0: got %v, want Deferred", res)
	}
	// g2 waits.
	if res, _, _ := gate.CheckSliceWithCohort(ctx, gangSlice("g2-0", "rsv-g2", 1, "u-g2-0"), "n", 10); res != GangBindWait {
		t.Fatalf("g2-0: got %v, want Wait", res)
	}
	// g1's reservation fails terminally.
	g1.Status.Phase = vgpuv1alpha1.ReservationPhaseFailed
	if err := c.Status().Update(ctx, g1); err != nil {
		// fake client without status subresource: fall back to a full update.
		if err2 := c.Update(ctx, g1); err2 != nil {
			t.Fatalf("update g1 phase: %v / %v", err, err2)
		}
	}
	// The next time g1's slice is seen, it's rejected and the slot frees.
	if res, _, _ := gate.CheckSliceWithCohort(ctx, gangSlice("g1-0", "rsv-g1", 1, "u-g1-0"), "n", 10); res != GangBindRejected {
		t.Fatalf("g1-0 after fail: got %v, want Rejected", res)
	}
	// g2 can now be admitted.
	if res, _, _ := gate.CheckSliceWithCohort(ctx, gangSlice("g2-0", "rsv-g2", 1, "u-g2-0"), "n", 10); res != GangBindDeferred {
		t.Fatalf("g2-0 after g1 fail: got %v, want Deferred (admitted)", res)
	}
}
