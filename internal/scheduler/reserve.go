package scheduler

import (
	"log"
	"sync/atomic"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/telemetry"
)

type ReservationManager struct {
	cache *VRAMCache
	ttl   time.Duration
}

// ReservationTx is a two-phase commit handle for a speculative reservation.
// Bug #33: confirmed is atomic.Bool so defer + panic on another goroutine is
// memory-safe.
//
// Option B addition: `held` atomic.Bool for the hold-the-reservation gang
// gate. When the gate defers a slice, it calls MarkHeld() to keep the
// speculative cache lock alive past the function return. The cache's TTL
// reaper will eventually free a hold that doesn't converge into a bind.
type ReservationTx struct {
	SliceUID  string
	Namespace string
	NodeName  string
	Bytes     int64
	cache     *VRAMCache
	confirmed atomic.Bool
	held      atomic.Bool
}

func NewReservationManager(cache *VRAMCache, ttl time.Duration) *ReservationManager {
	return &ReservationManager{cache: cache, ttl: ttl}
}

func (rm *ReservationManager) Reserve(sliceUID, namespace, nodeName string, bytes int64) (*ReservationTx, error) {
	if err := rm.cache.AssumeSlice(sliceUID, namespace, nodeName, bytes, rm.ttl); err != nil {
		return nil, err
	}
	return &ReservationTx{SliceUID: sliceUID, Namespace: namespace, NodeName: nodeName, Bytes: bytes, cache: rm.cache}, nil
}

// NewReservationTxForHeld constructs a Tx wrapping an already-existing
// assumedBySlice entry. Used by Schedule()'s fast-forward path when a
// gang member's reservation persists across reconcile cycles. namespace and
// bytes ride the Tx so Confirm can re-arm if the hold is reaped mid-bind.
func NewReservationTxForHeld(cache *VRAMCache, sliceUID, namespace, nodeName string, bytes int64) *ReservationTx {
	return &ReservationTx{SliceUID: sliceUID, Namespace: namespace, NodeName: nodeName, Bytes: bytes, cache: cache}
}

func (tx *ReservationTx) Confirm() {
	tx.confirmed.Store(true)
	if rearmed := tx.cache.ConfirmSliceOrRearm(tx.SliceUID, tx.Namespace, tx.NodeName, tx.Bytes); rearmed {
		telemetry.ConfirmRearms.Inc()
		log.Printf("Reservation Confirmed with RE-ARM: slice %s hold was reaped mid-bind; capacity re-charged (bind latency exceeded the reservation TTL)", tx.SliceUID)
		return
	}
	log.Printf("Reservation Confirmed: Slice %s locked in API", tx.SliceUID)
}

// MarkHeld signals that the cache assumption should outlive this Tx's
// scope. Used by the gang gate's Deferred path: the slice stays in
// assumedBySlice across reconcile cycles, refreshed by gate calls, until
// the gang either tips quorum (next call: Confirm + bind) or the TTL
// reaper reclaims it.
func (tx *ReservationTx) MarkHeld() {
	tx.held.Store(true)
}

func (tx *ReservationTx) RollbackIfNotConfirmed() {
	if tx.confirmed.Load() || tx.held.Load() {
		return
	}
	log.Printf("Reservation Rollback: Slice %s dropping speculative lock", tx.SliceUID)
	tx.cache.RollbackAssumedSlice(tx.SliceUID)
}
