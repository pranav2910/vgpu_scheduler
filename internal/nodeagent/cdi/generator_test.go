package cdi

// Regression coverage for the AllocationID allowlist (audit finding): both
// Generate and Teardown build a root-owned host path under /var/run/cdi from
// the ID, and Teardown reads it from slice STATUS — so a hostile value could
// otherwise traverse ("../../etc/...") into an arbitrary create/delete.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFirewallRoundTripWithMintedIDShape(t *testing.T) {
	dir := t.TempDir()
	SetDirectoryForTesting(dir)
	defer SetDirectoryForTesting("/var/run/cdi")

	// The exact shape the allocator mints: alloc-<8 hex of UID>-<unix nanos>.
	id := "alloc-b9881f2e-1782173889355732419"
	if err := GenerateFirewall(id, "GPU-TEST-0000"); err != nil {
		t.Fatalf("GenerateFirewall(%q): %v", id, err)
	}
	want := filepath.Join(dir, vendorName+"-"+id+".json")
	if _, err := os.Stat(want); err != nil {
		t.Fatalf("spec file not written: %v", err)
	}
	if err := TeardownFirewall(id); err != nil {
		t.Fatalf("TeardownFirewall(%q): %v", id, err)
	}
	if _, err := os.Stat(want); !os.IsNotExist(err) {
		t.Fatalf("spec file still present after teardown")
	}
}

func TestHostileAllocationIDsRefused(t *testing.T) {
	dir := t.TempDir()
	SetDirectoryForTesting(dir)
	defer SetDirectoryForTesting("/var/run/cdi")

	hostile := []string{
		"../../etc/cron.d/backdoor",
		"alloc-../../../etc/shadow",
		"alloc-x/../../escape",
		"alloc-UPPER-123", // uppercase not minted; refuse anything unexpected
		"alloc-",          // empty suffix
		"",                // empty
		"notalloc-abc-1",  // wrong prefix
		"alloc-abc_1",     // underscore outside the alphabet
	}
	for _, id := range hostile {
		if err := GenerateFirewall(id, "GPU-TEST-0000"); err == nil {
			t.Errorf("GenerateFirewall(%q) accepted a hostile/invalid ID", id)
		}
		if err := TeardownFirewall(id); err == nil {
			t.Errorf("TeardownFirewall(%q) accepted a hostile/invalid ID", id)
		}
	}

	// Nothing may have been created anywhere under the test dir.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		t.Errorf("unexpected file created by refused ID: %s", e.Name())
	}
}

func TestRefusalErrorNamesTheRule(t *testing.T) {
	SetDirectoryForTesting(t.TempDir())
	defer SetDirectoryForTesting("/var/run/cdi")
	err := TeardownFirewall("alloc-../x")
	if err == nil || !strings.Contains(err.Error(), "invalid AllocationID") {
		t.Fatalf("want an 'invalid AllocationID' error, got: %v", err)
	}
}
