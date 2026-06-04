package cdi

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const (
	cdiDirectory = "/var/run/cdi"
	vendorName   = "infrastructure.pranav2910.com"
	className    = "vgpu"
	// Bug #38: CDI kind must be "<vendor>/<class>".
	cdiKind    = vendorName + "/" + className
	cdiVersion = "0.5.0"
)

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

	// Named by UUID so TeardownFirewall can find the file without extra lookup.
	filePath := filepath.Join(cdiDirectory, fmt.Sprintf("%s-%s.json", vendorName, uuid))
	// Round-3 fix: atomic write. A crash mid-write would otherwise leave a
	// partial JSON file that containerd fails to parse.
	tmpPath := filePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0640); err != nil {
		return err
	}
	return os.Rename(tmpPath, filePath)
}

// TeardownFirewall removes the CDI spec file, revoking the container's hardware access.
func TeardownFirewall(uuid string) error {
	filePath := filepath.Join(cdiDirectory, fmt.Sprintf("%s-%s.json", vendorName, uuid))
	if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to teardown CDI firewall for %s: %w", uuid, err)
	}
	return nil
}
