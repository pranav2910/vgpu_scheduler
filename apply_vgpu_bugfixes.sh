#!/usr/bin/env bash
set -euo pipefail

# vGPU Scheduler bugfix patch script
# Run from the root of your vgpu-scheduler repository:
#   bash apply_vgpu_bugfixes.sh
#
# This script overwrites/creates selected files with safer production-oriented fixes.
# It also backs up replaced files to .bugfix-backup/<timestamp>/.

ROOT="${1:-$(pwd)}"
cd "$ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".bugfix-backup/$STAMP"
mkdir -p "$BACKUP_DIR"

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$path")"
    cp -a "$path" "$BACKUP_DIR/$path"
  fi
}

write_file() {
  local path="$1"
  backup_if_exists "$path"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  echo "wrote $path"
}

write_file go.mod <<'GOEOF'
module github.com/pranav2910/vgpu-scheduler

go 1.22

require (
	github.com/NVIDIA/go-nvml v0.12.4-0
	github.com/prometheus/client_golang v1.19.1
	go.opentelemetry.io/otel v1.28.0
	go.opentelemetry.io/otel/trace v1.28.0
	k8s.io/api v0.31.0
	k8s.io/apimachinery v0.31.0
	k8s.io/client-go v0.31.0
	sigs.k8s.io/controller-runtime v0.19.0
)
GOEOF

write_file internal/nodeagent/nvml/allocator.go <<'GOEOF'
package nvml

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
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

type Allocator struct {
	mockMode    bool
	initialized bool
}

func NewAllocator(mock bool) *Allocator {
	return &Allocator{mockMode: mock, initialized: true}
}

func (a *Allocator) Allocate(ctx context.Context, req AllocationRequest) (*AllocationResult, error) {
	if !a.initialized {
		return nil, fmt.Errorf("allocator not initialized")
	}
	if req.SliceUID == "" {
		return nil, fmt.Errorf("allocation request missing SliceUID")
	}
	if req.RequestedVRAMBytes <= 0 {
		return nil, fmt.Errorf("requested VRAM must be positive")
	}

	if !a.mockMode {
		return nil, fmt.Errorf("real NVML allocation is not implemented yet; set VGPU_MOCK=true only for local development")
	}

	suffix, err := randomSuffix(8)
	if err != nil {
		return nil, err
	}

	shortUID := req.SliceUID
	if len(shortUID) > 8 {
		shortUID = shortUID[:8]
	}

	return &AllocationResult{
		AllocationID:   fmt.Sprintf("mock-alloc-%s-%s", shortUID, suffix),
		DeviceUUID:     fmt.Sprintf("GPU-MOCK-%s-%s", shortUID, suffix),
		AllocatedBytes: req.RequestedVRAMBytes,
	}, nil
}

func (a *Allocator) Release(ctx context.Context, allocationID string) error {
	if !a.initialized {
		return fmt.Errorf("allocator not initialized")
	}
	if allocationID == "" {
		return nil
	}
	if !a.mockMode {
		return fmt.Errorf("real NVML release is not implemented yet")
	}
	return nil
}

func (a *Allocator) InspectAllHardware() map[string]bool {
	return map[string]bool{}
}

func randomSuffix(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generating allocation id: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
GOEOF

write_file internal/nodeagent/checkpoint/checkpoint.go <<'GOEOF'
package checkpoint

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type AllocationRecord struct {
	SliceUID       string `json:"sliceUID"`
	AllocationID   string `json:"allocationID"`
	DeviceUUID     string `json:"deviceUUID"`
	AllocatedBytes int64  `json:"allocatedBytes"`
}

type Store struct {
	mu      sync.Mutex
	baseDir string
}

func NewStore() *Store {
	baseDir := os.Getenv("VGPU_CHECKPOINT_DIR")
	if baseDir == "" {
		baseDir = "/var/lib/vgpu-scheduler"
	}
	return &Store{baseDir: baseDir}
}

func (s *Store) path() string {
	return filepath.Join(s.baseDir, "allocations.json")
}

func (s *Store) Load() (map[string]AllocationRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path())
	if os.IsNotExist(err) {
		return map[string]AllocationRecord{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading checkpoint: %w", err)
	}

	records := map[string]AllocationRecord{}
	if len(data) == 0 {
		return records, nil
	}
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, fmt.Errorf("parsing checkpoint: %w", err)
	}
	return records, nil
}

