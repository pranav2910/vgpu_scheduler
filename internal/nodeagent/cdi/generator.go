package cdi

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// allocationIDPattern is the defense-in-depth allowlist for AllocationIDs used
// in host paths (audit finding): both Generate and Teardown build a file path
// under /var/run/cdi from the ID, and Teardown reads it from slice STATUS — a
// compromised writer could otherwise smuggle path traversal ("../..") into a
// root-owned create/delete. The allocator only ever mints "alloc-<hex>-<num>",
// so anything outside [a-z0-9-] after the prefix is rejected, never pathed.
var allocationIDPattern = regexp.MustCompile(`^alloc-[a-z0-9-]+$`)

func validateAllocationID(id string) error {
	if !allocationIDPattern.MatchString(id) {
		return fmt.Errorf("invalid AllocationID %q: must match %s (refusing to build a host path from it)",
			id, allocationIDPattern)
	}
	return nil
}

// cdiDirectory is a var (not const) solely so tests can point spec writes at
// a temp dir via SetDirectoryForTesting; production never changes it.
var cdiDirectory = "/var/run/cdi"

const (
	vendorName = "infrastructure.pranav2910.com"
	className  = "vgpu"
	// Bug #38: CDI kind must be "<vendor>/<class>".
	cdiKind    = vendorName + "/" + className
	cdiVersion = "0.5.0"
)

// SetDirectoryForTesting overrides where CDI spec files are written. TESTS ONLY
// — lets manager-level lifecycle tests run on machines where /var/run/cdi is
// not writable.
func SetDirectoryForTesting(dir string) { cdiDirectory = dir }

type CDISpec struct {
	Version string   `json:"cdiVersion"`
	Kind    string   `json:"kind"`
	Devices []Device `json:"devices"`
}

type Device struct {
	Name           string         `json:"name"`
	ContainerEdits ContainerEdits `json:"containerEdits"`
}

type ContainerEdits struct {
	Env []string `json:"env,omitempty"`
}

// GenerateFirewall writes a CDI spec file that locks the container to the given
// GPU partition. deviceName MUST be the slice's AllocationID, because the
// mutating webhook requests the CDI device as "<vendor>/<class>=<AllocationID>"
// (internal/webhook/mutating_pod.go) — the device Name here and that request
// must be identical or containerd's CDI lookup finds nothing.
func GenerateFirewall(deviceName string, uuid string) error {
	if err := validateAllocationID(deviceName); err != nil {
		return err
	}
	if err := os.MkdirAll(cdiDirectory, 0750); err != nil {
		return fmt.Errorf("failed to create CDI directory: %w", err)
	}

	spec := CDISpec{
		Version: cdiVersion,
		Kind:    cdiKind,
		Devices: []Device{
			{
				Name: deviceName,
				ContainerEdits: ContainerEdits{
					Env: []string{fmt.Sprintf("NVIDIA_VISIBLE_DEVICES=%s", uuid)},
				},
			},
		},
	}

	data, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		return fmt.Errorf("CDI spec serialisation failed: %w", err)
	}

	// Named by ALLOCATION (deviceName), not by GPU UUID. On real hardware every
	// slice on a node shares the same physical GPU UUID, so a uuid-named file
	// meant: the second slice's spec OVERWROTE the first's (its CDI device
	// vanished — any container restart of the first pod then failed CDI
	// resolution), and releasing any one slice deleted the shared file,
	// revoking every other slice on the GPU. One file per allocation keeps
	// specs independent; containerd merges all spec files for the vendor/class.
	// (The mock allocator's unique fake UUIDs masked this in kind testing.)
	filePath := filepath.Join(cdiDirectory, fmt.Sprintf("%s-%s.json", vendorName, deviceName))
	// Round-3 fix: atomic write. A crash mid-write would otherwise leave a
	// partial JSON file that containerd fails to parse.
	tmpPath := filePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0640); err != nil {
		return err
	}
	return os.Rename(tmpPath, filePath)
}

// TeardownFirewall removes one allocation's CDI spec file, revoking that
// container's hardware access — and ONLY that container's. Takes the
// AllocationID (the same name GenerateFirewall keyed the file by).
func TeardownFirewall(allocationID string) error {
	if err := validateAllocationID(allocationID); err != nil {
		return err
	}
	filePath := filepath.Join(cdiDirectory, fmt.Sprintf("%s-%s.json", vendorName, allocationID))
	if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to teardown CDI firewall for %s: %w", allocationID, err)
	}
	return nil
}
