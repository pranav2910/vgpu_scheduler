//go:build !nvml

package nvml

import "fmt"

// enumerateDevices is the default (no real NVML) stub. Real hardware
// enumeration requires the nvml build tag; the default build runs the
// allocator in mock mode, which synthesizes devices from the VGPU_FAKE_*
// env knobs instead of calling this. Keeping this behind a build tag means
// the default node-agent binary never imports or links go-nvml.
func enumerateDevices() ([]allocDevice, error) {
	return nil, fmt.Errorf("real GPU enumeration requires the nvml build tag (default build must use mock mode)")
}
