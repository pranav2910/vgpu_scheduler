# vGPU Scheduler Bug Fix Code — File by File

## 1) `go.mod`
Fix: do not force unreleased/new toolchain. Use Go 1.22 and Kubernetes/controller-runtime versions that work together.

```go
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
```

After replacing, run:

```bash
go mod tidy
```

---

## 2) `internal/nodeagent/nvml/allocator.go`
Fix: fail closed. Do not pretend real NVML allocation works. Mock must be explicit.

```go
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
		return nil, fmt.Errorf("real NVML allocation is not implemented yet; run with explicit mock mode only for development")
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
```

---

## 3) `cmd/nodeagent/main.go`
Fix: mock mode should not silently default to true.

Add this helper:

```go
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
```

Then wherever you create the allocator/manager, make sure it receives explicit mock behavior. If your `nodeagent.NewManager` currently creates the allocator internally, change manager construction like this:

```go
mockMode := explicitMockMode()
mgr := nodeagent.NewManagerWithAllocator(
	nodeName,
	ctrlMgr.GetClient(),
	nvml.NewAllocator(mockMode),
)
```

---

## 4) `internal/nodeagent/manager.go`
Fix: dependency injection for allocator, instead of hiding mock-mode inside manager.

Add this constructor:

```go
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
```

Keep the old constructor only for tests:

```go
func NewManager(nodeName string, k8sClient client.Client) *Manager {
	return NewManagerWithAllocator(nodeName, k8sClient, nvml.NewAllocator(true))
}
```

---

## 5) `internal/nodeagent/checkpoint/checkpoint.go`
Fix: atomic checkpoint writes. Current direct `os.WriteFile` can corrupt state if the process crashes mid-write.

Add this helper:

```go
func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
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
```

Replace both checkpoint writes:

```go
return atomicWriteFile(s.path(), out, 0640)
```

---

## 6) `internal/scheduler/cache.go`
Fix: no double-counting on restart, no zero-byte release, and allow scheduler cache rebuild from existing slices.

Add these types and methods:

```go
type SliceAllocationSnapshot struct {
	SliceUID       string
	NodeName       string
	Phase          string
	AllocatedBytes int64
	ReservedBytes  int64
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
				c.confirmedBySlice[s.SliceUID] = &AssumedAllocation{
					SliceUID:           s.SliceUID,
					NodeName:           s.NodeName,
					RequestedVRAMBytes: reserved,
				}
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
```

Then change `SyncCacheFromSlice` in `internal/scheduler/plugin.go` to handle the new error:

```go
func (s *SliceScheduler) SyncCacheFromSlice(sliceUID, nodeName, phase string, allocatedBytes int64) {
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
}
```

---

## 7) `internal/scheduler/plugin.go`
Fix: avoid `Scheduled` status with empty `spec.nodeName`.

Replace `bindToKubernetesAPI` with:

```go
func (s *SliceScheduler) bindToKubernetesAPI(ctx context.Context, nn types.NamespacedName, nodeName string) error {
	var target vgpuv1alpha1.VGPUSlice
	if err := s.K8sClient.Get(ctx, nn, &target); err != nil {
		return fmt.Errorf("fetching slice %s: %w", nn, err)
	}

	if target.Spec.NodeName != "" && target.Spec.NodeName != nodeName {
		return fmt.Errorf("slice already bound to different node %q", target.Spec.NodeName)
	}

	// Spec first: NodeAgent can only act when nodeName is visible.
	specBase := client.MergeFrom(target.DeepCopy())
	target.Spec.NodeName = nodeName
	if err := s.K8sClient.Patch(ctx, &target, specBase); err != nil {
		return fmt.Errorf("patching spec.nodeName: %w", err)
	}

	statusBase := client.MergeFrom(target.DeepCopy())
	target.Status.Phase = vgpuv1alpha1.VGPUSlicePhase("Scheduled")
	if err := s.K8sClient.Status().Patch(ctx, &target, statusBase); err != nil {
		// Best-effort revert so the reservation rollback can make the object schedulable again.
		var fresh vgpuv1alpha1.VGPUSlice
		if getErr := s.K8sClient.Get(ctx, nn, &fresh); getErr == nil {
			revertBase := client.MergeFrom(fresh.DeepCopy())
			fresh.Spec.NodeName = ""
			_ = s.K8sClient.Patch(ctx, &fresh, revertBase)
		}
		return fmt.Errorf("patching status.phase to Scheduled: %w", err)
	}

	return nil
}
```

---

## 8) `cmd/scheduler/main.go`
Fix: rebuild scheduler cache from existing `VGPUSlice` objects after restart.

Update `seedRunnable.Start`:

```go
func (s *seedRunnable) Start(ctx context.Context) error {
	if err := seedCacheFromNodes(ctx, s.client, s.cache); err != nil {
		log.Printf("WARNING: seed from nodes failed: %v", err)
	}
	if err := seedCacheFromSlices(ctx, s.client, s.cache); err != nil {
		log.Printf("WARNING: seed from slices failed: %v", err)
	}
	<-ctx.Done()
	return nil
}
```

Add:

```go
func seedCacheFromSlices(ctx context.Context, k8sClient client.Client, cache *scheduler.VRAMCache) error {
	var sliceList vgpuv1alpha1.VGPUSliceList
	if err := k8sClient.List(ctx, &sliceList); err != nil {
		return fmt.Errorf("listing slices: %w", err)
	}

	snapshots := make([]scheduler.SliceAllocationSnapshot, 0, len(sliceList.Items))
	for i := range sliceList.Items {
		s := &sliceList.Items[i]
		if s.Spec.NodeName == "" {
			continue
		}
		snapshots = append(snapshots, scheduler.SliceAllocationSnapshot{
			SliceUID:       string(s.UID),
			NodeName:       s.Spec.NodeName,
			Phase:          string(s.Status.Phase),
			AllocatedBytes: s.Status.AllocatedBytes,
			ReservedBytes:  s.Spec.RequestedVRAMBytes,
		})
	}
	cache.RebuildSliceState(snapshots)
	return nil
}
```

---

## 9) `internal/controller/vgpuslice_reconciler.go`
Fix: deletion should not rely forever on external events. Always requeue while releasing.

Replace the end of `handleDelete` with:

```go
if currentPhase == state.SlicePhaseReleased {
	log.Printf("Hardware freed. Removing finalizer from Slice %s", slice.Name)
	key := types.NamespacedName{Namespace: slice.Namespace, Name: slice.Name}
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUSlice
		if err := r.Client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		if !RemoveFinalizer(&fresh, SliceFinalizerName) {
			return nil
		}
		return r.Client.Update(ctx, &fresh)
	})
}

return PatchSliceStatus(ctx, r.Client, slice, func() {
	if string(slice.Status.Phase) != state.SlicePhaseReleasing {
		_ = state.TransitionSlicePhase(slice, state.SlicePhaseReleasing, "DeleteRequested", "Deletion requested")
	}
})
```

The parent `Reconcile` already returns `RequeueAfter: 5 * time.Second` while deletion is not complete.