func (s *Store) Save(records map[string]AllocationRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(s.baseDir, 0750); err != nil {
		return fmt.Errorf("creating checkpoint dir: %w", err)
	}
	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("marshalling checkpoint: %w", err)
	}
	return atomicWriteFile(s.path(), out, 0640)
}

func (s *Store) Put(record AllocationRecord) error {
	records, err := s.Load()
	if err != nil {
		return err
	}
	records[record.SliceUID] = record
	return s.Save(records)
}

func (s *Store) Delete(sliceUID string) error {
	records, err := s.Load()
	if err != nil {
		return err
	}
	delete(records, sliceUID)
	return s.Save(records)
}

func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0750); err != nil {
		return fmt.Errorf("creating checkpoint dir: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".allocations-*.tmp")
	if err != nil {
		return fmt.Errorf("creating temp checkpoint: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("writing temp checkpoint: %w", err)
	}
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("chmod temp checkpoint: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("sync temp checkpoint: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing temp checkpoint: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("renaming checkpoint: %w", err)
	}
	return nil
}
GOEOF

write_file internal/scheduler/cache.go <<'GOEOF'
package scheduler

import (
	"fmt"
	"sync"
)

type NodeResourceState struct {
	NodeName           string
	TotalVRAMBytes     int64
	AllocatedVRAMBytes int64
	ReservedVRAMBytes  int64
	FreeVRAMBytes      int64
}

type AssumedAllocation struct {
	SliceUID           string
	NodeName           string
	RequestedVRAMBytes int64
}

type SliceAllocationSnapshot struct {
	SliceUID       string
	NodeName       string
	Phase          string
	AllocatedBytes int64
	ReservedBytes  int64
}

type VRAMCache struct {
	mu                    sync.Mutex
	nodes                 map[string]*NodeResourceState
	assumedBySlice        map[string]*AssumedAllocation
	confirmedBySlice      map[string]*AssumedAllocation
	syncedPhaseBySlice    map[string]string
	allocatedBytesBySlice map[string]int64
}

func NewVRAMCache() *VRAMCache {
	return &VRAMCache{
		nodes:                 map[string]*NodeResourceState{},
		assumedBySlice:        map[string]*AssumedAllocation{},
		confirmedBySlice:      map[string]*AssumedAllocation{},
		syncedPhaseBySlice:    map[string]string{},
		allocatedBytesBySlice: map[string]int64{},
	}
}

func (c *VRAMCache) UpsertNode(nodeName string, totalVRAMBytes int64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	node, ok := c.nodes[nodeName]
	if !ok {
		node = &NodeResourceState{NodeName: nodeName}
		c.nodes[nodeName] = node
	}
	node.TotalVRAMBytes = totalVRAMBytes
	c.recalculateFreeVRAM(node)
}

func (c *VRAMCache) Assume(sliceUID string, requestedVRAMBytes int64) (*AssumedAllocation, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if requestedVRAMBytes <= 0 {
		return nil, fmt.Errorf("requested VRAM must be positive")
	}
	if _, exists := c.assumedBySlice[sliceUID]; exists {
		return nil, fmt.Errorf("slice %s already assumed", sliceUID)
	}

	var best *NodeResourceState
	for _, node := range c.nodes {
		if node.FreeVRAMBytes >= requestedVRAMBytes {
			if best == nil || node.FreeVRAMBytes > best.FreeVRAMBytes {
				best = node
			}
		}
	}
	if best == nil {
		return nil, fmt.Errorf("no node has enough free VRAM for %d bytes", requestedVRAMBytes)
	}

	alloc := &AssumedAllocation{SliceUID: sliceUID, NodeName: best.NodeName, RequestedVRAMBytes: requestedVRAMBytes}
	c.assumedBySlice[sliceUID] = alloc
	best.ReservedVRAMBytes += requestedVRAMBytes
	c.recalculateFreeVRAM(best)
	return alloc, nil
}

func (c *VRAMCache) ConfirmAssumption(sliceUID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	alloc, ok := c.assumedBySlice[sliceUID]
	if !ok {
		return fmt.Errorf("slice %s has no assumption to confirm", sliceUID)
	}
	delete(c.assumedBySlice, sliceUID)
	c.confirmedBySlice[sliceUID] = alloc
	return nil
}

func (c *VRAMCache) RollbackAssumption(sliceUID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	alloc, ok := c.assumedBySlice[sliceUID]
	if !ok {
		return
	}
	if node, exists := c.nodes[alloc.NodeName]; exists {
		node.ReservedVRAMBytes -= alloc.RequestedVRAMBytes
		if node.ReservedVRAMBytes < 0 {
			node.ReservedVRAMBytes = 0
		}
		c.recalculateFreeVRAM(node)
	}
	delete(c.assumedBySlice, sliceUID)
}

func (c *VRAMCache) RebuildSliceState(slices []SliceAllocationSnapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()

	for _, n := range c.nodes {
		n.AllocatedVRAMBytes = 0
		n.ReservedVRAMBytes = 0
	}
	c.assumedBySlice = map[string]*AssumedAllocation{}
	c.confirmedBySlice = map[string]*AssumedAllocation{}
	c.syncedPhaseBySlice = map[string]string{}
	c.allocatedBytesBySlice = map[string]int64{}

	for _, s := range slices {
		node, ok := c.nodes[s.NodeName]
		if !ok || s.SliceUID == "" || s.NodeName == "" {
			continue
		}

		switch s.Phase {
		case "Scheduled", "Allocating":
			reserved := s.ReservedBytes
			if reserved <= 0 {
				reserved = s.AllocatedBytes
			}
			if reserved > 0 {
				node.ReservedVRAMBytes += reserved
				c.confirmedBySlice[s.SliceUID] = &AssumedAllocation{SliceUID: s.SliceUID, NodeName: s.NodeName, RequestedVRAMBytes: reserved}
			}
		case "Ready":
			if s.AllocatedBytes > 0 {
				node.AllocatedVRAMBytes += s.AllocatedBytes
				c.syncedPhaseBySlice[s.SliceUID] = "Ready"
				c.allocatedBytesBySlice[s.SliceUID] = s.AllocatedBytes
			}
		case "Released", "Failed":
			c.syncedPhaseBySlice[s.SliceUID] = s.Phase
		}
	}

	for _, n := range c.nodes {
		c.recalculateFreeVRAM(n)
	}
}

func (c *VRAMCache) PromoteSliceToAllocatedOnce(sliceUID, nodeName string, actualBytes int64) error {
	if actualBytes <= 0 {
		return fmt.Errorf("cannot promote slice %s with non-positive allocation bytes", sliceUID)
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.syncedPhaseBySlice[sliceUID] == "Ready" {
		return nil
	}

	node, exists := c.nodes[nodeName]
	if !exists {
		return fmt.Errorf("node %s not found for promotion", nodeName)
	}

	if assumption, exists := c.confirmedBySlice[sliceUID]; exists {
		node.ReservedVRAMBytes -= assumption.RequestedVRAMBytes
		if node.ReservedVRAMBytes < 0 {
			node.ReservedVRAMBytes = 0
		}
		delete(c.confirmedBySlice, sliceUID)
	}

	node.AllocatedVRAMBytes += actualBytes
	c.syncedPhaseBySlice[sliceUID] = "Ready"
	c.allocatedBytesBySlice[sliceUID] = actualBytes
	c.recalculateFreeVRAM(node)
	return nil
}

func (c *VRAMCache) ReleaseSliceOnce(sliceUID, nodeName string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.syncedPhaseBySlice[sliceUID] == "Released" {
		return nil
	}

	node, exists := c.nodes[nodeName]
	if !exists {
		return fmt.Errorf("node %s not found for release", nodeName)
	}

	bytes := c.allocatedBytesBySlice[sliceUID]
	if bytes <= 0 {
		return fmt.Errorf("cannot release slice %s: allocation bytes unknown", sliceUID)
	}

	node.AllocatedVRAMBytes -= bytes
	if node.AllocatedVRAMBytes < 0 {
		node.AllocatedVRAMBytes = 0
	}
	delete(c.allocatedBytesBySlice, sliceUID)
	c.syncedPhaseBySlice[sliceUID] = "Released"
	c.recalculateFreeVRAM(node)
	return nil
}

func (c *VRAMCache) Snapshot() map[string]NodeResourceState {
	c.mu.Lock()
	defer c.mu.Unlock()

	out := make(map[string]NodeResourceState, len(c.nodes))
	for k, v := range c.nodes {
		out[k] = *v
	}
	return out
}

func (c *VRAMCache) recalculateFreeVRAM(node *NodeResourceState) {
	node.FreeVRAMBytes = node.TotalVRAMBytes - node.AllocatedVRAMBytes - node.ReservedVRAMBytes
	if node.FreeVRAMBytes < 0 {
		node.FreeVRAMBytes = 0
	}
}
GOEOF

cat > /tmp/plugin_patch.py <<'PYEOF'
from pathlib import Path
p = Path('internal/scheduler/plugin.go')
if not p.exists():
    print('skip internal/scheduler/plugin.go: file not found')
    raise SystemExit(0)
s = p.read_text()
start = s.find('func (s *SliceScheduler) bindToKubernetesAPI(')
if start != -1:
    depth = 0
    end = None
    for i in range(start, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    new = r'''func (s *SliceScheduler) bindToKubernetesAPI(ctx context.Context, nn types.NamespacedName, nodeName string) error {
	var target vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &target); err != nil {
		return fmt.Errorf("fetching slice %s: %w", nn, err)
	}

	if target.Spec.NodeName != "" && target.Spec.NodeName != nodeName {
		return fmt.Errorf("slice already bound to different node %q", target.Spec.NodeName)
	}

	// Spec first: NodeAgent can only act after nodeName is visible.
	specBase := client.MergeFrom(target.DeepCopy())
	target.Spec.NodeName = nodeName
	if err := s.K8sClient.Patch(ctx, &target, specBase); err != nil {
		return fmt.Errorf("patching spec.nodeName: %w", err)
	}

	statusBase := client.MergeFrom(target.DeepCopy())
	target.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Scheduled")
	if err := s.K8sClient.Status().Patch(ctx, &target, statusBase); err != nil {
		// Best-effort revert so reservation rollback can make the object schedulable again.
		var fresh vgpuv1alpha1.VGPUSlice
		if getErr := s.K8sClient.Get(ctx, nn, &fresh); getErr == nil {
			revertBase := client.MergeFrom(fresh.DeepCopy())
			fresh.Spec.NodeName = ""
			_ = s.K8sClient.Patch(ctx, &fresh, revertBase)
		}
		return fmt.Errorf("patching status.phase to Scheduled: %w", err)
	}

	return nil
}'''
    s = s[:start] + new + s[end:]

start = s.find('func (s *SliceScheduler) SyncCacheFromSlice(')
if start != -1:
    depth = 0
    end = None
    for i in range(start, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    new = r'''func (s *SliceScheduler) SyncCacheFromSlice(sliceUID, nodeName, phase string, allocatedBytes int64) {
	switch phase {
	case "Ready":
		if err := s.Cache.PromoteSliceToAllocatedOnce(sliceUID, nodeName, allocatedBytes); err != nil {
			log.Printf("cache sync Ready failed for slice %s: %v", sliceUID, err)
		}
	case "Released":
		if err := s.Cache.ReleaseSliceOnce(sliceUID, nodeName); err != nil {
			log.Printf("cache sync Released failed for slice %s: %v", sliceUID, err)
		}
	}
}'''
    s = s[:start] + new + s[end:]
p.write_text(s)
print('patched internal/scheduler/plugin.go')
PYEOF
python3 /tmp/plugin_patch.py

cat > /tmp/nodeagent_main_patch.py <<'PYEOF'
from pathlib import Path
p = Path('cmd/nodeagent/main.go')
if not p.exists():
    print('skip cmd/nodeagent/main.go: file not found')
    raise SystemExit(0)
s = p.read_text()
if 'func explicitMockMode() bool' not in s:
    s += r'''

func explicitMockMode() bool {
	value := os.Getenv("VGPU_MOCK")
	switch value {
	case "true", "1", "yes":
		return true
	case "false", "0", "no":
		return false
	default:
		log.Fatalf("VGPU_MOCK must be explicitly set to true for local development or false for production")
		return false
	}
}
'''
# This part is intentionally conservative because constructor names vary by repo version.
# Manual check may be needed if your main.go still calls nvml.NewAllocator(true) or nodeagent.NewManager(...).
p.write_text(s)
print('patched cmd/nodeagent/main.go with explicitMockMode helper')
PYEOF
python3 /tmp/nodeagent_main_patch.py

cat > /tmp/manager_patch.py <<'PYEOF'
from pathlib import Path
p = Path('internal/nodeagent/manager.go')
if not p.exists():
    print('skip internal/nodeagent/manager.go: file not found')
    raise SystemExit(0)
s = p.read_text()
if 'func NewManagerWithAllocator(' not in s:
    insert = r'''

func NewManagerWithAllocator(nodeName string, k8sClient client.Client, allocator *nvml.Allocator) *Manager {
	store := checkpoint.NewStore()
	return &Manager{
		NodeName:  nodeName,
		Client:    k8sClient,
		Allocator: allocator,
		Store:     store,
		Reporter:  NewReporter(k8sClient),
		Detector:  drift.NewDetector(store, allocator),
	}
}
'''
    s += insert
p.write_text(s)
print('patched internal/nodeagent/manager.go with NewManagerWithAllocator helper')
PYEOF
python3 /tmp/manager_patch.py

write_file PATCH_NOTES.md <<'MDEOF'
# Applied vGPU scheduler bugfix patch

This script applied the following fixes:

1. Changed `go.mod` from Go 1.25 to Go 1.22-compatible dependencies.
2. Made NVML allocator fail closed when real allocation is not implemented.
3. Added explicit mock-mode helper for nodeagent startup.
4. Added allocator dependency injection helper for nodeagent manager.
5. Replaced checkpoint writes with atomic write/rename logic.
6. Rebuilt scheduler cache accounting to avoid double-counting after restarts.
7. Patched scheduler binding order where possible: `spec.nodeName` before `status.phase=Scheduled`.
8. Added safer cache sync for Ready/Released transitions.

Next commands:

```bash
go mod tidy
gofmt -w go.mod cmd internal api 2>/dev/null || gofmt -w $(find . -name '*.go')
go test ./...
```

If `cmd/nodeagent/main.go` or `internal/nodeagent/manager.go` had a different structure, inspect those files manually and wire `explicitMockMode()` into the allocator creation.
MDEOF

echo
printf 'Patch complete. Backups saved in %s\n' "$BACKUP_DIR"
echo 'Run next:'
echo '  go mod tidy'
echo "  gofmt -w \\$(find . -name '*.go')"
echo '  go test ./...'
