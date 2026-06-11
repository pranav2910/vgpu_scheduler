package scheduler

// Batch A regression tests — gang gate fails closed, reservation pin +
// confirm re-arm, quota in-flight ledger. Each test names the production
// failure it locks out.

import (
	"context"
	"fmt"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// ── Fix: reservation pin + confirm re-arm ────────────────────────────────────

func TestPinAssumptionAtomicLifecycle(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("n1", 80*testGiB, 0)

	// Pin on a hold that doesn't exist: refused — the caller must not bind.
	if _, _, ok := c.PinAssumption("uid-pin", time.Minute); ok {
		t.Fatalf("pin succeeded for a hold that does not exist")
	}

	// Assume with an already-expired TTL, then pin BEFORE the reaper runs: the
	// pin must extend the hold so a reaper tick mid-bind cannot kill it.
	if err := c.AssumeSlice("uid-pin", "default", "n1", 8*testGiB, -time.Second); err != nil {
		t.Fatalf("assume: %v", err)
	}
	node, bytes, ok := c.PinAssumption("uid-pin", time.Hour)
	if !ok || node != "n1" || bytes != 8*testGiB {
		t.Fatalf("pin: got (%s,%d,%v), want (n1,%d,true)", node, bytes, ok, 8*testGiB)
	}
	c.reapExpiredAssumptions()
	if _, _, held := c.IsAssumed("uid-pin"); !held {
		t.Fatalf("reaper killed a pinned hold — pin did not extend the TTL")
	}

	// Reaped without a pin: pin must refuse afterwards (the old two-call
	// IsAssumed+Refresh shape proceeded to bind in exactly this state).
	if err := c.AssumeSlice("uid-gone", "default", "n1", 8*testGiB, -time.Second); err != nil {
		t.Fatalf("assume: %v", err)
	}
	c.reapExpiredAssumptions()
	if _, _, ok := c.PinAssumption("uid-gone", time.Minute); ok {
		t.Fatalf("pin succeeded on a reaped hold — caller would bind with no reservation")
	}
}

func TestConfirmSliceOrRearm(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("n1", 80*testGiB, 0)

	// Normal path: assumed → confirmed, no re-arm, accounting unchanged.
	if err := c.AssumeSlice("uid-ok", "default", "n1", 8*testGiB, time.Minute); err != nil {
		t.Fatalf("assume: %v", err)
	}
	if rearmed := c.ConfirmSliceOrRearm("uid-ok", "default", "n1", 8*testGiB); rearmed {
		t.Fatalf("normal confirm reported a re-arm")
	}
	if got := c.SnapshotNode("n1").ReservedVRAMBytes; got != 8*testGiB {
		t.Fatalf("reserved after confirm = %d, want %d", got, 8*testGiB)
	}

	// Reaped-mid-bind path: the hold expired and the reaper rolled it back
	// while the bind API call was in flight. The bind DID happen, so Confirm
	// must re-charge the node — otherwise the bound slice holds zero cache
	// footprint until Ready and the capacity gets re-sold.
	if err := c.AssumeSlice("uid-slow", "default", "n1", 16*testGiB, -time.Second); err != nil {
		t.Fatalf("assume: %v", err)
	}
	c.reapExpiredAssumptions()
	before := c.SnapshotNode("n1").ReservedVRAMBytes
	if rearmed := c.ConfirmSliceOrRearm("uid-slow", "default", "n1", 16*testGiB); !rearmed {
		t.Fatalf("expected re-arm for a reaped hold")
	}
	if got := c.SnapshotNode("n1").ReservedVRAMBytes; got != before+16*testGiB {
		t.Fatalf("re-arm did not re-charge: reserved %d → %d, want +%d", before, got, 16*testGiB)
	}
	// A re-armed entry releases cleanly through the normal confirmed path.
	c.ReleaseConfirmedSlice("uid-slow")
	if got := c.SnapshotNode("n1").ReservedVRAMBytes; got != before {
		t.Fatalf("release after re-arm: reserved = %d, want %d", got, before)
	}
}

// ── Fix: quota in-flight ledger ──────────────────────────────────────────────

func TestPendingNamespaceBytes(t *testing.T) {
	c := NewVRAMCache()
	c.UpdateNode("n1", 80*testGiB, 0)

	mustAssume := func(uid, ns string, bytes int64) {
		t.Helper()
		if err := c.AssumeSlice(uid, ns, "n1", bytes, time.Minute); err != nil {
			t.Fatalf("assume %s: %v", uid, err)
		}
	}
	mustAssume("uid-a1", "team-a", 8*testGiB)
	mustAssume("uid-a2", "team-a", 4*testGiB)
	mustAssume("uid-b1", "team-b", 2*testGiB)
	// Confirmed holds (bound, not yet observed by the informer) count too.
	c.ConfirmSliceOrRearm("uid-a1", "team-a", "n1", 8*testGiB)

	if got := c.PendingNamespaceBytes("team-a", nil); got != 12*testGiB {
		t.Fatalf("team-a pending = %d, want %d", got, 12*testGiB)
	}
	// A UID the API list already counted is excluded (no double count).
	counted := map[string]struct{}{"uid-a1": {}}
	if got := c.PendingNamespaceBytes("team-a", counted); got != 4*testGiB {
		t.Fatalf("team-a pending excluding counted = %d, want %d", got, 4*testGiB)
	}
	if got := c.PendingNamespaceBytes("team-b", nil); got != 2*testGiB {
		t.Fatalf("team-b pending = %d, want %d", got, 2*testGiB)
	}
}

func TestQuota_InFlightLedgerClosesInformerWindow(t *testing.T) {
	// The informer shows NOTHING in the namespace — exactly as it would
	// milliseconds after this scheduler bound a slice — but the scheduler's own
	// cache holds a 25 GiB confirmed admission. 25 in-flight + 25 demand > 40
	// quota must reject; the informer-only check admitted it.
	cache := NewVRAMCache()
	cache.UpdateNode("n1", 80*qGiB, 0)
	if err := cache.AssumeSlice("uid-inflight", "default", "n1", 25*qGiB, time.Minute); err != nil {
		t.Fatalf("assume: %v", err)
	}
	cache.ConfirmSliceOrRearm("uid-inflight", "default", "n1", 25*qGiB)

	b := fake.NewClientBuilder().WithScheme(gangTestScheme(t)).WithObjects(quotaObj("default", 40*qGiB))
	qc := NewQuotaChecker(b.Build(), cache)

	if ok, reason, _ := qc.Check(context.Background(), "default", 25*qGiB, "", 0); ok {
		t.Fatalf("expected reject: 25 GiB in-flight + 25 GiB demand > 40 GiB quota (informer-staleness window)")
	} else if reason != "QuotaExceeded" {
		t.Fatalf("reason: got %q want QuotaExceeded", reason)
	}
	// 15 GiB still fits: 25 + 15 == 40.
	if ok, _, msg := qc.Check(context.Background(), "default", 15*qGiB, "", 0); !ok {
		t.Fatalf("expected allow at 25 + 15 == 40: %s", msg)
	}
}

func TestQuota_LedgerAndInformerNeverDoubleCount(t *testing.T) {
	// The same admission visible BOTH ways — the informer shows the bound slice
	// AND the ledger still holds its confirmed entry (Ready not yet reported) —
	// must count once: 25 + 15 == 40 → allowed.
	cache := NewVRAMCache()
	cache.UpdateNode("n1", 80*qGiB, 0)
	if err := cache.AssumeSlice("uid-both", "default", "n1", 25*qGiB, time.Minute); err != nil {
		t.Fatalf("assume: %v", err)
	}
	cache.ConfirmSliceOrRearm("uid-both", "default", "n1", 25*qGiB)

	bound := qSlice("bound", "", 25*qGiB, 0, "n1", "Scheduled")
	bound.UID = types.UID("uid-both") // informer sees the same UID the ledger holds
	b := fake.NewClientBuilder().WithScheme(gangTestScheme(t)).WithObjects(quotaObj("default", 40*qGiB), bound)
	qc := NewQuotaChecker(b.Build(), cache)

	if ok, _, msg := qc.Check(context.Background(), "default", 15*qGiB, "", 0); !ok {
		t.Fatalf("double-counted the same admission via informer AND ledger: %s", msg)
	}
	if ok, _, _ := qc.Check(context.Background(), "default", 16*qGiB, "", 0); ok {
		t.Fatalf("expected reject at 25 + 16 > 40")
	}
}

func TestQuota_CheckedGangHoldsExcludedFromLedger(t *testing.T) {
	// A converging member of the CHECKED gang holds an unbound reservation in
	// the ledger. gangTotal already covers the whole gang, so that hold must
	// not also count — else a fitting gang is spuriously rejected. An UNRELATED
	// hold in the same namespace must still count.
	cache := NewVRAMCache()
	cache.UpdateNode("n1", 80*qGiB, 0)
	if err := cache.AssumeSlice("uid-g1", "default", "n1", 20*qGiB, time.Minute); err != nil {
		t.Fatalf("assume: %v", err)
	}

	member := qSlice("g-member", "gang-x", 20*qGiB, 0, "", "Pending") // unbound, converging
	member.UID = types.UID("uid-g1")
	b := fake.NewClientBuilder().WithScheme(gangTestScheme(t)).WithObjects(quotaObj("default", 40*qGiB), member)
	qc := NewQuotaChecker(b.Build(), cache)

	// Whole gang = 40 GiB demand against a 40 GiB quota: fits exactly — unless
	// the member's own 20 GiB hold leaks in via the ledger.
	if ok, _, msg := qc.Check(context.Background(), "default", 20*qGiB, "gang-x", 40*qGiB); !ok {
		t.Fatalf("checked gang's own hold double-counted via the ledger: %s", msg)
	}
	// An unrelated solo hold appears → 10 + 40 > 40 → reject.
	if err := cache.AssumeSlice("uid-other", "default", "n1", 10*qGiB, time.Minute); err != nil {
		t.Fatalf("assume: %v", err)
	}
	if ok, _, _ := qc.Check(context.Background(), "default", 20*qGiB, "gang-x", 40*qGiB); ok {
		t.Fatalf("expected reject: unrelated 10 GiB hold + 40 GiB gang demand > 40 GiB quota")
	}
}

// ── Fix: gang gate fails closed ──────────────────────────────────────────────

// errGetClient fails every Get — a transient API/informer failure at the worst
// possible moment.
type errGetClient struct {
	client.Client
}

func (e *errGetClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	return fmt.Errorf("injected transient error")
}

func TestGangGate_TransientErrorFailsClosed(t *testing.T) {
	base := fake.NewClientBuilder().WithScheme(gangTestScheme(t)).Build()
	gate := NewGangBindingGate(&errGetClient{base})

	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name: "gm", Namespace: "default", UID: types.UID("uid-gm"),
			Annotations: map[string]string{vgpuv1alpha1.AnnotationReservationRef: "rsv-x"},
		},
	}
	res, _, err := gate.CheckSliceWithCohort(context.Background(), slice, "n1", qGiB)
	if res != GangRetry {
		t.Fatalf("transient reservation read error: got result %v, want GangRetry (fail closed) — anything else lets a gang member bind solo", res)
	}
	if err == nil {
		t.Fatalf("expected the transient error to surface alongside GangRetry")
	}
}

