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
// nvml build → true. NOTE: this makes the *observation* path real (discovery,
// memory accounting, process listing, drift/over-use detection). It does NOT yet
// make allocation real — internal/nodeagent/nvml/allocator.go still returns a
// synthetic handle on every build (no MIG/MPS partition, no CDI device nodes).
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

func (p *nvmlProvider) ListProcesses(_ context.Context) ([]GPUProcess, error) {
	count, ret := nvml.DeviceGetCount()
	if ret != nvml.SUCCESS {
		return nil, fmt.Errorf("nvml.DeviceGetCount: %s", nvml.ErrorString(ret))
	}
	var procs []GPUProcess
	for i := 0; i < count; i++ {
		handle, ret := nvml.DeviceGetHandleByIndex(i)
		if ret != nvml.SUCCESS {
			continue // a single bad device must not blank the rest
		}
		uuid, ret := handle.GetUUID()
		if ret != nvml.SUCCESS || uuid == "" {
			uuid = fmt.Sprintf("GPU-INDEX-%d", i)
		}
		// Dedupe by PID per device: a process holding BOTH a compute and a
		// graphics context (nvidia-smi type "C+G" — CUDA/GL interop) is reported
		// in both lists, each entry carrying its FB usage. Consumers sum our
		// entries per pod/slice, so emitting both would double-count such a
		// process — inflated usage that can cross the violation threshold and,
		// in evict mode, evict a compliant pod. Keep the max of the two figures
		// (they are normally identical).
		perPID := make(map[int]int64)
		for _, getter := range []func() ([]nvml.ProcessInfo, nvml.Return){
			handle.GetComputeRunningProcesses,
			handle.GetGraphicsRunningProcesses,
		} {
			infos, ret := getter()
			if ret != nvml.SUCCESS {
				continue
			}
			for _, pi := range infos {
				used := int64(pi.UsedGpuMemory)
				if used < 0 {
					used = 0 // NVML_VALUE_NOT_AVAILABLE sentinel → unknown
				}
				pid := int(pi.Pid)
				if cur, seen := perPID[pid]; !seen || used > cur {
					perPID[pid] = used
				}
			}
		}
		for pid, used := range perPID {
			procs = append(procs, GPUProcess{
				PID:             pid,
				DeviceUUID:      uuid,
				UsedMemoryBytes: used,
			})
		}
	}
	return procs, nil
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

	// Prefer GetMemoryInfo_v2, which separates driver-Reserved memory from Used
	// (Total = Used + Free + Reserved). Fall back to v1 on any driver that
	// doesn't support it — v1 rolls Reserved into Used (Total = Used + Free).
	if mem2, ret := handle.GetMemoryInfo_v2(); ret == nvml.SUCCESS && mem2.Total > 0 {
		d.TotalMemoryBytes = int64(mem2.Total)
		d.UsedMemoryBytes = int64(mem2.Used)
		d.FreeMemoryBytes = int64(mem2.Free)
		d.ReservedMemoryBytes = int64(mem2.Reserved)
		return d
	}
	mem, ret := handle.GetMemoryInfo()
	if ret != nvml.SUCCESS {
		return unhealthy(i, fmt.Sprintf("GetMemoryInfo(%d): %s", i, nvml.ErrorString(ret)))
	}
	d.TotalMemoryBytes = int64(mem.Total)
	d.UsedMemoryBytes = int64(mem.Used) // v1: includes reserved
	d.FreeMemoryBytes = int64(mem.Free)
	// ReservedMemoryBytes left 0 — v1 does not separate it.
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
