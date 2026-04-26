package nvml

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/NVIDIA/go-nvml/pkg/nvml"
)

// CheckHardwareHealth probes every GPU on the node. Bug #20: the old version
// only probed device 0, so GPUs 1–7 could fall off the bus undetected on a
// multi-GPU host.
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

// StartHealthProbe runs CheckHardwareHealth on a timer. Bug #20 fix — the
// probe function existed but nothing ever called it.
func (a *Allocator) StartHealthProbe(ctx context.Context, interval time.Duration, onUnhealthy func(error)) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := a.CheckHardwareHealth(); err != nil {
					log.Printf("NVML health probe FAILED: %v", err)
					if onUnhealthy != nil {
						onUnhealthy(err)
					}
				}
			case <-ctx.Done():
				return
			}
		}
	}()
}
