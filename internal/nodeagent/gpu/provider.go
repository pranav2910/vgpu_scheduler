// Package gpu provides read-only observation of the node's physical GPUs.
//
// Phase 3.1 ("NVML hardware-truth scaffolding") is deliberately observation
// only: it discovers GPUs, reports their VRAM and health, and surfaces drift
// between observed hardware and the capacity the scheduler assumes. It does NOT
// enforce limits, create MIG partitions, evict processes, or write the node's
// advertised capacity — those are later phases.
//
// The real implementation lives behind the `nvml` build tag (nvml_provider.go);
// the default build uses a deterministic fake (fake_provider.go), so the kind
// test path never needs a GPU or the NVIDIA driver.
package gpu

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// GPUProvider is a read-only source of GPU truth. Implementations must be safe
// for concurrent use.
type GPUProvider interface {
	// Name identifies the active implementation ("fake" | "nvml" | "degraded").
	Name() string
	// ListDevices returns the current state of every GPU on the node.
	ListDevices(ctx context.Context) ([]GPUDevice, error)
	// GetDevice returns a single device by UUID, or an error if absent.
	GetDevice(ctx context.Context, uuid string) (*GPUDevice, error)
	// ListProcesses returns the GPU-using processes across all devices (Phase
	// 3.4b attribution). PIDs are in the host PID namespace.
	ListProcesses(ctx context.Context) ([]GPUProcess, error)
	// Shutdown releases any provider resources (e.g. nvml.Shutdown()).
	Shutdown() error
}

// GPUProcess is one process holding VRAM on a GPU, as reported by NVML. The PID
// is in the host PID namespace (so reading /proc/<pid>/cgroup requires hostPID).
type GPUProcess struct {
	PID             int
	DeviceUUID      string
	UsedMemoryBytes int64
}

// GPUDevice is a point-in-time observation of one physical GPU. Memory figures
// are in bytes. When Healthy is false, Error explains why and the memory
// figures should be treated as unknown (they are zeroed).
type GPUDevice struct {
	UUID  string
	Index int
	Name  string
	// Memory figures follow NVML's v2 accounting (Total = Used + Free + Reserved):
	//   Used     = active/process-allocated memory
	//   Reserved = driver/device-reserved memory (NVML v1 lumps this into Used)
	//   Free     = allocatable free memory — the SCHEDULING-RELEVANT value
	TotalMemoryBytes    int64
	UsedMemoryBytes     int64
	FreeMemoryBytes     int64
	ReservedMemoryBytes int64
	Healthy             bool
	Error               string
}

// Aggregate is the node-level rollup of a device snapshot.
type Aggregate struct {
	DeviceCount   int
	HealthyCount  int
	TotalBytes    int64 // summed over healthy devices
	UsedBytes     int64 // summed over healthy devices
	FreeBytes     int64 // summed over healthy devices
	ReservedBytes int64 // summed over healthy devices
	AllHealthy    bool
}

// Inventory holds the most recent device snapshot and the time it was taken.
// It is the in-memory "observed truth" surface (Phase 3.1 keeps observed state
// in-process + metrics only — no CRD).
type Inventory struct {
	mu       sync.RWMutex
	devices  []GPUDevice
	observed time.Time
	lastErr  string
}

// NewInventory returns an empty inventory.
func NewInventory() *Inventory { return &Inventory{} }

// Update replaces the snapshot. observedAt is passed in (not read from the
// clock) so callers and tests stay deterministic.
func (i *Inventory) Update(devices []GPUDevice, observedAt time.Time) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.devices = devices
	i.observed = observedAt
	i.lastErr = ""
}

// MarkError records that the most recent observation failed. The previous
// snapshot is retained (stale) so consumers can distinguish "no GPUs" from
// "couldn't look".
func (i *Inventory) MarkError(observedAt time.Time, err string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.observed = observedAt
	i.lastErr = err
}

// Snapshot returns a copy of the current devices, the observation time, and the
// last error (empty if the last observation succeeded).
func (i *Inventory) Snapshot() ([]GPUDevice, time.Time, string) {
	i.mu.RLock()
	defer i.mu.RUnlock()
	out := make([]GPUDevice, len(i.devices))
	copy(out, i.devices)
	return out, i.observed, i.lastErr
}

// Aggregate rolls the current snapshot up to node level. Only healthy devices
// contribute to the byte totals (an unhealthy GPU's capacity is not real).
func (i *Inventory) Aggregate() Aggregate {
	i.mu.RLock()
	defer i.mu.RUnlock()
	return aggregate(i.devices)
}

func aggregate(devices []GPUDevice) Aggregate {
	a := Aggregate{DeviceCount: len(devices), AllHealthy: len(devices) > 0}
	for _, d := range devices {
		if !d.Healthy {
			a.AllHealthy = false
			continue
		}
		a.HealthyCount++
		a.TotalBytes += d.TotalMemoryBytes
		a.UsedBytes += d.UsedMemoryBytes
		a.FreeBytes += d.FreeMemoryBytes
		a.ReservedBytes += d.ReservedMemoryBytes
	}
	if len(devices) == 0 {
		a.AllHealthy = false
	}
	return a
}

// DriftBytes reports observed-healthy-total minus an expected total (e.g. the
// node's advertised vgpu-bytes capacity). Positive => hardware shows more VRAM
// than the scheduler assumes; negative => less (the dangerous direction —
// scheduler may over-admit relative to real hardware). expected <= 0 means "no
// expectation configured" and returns (0, false).
func (i *Inventory) DriftBytes(expected int64) (int64, bool) {
	if expected <= 0 {
		return 0, false
	}
	return i.Aggregate().TotalBytes - expected, true
}

// degradedProvider is returned when the real provider cannot initialise (NVML
// missing, driver absent, permission denied). It keeps the agent running: every
// observation fails loudly via metrics/logs, but nothing crashes and no
// scheduler state is touched.
type degradedProvider struct{ err error }

// NewDegradedProvider wraps an init error as a provider whose every call fails.
func NewDegradedProvider(err error) GPUProvider { return &degradedProvider{err: err} }

func (d *degradedProvider) Name() string { return "degraded" }

func (d *degradedProvider) ListDevices(context.Context) ([]GPUDevice, error) {
	return nil, fmt.Errorf("GPU provider degraded: %w", d.err)
}

func (d *degradedProvider) GetDevice(context.Context, string) (*GPUDevice, error) {
	return nil, fmt.Errorf("GPU provider degraded: %w", d.err)
}

func (d *degradedProvider) ListProcesses(context.Context) ([]GPUProcess, error) {
	return nil, fmt.Errorf("GPU provider degraded: %w", d.err)
}

func (d *degradedProvider) Shutdown() error { return nil }
