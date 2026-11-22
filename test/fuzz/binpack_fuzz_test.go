package fuzz

import (
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
)

// FuzzVRAMCache ensures the cache never panics on arbitrary byte inputs.
func FuzzVRAMCache(f *testing.F) {
	f.Add(int64(85_899_345_920), int64(8_589_934_592)) // 80 GiB node, 8 GiB request

	f.Fuzz(func(t *testing.T, totalVRAM int64, request int64) {
		cache := scheduler.NewVRAMCache()
		cache.UpdateNode("node-1", totalVRAM, 0) // fixed: UpdateNode added in FIX 8

		// AssumeSlice is the correct cache primitive (Reserve wraps it).
		err := cache.AssumeSlice("fuzz-slice", "default", "node-1", request, 30*time.Second)
		if (request <= 0 || request > totalVRAM) && err == nil {
			t.Errorf("Cache allowed invalid reservation: total=%d, request=%d", totalVRAM, request)
		}
	})
}
