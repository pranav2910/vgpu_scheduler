package scheduler

import (
	"log"
	"sync/atomic"
	"time"
)

type ReservationManager struct {
	cache *VRAMCache
	ttl   time.Duration
}

// ReservationTx is a two-phase commit handle for a speculative reservation.
// Bug #33: confirmed is atomic.Bool so defer + panic on another goroutine is
// memory-safe.
type ReservationTx struct {
	SliceUID  string
	NodeName  string
	cache     *VRAMCache
	confirmed atomic.Bool
}

func NewReservationManager(cache *VRAMCache, ttl time.Duration) *ReservationManager {
	return &ReservationManager{cache: cache, ttl: ttl}
}

func (rm *ReservationManager) Reserve(sliceUID, nodeName string, bytes int64) (*ReservationTx, error) {
	if err := rm.cache.AssumeSlice(sliceUID, nodeName, bytes, rm.ttl); err != nil {
		return nil, err
	}
	return &ReservationTx{SliceUID: sliceUID, NodeName: nodeName, cache: rm.cache}, nil
}

func (tx *ReservationTx) Confirm() {
	tx.confirmed.Store(true)
	tx.cache.ConfirmSlice(tx.SliceUID)
	log.Printf("Reservation Confirmed: Slice %s locked in API", tx.SliceUID)
}

func (tx *ReservationTx) RollbackIfNotConfirmed() {
	if !tx.confirmed.Load() {
		log.Printf("Reservation Rollback: Slice %s dropping speculative lock", tx.SliceUID)
		tx.cache.RollbackAssumedSlice(tx.SliceUID)
	}
}
