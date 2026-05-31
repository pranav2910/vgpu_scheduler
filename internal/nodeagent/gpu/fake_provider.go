//go:build !nvml

package gpu

import (
	"context"
	"fmt"
	"os"
	"strconv"
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
	devices []GPUDevice
	failErr error // when set, ListDevices/GetDevice return this (degraded simulation)
}

// NewProvider is the build-tag-selected constructor. The fake build never fails
// init (it returns a usable provider); VGPU_FAKE_FAIL only makes observations
// fail, exercising the same degraded path the real provider hits on hardware
// errors.
func NewProvider() (GPUProvider, error) {
	count := envInt("VGPU_FAKE_GPU_COUNT", 1)
	mem := envInt64("VGPU_FAKE_GPU_MEM_BYTES", fakeDefaultGPUMemBytes)
	used := envInt64("VGPU_FAKE_GPU_USED_BYTES", 0)
	if used > mem {
		used = mem
	}
	unhealthyIdx := envInt("VGPU_FAKE_UNHEALTHY_IDX", -1)

	devices := make([]GPUDevice, 0, count)
	for i := 0; i < count; i++ {
		d := GPUDevice{
			UUID:             fmt.Sprintf("GPU-FAKE-%08d", i),
			Index:            i,
			Name:             "FAKE-GPU",
			TotalMemoryBytes: mem,
			UsedMemoryBytes:  used,
			FreeMemoryBytes:  mem - used,
			Healthy:          true,
		}
		if i == unhealthyIdx {
			d.Healthy = false
			d.Error = "fake: marked unhealthy via VGPU_FAKE_UNHEALTHY_IDX"
			d.UsedMemoryBytes, d.FreeMemoryBytes = 0, 0
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
