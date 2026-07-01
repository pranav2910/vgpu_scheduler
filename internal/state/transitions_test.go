package state

// Regression coverage for the slice-phase DAG, with emphasis on the rule the
// multi-node soak exposed: teardown (→ Releasing) must be legal from EVERY
// pre-Ready state, including the empty initial phase and Pending — a slice can
// be deleted at any instant (node loss, fast churn, namespace teardown).

import (
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func sliceAt(phase string) *vgpuv1alpha1.VGPUSlice {
	return &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "s", Namespace: "default"},
		Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase(phase)},
	}
}

// THE FIX: deleting a slice before it ever left "" (or Pending) must be able to
// start teardown. Before this, the soak logged "Cannot transition from ” to
// 'Releasing'" under churn / node loss.
func TestReleasingLegalFromEveryPreReadyState(t *testing.T) {
	for _, from := range []string{"", SlicePhasePending, SlicePhaseScheduled, SlicePhaseAllocating, SlicePhaseReady, SlicePhaseFailed} {
		s := sliceAt(from)
		if err := TransitionSlicePhase(s, SlicePhaseReleasing, "Deleting", "teardown"); err != nil {
			t.Errorf("Releasing must be legal from %q: %v", from, err)
		}
	}
}

// And the full teardown chain from the empty phase completes to Released.
func TestEmptyPhaseTearsDownToReleased(t *testing.T) {
	s := sliceAt("")
	if err := TransitionSlicePhase(s, SlicePhaseReleasing, "Deleting", ""); err != nil {
		t.Fatalf("'' -> Releasing: %v", err)
	}
	if err := TransitionSlicePhase(s, SlicePhaseReleased, "CleanupComplete", ""); err != nil {
		t.Fatalf("Releasing -> Released: %v", err)
	}
	if string(s.Status.Phase) != SlicePhaseReleased {
		t.Fatalf("phase = %s, want Released", s.Status.Phase)
	}
}

// Guard: the DAG didn't go loose. Illegal jumps still rejected, and Released
// stays terminal.
func TestIllegalTransitionsStillRejected(t *testing.T) {
	bad := []struct{ from, to string }{
		{"", SlicePhaseReady}, // can't allocate from nothing
		{SlicePhasePending, SlicePhaseReady},
		{SlicePhaseReleased, SlicePhaseReleasing}, // terminal
		{SlicePhaseReleased, SlicePhasePending},
		{SlicePhaseReady, SlicePhaseAllocating}, // no going backwards
	}
	for _, c := range bad {
		if err := TransitionSlicePhase(sliceAt(c.from), c.to, "x", "y"); err == nil {
			t.Errorf("expected %q -> %q to be rejected, but it was allowed", c.from, c.to)
		}
	}
}
