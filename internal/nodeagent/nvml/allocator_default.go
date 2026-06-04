//go:build !nvml

package nvml

// physicalGPUUUID is the default (no real NVML) stub: it returns an empty string
// so Allocate falls back to a synthetic GPU-MOCK UUID. The real implementation
// lives in allocator_nvml.go (built with -tags nvml). Keeping this behind a build
// tag means the default node-agent binary never imports or links go-nvml.
func physicalGPUUUID() (string, error) { return "", nil }
