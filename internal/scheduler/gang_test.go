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
	// Ordering sub-cases give every cohort a member: a member-less cohort is
	// (deliberately) unpickable except via its own check — covered separately.
	m := func() map[string]gangMember { return map[string]gangMember{"u": {sliceUID: "u"}} }

	// Same age, different priority → highest priority wins.
	gate.cohorts = map[string]*gangCohort{
		"ns/low":  {gangSize: 2, priority: 1, createdAt: now, members: m()},
		"ns/high": {gangSize: 2, priority: 9, createdAt: now, members: m()},
		"ns/mid":  {gangSize: 2, priority: 5, createdAt: now, members: m()},
	}
	if got := gate.pickAdmissionHeadLocked(now, ""); got != "ns/high" {
		t.Fatalf("priority ordering: got %q, want ns/high", got)
	}

	// Equal priority → oldest (earliest createdAt) wins.
	gate.cohorts = map[string]*gangCohort{
		"ns/younger": {gangSize: 2, priority: 5, createdAt: now, members: m()},
		"ns/older":   {gangSize: 2, priority: 5, createdAt: now.Add(-time.Minute), members: m()},
	}
	if got := gate.pickAdmissionHeadLocked(now, ""); got != "ns/older" {
		t.Fatalf("age ordering: got %q, want ns/older", got)
	}

	// Equal priority and age → lexicographically smaller key wins.
	gate.cohorts = map[string]*gangCohort{
		"ns/bbb": {gangSize: 2, priority: 5, createdAt: now, members: m()},
		"ns/aaa": {gangSize: 2, priority: 5, createdAt: now, members: m()},
	}
	if got := gate.pickAdmissionHeadLocked(now, ""); got != "ns/aaa" {
		t.Fatalf("name tiebreak: got %q, want ns/aaa", got)
	}

	// Released and backed-off cohorts are skipped.
	gate.cohorts = map[string]*gangCohort{
		"ns/done":    {gangSize: 2, priority: 9, createdAt: now, released: true, members: m()},
		"ns/cooling": {gangSize: 2, priority: 8, createdAt: now, members: m()},
		"ns/ready":   {gangSize: 2, priority: 1, createdAt: now, members: m()},
	}
	gate.backoff = map[string]time.Time{"ns/cooling": now.Add(time.Minute)}
	if got := gate.pickAdmissionHeadLocked(now, ""); got != "ns/ready" {
		t.Fatalf("skip released+backoff: got %q, want ns/ready", got)
	}

	// Backoff that has elapsed makes the cohort eligible again.
	gate.backoff = map[string]time.Time{"ns/cooling": now.Add(-time.Second)}
	if got := gate.pickAdmissionHeadLocked(now, ""); got != "ns/cooling" {
		t.Fatalf("expired backoff: got %q, want ns/cooling", got)
	}

	// Round-2 ghost rule: a member-less cohort is unpickable through anyone
	// else's check (it may be a ghost whose slices are gone) — but its OWN
	// check may still claim the slot (cohort creation + first-member
	// registration happen in that same check, so live gangs self-revive).
	gate.backoff = map[string]time.Time{}
	gate.cohorts = map[string]*gangCohort{
		"ns/ghost": {gangSize: 2, priority: 9, createdAt: now.Add(-time.Minute)}, // no members
		"ns/live":  {gangSize: 2, priority: 1, createdAt: now, members: m()},
	}
	if got := gate.pickAdmissionHeadLocked(now, "ns/live"); got != "ns/live" {
		t.Fatalf("member-less ghost must be skipped for other callers: got %q, want ns/live", got)
	}
	if got := gate.pickAdmissionHeadLocked(now, "ns/ghost"); got != "ns/ghost" {
		t.Fatalf("a cohort's own check may claim the slot from 0 members: got %q, want ns/ghost", got)
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

// TestGate_GhostHolderForgottenOnStall is the regression test for the battery
// 2.7 starvation: a gang whose slices no longer exist (namespace deleted —
// deletion never re-enters the scheduler, so the terminal-phase forget path
// never fires) held the admission slot, and on stall was merely BACKED OFF.
// Its old createdAt then out-ranked every live gang under age-asc ordering
// each time the backoff elapsed — starving a feasible gang for its entire
// reservation deadline (filler-rsv died at 60s with 0/4 slots). A holder that
// stalls the full timeout with ZERO members is definitionally such a ghost (a
// live holder registers its first member in the very check that granted it
// the slot), and must be forgotten outright.
func TestGate_GhostHolderForgottenOnStall(t *testing.T) {
	ctx := context.Background()
	c := fake.NewClientBuilder().
		WithScheme(gangTestScheme(t)).
		WithObjects(reservingRsv("rsv-live", 2)).
		Build()
	gate := NewGangBindingGate(c)

	// Plant the ghost: an old, member-less cohort holding the slot past the
	// stall timeout. Its reservation does NOT exist in the API (namespace
	// gone) and no slice of its will ever check in again.
	const ghostKey = "default/rsv-ghost"
	gate.cohorts[ghostKey] = &gangCohort{
		gangSize:  4,
		priority:  500,
		members:   map[string]gangMember{},
		createdAt: time.Now().Add(-6 * time.Minute), // oldest → would win age-asc forever
	}
	gate.admitting = ghostKey
	gate.admittingSince = time.Now().Add(-gangAdmissionTimeout - 5*time.Second)

	// A live, feasible gang checks in. This single check must: detect the
	// stalled member-less holder, forget it (NOT back it off), and hand the
	// slot to the live gang.
	res, _, err := gate.CheckSliceWithCohort(ctx, gangSlice("live-0", "rsv-live", 500, "u-live-0"), "node-a", 10)
	if err != nil {
		t.Fatalf("live-0 check: %v", err)
	}
	if res != GangBindDeferred {
		t.Fatalf("live-0: got %v, want Deferred (live gang must take the slot over the ghost)", res)
	}
	if gate.admitting != "default/rsv-live" {
		t.Fatalf("slot holder = %q, want default/rsv-live", gate.admitting)
	}
	if _, still := gate.cohorts[ghostKey]; still {
		t.Fatalf("ghost cohort still tracked after stall — it must be forgotten, not backed off")
	}
	if _, backed := gate.backoff[ghostKey]; backed {
		t.Fatalf("ghost cohort placed in backoff — backoff lets it re-win the slot via age-asc ordering")
	}

	// And the live gang completes: quorum on its second member.
	res, _, err = gate.CheckSliceWithCohort(ctx, gangSlice("live-1", "rsv-live", 500, "u-live-1"), "node-a", 10)
	if err != nil {
		t.Fatalf("live-1 check: %v", err)
	}
	if res != GangBindAllowed {
		t.Fatalf("live-1: got %v, want Allowed (quorum)", res)
	}
}

// TestGate_RealStallerForfeitsSeniority: a holder that stalls WITH members (a
// real but slow/oversized gang) is backed off — and must lose its age
// seniority, or it re-wins the slot over younger feasible gangs after every
// backoff (rotation, not starvation).
func TestGate_RealStallerForfeitsSeniority(t *testing.T) {
	ctx := context.Background()
	c := fake.NewClientBuilder().
		WithScheme(gangTestScheme(t)).
		WithObjects(reservingRsv("rsv-live", 2)).
		Build()
	gate := NewGangBindingGate(c)

	testStart := time.Now()
	const slowKey = "default/rsv-slow"
	gate.cohorts[slowKey] = &gangCohort{
		gangSize: 4,
		priority: 500,
		members: map[string]gangMember{
			"u-slow-0": {sliceUID: "u-slow-0", nodeName: "node-a", bytes: 10},
		},
		// Old enough to hold age seniority, but inside the gateMaxHoldAge (90s)
		// window — the stale-cohort reaper runs before the stall branch and
		// would otherwise reap the cohort before demotion is exercised.
		createdAt: testStart.Add(-60 * time.Second),
	}
	gate.admitting = slowKey
	gate.admittingSince = testStart.Add(-gangAdmissionTimeout - 5*time.Second)

	res, _, err := gate.CheckSliceWithCohort(ctx, gangSlice("live-0", "rsv-live", 500, "u-live-0"), "node-a", 10)
	if err != nil {
		t.Fatalf("live-0 check: %v", err)
	}
	if res != GangBindDeferred {
		t.Fatalf("live-0: got %v, want Deferred (slot freed by the stall)", res)
	}

	slow, ok := gate.cohorts[slowKey]
	if !ok {
		t.Fatalf("real staller (has members) must be kept + backed off, not forgotten")
	}
	if _, backed := gate.backoff[slowKey]; !backed {
		t.Fatalf("real staller must be in backoff")
	}
	if slow.createdAt.Before(testStart) {
		t.Fatalf("staller kept its age seniority (createdAt=%v) — it would out-rank every younger gang after backoff", slow.createdAt)
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
