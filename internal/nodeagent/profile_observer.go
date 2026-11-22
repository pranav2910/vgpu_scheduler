package nodeagent

import (
	"context"
	"log"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"k8s.io/apimachinery/pkg/types"
)

// Phase 3.5 — Runtime Feedback Engine (node-agent side). The detector already
// attributes GPU memory to each slice every cycle for enforcement; here it ALSO
// accumulates that into durable per-slice runtime stats on VGPUSlice.status. The
// controller aggregates those per workload into a VGPUWorkloadProfile. This runs
// regardless of enforcement mode — learning happens even with enforcement off.

const (
	// profileFlushInterval throttles how often accumulated stats are written to
	// the slice status (between flushes, samples accumulate in memory). Stats are
	// also flushed immediately when the peak grows.
	profileFlushInterval = 2 * time.Minute
	// profileEWMAAlpha weights the most recent sample in the running average.
	profileEWMAAlpha = 0.3
)

// sliceStat is the in-memory running record for one slice. Counters are tracked
// as deltas-since-last-flush and merged additively into the (cumulative) slice
// status, so a node-agent restart loses at most one flush interval of samples.
type sliceStat struct {
	peak        int64
	ewma        float64
	lastObs     int64
	obsDelta    int64
	violDelta   int64
	warnDelta   int64
	evictDelta  int64
	flushedPeak int64
	lastFlush   time.Time
}

// statFor returns the slice's running record, creating it lazily so the event
// hooks and the per-cycle sampler can be called in any order.
func (d *SliceViolationDetector) statFor(key string) *sliceStat {
	st := d.profileStats[key]
	if st == nil {
		st = &sliceStat{lastFlush: d.now()}
		d.profileStats[key] = st
	}
	return st
}

// observeProfile records one sample of attributed usage and flushes the
// accumulated stats to the slice status when the peak grows or the flush
// interval elapses.
func (d *SliceViolationDetector) observeProfile(ctx context.Context, u *sliceUsage) {
	st := d.statFor(sliceKey(u.namespace, u.name))
	if u.used > st.peak {
		st.peak = u.used
	}
	if st.ewma == 0 {
		st.ewma = float64(u.used)
	} else {
		st.ewma = profileEWMAAlpha*float64(u.used) + (1-profileEWMAAlpha)*st.ewma
	}
	st.lastObs = u.used
	st.obsDelta++

	if st.peak > st.flushedPeak || d.now().Sub(st.lastFlush) >= profileFlushInterval {
		d.flushProfile(ctx, u, st)
	}
}

// flushProfile merges the in-memory deltas into the slice status. Peak is
// monotonic (max); observations/incident counts are additive; avg/observed are
// overwritten. On a write conflict the deltas are kept and retried next cycle.
func (d *SliceViolationDetector) flushProfile(ctx context.Context, u *sliceUsage, st *sliceStat) {
	var slice vgpuv1alpha1.VGPUSlice
	if err := d.client.Get(ctx, types.NamespacedName{Namespace: u.namespace, Name: u.name}, &slice); err != nil {
		return
	}
	if st.peak > slice.Status.PeakObservedVRAMBytes {
		slice.Status.PeakObservedVRAMBytes = st.peak
	}
	slice.Status.ObservedVRAMBytes = st.lastObs
	slice.Status.AvgObservedVRAMBytes = int64(st.ewma)
	slice.Status.Observations += st.obsDelta
	slice.Status.ViolationCount += st.violDelta
	slice.Status.SoftWarnCount += st.warnDelta
	slice.Status.EvictionCount += st.evictDelta
	if err := d.client.Status().Update(ctx, &slice); err != nil {
		log.Printf("[profile] flush slice %s/%s: %v (will retry)", u.namespace, u.name, err)
		return // keep deltas; retry next cycle
	}
	st.obsDelta, st.violDelta, st.warnDelta, st.evictDelta = 0, 0, 0, 0
	st.flushedPeak = st.peak
	st.lastFlush = d.now()
}

// profileOnViolation / profileOnSoftWarn / profileOnEviction record a 3.4
// incident against the slice's running stats (flushed with the next sample).
func (d *SliceViolationDetector) profileOnViolation(key string) { d.statFor(key).violDelta++ }
func (d *SliceViolationDetector) profileOnSoftWarn(key string)  { d.statFor(key).warnDelta++ }
func (d *SliceViolationDetector) profileOnEviction(key string)  { d.statFor(key).evictDelta++ }
