package drift

import (
	"context"
	"errors"
	"fmt"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Detector struct {
	store     *checkpoint.Store
	allocator *nvml.Allocator
	k8sClient client.Client
}

func NewDetector(store *checkpoint.Store, allocator *nvml.Allocator, k8sClient client.Client) *Detector {
	return &Detector{store: store, allocator: allocator, k8sClient: k8sClient}
}

func (d *Detector) DetectAndHeal(ctx context.Context) error {
	diskRecords, err := d.store.LoadAll()
	if err != nil {
		return fmt.Errorf("loading checkpoint: %w", err)
	}

	hardwareAllocations := d.allocator.InspectAllHardware()

	// Bug #13 fix: accumulate errors rather than dropping them.
	var errs []error

	for allocID, record := range diskRecords {
		if hardwareAllocations[allocID] {
			delete(hardwareAllocations, allocID)
			continue
		}

		telemetry.RecordDrift()
		log.Printf("Recovery [Case 2]: Allocation %s missing from hardware", allocID)

		if d.k8sClient == nil {
			log.Printf("  -> No K8s client configured; pruning orphan checkpoint %s", allocID)
			if err := d.store.Delete(allocID); err != nil {
				errs = append(errs, fmt.Errorf("pruning orphan checkpoint %s: %w", allocID, err))
			}
			continue
		}

		var slice vgpuv1alpha1.VGPUSlice
		key := client.ObjectKey{Namespace: record.Namespace, Name: record.SliceName}
		if err := d.k8sClient.Get(ctx, key, &slice); err != nil {
			log.Printf("  -> Slice not in K8s API (%v). Pruning dead checkpoint %s", err, allocID)
			if err := d.store.Delete(allocID); err != nil {
				errs = append(errs, fmt.Errorf("pruning dead checkpoint %s: %w", allocID, err))
			}
			continue
		}

		if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReady) {
			log.Printf("  -> API expects Ready. Signalling Failed.")
			if err := state.TransitionSlicePhase(&slice, state.SlicePhaseFailed,
				state.ReasonDriftDetected, "Device missing from PCIe bus on node boot"); err != nil {
				errs = append(errs, fmt.Errorf("state transition for %s: %w", allocID, err))
			} else if err := d.k8sClient.Status().Update(ctx, &slice); err != nil {
				errs = append(errs, fmt.Errorf("updating slice %s status: %w", allocID, err))
			}
			if err := d.store.Delete(allocID); err != nil {
				errs = append(errs, fmt.Errorf("pruning checkpoint %s after drift: %w", allocID, err))
			}
		}
	}

	for orphanAllocID := range hardwareAllocations {
		telemetry.RecordDrift()
		log.Printf("Recovery [Case 3]: Orphaned hardware allocation %s — releasing.", orphanAllocID)
		if err := d.allocator.Release(ctx, orphanAllocID); err != nil {
			errs = append(errs, fmt.Errorf("releasing orphan allocation %s: %w", orphanAllocID, err))
		}
	}

	return errors.Join(errs...)
}
