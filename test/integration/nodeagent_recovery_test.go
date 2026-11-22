package integration

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/checkpoint"
)

// TestCheckpointSurviveRestart writes two records, simulates a restart by
// creating a new Store pointing at the same dir, and verifies both records
// load cleanly.
func TestCheckpointSurviveRestart(t *testing.T) {
	dir := t.TempDir()
	s := checkpoint.NewStoreAt(dir)

	for _, id := range []string{"alloc-a", "alloc-b"} {
		if err := s.Save(checkpoint.CheckpointRecord{
			AllocationID: id,
			SliceUID:     "uid-" + id,
			NodeName:     "h100-1",
			CreatedAt:    time.Now(),
		}); err != nil {
			t.Fatalf("save: %v", err)
		}
	}

	// Simulate restart.
	s2 := checkpoint.NewStoreAt(dir)
	records, err := s2.LoadAll()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("want 2 records after restart, got %d", len(records))
	}
}

// TestCheckpointCorruptionRefusesOverwrite verifies Bug #4's fix.
func TestCheckpointCorruptionRefusesOverwrite(t *testing.T) {
	dir := t.TempDir()
	s := checkpoint.NewStoreAt(dir)

	if err := s.Save(checkpoint.CheckpointRecord{AllocationID: "good"}); err != nil {
		t.Fatalf("save: %v", err)
	}
	// Corrupt the file.
	if err := os.WriteFile(filepath.Join(dir, checkpoint.CheckpointFile), []byte("{bad json"), 0640); err != nil {
		t.Fatalf("corrupt: %v", err)
	}
	// Save must refuse — it must NOT silently reset the file.
	err := s.Save(checkpoint.CheckpointRecord{AllocationID: "next"})
	if err == nil {
		t.Fatal("Save over corrupt file should return an error")
	}
}
