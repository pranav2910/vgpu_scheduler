//go:build nvml

package nvml

import (
	"fmt"

	nvmllib "github.com/NVIDIA/go-nvml/pkg/nvml"
)

// physicalGPUUUID returns the TRUE UUID of the node's GPU (index 0 — this product
// models one GPU per node). Compiled only with -tags nvml; this is the sole place
// the allocator touches the NVIDIA driver. Init/Shutdown are balanced and NVML's
// init is ref-counted, so this is safe alongside the long-lived observation
// provider's NVML session.
//
// This records WHICH physical GPU a slice is bound to. Letting the container
// actually open that GPU (device nodes + driver libraries) is the job of the CDI
// spec + the NVIDIA container runtime, finalized and validated on real hardware.
func physicalGPUUUID() (string, error) {
	if ret := nvmllib.Init(); ret != nvmllib.SUCCESS {
		return "", fmt.Errorf("nvml init: %s", nvmllib.ErrorString(ret))
	}
	defer nvmllib.Shutdown()

	handle, ret := nvmllib.DeviceGetHandleByIndex(0)
	if ret != nvmllib.SUCCESS {
		return "", fmt.Errorf("nvml get device 0: %s", nvmllib.ErrorString(ret))
	}
	uuid, ret := handle.GetUUID()
	if ret != nvmllib.SUCCESS {
		return "", fmt.Errorf("nvml get uuid: %s", nvmllib.ErrorString(ret))
	}
	return uuid, nil
}
