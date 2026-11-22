package gpu

import (
	"context"
	"log"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
)

// Collector runs the periodic observation loop: it polls the GPUProvider,
// stores the latest snapshot in an Inventory, and publishes per-device and
// drift metrics. It is observation-only — it never mutates scheduler state or
// node capacity.
type Collector struct {
	provider GPUProvider
	inv      *Inventory
	interval time.Duration
	nodeName string
	// expectedBytes, if > 0, is the capacity the scheduler assumes for this
	// node (e.g. the advertised vgpu-bytes). When set, the collector emits a
	// drift gauge = observed_total - expected. Sourced from an env var so the
	// agent needs no extra RBAC to read the Node object.
	expectedBytes int64
	now           func() time.Time // injectable clock for tests
}

// NewCollector builds a collector. interval <= 0 defaults to 30s.
func NewCollector(p GPUProvider, nodeName string, interval time.Duration, expectedBytes int64) *Collector {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	return &Collector{
		provider:      p,
		inv:           NewInventory(),
		interval:      interval,
		nodeName:      nodeName,
		expectedBytes: expectedBytes,
		now:           time.Now,
	}
}

// Inventory exposes the latest observed state (for tests / future consumers).
func (c *Collector) Inventory() *Inventory { return c.inv }

// Start satisfies controller-runtime's Runnable. It collects once immediately,
// then every interval, until the context is cancelled. It never returns an
// error (observation failures degrade visibly via metrics; they don't crash
// the agent).
func (c *Collector) Start(ctx context.Context) error {
	telemetry.GPUProviderInfo.WithLabelValues(c.nodeName, c.provider.Name()).Set(1)
	log.Printf("[gpu] observation collector started: provider=%s interval=%s node=%s",
		c.provider.Name(), c.interval, c.nodeName)

	c.collectOnce(ctx)
	t := time.NewTicker(c.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			if err := c.provider.Shutdown(); err != nil {
				log.Printf("[gpu] provider shutdown: %v", err)
			}
			return nil
		case <-t.C:
			c.collectOnce(ctx)
		}
	}
}

// collectOnce performs a single observation and publishes metrics.
func (c *Collector) collectOnce(ctx context.Context) {
	now := c.now()
	devices, err := c.provider.ListDevices(ctx)
	if err != nil {
		// Observation failed — degrade visibly, keep the (stale) snapshot, and
		// do NOT touch scheduler state.
		c.inv.MarkError(now, err.Error())
		telemetry.GPUObservationErrors.WithLabelValues(c.nodeName).Inc()
		log.Printf("[gpu] observation failed (provider=%s): %v", c.provider.Name(), err)
		return
	}

	c.inv.Update(devices, now)

	// Per-device gauges. Reset first so a vanished GPU's series doesn't linger.
	telemetry.GPUDeviceTotalBytes.Reset()
	telemetry.GPUDeviceUsedBytes.Reset()
	telemetry.GPUDeviceFreeBytes.Reset()
	telemetry.GPUDeviceReservedBytes.Reset()
	telemetry.GPUDeviceHealthy.Reset()
	for _, d := range devices {
		telemetry.GPUDeviceHealthy.WithLabelValues(c.nodeName, d.UUID).Set(boolToFloat(d.Healthy))
		// Only publish memory for healthy devices; an unhealthy GPU's figures
		// are unknown, not zero-real-capacity.
		if d.Healthy {
			telemetry.GPUDeviceTotalBytes.WithLabelValues(c.nodeName, d.UUID).Set(float64(d.TotalMemoryBytes))
			telemetry.GPUDeviceUsedBytes.WithLabelValues(c.nodeName, d.UUID).Set(float64(d.UsedMemoryBytes))
			telemetry.GPUDeviceFreeBytes.WithLabelValues(c.nodeName, d.UUID).Set(float64(d.FreeMemoryBytes))
			telemetry.GPUDeviceReservedBytes.WithLabelValues(c.nodeName, d.UUID).Set(float64(d.ReservedMemoryBytes))
		}
	}

	// Drift: observed healthy-total vs scheduler-assumed capacity, if known.
	if drift, ok := c.inv.DriftBytes(c.expectedBytes); ok {
		telemetry.GPUCapacityDriftBytes.WithLabelValues(c.nodeName).Set(float64(drift))
		if drift != 0 {
			log.Printf("[gpu] capacity drift: observed_total=%d expected=%d drift=%d (node=%s)",
				c.inv.Aggregate().TotalBytes, c.expectedBytes, drift, c.nodeName)
		}
	}
}

func boolToFloat(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
