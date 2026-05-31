package nvml

import (
	"context"
	"log"
	"time"
)

// StartHealthProbe runs CheckHardwareHealth on a timer. Bug #20 fix — the
// probe function existed but nothing ever called it.
//
// CheckHardwareHealth itself is build-tagged: the real NVML implementation
// lives in probe_nvml.go (//go:build nvml); the default build uses the mock in
// probe_fake.go, so this package links go-nvml only in the `nvml` build.
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
