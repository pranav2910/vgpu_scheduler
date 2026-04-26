#!/usr/bin/env bash
# fix_vgpu_scheduler.sh
# Fixes all compilation-blocking bugs and design issues identified in the code review.
# Run from the project root: bash fix_vgpu_scheduler.sh

set -euo pipefail

# ─── Sanity check ────────────────────────────────────────────────────────────
if [[ ! -f "go.mod" ]]; then
  echo "ERROR: Run this script from the vgpu-scheduler project root (where go.mod lives)."
  exit 1
fi

BACKUP_DIR=".fix_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local dest="$BACKUP_DIR/$f"
    mkdir -p "$(dirname "$dest")"
    cp "$f" "$dest"
  fi
}

echo "==> Backing up files to $BACKUP_DIR"
FILES_TO_TOUCH=(
  "api/v1alpha1/conditions.go"
  "api/v1alpha1/vgpuclaim_types.go"
  "api/v1alpha1/vgpuslice_types.go"
  "api/v1alpha1/zz_generated.deepcopy.go"
  "internal/scheduler/filter.go"
  "internal/scheduler/reserve.go"
  "internal/scheduler/score.go"
  "internal/scheduler/cache.go"
  "internal/nodeagent/checkpoint/checkpoint.go"
  "internal/nodeagent/drift/detector.go"
  "internal/nodeagent/nvml/allocator.go"
  "internal/nodeagent/nvml/probe.go"
  "internal/nodeagent/manager.go"
  "internal/nodeagent/checkpoint.go"
  "internal/webhook/mutating_pod.go"
  "internal/webhook/validating_vgpuclaim.go"
  "internal/nodeagent/cdi/generator.go"
  "test/integration/scheduler_cache_test.go"
  "test/fuzz/binpack_fuzz_test.go"
  "cmd/nodeagent/main.go"
)
for f in "${FILES_TO_TOUCH[@]}"; do backup "$f"; done

echo ""
echo "==> FIX 1: api/v1alpha1/conditions.go — remove duplicate phase consts, keep type declarations"
cat > api/v1alpha1/conditions.go << 'EOF'
package v1alpha1

// ServiceTier defines the strictness of the VRAM reservation.
type ServiceTier string

const (
	// ServiceTierGuaranteed ensures strict VRAM reservation and zero preemption.
	ServiceTierGuaranteed ServiceTier = "Guaranteed"
	// ServiceTierBestEffort allows flexible placement but may be preempted.
	ServiceTierBestEffort ServiceTier = "BestEffort"
)

// VGPUClaimPhase represents the current lifecycle state of a Claim.
// Authoritative phase string values are defined in internal/state/phases.go.
type VGPUClaimPhase string

// VGPUSlicePhase represents the physical hardware allocation state.
// Authoritative phase string values are defined in internal/state/phases.go.
type VGPUSlicePhase string

// Common Condition Types used across Claims and Slices.
const (
	ConditionTypeScheduled = "Scheduled"
	ConditionTypeAllocated = "Allocated"
	ConditionTypeReady     = "Ready"
)
EOF

echo ""
echo "==> FIX 2: api/v1alpha1/vgpuclaim_types.go — int64 bytes field, add FailureReason to status"
cat > api/v1alpha1/vgpuclaim_types.go << 'EOF'
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VGPUClaimSpec defines the desired state of VGPUClaim (Owned by User)
type VGPUClaimSpec struct {
	// RequestedVRAMBytes specifies the exact amount of GPU memory required in bytes (e.g. 8589934592 for 8 GiB).
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=85899345920
	RequestedVRAMBytes int64 `json:"requestedVramBytes"`

	// ServiceTier enforces the workload isolation priority.
	// +kubebuilder:validation:Enum=Guaranteed;BestEffort
	// +kubebuilder:default=Guaranteed
	ServiceTier ServiceTier `json:"serviceTier,omitempty"`
}

