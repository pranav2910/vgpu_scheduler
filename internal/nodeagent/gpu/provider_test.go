package gpu

import (
	"context"
	"testing"
	"time"
)

func dev(uuid string, total, used int64, healthy bool) GPUDevice {
	d := GPUDevice{UUID: uuid, Name: "T", TotalMemoryBytes: total, UsedMemoryBytes: used, FreeMemoryBytes: total - used, Healthy: healthy}
	if !healthy {
		d.TotalMemoryBytes, d.UsedMemoryBytes, d.FreeMemoryBytes = 0, 0, 0
		d.Error = "down"
	}
	return d
}

func TestAggregate_HealthyOnly(t *testing.T) {
	a := aggregate([]GPUDevice{
		dev("a", 100, 30, true),
		dev("b", 200, 50, true),
		dev("c", 0, 0, false), // unhealthy: excluded from byte totals
	})
	if a.DeviceCount != 3 {
		t.Fatalf("DeviceCount: got %d want 3", a.DeviceCount)
	}
	if a.HealthyCount != 2 {
		t.Fatalf("HealthyCount: got %d want 2", a.HealthyCount)
	}
	if a.TotalBytes != 300 || a.UsedBytes != 80 || a.FreeBytes != 220 {
		t.Fatalf("totals: got total=%d used=%d free=%d want 300/80/220", a.TotalBytes, a.UsedBytes, a.FreeBytes)
	}
	if a.AllHealthy {
		t.Fatalf("AllHealthy should be false when a device is unhealthy")
	}
}

func TestAggregate_SumsReserved(t *testing.T) {
	a := dev("a", 100, 30, true)
	a.ReservedMemoryBytes = 10
	a.FreeMemoryBytes = 60 // total(100) - used(30) - reserved(10)
	b := dev("b", 200, 40, true)
	b.ReservedMemoryBytes = 20
	b.FreeMemoryBytes = 140
	agg := aggregate([]GPUDevice{a, b})
	if agg.ReservedBytes != 30 || agg.UsedBytes != 70 || agg.FreeBytes != 200 || agg.TotalBytes != 300 {
		t.Fatalf("aggregate with reserved: %+v", agg)
	}
}

func TestAggregate_Empty(t *testing.T) {
	a := aggregate(nil)
	if a.DeviceCount != 0 || a.HealthyCount != 0 || a.TotalBytes != 0 || a.AllHealthy {
		t.Fatalf("empty aggregate wrong: %+v", a)
	}
}

func TestInventory_UpdateSnapshotIsolation(t *testing.T) {
	inv := NewInventory()
	now := time.Unix(1000, 0)
	src := []GPUDevice{dev("a", 100, 10, true)}
	inv.Update(src, now)

	got, ts, errStr := inv.Snapshot()
	if len(got) != 1 || ts != now || errStr != "" {
		t.Fatalf("snapshot: got len=%d ts=%v err=%q", len(got), ts, errStr)
	}
	// Mutating the returned slice must not affect the inventory.
	got[0].TotalMemoryBytes = 999
	if again, _, _ := inv.Snapshot(); again[0].TotalMemoryBytes != 100 {
		t.Fatalf("snapshot not isolated: inventory mutated to %d", again[0].TotalMemoryBytes)
	}
}

func TestInventory_MarkErrorRetainsStaleSnapshot(t *testing.T) {
	inv := NewInventory()
	inv.Update([]GPUDevice{dev("a", 100, 10, true)}, time.Unix(1, 0))
	inv.MarkError(time.Unix(2, 0), "boom")
	got, ts, errStr := inv.Snapshot()
	if len(got) != 1 {
		t.Fatalf("stale snapshot should be retained on error; got len=%d", len(got))
	}
	if errStr != "boom" || ts != time.Unix(2, 0) {
		t.Fatalf("error state wrong: err=%q ts=%v", errStr, ts)
	}
}

func TestInventory_DriftBytes(t *testing.T) {
	inv := NewInventory()
	inv.Update([]GPUDevice{dev("a", 80, 0, true)}, time.Unix(1, 0))

	if d, ok := inv.DriftBytes(0); ok || d != 0 {
		t.Fatalf("no expectation should yield (0,false); got (%d,%v)", d, ok)
	}
	if d, ok := inv.DriftBytes(80); !ok || d != 0 {
		t.Fatalf("matching capacity → drift 0; got (%d,%v)", d, ok)
	}
	if d, ok := inv.DriftBytes(100); !ok || d != -20 {
		t.Fatalf("hardware shows less → negative drift; got (%d,%v) want (-20,true)", d, ok)
	}
}

func TestDegradedProvider(t *testing.T) {
	p := NewDegradedProvider(context.DeadlineExceeded)
	if p.Name() != "degraded" {
		t.Fatalf("Name: got %q", p.Name())
	}
	if _, err := p.ListDevices(context.Background()); err == nil {
		t.Fatalf("degraded ListDevices should error")
	}
	if _, err := p.GetDevice(context.Background(), "x"); err == nil {
		t.Fatalf("degraded GetDevice should error")
	}
	if err := p.Shutdown(); err != nil {
		t.Fatalf("degraded Shutdown should be nil, got %v", err)
	}
}
