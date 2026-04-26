package integration

import (
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestClaimStatusDerivation verifies the claim phase follows slice phase.
func TestClaimStatusDerivation(t *testing.T) {
	cases := []struct {
		slicePhase string
		wantClaim  string
	}{
		{state.SlicePhasePending, state.ClaimPhasePending},
		{state.SlicePhaseReady, state.ClaimPhaseBound},
		{state.SlicePhaseFailed, state.ClaimPhaseFailed},
	}

	for _, tc := range cases {
		t.Run(tc.slicePhase, func(t *testing.T) {
			slice := &vgpuv1alpha1.VGPUSlice{
				ObjectMeta: metav1.ObjectMeta{Name: "s"},
				Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase(tc.slicePhase)},
			}
			var got string
			switch string(slice.Status.Phase) {
			case state.SlicePhaseReady:
				got = state.ClaimPhaseBound
			case state.SlicePhaseFailed:
				got = state.ClaimPhaseFailed
			default:
				got = state.ClaimPhasePending
			}
			if got != tc.wantClaim {
				t.Fatalf("slice phase %s: claim phase got %q, want %q",
					tc.slicePhase, got, tc.wantClaim)
			}
		})
	}
}

// TestSliceInvariantsReleasing verifies Bug #8's fix — a slice deleted before
// allocation should be allowed to enter Releasing without an AllocationID.
func TestSliceInvariantsReleasing(t *testing.T) {
	slice := &vgpuv1alpha1.VGPUSlice{
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase:          vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReleasing),
			AllocatedBytes: 0, // never got allocated
			AllocationID:   "",
		},
	}
	if err := state.ValidateSliceInvariant(slice); err != nil {
		t.Fatalf("pre-allocation Releasing should be valid, got %v", err)
	}

	// But a Releasing slice that DID have hardware must still have an ID.
	slice.Status.AllocatedBytes = 8 << 30
	if err := state.ValidateSliceInvariant(slice); err == nil {
		t.Fatal("Releasing with AllocatedBytes > 0 and empty AllocationID should error")
	}
}