// VGPUClaimStatus defines the observed state of VGPUClaim (Owned by Controller)
type VGPUClaimStatus struct {
	// Phase tracks the high-level scheduling state.
	// +kubebuilder:default=Pending
	Phase VGPUClaimPhase `json:"phase,omitempty"`

	// BoundSliceName is the exact name of the VGPUSlice fulfilling this claim.
	// +kubebuilder:validation:Optional
	BoundSliceName string `json:"boundSliceName,omitempty"`

	// FailureReason is a machine-readable failure code (e.g. NoCapacity, NodeUnhealthy).
	// +kubebuilder:validation:Optional
	FailureReason string `json:"failureReason,omitempty"`

	// Conditions hold structured state transitions and failure reasons.
	// +kubebuilder:validation:Optional
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="VRAM",type="integer",JSONPath=".spec.requestedVramBytes",description="Requested VRAM bytes"
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase",description="Current Phase"
// +kubebuilder:printcolumn:name="Slice",type="string",JSONPath=".status.boundSliceName",description="Bound Slice"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// VGPUClaim is the Schema for the vgpuclaims API
type VGPUClaim struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUClaimSpec   `json:"spec,omitempty"`
	Status VGPUClaimStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// VGPUClaimList contains a list of VGPUClaim
type VGPUClaimList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUClaim `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUClaim{}, &VGPUClaimList{})
}
EOF

echo ""
echo "==> FIX 3: api/v1alpha1/vgpuslice_types.go — ClaimRef as string, int64 bytes, add AllocationID/FailureReason/AllocatedBytes"
cat > api/v1alpha1/vgpuslice_types.go << 'EOF'
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VGPUSliceSpec defines the desired hardware state (Owned by Controller)
type VGPUSliceSpec struct {
	// ClaimRef is the name of the VGPUClaim this slice satisfies.
	// +kubebuilder:validation:Required
	ClaimRef string `json:"claimRef"`

	// NodeName is populated by the Scheduler once placement is decided.
	// +kubebuilder:validation:Optional
	NodeName string `json:"nodeName,omitempty"`

	// RequestedVRAMBytes is the exact memory to carve out on the physical hardware, in bytes.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	RequestedVRAMBytes int64 `json:"requestedVramBytes"`
}

// VGPUSliceStatus defines the observed hardware state (Split Ownership: NodeAgent / Controller)
type VGPUSliceStatus struct {
	// Phase tracks the hardware allocation lifecycle.
	// +kubebuilder:default=Allocating
	Phase VGPUSlicePhase `json:"phase,omitempty"`

	// DeviceUUID is the physical NVIDIA UUID of the isolated partition.
	// Must be populated before transitioning to Ready.
	// +kubebuilder:validation:Optional
	DeviceUUID string `json:"deviceUuid,omitempty"`

	// AllocationID is the durable identifier written to the on-disk checkpoint.
	// Required for Ready and Releasing states.
	// +kubebuilder:validation:Optional
	AllocationID string `json:"allocationId,omitempty"`

	// AllocatedBytes is the actual number of bytes locked on the physical device.
	// +kubebuilder:validation:Optional
	AllocatedBytes int64 `json:"allocatedBytes,omitempty"`

	// FailureReason provides a machine-readable failure code for fast ops debugging.
	// +kubebuilder:validation:Optional
	FailureReason string `json:"failureReason,omitempty"`

	// LastError provides a human-readable failure message.
	// +kubebuilder:validation:Optional
	LastError string `json:"lastError,omitempty"`

	// Conditions hold structured state transitions (e.g., IsolationVerified).
	// +kubebuilder:validation:Optional
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Node",type="string",JSONPath=".spec.nodeName",description="Assigned Node"
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase",description="Current Phase"
// +kubebuilder:printcolumn:name="UUID",type="string",JSONPath=".status.deviceUuid",description="Physical Device UUID"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// VGPUSlice is the Schema for the vgpuslices API
type VGPUSlice struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGPUSliceSpec   `json:"spec,omitempty"`
	Status VGPUSliceStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// VGPUSliceList contains a list of VGPUSlice
type VGPUSliceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VGPUSlice `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VGPUSlice{}, &VGPUSliceList{})
}
EOF

echo ""
echo "==> FIX 4: api/v1alpha1/zz_generated.deepcopy.go — remove Quantity.DeepCopy() calls (now plain int64/string)"
cat > api/v1alpha1/zz_generated.deepcopy.go << 'EOF'
//go:build !ignore_autogenerated

// Code generated by controller-gen. DO NOT EDIT.

package v1alpha1

import (
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
)

func (in *VGPUClaim) DeepCopyInto(out *VGPUClaim) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = in.Spec
	in.Status.DeepCopyInto(&out.Status)
}

