package nodeagent

// Lifecycle regression tests for the conflict-wedge bug cluster found by the
// 32-slice burst on the 8×V100 box: a status-write conflict used to wedge a
// slice in Allocating forever (dead zone), its committed ledger allocation
// leaked permanently when the wedged slice was deleted, and deleting a Ready
// slice error-stormed on the illegal Ready→Released transition.

import (
	"context"
	"strings"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/cdi"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const mGiB = int64(1) << 30

func managerScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("AddToScheme: %v", err)
	}
	return s
}

// flakyStatusClient fails the Nth status Update with a CONFLICT — the exact
// failure a 32-slice burst produces when the controller/scheduler touch the
// slice between the agent's read and its status write.
type flakyStatusClient struct {
	client.Client
	updateCalls int
	failOnCall  int
}

func (f *flakyStatusClient) Status() client.SubResourceWriter {
	return &flakySW{inner: f.Client.Status(), p: f}
}

type flakySW struct {
	inner client.SubResourceWriter
	p     *flakyStatusClient
}

func (s *flakySW) Update(ctx context.Context, obj client.Object, opts ...client.SubResourceUpdateOption) error {
	s.p.updateCalls++
	if s.p.updateCalls == s.p.failOnCall {
		return apierrors.NewConflict(
			schema.GroupResource{Group: "infrastructure.pranav2910.com", Resource: "vgpuslices"},
			obj.GetName(), nil)
	}
	return s.inner.Update(ctx, obj, opts...)
}

func (s *flakySW) Create(ctx context.Context, obj client.Object, sub client.Object, opts ...client.SubResourceCreateOption) error {
	return s.inner.Create(ctx, obj, sub, opts...)
}

func (s *flakySW) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.SubResourcePatchOption) error {
	return s.inner.Patch(ctx, obj, patch, opts...)
}

func newTestManager(t *testing.T, cl client.Client) *Manager {
	t.Helper()
	t.Setenv("VGPU_FAKE_GPU_COUNT", "1")
	t.Setenv("VGPU_FAKE_GPU_MEM_BYTES", "85899345920")
	cdi.SetDirectoryForTesting(t.TempDir())
	return &Manager{
		NodeName:  "n1",
		Allocator: nvml.NewAllocator(true),
		Store:     checkpoint.NewStoreAt(t.TempDir()),
		Reporter:  NewReporter(cl),
	}
}

func schedSlice(name, uid string, phase string) *vgpuv1alpha1.VGPUSlice {
	return &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default", UID: types.UID(uid)},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{NodeName: "n1", RequestedVRAMBytes: 16 * mGiB},
		Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase(phase)},
	}
}

// THE WEDGE: the Ready status write conflicts; the retry must re-drive from
// Allocating (not dead-zone), reuse the SAME allocation (no ledger
// double-commit), and finish Ready.
func TestReconcile_ConflictWedgeRedrives(t *testing.T) {
	s := managerScheme(t)
	sl := schedSlice("w1", "uid-w1", "Scheduled")
	base := fake.NewClientBuilder().WithScheme(s).
		WithStatusSubresource(&vgpuv1alpha1.VGPUSlice{}).
		WithObjects(sl).Build()
	// Update #1 = Allocating (succeeds), #2 = Ready (CONFLICT).
	cl := &flakyStatusClient{Client: base, failOnCall: 2}
	m := newTestManager(t, cl)

	// Attempt 1: errors on the Ready write — the slice persists as Allocating.
	var got vgpuv1alpha1.VGPUSlice
	if err := base.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: "w1"}, &got); err != nil {
		t.Fatal(err)
	}
	if err := m.ReconcileSlice(context.Background(), got.DeepCopy()); err == nil {
		t.Fatalf("first reconcile must surface the conflict error (so the controller retries)")
	}
	if err := base.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: "w1"}, &got); err != nil {
		t.Fatal(err)
	}
	if string(got.Status.Phase) != "Allocating" {
		t.Fatalf("after failed Ready write, persisted phase = %s, want Allocating (the wedge state)", got.Status.Phase)
	}

	// Attempt 2 (the retry): used to dead-zone here. Must re-drive to Ready.
	if err := m.ReconcileSlice(context.Background(), got.DeepCopy()); err != nil {
		t.Fatalf("re-drive from Allocating: %v", err)
	}
	if err := base.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: "w1"}, &got); err != nil {
		t.Fatal(err)
	}
	if string(got.Status.Phase) != "Ready" || got.Status.AllocationID == "" {
		t.Fatalf("after re-drive: phase=%s alloc=%q, want Ready with an allocation", got.Status.Phase, got.Status.AllocationID)
	}
	// Idempotency: exactly ONE ledger commit and ONE checkpoint record.
	if c := m.Allocator.CommittedBytes("GPU-FAKE-00000000"); c != 16*mGiB {
		t.Fatalf("ledger = %d, want %d (re-drive must not double-commit)", c, 16*mGiB)
	}
	if recs, _ := m.Store.LoadAll(); len(recs) != 1 {
		t.Fatalf("checkpoint records = %d, want 1", len(recs))
	}
}

