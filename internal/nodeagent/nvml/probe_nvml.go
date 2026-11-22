//go:build nvml

package nvml

import (
	"fmt"

	"github.com/NVIDIA/go-nvml/pkg/nvml"
)

// CheckHardwareHealth probes every GPU on the node. Bug #20: the old version
// only probed device 0, so GPUs 1–7 could fall off the bus undetected on a
// multi-GPU host. Real implementation — compiled only with `-tags nvml`.
func (a *Allocator) CheckHardwareHealth() error {
	if !a.initialized {
		return fmt.Errorf("NVML not initialized")
	}
	if a.mockMode {
		return nil
	}
	count, ret := nvml.DeviceGetCount()
	if ret != nvml.SUCCESS {
		return fmt.Errorf("DeviceGetCount failed: %v", nvml.ErrorString(ret))
	}
	for i := 0; i < count; i++ {
		if _, r := nvml.DeviceGetHandleByIndex(i); r != nvml.SUCCESS {
			return fmt.Errorf("GPU %d health check failed: %v", i, nvml.ErrorString(r))
		}
	}
	return nil
}
