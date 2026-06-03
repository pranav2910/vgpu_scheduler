//go:build !nvml

package gpu

import (
	"context"
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestNewProvider_FakeFromEnv(t *testing.T) {
	t.Setenv("VGPU_FAKE_GPU_COUNT", "2")
	t.Setenv("VGPU_FAKE_GPU_MEM_BYTES", "1000")
	t.Setenv("VGPU_FAKE_GPU_USED_BYTES", "250")

	p, err := NewProvider()
	if err != nil {
		t.Fatalf("NewProvider: %v", err)
	}
	if p.Name() != "fake" {
		t.Fatalf("Name: got %q want fake", p.Name())
	}
	devices, err := p.ListDevices(context.Background())
	if err != nil {
		t.Fatalf("ListDevices: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("device count: got %d want 2", len(devices))
	}
	d := devices[0]
	if d.TotalMemoryBytes != 1000 || d.UsedMemoryBytes != 250 || d.FreeMemoryBytes != 750 || !d.Healthy {
		t.Fatalf("device0 wrong: %+v", d)
	}
	if got, err := p.GetDevice(context.Background(), d.UUID); err != nil || got.UUID != d.UUID {
		t.Fatalf("GetDevice(%s): got=%+v err=%v", d.UUID, got, err)
	}
}

func TestNewProvider_FakeReserved_V2Semantics(t *testing.T) {
	t.Setenv("VGPU_FAKE_GPU_COUNT", "1")
	t.Setenv("VGPU_FAKE_GPU_MEM_BYTES", "1000")
	t.Setenv("VGPU_FAKE_GPU_USED_BYTES", "100")
	t.Setenv("VGPU_FAKE_GPU_RESERVED_BYTES", "200")

	p, err := NewProvider()
	if err != nil {
		t.Fatalf("NewProvider: %v", err)
	}
	d, err := p.ListDevices(context.Background())
	if err != nil || len(d) != 1 {
		t.Fatalf("ListDevices: %v (n=%d)", err, len(d))
	}
	g := d[0]
	if g.UsedMemoryBytes != 100 || g.ReservedMemoryBytes != 200 || g.FreeMemoryBytes != 700 {
		t.Fatalf("v2 fake: used=%d reserved=%d free=%d, want 100/200/700",
			g.UsedMemoryBytes, g.ReservedMemoryBytes, g.FreeMemoryBytes)
	}
	// Invariant: total = used + free + reserved.
	if g.UsedMemoryBytes+g.FreeMemoryBytes+g.ReservedMemoryBytes != g.TotalMemoryBytes {
		t.Fatalf("v2 invariant broken: %d + %d + %d != %d",
			g.UsedMemoryBytes, g.FreeMemoryBytes, g.ReservedMemoryBytes, g.TotalMemoryBytes)
	}
}

func TestNewProvider_FakeFailInjection(t *testing.T) {
	t.Setenv("VGPU_FAKE_FAIL", "true")
	p, err := NewProvider()
	if err != nil {
		t.Fatalf("NewProvider should not error on init even with VGPU_FAKE_FAIL; got %v", err)
	}
	if _, err := p.ListDevices(context.Background()); err == nil {
		t.Fatalf("ListDevices should fail when VGPU_FAKE_FAIL is set")
	}
}

func TestCollector_CollectOnce_PopulatesInventoryAndMetrics(t *testing.T) {
	provider := NewFakeProvider([]GPUDevice{
		dev("GPU-0", 100, 40, true),
		dev("GPU-1", 100, 10, true),
	}, nil)
	c := NewCollector(provider, "node-x", time.Minute, 250) // expected 250 → drift = 200-250 = -50
	c.collectOnce(context.Background())

	devices, _, errStr := c.Inventory().Snapshot()
	if len(devices) != 2 || errStr != "" {
		t.Fatalf("inventory after collect: len=%d err=%q", len(devices), errStr)
	}
	if got := testutil.ToFloat64(telemetry.GPUDeviceFreeBytes.WithLabelValues("node-x", "GPU-0")); got != 60 {
		t.Fatalf("GPU-0 free metric: got %v want 60", got)
	}
	if got := testutil.ToFloat64(telemetry.GPUDeviceHealthy.WithLabelValues("node-x", "GPU-1")); got != 1 {
		t.Fatalf("GPU-1 healthy metric: got %v want 1", got)
	}
	if got := testutil.ToFloat64(telemetry.GPUCapacityDriftBytes.WithLabelValues("node-x")); got != -50 {
		t.Fatalf("drift metric: got %v want -50", got)
	}
}

func TestCollector_CollectOnce_DegradedOnError(t *testing.T) {
	errsBefore := testutil.ToFloat64(telemetry.GPUObservationErrors.WithLabelValues("node-err"))
	provider := NewDegradedProvider(context.DeadlineExceeded)
	c := NewCollector(provider, "node-err", time.Minute, 0)
	c.collectOnce(context.Background())

	_, _, errStr := c.Inventory().Snapshot()
	if errStr == "" {
		t.Fatalf("inventory should record an observation error in degraded mode")
	}
	if got := testutil.ToFloat64(telemetry.GPUObservationErrors.WithLabelValues("node-err")); got != errsBefore+1 {
		t.Fatalf("observation errors: got %v want %v", got, errsBefore+1)
	}
}
