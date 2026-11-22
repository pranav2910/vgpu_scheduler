package checkpoint

// Regression coverage for the checkpoint store, with emphasis on the audit
// finding: Delete() wrote truncate-in-place while Save() wrote atomically. A
// crash mid-delete left torn JSON, and the corrupt-file guard (Bug #4) then
// refused every future Save — a permanent allocation outage. Delete runs on
// every job completion, so it was the WIDEST corruption window, not a corner.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testRecord(id string) CheckpointRecord {
	return CheckpointRecord{
		AllocationID:   id,
		SliceUID:       "uid-" + id,
		SliceName:      "slice-" + id,
		Namespace:      "default",
		ClaimName:      "claim-" + id,
		DeviceUUID:     "GPU-TEST-0000",
		AllocatedBytes: 1 << 30,
		NodeName:       "node-a",
		CreatedAt:      time.Now().UTC(),
	}
}

func TestSaveLoadDeleteRoundTrip(t *testing.T) {
	s := NewStoreAt(t.TempDir())

	if err := s.Save(testRecord("alloc-1")); err != nil {
		t.Fatalf("Save alloc-1: %v", err)
	}
	if err := s.Save(testRecord("alloc-2")); err != nil {
		t.Fatalf("Save alloc-2: %v", err)
	}

	if err := s.Delete("alloc-1"); err != nil {
		t.Fatalf("Delete alloc-1: %v", err)
	}

	records, err := s.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll after delete: %v", err)
	}
	if _, gone := records["alloc-1"]; gone {
		t.Error("alloc-1 still present after Delete")
	}
	if _, kept := records["alloc-2"]; !kept {
		t.Error("alloc-2 lost by Delete of a different record")
	}
}

func TestDeleteOnMissingFileIsNoop(t *testing.T) {
	s := NewStoreAt(t.TempDir())
	if err := s.Delete("alloc-never-existed"); err != nil {
		t.Fatalf("Delete with no checkpoint file must be a no-op, got: %v", err)
	}
}

// THE FIX: Delete must write via the same temp+rename path as Save. The
// observable contract: after Delete the file is valid JSON, has the checkpoint
// mode, and no temp residue is left in the directory. (True torn-write
// injection needs a crash harness; this locks the code path + cleanup.)
func TestDeleteWritesAtomically(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreAt(dir)
	if err := s.Save(testRecord("alloc-1")); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if err := s.Delete("alloc-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	// File still parses (never observable torn on a completed call).
	data, err := os.ReadFile(filepath.Join(dir, CheckpointFile))
	if err != nil {
		t.Fatalf("read after delete: %v", err)
	}
	var m map[string]CheckpointRecord
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("checkpoint not valid JSON after Delete: %v", err)
	}
	if len(m) != 0 {
		t.Errorf("expected empty checkpoint after deleting the only record, got %d", len(m))
	}

	// No leftover writeAtomic temp files.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp-") {
			t.Errorf("temp file left behind by Delete: %s", e.Name())
		}
	}

	// Atomic path must preserve the checkpoint file mode.
	info, err := os.Stat(filepath.Join(dir, CheckpointFile))
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if info.Mode().Perm() != 0640 {
		t.Errorf("checkpoint mode = %v, want 0640", info.Mode().Perm())
	}
}

// The guard that made non-atomic Delete fatal: a corrupt file must be refused
// (fail loud), never silently clobbered — by Save OR Delete.
func TestCorruptFileRefusedBySaveAndDelete(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreAt(dir)
	if err := os.WriteFile(filepath.Join(dir, CheckpointFile), []byte(`{"alloc-1": {"allocationID": "alloc-1", TORN`), 0640); err != nil {
		t.Fatalf("write corrupt file: %v", err)
	}

	if err := s.Save(testRecord("alloc-2")); !errors.Is(err, ErrCorruptCheckpoint) {
		t.Errorf("Save on corrupt file: want ErrCorruptCheckpoint, got %v", err)
	}
	if err := s.Delete("alloc-1"); !errors.Is(err, ErrCorruptCheckpoint) {
		t.Errorf("Delete on corrupt file: want ErrCorruptCheckpoint, got %v", err)
	}
	if _, err := s.LoadAll(); !errors.Is(err, ErrCorruptCheckpoint) {
		t.Errorf("LoadAll on corrupt file: want ErrCorruptCheckpoint, got %v", err)
	}
}

func TestDeleteNonexistentIDLeavesFileValid(t *testing.T) {
	s := NewStoreAt(t.TempDir())
	if err := s.Save(testRecord("alloc-1")); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if err := s.Delete("alloc-does-not-exist"); err != nil {
		t.Fatalf("Delete of unknown ID: %v", err)
	}
	records, err := s.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	if _, kept := records["alloc-1"]; !kept {
		t.Error("alloc-1 lost by Delete of a nonexistent ID")
	}
}
