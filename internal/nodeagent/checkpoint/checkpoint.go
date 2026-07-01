package checkpoint

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var ErrCorruptCheckpoint = errors.New("checkpoint file is corrupt")

const (
	defaultCheckpointDir = "/var/run/vgpu-state"
	CheckpointDir        = defaultCheckpointDir
	CheckpointFile       = "allocations.json"
)

type CheckpointRecord struct {
	AllocationID   string    `json:"allocationID"`
	SliceUID       string    `json:"sliceUID"`
	SliceName      string    `json:"sliceName"`
	Namespace      string    `json:"namespace"`
	ClaimName      string    `json:"claimName"`
	DeviceUUID     string    `json:"deviceUUID"`
	AllocatedBytes int64     `json:"allocatedBytes"`
	NodeName       string    `json:"nodeName"`
	CreatedAt      time.Time `json:"createdAt"`
}

type Store struct {
	mu  sync.RWMutex
	dir string
}

func NewStore() *Store {
	return &Store{dir: defaultCheckpointDir}
}

func NewStoreAt(dir string) *Store {
	return &Store{dir: dir}
}

func (s *Store) path() string {
	return filepath.Join(s.dir, CheckpointFile)
}

func (s *Store) LoadAll() (map[string]CheckpointRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	data, err := os.ReadFile(s.path())
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]CheckpointRecord), nil
		}
		return nil, fmt.Errorf("checkpoint read failed: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCorruptCheckpoint, err)
	}
	return records, nil
}

func (s *Store) Save(record CheckpointRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(s.dir, 0750); err != nil {
		return fmt.Errorf("checkpoint dir creation failed: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if data, err := os.ReadFile(s.path()); err == nil {
		if err := json.Unmarshal(data, &records); err != nil {
			// Bug #4 fix: refuse to overwrite a corrupt file. Silently
			// resetting here caused every reboot-after-corruption to lose
			// every allocation that wasn't the one being saved right now.
			return fmt.Errorf("%w: refusing to overwrite existing unparseable checkpoint: %v",
				ErrCorruptCheckpoint, err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("checkpoint read failed during save: %w", err)
	}

	records[record.AllocationID] = record

	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("checkpoint serialisation failed: %w", err)
	}
	return writeAtomic(s.path(), out, 0640)
}

// writeAtomic writes via a same-directory temp file + rename. The Bug #4 guard
// above turns a corrupt checkpoint into a permanent allocation outage (every
// Save refuses, no repair path), so the write path must make torn writes
// impossible — a truncate-in-place WriteFile interrupted by a crash/power loss
// is exactly how the file gets corrupted in the first place.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("checkpoint temp file creation failed: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once renamed
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("checkpoint temp write failed: %w", err)
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return fmt.Errorf("checkpoint temp chmod failed: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("checkpoint temp sync failed: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("checkpoint temp close failed: %w", err)
	}
	return os.Rename(tmpName, path)
}

func (s *Store) Delete(allocationID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("checkpoint read failed during delete: %w", err)
	}

	records := make(map[string]CheckpointRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return fmt.Errorf("%w: %v", ErrCorruptCheckpoint, err)
	}

	delete(records, allocationID)

	out, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("checkpoint serialisation failed during delete: %w", err)
	}
	// Same atomicity requirement as Save: Delete runs on every job completion,
	// so a truncate-in-place write here was the widest window for the torn-file
	// corruption the Bug #4 guard then refuses forever (node can't allocate).
	return writeAtomic(s.path(), out, 0640)
}
