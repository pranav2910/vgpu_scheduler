//go:build nvml

package gpu

import (
	"context"
	"fmt"

	"github.com/NVIDIA/go-nvml/pkg/nvml"
)

// This file is compiled only with `-tags nvml`. It is the sole place the
// default-build observation path touches the NVIDIA driver, so the default
// node-agent binary neither imports nor links go-nvml for GPU discovery.
//
//	go build -tags nvml ./cmd/nodeagent   # real-hardware build (g5)

// RealBuild reports whether this binary was compiled against real NVML.
// nvml build → true (real provider + real allocator).
const RealBuild = true

type nvmlProvider struct{}

// NewProvider initialises NVML. On any init failure (driver missing, library
// absent, permission denied) it returns an error; the caller wraps it in a
// degraded provider so the agent stays up and reports the failure via metrics
// rather than crashing.
func NewProvider() (GPUProvider, error) {
	if ret := nvml.Init(); ret != nvml.SUCCESS {
		return nil, fmt.Errorf("nvml.Init: %s", nvml.ErrorString(ret))
	}
	return &nvmlProvider{}, nil
}

func (p *nvmlProvider) Name() string { return "nvml" }

func (p *nvmlProvider) ListDevices(_ context.Context) ([]GPUDevice, error) {
	count, ret := nvml.DeviceGetCount()
	if ret != nvml.SUCCESS {
		// Whole-node query failed → degraded; caller marks the snapshot errored.
		return nil, fmt.Errorf("nvml.DeviceGetCount: %s", nvml.ErrorString(ret))
	}
	devices := make([]GPUDevice, 0, count)
	for i := 0; i < count; i++ {
		devices = append(devices, queryDevice(i))
	}
	return devices, nil
}

func (p *nvmlProvider) GetDevice(ctx context.Context, uuid string) (*GPUDevice, error) {
	devices, err := p.ListDevices(ctx)
	if err != nil {
		return nil, err
	}
	for i := range devices {
		if devices[i].UUID == uuid {
			d := devices[i]
			return &d, nil
		}
	}
	return nil, fmt.Errorf("nvml: device %q not found", uuid)
}

func (p *nvmlProvider) Shutdown() error {
	if ret := nvml.Shutdown(); ret != nvml.SUCCESS {
		return fmt.Errorf("nvml.Shutdown: %s", nvml.ErrorString(ret))
	}
	return nil
}

// queryDevice reads one GPU. A per-device failure marks THAT device unhealthy
// (so a single GPU falling off the bus doesn't blank the rest of the node) and
// zeroes its memory figures (an unhealthy GPU's capacity is unknown, not free).
func queryDevice(i int) GPUDevice {
	d := GPUDevice{Index: i, Healthy: true}

	handle, ret := nvml.DeviceGetHandleByIndex(i)
	if ret != nvml.SUCCESS {
		return unhealthy(i, fmt.Sprintf("DeviceGetHandleByIndex(%d): %s", i, nvml.ErrorString(ret)))
	}

	uuid, ret := handle.GetUUID()
	if ret != nvml.SUCCESS || uuid == "" {
		// Keep a stable label even when UUID is unreadable.
		uuid = fmt.Sprintf("GPU-INDEX-%d", i)
	}
	d.UUID = uuid

	if name, ret := handle.GetName(); ret == nvml.SUCCESS {
		d.Name = name
	}

	mem, ret := handle.GetMemoryInfo()
	if ret != nvml.SUCCESS {
		return unhealthy(i, fmt.Sprintf("GetMemoryInfo(%d): %s", i, nvml.ErrorString(ret)))
	}
	d.TotalMemoryBytes = int64(mem.Total)
	d.UsedMemoryBytes = int64(mem.Used)
	d.FreeMemoryBytes = int64(mem.Free)
	return d
}

func unhealthy(i int, reason string) GPUDevice {
	return GPUDevice{
		UUID:    fmt.Sprintf("GPU-INDEX-%d", i),
		Index:   i,
		Healthy: false,
		Error:   reason,
	}
}
