package state

import (
	"fmt"
	"log"
	"strings"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// legalSliceTransitions is the absolute DAG for the system.
var legalSliceTransitions = map[string]map[string]bool{
	"":                   {SlicePhasePending: true, SlicePhaseReleasing: true},
	SlicePhasePending:    {SlicePhaseScheduled: true, SlicePhaseReleasing: true, SlicePhaseFailed: true},
	SlicePhaseScheduled:  {SlicePhaseAllocating: true, SlicePhaseFailed: true, SlicePhaseReleasing: true},
	SlicePhaseAllocating: {SlicePhaseReady: true, SlicePhaseFailed: true, SlicePhaseReleasing: true},
	SlicePhaseReady:      {SlicePhaseReleasing: true, SlicePhaseReleased: true, SlicePhaseFailed: true},
	SlicePhaseReleasing:  {SlicePhaseReleased: true, SlicePhaseFailed: true},
	SlicePhaseReleased:   {},                          // Terminal state
	SlicePhaseFailed:     {SlicePhaseReleasing: true}, // Failed is terminal-except-release; retry requires a backoff counter in spec (not implemented yet)
}

// TransitionSlicePhase strictly enforces the DAG. Controllers MUST use this.
func TransitionSlicePhase(slice *vgpuv1alpha1.VGPUSlice, nextPhase, reason, message string) error {
	currentPhase := string(slice.Status.Phase) // convert typed string → string for map lookup

	if currentPhase == nextPhase {
		return nil // Idempotent
	}

	allowed, exists := legalSliceTransitions[currentPhase]
	if !exists || !allowed[nextPhase] {
		return fmt.Errorf("FATAL STATE VIOLATION: Cannot transition Slice from '%s' to '%s'", currentPhase, nextPhase)
	}

	// Bug #49: sanitize user-controllable fields to prevent log injection.
	log.Printf("State Transition: %s [%s -> %s] Reason: %s",
		sanitizeForLog(slice.Name), currentPhase, nextPhase, sanitizeForLog(reason))

	slice.Status.Phase = vgpuv1alpha1.VGPUSlicePhase(nextPhase) // convert back to typed string
	if reason != "" {
		slice.Status.FailureReason = reason
	}
	if message != "" {
		slice.Status.LastError = message
	}

	return nil
}

// MarkSliceReady requires AllocationID as a first-class citizen.
func MarkSliceReady(slice *vgpuv1alpha1.VGPUSlice, allocID, devUUID string, bytes int64) error {
	if allocID == "" {
		return fmt.Errorf("FATAL STATE VIOLATION: Cannot mark Ready without a durable AllocationID")
	}

	if err := TransitionSlicePhase(slice, SlicePhaseReady, "", ""); err != nil {
		return err
	}

	slice.Status.AllocationID = allocID
	slice.Status.DeviceUUID = devUUID
	slice.Status.AllocatedBytes = bytes
	return nil
}

// sanitizeForLog strips newlines and control chars so attacker-influenced
// strings (slice names, failure reasons) can't inject fake log lines.
func sanitizeForLog(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return '_'
		}
		return r
	}, s)
}
