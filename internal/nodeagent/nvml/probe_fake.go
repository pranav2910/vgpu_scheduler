//go:build !nvml

package nvml

import "fmt"

// CheckHardwareHealth is the default-build (mock) health check. It performs no
// real probing — the mock allocator has no physical GPUs to fall off the bus —
// and reports healthy. This is what keeps the default node-agent binary free of
// the go-nvml dependency. Real hardware health lives in probe_nvml.go.
func (a *Allocator) CheckHardwareHealth() error {
	if !a.initialized {
		return fmt.Errorf("allocator not initialized")
	}
	return nil
}