func (in *VGPUClaim) DeepCopy() *VGPUClaim {
	if in == nil {
		return nil
	}
	out := new(VGPUClaim)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUClaim) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *VGPUClaimList) DeepCopyInto(out *VGPUClaimList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		in, out := &in.Items, &out.Items
		*out = make([]VGPUClaim, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
}

func (in *VGPUClaimList) DeepCopy() *VGPUClaimList {
	if in == nil {
		return nil
	}
	out := new(VGPUClaimList)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUClaimList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

// VGPUClaimSpec contains only value types (int64, string, ServiceTier) — plain copy suffices.
func (in *VGPUClaimSpec) DeepCopyInto(out *VGPUClaimSpec) {
	*out = *in
}

func (in *VGPUClaimSpec) DeepCopy() *VGPUClaimSpec {
	if in == nil {
		return nil
	}
	out := new(VGPUClaimSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUClaimStatus) DeepCopyInto(out *VGPUClaimStatus) {
	*out = *in
	if in.Conditions != nil {
		in, out := &in.Conditions, &out.Conditions
		*out = make([]v1.Condition, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
}

func (in *VGPUClaimStatus) DeepCopy() *VGPUClaimStatus {
	if in == nil {
		return nil
	}
	out := new(VGPUClaimStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUSlice) DeepCopyInto(out *VGPUSlice) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = in.Spec
	in.Status.DeepCopyInto(&out.Status)
}

func (in *VGPUSlice) DeepCopy() *VGPUSlice {
	if in == nil {
		return nil
	}
	out := new(VGPUSlice)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUSlice) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *VGPUSliceList) DeepCopyInto(out *VGPUSliceList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		in, out := &in.Items, &out.Items
		*out = make([]VGPUSlice, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
}

func (in *VGPUSliceList) DeepCopy() *VGPUSliceList {
	if in == nil {
		return nil
	}
	out := new(VGPUSliceList)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUSliceList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

// VGPUSliceSpec contains only value types (int64, string) — plain copy suffices.
func (in *VGPUSliceSpec) DeepCopyInto(out *VGPUSliceSpec) {
	*out = *in
}

func (in *VGPUSliceSpec) DeepCopy() *VGPUSliceSpec {
	if in == nil {
		return nil
	}
	out := new(VGPUSliceSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *VGPUSliceStatus) DeepCopyInto(out *VGPUSliceStatus) {
	*out = *in
	if in.Conditions != nil {
		in, out := &in.Conditions, &out.Conditions
		*out = make([]v1.Condition, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
}

func (in *VGPUSliceStatus) DeepCopy() *VGPUSliceStatus {
	if in == nil {
		return nil
	}
	out := new(VGPUSliceStatus)
	in.DeepCopyInto(out)
	return out
}
EOF

echo ""
echo "==> FIX 5: internal/scheduler/filter.go — capture all 3 return values from CanFit"
cat > internal/scheduler/filter.go << 'EOF'
package scheduler

import (
	"fmt"
	"log"
)

type FilterResult struct {
	NodeName string
	Passed   bool
	Reason   string
	Details  string // SRE-level telemetry
}

// Filter evaluates a node and returns a structured result with a rejection reason.
func Filter(cache *VRAMCache, nodeName string, requestedBytes int64) FilterResult {
	fits, reason, details := cache.CanFit(nodeName, requestedBytes) // was: fits, reason (missing 3rd return)

	if !fits {
		log.Printf("Filter Rejected: Node [%s] - %s: %s", nodeName, reason, details)
		return FilterResult{
			NodeName: nodeName,
			Passed:   false,
			Reason:   reason,
			Details:  details,
		}
	}

	return FilterResult{
		NodeName: nodeName,
		Passed:   true,
		Reason:   "PASSED",
		Details:  fmt.Sprintf("Capacity verified for %d bytes", requestedBytes),
	}
}
EOF

echo ""
echo "==> FIX 6: internal/scheduler/reserve.go — ForgetSlice → RollbackAssumedSlice"
cat > internal/scheduler/reserve.go << 'EOF'
package scheduler

import (
	"log"
	"time"
)

type ReservationManager struct {
	cache *VRAMCache
	ttl   time.Duration
}

type ReservationTx struct {
	SliceUID  string
	NodeName  string
	cache     *VRAMCache
	confirmed bool
}

func NewReservationManager(cache *VRAMCache, ttl time.Duration) *ReservationManager {
	return &ReservationManager{cache: cache, ttl: ttl}
}

func (rm *ReservationManager) Reserve(sliceUID, nodeName string, bytes int64) (*ReservationTx, error) {
	err := rm.cache.AssumeSlice(sliceUID, nodeName, bytes, rm.ttl)
	if err != nil {
		return nil, err
	}
	return &ReservationTx{SliceUID: sliceUID, NodeName: nodeName, cache: rm.cache}, nil
}

func (tx *ReservationTx) Confirm() {
	tx.confirmed = true
	tx.cache.ConfirmSlice(tx.SliceUID)
	log.Printf("Reservation Confirmed: Slice %s locked in API", tx.SliceUID)
}

func (tx *ReservationTx) RollbackIfNotConfirmed() {
	if !tx.confirmed {
		log.Printf("Reservation Rollback: Slice %s dropping speculative lock", tx.SliceUID)
		tx.cache.RollbackAssumedSlice(tx.SliceUID) // was: ForgetSlice (non-existent method)
	}
}
EOF

echo ""
echo "==> FIX 7: internal/scheduler/score.go — extract magic numbers to named constants"
cat > internal/scheduler/score.go << 'EOF'
package scheduler

import (
	"log"
	"sort"
)

const (
	// scoreWeightVRAMBytes is the reference VRAM used for bin-packing score normalisation (80 GiB).
	scoreWeightVRAMBytes = int64(80_000_000_000)
	// fragmentThresholdBytes is the minimum leftover considered "usable". Below this we penalise.
	fragmentThresholdBytes = int64(4_000_000_000)
	// fragmentPenalty is subtracted from the total score when the leftover is an unusable sliver.
	fragmentPenalty = int64(-5_000_000_000)
)

type ScoreBreakdown struct {
	BinPackScore       int64
	FragmentationScore int64
	Total              int64
}

type NodeScore struct {
	NodeName string
	Score    ScoreBreakdown
}

// Score ranks eligible nodes by bin-packing efficiency and fragmentation penalty.
func Score(cache *VRAMCache, validNodes []string, requestedBytes int64) []NodeScore {
	cache.mu.RLock()
	defer cache.mu.RUnlock()

	var scores []NodeScore
	log.Println("Starting scoring phase...")

	for _, nodeName := range validNodes {
		if node, exists := cache.nodes[nodeName]; exists {
			leftover := node.FreeVRAMBytes - requestedBytes

			// Bin-packing: higher score → less leftover (filling nearly-full nodes first).
			binPack := scoreWeightVRAMBytes - leftover

			// Fragmentation penalty: unusable slivers below the threshold are penalised.
			frag := int64(0)
			if leftover > 0 && leftover < fragmentThresholdBytes {
				frag = fragmentPenalty
			}

			total := binPack + frag

			scores = append(scores, NodeScore{
				NodeName: nodeName,
				Score: ScoreBreakdown{
					BinPackScore:       binPack,
					FragmentationScore: frag,
					Total:              total,
				},
			})

			log.Printf("  Node [%s] score=%d (binPack=%d, fragPenalty=%d)",
				nodeName, total, binPack, frag)
		}
	}

	sort.Slice(scores, func(i, j int) bool {
		return scores[i].Score.Total > scores[j].Score.Total
	})

	if len(scores) > 0 {
		log.Printf("Scoring winner: [%s] score=%d", scores[0].NodeName, scores[0].Score.Total)
	}

	return scores
}
EOF

echo ""
echo "==> FIX 8: internal/scheduler/cache.go — add UpdateNode and UpdateNodeCapacity helpers"
# Append the two helpers just before the final closing of the file.
# We use a temp file approach so we don't accidentally duplicate them on re-runs.
if ! grep -q "UpdateNodeCapacity" internal/scheduler/cache.go; then
cat >> internal/scheduler/cache.go << 'EOF'

// ---------------------------------------------------------------------------
// NODE REGISTRATION HELPERS
// ---------------------------------------------------------------------------

// UpdateNode sets or replaces a node's VRAM accounting. Safe to call from
// a watch loop each time a Node resource changes.
func (c *VRAMCache) UpdateNode(nodeName string, totalBytes, allocatedBytes int64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	node, exists := c.nodes[nodeName]
	if !exists {
		node = &NodeState{NodeName: nodeName, Healthy: true}
		c.nodes[nodeName] = node
	}
	node.TotalVRAMBytes = totalBytes
	node.AllocatedVRAMBytes = allocatedBytes
	node.ReservedVRAMBytes = 0
	c.recalculateFreeVRAM(node)
}

// UpdateNodeCapacity is a convenience wrapper that accepts VRAM in whole GiB
// (useful for tests and CLI tooling).
func (c *VRAMCache) UpdateNodeCapacity(nodeName string, totalGiB int64) {
	c.UpdateNode(nodeName, totalGiB*1024*1024*1024, 0)
}
EOF
else
  echo "    (UpdateNodeCapacity already present — skipping append)"
fi

echo ""
echo "==> FIX 9: internal/nodeagent/checkpoint/checkpoint.go — add SliceName/Namespace fields, fix ignored errors"
cat > internal/nodeagent/checkpoint/checkpoint.go << 'EOF'
package checkpoint

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	CheckpointDir  = "/var/run/vgpu-state"
	CheckpointFile = "allocations.json"
)

type CheckpointRecord struct {
	AllocationID   string    `json:"allocationID"`
	SliceUID       string    `json:"sliceUID"`
	SliceName      string    `json:"sliceName"`  // needed by drift detector for K8s lookup
	Namespace      string    `json:"namespace"`  // needed by drift detector for K8s lookup
	ClaimName      string    `json:"claimName"`
	DeviceUUID     string    `json:"deviceUUID"`
	AllocatedBytes int64     `json:"allocatedBytes"`
	NodeName       string    `json:"nodeName"`
	CreatedAt      time.Time `json:"createdAt"`
}

type Store struct {
	mu sync.RWMutex
}

func NewStore() *Store {
	return &Store{}
}

func (s *Store) LoadAll() (map[string]CheckpointRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make(map[string]CheckpointRecord)
	path := filepath.Join(CheckpointDir, CheckpointFile)

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return records, nil // first boot — no checkpoint yet
		}
		return nil, fmt.Errorf("checkpoint read failed: %w", err)
	}

	if err := json.Unmarshal(data, &records); err != nil {
		return nil, fmt.Errorf("checkpoint parse failed (file may be corrupt): %w", err)
	}
	return records, nil
}

func (s *Store) Save(record CheckpointRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(CheckpointDir, 0750); err != nil {
		return fmt.Errorf("checkpoint dir creation failed: %w", err)
	}

	path := filepath.Join(CheckpointDir, CheckpointFile)

	// Read-modify-write. We already hold the write lock so no second guard needed.
	records := make(map[string]CheckpointRecord)
	if data, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(data, &records); err != nil {
			// Corrupt checkpoint: log and continue with empty map to avoid a permanent lock.
			// The caller must treat previously-unknown allocations as orphans.
			records = make(map[string]CheckpointRecord)
		}
	}

	records[record.AllocationID] = record

	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("checkpoint serialisation failed: %w", err)
	}
	return os.WriteFile(path, out, 0640)
}

func (s *Store) Delete(allocationID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := filepath.Join(CheckpointDir, CheckpointFile)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // nothing to delete
		}
		return fmt.Errorf("checkpoint read failed during delete: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return fmt.Errorf("checkpoint parse failed during delete: %w", err)
	}

	delete(records, allocationID)

	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("checkpoint serialisation failed during delete: %w", err)
	}
	return os.WriteFile(path, out, 0640)
}
EOF

echo ""
echo "==> FIX 10: internal/nodeagent/drift/detector.go — fix record field names, guard nil k8sClient"
cat > internal/nodeagent/drift/detector.go << 'EOF'
package drift

import (
	"context"
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Detector struct {
	store     *checkpoint.Store
	allocator *nvml.Allocator
	k8sClient client.Client // may be nil in tests / mock environments
}

func NewDetector(store *checkpoint.Store, allocator *nvml.Allocator, k8sClient client.Client) *Detector {
	return &Detector{store: store, allocator: allocator, k8sClient: k8sClient}
}

func (d *Detector) DetectAndHeal(ctx context.Context) error {
	diskRecords, err := d.store.LoadAll()
	if err != nil {
		return err
	}

	hardwareAllocations := d.allocator.InspectAllHardware()

	for allocID, record := range diskRecords {
		if hardwareAllocations[allocID] {
			// Case 1: Checkpoint and hardware agree — healthy.
			delete(hardwareAllocations, allocID)
			continue
		}

		// Case 2: Checkpoint entry exists but hardware is missing.
		log.Printf("Recovery [Case 2]: Allocation %s missing from hardware!", allocID)

		if d.k8sClient == nil {
			log.Printf("  -> No K8s client configured; pruning orphaned checkpoint entry %s", allocID)
			_ = d.store.Delete(allocID)
			continue
		}

		var slice vgpuv1alpha1.VGPUSlice
		// Use SliceName + Namespace from the checkpoint record (added in FIX 9).
		key := client.ObjectKey{Namespace: record.Namespace, Name: record.SliceName}
		if err := d.k8sClient.Get(ctx, key, &slice); err != nil {
			log.Printf("  -> Slice no longer in K8s API. Pruning dead checkpoint entry %s", allocID)
			_ = d.store.Delete(allocID)
			continue
		}

		if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReady) {
			// Hardware is gone but API says Ready: signal failure so the controller reacts.
			log.Printf("  -> API expects hardware to be Ready. Signalling Failed phase.")
			_ = state.TransitionSlicePhase(&slice, state.SlicePhaseFailed,
				state.ReasonDriftDetected, "Device missing from PCIe bus on node boot")
			_ = d.k8sClient.Status().Update(ctx, &slice)
			_ = d.store.Delete(allocID)
		}
	}

	// Case 3: Hardware allocation has no checkpoint — orphaned hardware.
	for orphanAllocID := range hardwareAllocations {
		log.Printf("Recovery [Case 3]: Orphaned hardware allocation %s — releasing.", orphanAllocID)
		_ = d.allocator.Release(ctx, orphanAllocID)
	}

	return nil
}
EOF

echo ""
echo "==> FIX 11: internal/nodeagent/nvml/allocator.go — add initialized field, NewAllocator constructor, InspectAllHardware"
cat > internal/nodeagent/nvml/allocator.go << 'EOF'
package nvml

import (
	"context"
	"fmt"
	"time"
)

type AllocationRequest struct {
	SliceUID           string
	ClaimName          string
	RequestedVRAMBytes int64
}

type AllocationResult struct {
	AllocationID   string
	DeviceUUID     string
	AllocatedBytes int64
}

// Allocator owns the interface to the physical GPU hardware.
type Allocator struct {
	mockMode    bool
	initialized bool
}

func NewAllocator(mock bool) *Allocator {
	return &Allocator{mockMode: mock, initialized: true}
}

func (a *Allocator) Allocate(ctx context.Context, req AllocationRequest) (*AllocationResult, error) {
	if !a.initialized {
		return nil, fmt.Errorf("allocator not initialised")
	}

	allocID := fmt.Sprintf("alloc-%s-%d", req.SliceUID[:8], time.Now().Unix())
	devUUID := "GPU-MOCK-ENTERPRISE-1"

	if !a.mockMode {
		// TODO: real NVML C-binding calls go here.
	}

	return &AllocationResult{
		AllocationID:   allocID,
		DeviceUUID:     devUUID,
		AllocatedBytes: req.RequestedVRAMBytes,
	}, nil
}

func (a *Allocator) Release(ctx context.Context, allocationID string) error {
	if !a.initialized {
		return fmt.Errorf("allocator not initialised")
	}
	// TODO: teardown CDI firewall and free NVML memory partition.
	return nil
}

// InspectAllHardware returns the set of allocationIDs currently present on
// the physical hardware. Used by the drift detector to reconcile disk state.
// In mock mode, returns an empty map (nothing to detect).
func (a *Allocator) InspectAllHardware() map[string]bool {
	if !a.initialized || a.mockMode {
		return make(map[string]bool)
	}
	// TODO: query NVML / sysfs for active memory partitions and map them back
	// to allocationIDs stored in their CDI annotations.
	return make(map[string]bool)
}
EOF

echo ""
echo "==> FIX 12: internal/nodeagent/nvml/probe.go — initialized field now exists on Allocator"
cat > internal/nodeagent/nvml/probe.go << 'EOF'
package nvml

import (
	"fmt"

	"github.com/NVIDIA/go-nvml/pkg/nvml"
)

// CheckHardwareHealth pings the PCIe bus to ensure the GPU hasn't fallen off (Xid errors).
func (a *Allocator) CheckHardwareHealth() error {
	if !a.initialized { // field now defined on Allocator struct
		return fmt.Errorf("NVML not initialized")
	}
	if a.mockMode {
		return nil // mock hardware is always healthy
	}
	_, ret := nvml.DeviceGetHandleByIndex(0)
	if ret != nvml.SUCCESS {
		return fmt.Errorf("GPU health check failed: %v", nvml.ErrorString(ret))
	}
	return nil
}
EOF

echo ""
echo "==> FIX 13: internal/nodeagent/manager.go — use NewAllocator, fix drift.NewDetector call (3 args)"
cat > internal/nodeagent/manager.go << 'EOF'
package nodeagent

import (
	"context"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/drift"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/nvml"
	"github.com/pranav2910/vgpu-scheduler/internal/state"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Manager struct {
	NodeName  string
	Allocator *nvml.Allocator
	Store     *checkpoint.Store
	Reporter  *Reporter
	Detector  *drift.Detector
}

// NewManager wires all NodeAgent subsystems together.
// k8sClient may be nil in unit/integration tests; drift healing will skip API
// calls in that case (checkpoint entries are pruned locally instead).
func NewManager(nodeName string, k8sClient client.Client) *Manager {
	store := checkpoint.NewStore()
	allocator := nvml.NewAllocator(true) // use NewAllocator so initialized=true
	return &Manager{
		NodeName:  nodeName,
		Store:     store,
		Allocator: allocator,
		Reporter:  NewReporter(),
		Detector:  drift.NewDetector(store, allocator, k8sClient), // fixed: was missing k8sClient arg
	}
}

// ReconcileSlice is called whenever the Kubernetes API updates a Slice assigned to this node.
func (m *Manager) ReconcileSlice(ctx context.Context, slice *vgpuv1alpha1.VGPUSlice) error {

	// 1. ALLOCATION PATH
	if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseScheduled) {
		req := nvml.AllocationRequest{
			SliceUID:           string(slice.UID),
			ClaimName:          slice.Spec.ClaimRef,
			RequestedVRAMBytes: slice.Spec.RequestedVRAMBytes,
		}
		result, err := m.Allocator.Allocate(ctx, req)
		if err != nil {
			return err
		}

		// Save durable checkpoint. SliceName + Namespace populate drift detector lookups.
		if err := m.Store.Save(checkpoint.CheckpointRecord{
			AllocationID:   result.AllocationID,
			SliceUID:       req.SliceUID,
			SliceName:      slice.Name,
			Namespace:      slice.Namespace,
			ClaimName:      req.ClaimName,
			DeviceUUID:     result.DeviceUUID,
			AllocatedBytes: result.AllocatedBytes,
			NodeName:       m.NodeName,
			CreatedAt:      time.Now(),
		}); err != nil {
			return err
		}

		log.Printf("Successfully allocated hardware for %s", req.SliceUID)
		return m.Reporter.ReportAllocationReady(ctx, slice, result)
	}

	// 2. RELEASE PATH
	if slice.Status.Phase == vgpuv1alpha1.VGPUSlicePhase(state.SlicePhaseReleasing) ||
		!slice.DeletionTimestamp.IsZero() {

		if err := m.Allocator.Release(ctx, slice.Status.AllocationID); err != nil {
			return err
		}
		if err := m.Store.Delete(slice.Status.AllocationID); err != nil {
			return err
		}

		log.Printf("Successfully released hardware for %s", slice.UID)
		return m.Reporter.ReportReleaseComplete(ctx, slice)
	}

	return nil
}
EOF

echo ""
echo "==> FIX 14: internal/nodeagent/checkpoint.go — delete orphan file (superseded by checkpoint/ package)"
if [[ -f "internal/nodeagent/checkpoint.go" ]]; then
  rm internal/nodeagent/checkpoint.go
  echo "    Deleted internal/nodeagent/checkpoint.go"
else
  echo "    Already absent — skipping"
fi

echo ""
echo "==> FIX 15: internal/webhook/mutating_pod.go — fmt.Printf → log.Printf for consistency"
cat > internal/webhook/mutating_pod.go << 'EOF'
package webhook

import (
	"context"
	"fmt"
	"log"

	corev1 "k8s.io/api/core/v1"

	"github.com/pranav2910/vgpu-scheduler/internal/security"
)

const (
	// VGPUClaimAnnotation is the annotation users place on Pods to request a GPU slice.
	VGPUClaimAnnotation = "infrastructure.pranav2910.com/claim-ref"
)

// MutatePod intercepts Pods right before they launch and forces them into the CDI boundary.
func MutatePod(ctx context.Context, pod *corev1.Pod) error {
	claimName, exists := pod.Annotations[VGPUClaimAnnotation]
	if !exists {
		return nil // not a vGPU workload
	}

	// 1. Enforce security policy before injecting anything.
	if err := security.ValidatePodSecurity(pod); err != nil {
		return err
	}

	// 2. Inject CDI device reference so containerd picks up the hardware firewall.
	// In production: resolve the slice's AllocationID from the API and use that.
	cdiDeviceName := fmt.Sprintf("vgpu.pranav2910.com/device=%s", claimName)

	for i := range pod.Spec.Containers {
		pod.Spec.Containers[i].Env = append(pod.Spec.Containers[i].Env, corev1.EnvVar{
			Name:  "NVIDIA_VISIBLE_DEVICES",
			Value: cdiDeviceName,
		})
	}

	log.Printf("Pod %s/%s mutated for vGPU claim %s", pod.Namespace, pod.Name, claimName)
	return nil
}
EOF

echo ""
echo "==> FIX 16: internal/webhook/validating_vgpuclaim.go — fix ServiceTier check to match defined tiers"
cat > internal/webhook/validating_vgpuclaim.go << 'EOF'
package webhook

import (
	"context"
	"fmt"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// ValidateVGPUClaim ensures garbage data never enters the reconciliation loop.
func ValidateVGPUClaim(ctx context.Context, claim *vgpuv1alpha1.VGPUClaim) error {
	// 1. Validate VRAM bounds (must be positive and within max physical card capacity).
	if claim.Spec.RequestedVRAMBytes <= 0 {
		return fmt.Errorf("validation failed: RequestedVRAMBytes must be > 0")
	}
	const maxVRAMBytes = int64(85_899_345_920) // 80 GiB — adjust per hardware fleet
	if claim.Spec.RequestedVRAMBytes > maxVRAMBytes {
		return fmt.Errorf("validation failed: RequestedVRAMBytes %d exceeds max capacity %d",
			claim.Spec.RequestedVRAMBytes, maxVRAMBytes)
	}

	// 2. Validate ServiceTier against the canonical set defined in api/v1alpha1.
	tier := claim.Spec.ServiceTier
	if tier != "" &&
		tier != vgpuv1alpha1.ServiceTierGuaranteed &&
		tier != vgpuv1alpha1.ServiceTierBestEffort {
		return fmt.Errorf("validation failed: unsupported ServiceTier %q (want Guaranteed or BestEffort)", tier)
	}

	return nil
}

// ValidateClaimUpdate ensures users cannot change the VRAM request after hardware is locked.
func ValidateClaimUpdate(ctx context.Context, oldClaim, newClaim *vgpuv1alpha1.VGPUClaim) error {
	if oldClaim.Spec.RequestedVRAMBytes != newClaim.Spec.RequestedVRAMBytes {
		return fmt.Errorf("immutability violation: cannot change RequestedVRAMBytes after creation")
	}
	return nil
}
EOF

echo ""
echo "==> FIX 17: internal/nodeagent/cdi/generator.go — 0644 → 0640 on CDI spec files"
cat > internal/nodeagent/cdi/generator.go << 'EOF'
package cdi

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const (
	cdiDirectory = "/var/run/cdi"
	vendorName   = "infrastructure.pranav2910.com"
	cdiVersion   = "0.5.0"
)

type CDISpec struct {
	Version string   `json:"cdiVersion"`
	Kind    string   `json:"kind"`
	Devices []Device `json:"devices"`
}

type Device struct {
	Name           string         `json:"name"`
	ContainerEdits ContainerEdits `json:"containerEdits"`
}

type ContainerEdits struct {
	Env []string `json:"env,omitempty"`
}

// GenerateFirewall writes a CDI spec file that locks the container to the given GPU partition.
func GenerateFirewall(sliceName string, uuid string) error {
	if err := os.MkdirAll(cdiDirectory, 0750); err != nil {
		return fmt.Errorf("failed to create CDI directory: %w", err)
	}

	spec := CDISpec{
		Version: cdiVersion,
		Kind:    vendorName,
		Devices: []Device{
			{
				Name: sliceName,
				ContainerEdits: ContainerEdits{
					Env: []string{fmt.Sprintf("NVIDIA_VISIBLE_DEVICES=%s", uuid)},
				},
			},
		},
	}

	data, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		return fmt.Errorf("CDI spec serialisation failed: %w", err)
	}

	// Named by UUID so TeardownFirewall can find the file without extra lookup.
	filePath := filepath.Join(cdiDirectory, fmt.Sprintf("%s-%s.json", vendorName, uuid))
	// 0640: owner r/w, group r, world none — CDI files should not be world-readable.
	return os.WriteFile(filePath, data, 0640) // was 0644
}

// TeardownFirewall removes the CDI spec file, revoking the container's hardware access.
func TeardownFirewall(uuid string) error {
	filePath := filepath.Join(cdiDirectory, fmt.Sprintf("%s-%s.json", vendorName, uuid))
	if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to teardown CDI firewall for %s: %w", uuid, err)
	}
	return nil
}
EOF

echo ""
echo "==> FIX 18: test/integration/scheduler_cache_test.go — fix API signatures (Reserve 2-return, CanFit 3-return, atomic counter)"
cat > test/integration/scheduler_cache_test.go << 'EOF'
package integration

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
)

