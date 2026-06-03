package nodeagent

import (
	"context"
	"fmt"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// overuseToleranceBytes is the slack before a GPU's process-used VRAM is
	// treated as exceeding its granted budget — absorbs measurement noise.
	overuseToleranceBytes = int64(256) << 20 // 256 MiB
	// overuseStreakThreshold is how many consecutive observation cycles a GPU
	// must be over budget before it is flagged (hysteresis — no flapping on
	// transient allocation spikes).
	overuseStreakThreshold = 3
)

// ViolationDetector is the Phase 3.4a observe-only over-use detector. Each cycle
// it compares each GPU's observed process-used VRAM against the VRAM the
// scheduler granted to bound slices on this node, and surfaces sustained
// over-use via metrics and a Kubernetes Event. It NEVER evicts, throttles, or
// mutates a workload — detection only.
//
// This product models one GPU per node, so all of a node's slice grants map to
// its GPU; "granted on the node" is therefore that GPU's budget. Per-slice
// attribution (which slice is over-using) arrives in Phase 3.4b.
type ViolationDetector struct {
	client   client.Client
	nodeName string
	inv      *gpu.Inventory
	recorder record.EventRecorder
	interval time.Duration

	// per-GPU hysteresis state, keyed by GPU UUID.
	streak map[string]int
	active map[string]bool
}

// NewViolationDetector builds the detector. interval <= 0 defaults to 30s.
func NewViolationDetector(c client.Client, nodeName string, inv *gpu.Inventory, recorder record.EventRecorder, interval time.Duration) *ViolationDetector {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	return &ViolationDetector{
		client:   c,
		nodeName: nodeName,
		inv:      inv,
		recorder: recorder,
		interval: interval,
		streak:   map[string]int{},
		active:   map[string]bool{},
	}
}

// Start satisfies controller-runtime's Runnable. It never returns an error
// (detection failures degrade visibly via logs; they don't crash the agent).
func (d *ViolationDetector) Start(ctx context.Context) error {
	log.Printf("[violation] over-use detector started: node=%s interval=%s (observe-only)", d.nodeName, d.interval)
	t := time.NewTicker(d.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
			if err := d.detectOnce(ctx); err != nil {
				log.Printf("[violation] detect cycle error: %v", err)
			}
		}
	}
}

func (d *ViolationDetector) detectOnce(ctx context.Context) error {
	devices, _, errStr := d.inv.Snapshot()
	if errStr != "" || len(devices) == 0 {
		return nil // no fresh observation to act on
	}
	granted, err := d.grantedBytes(ctx)
	if err != nil {
		return fmt.Errorf("computing granted bytes: %w", err)
	}
	for _, dev := range devices {
		if !dev.Healthy {
			continue
		}
		onset, overuse, violating := d.evaluate(dev.UUID, dev.UsedMemoryBytes, granted)
		telemetry.NodeMemoryOveruseBytes.WithLabelValues(d.nodeName, dev.UUID).Set(float64(overuse))
		telemetry.NodeMemoryViolationActive.WithLabelValues(d.nodeName, dev.UUID).Set(boolToFloat01(violating))
		if onset {
			d.emitEvent(dev.UUID, overuse, granted)
		}
	}
	return nil
}

// evaluate applies the tolerance + hysteresis to one GPU and returns:
//
//	onset     — true exactly on the cycle the GPU transitions INTO violation
//	overuse   — max(0, used - granted)
//	violating — current sustained-violation state
//
// Pure except for the per-GPU streak/active maps, so it is directly unit-testable.
func (d *ViolationDetector) evaluate(uuid string, used, granted int64) (onset bool, overuse int64, violating bool) {
	if used > granted {
		overuse = used - granted
	}
	if used-granted > overuseToleranceBytes {
		d.streak[uuid]++
	} else {
		d.streak[uuid] = 0
	}
	violating = d.streak[uuid] >= overuseStreakThreshold
	was := d.active[uuid]
	d.active[uuid] = violating
	onset = violating && !was
	return onset, overuse, violating
}

// grantedBytes sums RequestedVRAMBytes of slices bound to this node that hold
// capacity (nodeName set and phase not Pending/Released/Failed).
func (d *ViolationDetector) grantedBytes(ctx context.Context) (int64, error) {
	var slices vgpuv1alpha1.VGPUSliceList
	if err := d.client.List(ctx, &slices); err != nil {
		return 0, err
	}
	var total int64
	for i := range slices.Items {
		s := &slices.Items[i]
		if s.Spec.NodeName != d.nodeName {
			continue
		}
		switch string(s.Status.Phase) {
		case "", "Pending", "Released", "Failed":
			continue
		}
		total += s.Spec.RequestedVRAMBytes
	}
	return total, nil
}

func (d *ViolationDetector) emitEvent(uuid string, overuse, granted int64) {
	log.Printf("[violation] node=%s gpu=%s OVER-USE: process-used exceeds granted by %d MiB (granted=%d MiB) — observe-only, no eviction",
		d.nodeName, uuid, overuse>>20, granted>>20)
	if d.recorder == nil {
		return
	}
	// Reference the Node by name without fetching it (no extra RBAC/Get).
	node := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: d.nodeName}}
	d.recorder.Eventf(node, corev1.EventTypeWarning, "MemoryViolation",
		"Observed GPU %s memory usage exceeded granted VRAM by %d MiB for ~%ds (observe-only, no eviction)",
		uuid, overuse>>20, overuseStreakThreshold*int(d.interval.Seconds()))
}

func boolToFloat01(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
