package nodeagent

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Reporter patches VGPUSlice status back to the Kubernetes API after each
// hardware event. Bug #1 fix: previously the Update calls were commented out
// and the entire lifecycle stalled at Scheduled.
type Reporter struct {
	client client.Client
}

func NewReporter(k8sClient client.Client) *Reporter {
	return &Reporter{client: k8sClient}
}

// TransitionToAllocating is called by the Manager before it begins NVML work,
// so the controller and operators can see that hardware allocation has started.
func (r *Reporter) TransitionToAllocating(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseAllocating, "", "NodeAgent beginning hardware allocation"); err != nil {
		return fmt.Errorf("state transition to Allocating: %w", err)
	}
	if r.client == nil {
		return nil // test mode
	}
	return r.client.Status().Update(ctx, slice)
}

func (r *Reporter) ReportAllocationReady(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice, result *nvml.AllocationResult) error {
	if err := state.MarkSliceReady(slice, result.AllocationID, result.DeviceUUID, result.AllocatedBytes); err != nil {
		return fmt.Errorf("marking slice Ready: %w", err)
	}
	if r.client == nil {
		return nil
	}
	return r.client.Status().Update(ctx, slice)
}

// ReportAllocationFailed fails the slice LOUD with the given reason — used
// when allocation is impossible (e.g. fragmentation: the node-pooled scheduler
// admitted a slice no single GPU can host). Failed is terminal for the slice;
// the claim/job mirror surfaces the reason to the user. Deliberately NOT a
// retry: silent retry loops are exactly what the fail-loud contract forbids.
func (r *Reporter) ReportAllocationFailed(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice, reason string) error {
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseFailed, "AllocationImpossible", reason); err != nil {
		return fmt.Errorf("state transition to Failed: %w", err)
	}
	if r.client == nil {
		return nil
	}
	return r.client.Status().Update(ctx, slice)
}

func (r *Reporter) ReportReleaseComplete(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {
	// Already Released → the work is done. A teardown storm has the agent's
	// retries racing the controller's own finishing writes; a late retry that
	// reads back a terminal slice must no-op, not attempt Released→Releasing
	// (an illegal transition that error-looped 496 times across one 32-slice
	// namespace deletion).
	if string(slice.Status.Phase) == state.SlicePhaseReleased {
		return nil
	}
	// A slice can arrive here straight from Ready/Scheduled/Allocating/Failed
	// (namespace teardown deletes it without anyone stamping Releasing first).
	// The DAG only permits Releasing → Released, so step through Releasing
	// in-memory and persist once — jumping directly used to error-storm every
	// teardown of a Ready slice ("FATAL STATE VIOLATION: Ready -> Released").
	if string(slice.Status.Phase) != state.SlicePhaseReleasing {
		if err := state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "CleanupStarted", "Hardware release in progress"); err != nil {
			return fmt.Errorf("state transition to Releasing: %w", err)
		}
	}
	if err := state.TransitionSlicePhase(slice, state.SlicePhaseReleased, "CleanupComplete", "Hardware freed"); err != nil {
		return fmt.Errorf("state transition to Released: %w", err)
	}
	// Invariant: Released slices must not retain any allocation info.
	slice.Status.DeviceUUID = ""
	slice.Status.AllocationID = ""
	slice.Status.AllocatedBytes = 0
	if r.client == nil {
		return nil
	}
	return r.client.Status().Update(ctx, slice)
}
