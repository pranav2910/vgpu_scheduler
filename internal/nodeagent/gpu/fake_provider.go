//go:build !nvml

package gpu

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
)

// This is the DEFAULT provider (no `nvml` build tag). It synthesises a
// deterministic GPU inventory so the kind test path and CI need neither a GPU
// nor the NVIDIA driver. Behaviour is controlled by env vars so the deployed
// kind node-agent can model the cluster's advertised capacity:
//
//	VGPU_FAKE_GPU_COUNT      number of fake GPUs        (default 1)
//	VGPU_FAKE_GPU_MEM_BYTES  total VRAM per fake GPU    (default 80 GiB)
//	VGPU_FAKE_GPU_USED_BYTES used VRAM per fake GPU     (default 0)
//	VGPU_FAKE_FAIL           if truthy, ListDevices errors (exercise degraded mode)
//	VGPU_FAKE_UNHEALTHY_IDX  mark this device index unhealthy (default none)

// RealBuild reports whether this binary was compiled against real NVML.
// Default build → false (fake provider + mock allocator).
const RealBuild = false

const fakeDefaultGPUMemBytes = int64(80) << 30 // 80 GiB — matches the kind node model

type fakeProvider struct {
	devices   []GPUDevice
	processes []GPUProcess
	failErr   error // when set, list calls return this (degraded simulation)

	// procSeq, when non-nil, makes successive ListProcesses calls return each
	// list in order (repeating the last) — for tests exercising the
	// two-snapshot PID-reuse sandwich in attribution.
	procSeq [][]GPUProcess
	procIdx int
	mu      sync.Mutex
}

// NewProvider is the build-tag-selected constructor. The fake build never fails
// init (it returns a usable provider); VGPU_FAKE_FAIL only makes observations
// fail, exercising the same degraded path the real provider hits on hardware
// errors.
func NewProvider() (GPUProvider, error) {
	count := envInt("VGPU_FAKE_GPU_COUNT", 1)
	if count < 0 {
		count = 0 // a typo'd negative must degrade to "no GPUs", not panic the agent (makeslice: cap out of range)
	}
	mem := envInt64("VGPU_FAKE_GPU_MEM_BYTES", fakeDefaultGPUMemBytes)
	if mem < 0 {
		mem = 0
	}
	used := envInt64("VGPU_FAKE_GPU_USED_BYTES", 0)
	reserved := envInt64("VGPU_FAKE_GPU_RESERVED_BYTES", 0)
	if used+reserved > mem {
		used = mem - reserved
		if used < 0 {
			used, reserved = 0, mem
		}
	}
	unhealthyIdx := envInt("VGPU_FAKE_UNHEALTHY_IDX", -1)

	devices := make([]GPUDevice, 0, count)
	for i := 0; i < count; i++ {
		// v2 semantics: total = used + free + reserved.
		d := GPUDevice{
			UUID:                fmt.Sprintf("GPU-FAKE-%08d", i),
			Index:               i,
			Name:                "FAKE-GPU",
			TotalMemoryBytes:    mem,
			UsedMemoryBytes:     used,
			ReservedMemoryBytes: reserved,
			FreeMemoryBytes:     mem - used - reserved,
			Healthy:             true,
		}
		if i == unhealthyIdx {
			d.Healthy = false
			d.Error = "fake: marked unhealthy via VGPU_FAKE_UNHEALTHY_IDX"
			d.UsedMemoryBytes, d.FreeMemoryBytes, d.ReservedMemoryBytes = 0, 0, 0
		}
		devices = append(devices, d)
	}

	var failErr error
	if isTruthy(os.Getenv("VGPU_FAKE_FAIL")) {
		failErr = fmt.Errorf("fake: observation failure injected via VGPU_FAKE_FAIL")
	}
	return NewFakeProvider(devices, failErr), nil
}

// NewFakeProvider constructs a fake provider directly (used by unit tests).
func NewFakeProvider(devices []GPUDevice, failErr error) GPUProvider {
	return &fakeProvider{devices: devices, failErr: failErr}
}

// NewFakeProviderWithProcessSequence constructs a fake whose successive
// ListProcesses calls return each given list in order, repeating the last.
// Lets tests drive the two-snapshot PID-reuse sandwich (a PID present in
// snapshot #1 but gone in #2 must not be attributed).
func NewFakeProviderWithProcessSequence(devices []GPUDevice, seq ...[]GPUProcess) GPUProvider {
	return &fakeProvider{devices: devices, procSeq: seq}
}

func (f *fakeProvider) Name() string { return "fake" }

func (f *fakeProvider) ListDevices(context.Context) ([]GPUDevice, error) {
	if f.failErr != nil {
		return nil, f.failErr
	}
	out := make([]GPUDevice, len(f.devices))
	copy(out, f.devices)
	return out, nil
}

func (f *fakeProvider) GetDevice(_ context.Context, uuid string) (*GPUDevice, error) {
	if f.failErr != nil {
		return nil, f.failErr
	}
	for i := range f.devices {
		if f.devices[i].UUID == uuid {
			d := f.devices[i]
			return &d, nil
		}
	}
	return nil, fmt.Errorf("fake: device %q not found", uuid)
}

func (f *fakeProvider) ListProcesses(context.Context) ([]GPUProcess, error) {
	if f.failErr != nil {
		return nil, f.failErr
	}
	if f.procSeq != nil {
		f.mu.Lock()
		i := f.procIdx
		if i >= len(f.procSeq) {
			i = len(f.procSeq) - 1
		} else {
			f.procIdx++
		}
		f.mu.Unlock()
		out := make([]GPUProcess, len(f.procSeq[i]))
		copy(out, f.procSeq[i])
		return out, nil
	}
	out := make([]GPUProcess, len(f.processes))
	copy(out, f.processes)
	return out, nil
}

func (f *fakeProvider) Shutdown() error { return nil }

// ── small env helpers (shared by the fake provider + collector wiring) ───────

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envInt64(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}

func isTruthy(v string) bool {
	switch v {
	case "1", "true", "yes", "TRUE", "True":
		return true
	}
	return false
}