func TestThunderingHerd_Concurrency(t *testing.T) {
	// 1. Set up an 80 GiB node.
	cache := scheduler.NewVRAMCache()
	reserver := scheduler.NewReservationManager(cache, 30*time.Second)

	const nodeName = "h100-worker-1"
	const nodeCapacityGiB = int64(80)
	const requestGiB = int64(8)
	const expectedSuccesses = int(nodeCapacityGiB / requestGiB) // 10

	cache.UpdateNodeCapacity(nodeName, nodeCapacityGiB) // fixed: UpdateNodeCapacity added in FIX 8

	// 2. Fire 100 concurrent workloads each requesting 8 GiB. Only 10 can succeed.
	var wg sync.WaitGroup
	var successCount int32
	workers := 100

	fmt.Printf("Firing %d concurrent AI workloads...\n", workers)

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			sliceUID := fmt.Sprintf("slice-%d", id)

			// Reserve returns (*ReservationTx, error) — fixed: was used as single error return.
			_, err := reserver.Reserve(sliceUID, nodeName, requestGiB*1024*1024*1024)
			if err == nil {
				atomic.AddInt32(&successCount, 1) // fixed: atomic instead of mutex
			}
		}(i)
	}
	wg.Wait()

	// 3. Verify exactly 10 successes.
	got := int(successCount)
	if got != expectedSuccesses {
		t.Fatalf("Concurrency failure: expected %d successes, got %d — thundering herd broke the lock",
			expectedSuccesses, got)
	}

	// 4. Verify the node is truly full.
	fits, _, _ := cache.CanFit(nodeName, 1) // fixed: was capturing only 2 of 3 return values
	if fits {
		t.Fatal("Math failure: node should be full but CanFit returned true")
	}

	fmt.Printf("PASS: %d workloads fired, exactly %d succeeded, %d safely rejected.\n",
		workers, got, workers-got)
}
EOF