// THE LEAK: a wedged slice (committed allocation, EMPTY status.AllocationID)
// gets deleted. Release must recover the ledger entry via the slice UID — and
// clean the orphan checkpoint — instead of leaking both forever.
func TestReconcile_WedgedDeletionFreesLedger(t *testing.T) {
	s := managerScheme(t)
	sl := schedSlice("w2", "uid-w2", "Allocating")
	sl.Finalizers = []string{"test.pranav2910.com/hold"}
	base := fake.NewClientBuilder().WithScheme(s).
		WithStatusSubresource(&vgpuv1alpha1.VGPUSlice{}).
		WithObjects(sl).Build()
	m := newTestManager(t, base)

	// Simulate the wedge's first half out-of-band: allocation committed +
	// checkpointed, but never written to status.
	res, err := m.Allocator.Allocate(context.Background(), nvml.AllocationRequest{
		SliceUID: "uid-w2", RequestedVRAMBytes: 16 * mGiB,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Store.Save(checkpoint.CheckpointRecord{
		AllocationID: res.AllocationID, SliceUID: "uid-w2", SliceName: "w2",
		Namespace: "default", DeviceUUID: res.DeviceUUID, AllocatedBytes: res.AllocatedBytes, NodeName: "n1",
	}); err != nil {
		t.Fatal(err)
	}

	// Delete (finalizer keeps the object, DeletionTimestamp set) → reconcile.
	if err := base.Delete(context.Background(), sl); err != nil {
		t.Fatal(err)
	}
	var dying vgpuv1alpha1.VGPUSlice
	if err := base.Get(context.Background(), types.NamespacedName{Namespace: "default", Name: "w2"}, &dying); err != nil {
		t.Fatal(err)
	}
	if dying.DeletionTimestamp.IsZero() {
		t.Fatalf("setup: expected DeletionTimestamp on the finalized slice")
	}
	if err := m.ReconcileSlice(context.Background(), dying.DeepCopy()); err != nil {
		t.Fatalf("release reconcile: %v", err)
	}

	if c := m.Allocator.CommittedBytes(res.DeviceUUID); c != 0 {
		t.Fatalf("ledger after wedged deletion = %d, want 0 (this leak starved later allocations into fragmentation)", c)
	}
	if recs, _ := m.Store.LoadAll(); len(recs) != 0 {
		t.Fatalf("checkpoint records after wedged deletion = %d, want 0", len(recs))
	}
}

// THE STORM: deleting a slice that is Ready (or Scheduled/Allocating/Failed)
// must release cleanly through Releasing→Released — not error on the illegal
// direct jump (which used to error-loop every namespace teardown).
func TestReportReleaseComplete_LegalFromEveryLifecyclePhase(t *testing.T) {
	r := NewReporter(nil) // nil client = state-machine-only mode
	for _, from := range []string{"Ready", "Scheduled", "Allocating", "Failed", "Releasing"} {
		sl := schedSlice("w3", "uid-w3", from)
		if err := r.ReportReleaseComplete(context.Background(), sl); err != nil {
			t.Fatalf("release from %s: %v", from, err)
		}
		if string(sl.Status.Phase) != "Released" {
			t.Fatalf("release from %s: phase = %s, want Released", from, sl.Status.Phase)
		}
		if sl.Status.AllocationID != "" || sl.Status.DeviceUUID != "" || sl.Status.AllocatedBytes != 0 {
			t.Fatalf("release from %s: allocation fields not zeroed", from)
		}
	}

	// A LATE RETRY reading back an already-Released slice must no-op cleanly —
	// attempting Released→Releasing error-looped 496 times in one live
	// 32-slice teardown storm.
	done := schedSlice("w4", "uid-w4", "Released")
	if err := r.ReportReleaseComplete(context.Background(), done); err != nil {
		t.Fatalf("release of already-Released slice must be an idempotent no-op: %v", err)
	}
	if string(done.Status.Phase) != "Released" {
		t.Fatalf("already-Released slice mutated to %s", done.Status.Phase)
	}
}

// Allocator-level idempotency contract (the foundation the re-drive rests on).
func TestAllocateIdempotentPerSlice(t *testing.T) {
	t.Setenv("VGPU_FAKE_GPU_COUNT", "2")
	t.Setenv("VGPU_FAKE_GPU_MEM_BYTES", "85899345920")
	a := nvml.NewAllocator(true)

	r1, err := a.Allocate(context.Background(), nvml.AllocationRequest{SliceUID: "uid-i", RequestedVRAMBytes: 16 * mGiB})
	if err != nil {
		t.Fatal(err)
	}
	r2, err := a.Allocate(context.Background(), nvml.AllocationRequest{SliceUID: "uid-i", RequestedVRAMBytes: 16 * mGiB})
	if err != nil {
		t.Fatal(err)
	}
	if r1.AllocationID != r2.AllocationID || r1.DeviceUUID != r2.DeviceUUID {
		t.Fatalf("re-Allocate for the same slice returned a different allocation (%s/%s vs %s/%s)",
			r1.AllocationID, r1.DeviceUUID, r2.AllocationID, r2.DeviceUUID)
	}
	if c := a.CommittedBytes(r1.DeviceUUID); c != 16*mGiB {
		t.Fatalf("ledger = %d, want %d (single commit)", c, 16*mGiB)
	}

	// ReleaseBySlice frees it and reports the allocationID for cleanup.
	id, err := a.ReleaseBySlice(context.Background(), "uid-i")
	if err != nil || id != r1.AllocationID {
		t.Fatalf("ReleaseBySlice = (%q, %v), want (%q, nil)", id, err, r1.AllocationID)
	}
	if c := a.CommittedBytes(r1.DeviceUUID); c != 0 {
		t.Fatalf("ledger after ReleaseBySlice = %d, want 0", c)
	}
	if id2, _ := a.ReleaseBySlice(context.Background(), "uid-i"); id2 != "" {
		t.Fatalf("second ReleaseBySlice = %q, want \"\" (idempotent)", id2)
	}
	if !strings.HasPrefix(r1.AllocationID, "alloc-uid-i") {
		t.Fatalf("unexpected alloc id shape: %s", r1.AllocationID)
	}
}