func TestGangGate_ReservationNotYetVisibleRetriesInsteadOfRejecting(t *testing.T) {
	// At gang creation the slice events and the reservation object arrive on
	// different watch streams: a member can reach the gate before the informer
	// has EVER seen the reservation. That NotFound used to map to
	// GangBindRejected ("gang torn down") — a being-born gang misread as dead,
	// burning the member's early attempts (seen live in the 2.3 crash battery).
	// It must map to GangRetry (fast requeue, no error) instead.
	base := fake.NewClientBuilder().WithScheme(gangTestScheme(t)).Build() // no reservation object
	gate := NewGangBindingGate(base)

	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name: "born-0", Namespace: "default", UID: types.UID("uid-born"),
			Annotations: map[string]string{vgpuv1alpha1.AnnotationReservationRef: "rsv-being-born"},
		},
	}
	res, reason, err := gate.CheckSliceWithCohort(context.Background(), slice, "n1", qGiB)
	if res != GangRetry {
		t.Fatalf("reservation not yet visible: got %v (%s), want GangRetry — Rejected misreads a being-born gang as torn down", res, reason)
	}
	if err != nil {
		t.Fatalf("NotFound is knowably transient and must not surface as an error (that would route to slow backoff): %v", err)
	}
}

func TestScheduleFailsClosedWhenGateCannotReadSlice(t *testing.T) {
	// End-to-end: the gate cannot read the slice (transient error), so
	// Schedule must abort WITHOUT binding and roll the speculative hold back.
	// The old shape skipped the whole gate block on a read error and bound.
	cache := NewVRAMCache()
	cache.UpdateNode("n1", 80*qGiB, 0)
	cache.MarkSeeded()

	base := fake.NewClientBuilder().WithScheme(gangTestScheme(t)).Build()
	s := NewSliceScheduler(cache, &errGetClient{base})
	s.GangGate = NewGangBindingGate(&errGetClient{base})

	_, err := s.Schedule(context.Background(),
		types.NamespacedName{Namespace: "default", Name: "s1"}, "uid-fc", 8*qGiB, false)
	if err == nil {
		t.Fatalf("expected a fail-closed error when the gate cannot read the slice")
	}
	if _, _, held := cache.IsAssumed("uid-fc"); held {
		t.Fatalf("speculative hold leaked after the fail-closed abort")
	}
	if got := cache.SnapshotNode("n1").ReservedVRAMBytes; got != 0 {
		t.Fatalf("reserved bytes leaked after fail-closed abort: %d", got)
	}
}