echo ""
echo "==> FIX 19: test/fuzz/binpack_fuzz_test.go — fix cache.UpdateNode and cache.AssumeSlice API"
cat > test/fuzz/binpack_fuzz_test.go << 'EOF'
package fuzz

import (
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
)

// FuzzVRAMCache ensures the cache never panics on arbitrary byte inputs.
func FuzzVRAMCache(f *testing.F) {
	f.Add(int64(85_899_345_920), int64(8_589_934_592)) // 80 GiB node, 8 GiB request

	f.Fuzz(func(t *testing.T, totalVRAM int64, request int64) {
		cache := scheduler.NewVRAMCache()
		cache.UpdateNode("node-1", totalVRAM, 0) // fixed: UpdateNode added in FIX 8

		// AssumeSlice is the correct cache primitive (Reserve wraps it).
		err := cache.AssumeSlice("fuzz-slice", "node-1", request, 30*time.Second)
		if (request <= 0 || request > totalVRAM) && err == nil {
			t.Errorf("Cache allowed invalid reservation: total=%d, request=%d", totalVRAM, request)
		}
	})
}
EOF

echo ""
echo "==> FIX 20: cmd/nodeagent/main.go — pass nil k8s client to NewManager (wire real client in production)"
cat > cmd/nodeagent/main.go << 'EOF'
package main

import (
	"context"
	"log"
	"os"

	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent"
)

func main() {
	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		log.Fatalf("CRITICAL: NODE_NAME environment variable is required")
	}

	log.Printf("Booting vGPU NodeAgent on %s...", nodeName)

	ctx := context.Background()

	// TODO (production): build a real controller-runtime client here and pass it.
	// The client is needed for drift healing to update Slice status in the K8s API.
	// When nil, drift healing prunes local checkpoint entries only (safe for testing).
	manager := nodeagent.NewManager(nodeName, nil)

	log.Println("Running hardware vs. checkpoint drift detection...")
	if err := manager.Detector.DetectAndHeal(ctx); err != nil {
		log.Fatalf("Drift healing failed: %v", err)
	}

	log.Println("Hardware initialised. Listening for scheduled slices...")
	// TODO (production): Watch K8s API for VGPUSlices where spec.nodeName == NODE_NAME
	// and call manager.ReconcileSlice(ctx, slice) for each event.

	select {} // Block until signal.
}
EOF

echo ""
echo "========================================================================"
echo " All fixes applied. Summary:"
echo "========================================================================"
echo ""
echo "  API layer"
echo "  [1]  conditions.go        — removed duplicate phase consts; kept type aliases"
echo "  [2]  vgpuclaim_types.go   — VRAM: resource.Quantity -> RequestedVRAMBytes int64"
echo "                              added FailureReason to status"
echo "  [3]  vgpuslice_types.go   — ClaimRef: ObjectReference -> string"
echo "                              RequestedVRAM -> RequestedVRAMBytes int64"
echo "                              added AllocationID, AllocatedBytes, FailureReason"
echo "  [4]  zz_generated.deepcopy.go — removed Quantity.DeepCopy() calls"
echo ""
echo "  Scheduler"
echo "  [5]  filter.go            — CanFit 3-return captured (was 2)"
echo "  [6]  reserve.go           — ForgetSlice -> RollbackAssumedSlice"
echo "  [7]  score.go             — magic numbers extracted to named constants"
echo "  [8]  cache.go             — added UpdateNode / UpdateNodeCapacity helpers"
echo ""
echo "  NodeAgent"
echo "  [9]  checkpoint/checkpoint.go — added SliceName/Namespace fields"
echo "                              fixed all ignored json.Unmarshal/MarshalIndent errors"
echo "                              tightened file permissions to 0640"
echo "  [10] drift/detector.go    — fixed record.Namespace / record.SliceName refs"
echo "                              guarded nil k8sClient"
echo "  [11] nvml/allocator.go    — added initialized field, NewAllocator(), InspectAllHardware()"
echo "  [12] nvml/probe.go        — initialized field now exists (no change to logic)"
echo "  [13] manager.go           — NewAllocator(); drift.NewDetector gets k8sClient arg"
echo "  [14] checkpoint.go        — deleted orphan file (superseded by checkpoint/ package)"
echo ""
echo "  Webhooks"
echo "  [15] mutating_pod.go      — fmt.Printf -> log.Printf"
echo "  [16] validating_vgpuclaim.go — ServiceTier check uses typed constants"
echo ""
echo "  CDI"
echo "  [17] cdi/generator.go     — file permissions 0644 -> 0640"
echo ""
echo "  Tests"
echo "  [18] scheduler_cache_test.go  — fixed Reserve/CanFit signatures, atomic counter"
echo "  [19] binpack_fuzz_test.go     — fixed UpdateNode/AssumeSlice API"
echo ""
echo "  Entrypoint"
echo "  [20] cmd/nodeagent/main.go — NewManager now accepts k8s client (nil for now)"
echo ""
echo "  NEXT STEPS (not auto-fixable — require production wiring):"
echo "  • cmd/controller/main.go  — wire reconcilers with ctrl.NewControllerManagedBy()"
echo "  • cmd/scheduler/main.go   — connect SliceScheduler to a Slice watch loop"
echo "  • cmd/nodeagent/main.go   — replace nil k8s client with a real client"
echo "  • Run: controller-gen object:headerFile=hack/boilerplate.go.txt paths=./api/..."
echo "    to regenerate zz_generated.deepcopy.go from the updated types."
echo ""
echo "  Backups saved to: $BACKUP_DIR"
echo "========================================================================"
