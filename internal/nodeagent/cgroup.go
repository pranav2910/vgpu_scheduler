package nodeagent

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// podUIDRe matches the Kubernetes pod UID embedded in a cgroup path. Pod UIDs
// are UUIDs; the cgroupfs driver keeps the dashes (pod<uuid>) while the systemd
// driver replaces them with underscores (pod<uuid_with_underscores>.slice).
var podUIDRe = regexp.MustCompile(`pod([0-9a-fA-F]{8}[-_][0-9a-fA-F]{4}[-_][0-9a-fA-F]{4}[-_][0-9a-fA-F]{4}[-_][0-9a-fA-F]{12})`)

// parsePodUIDFromCgroup extracts the Kubernetes pod UID from the contents of a
// /proc/<pid>/cgroup file. It handles cgroup v1 (multiple subsystem lines) and
// v2 (a single `0::<path>` line), and both the cgroupfs and systemd drivers.
// Returns "" if no pod UID is present (i.e. not a pod's process). Pure — the
// hardware/host dependency (reading /proc) lives in podUIDForPID.
func parsePodUIDFromCgroup(content string) string {
	for _, line := range strings.Split(content, "\n") {
		// cgroup line format: "hierarchy-ID:controller-list:cgroup-path".
		path := line
		if i := strings.LastIndex(line, ":"); i >= 0 {
			path = line[i+1:]
		}
		if m := podUIDRe.FindStringSubmatch(path); m != nil {
			// Normalize the systemd underscore form back to a canonical UID.
			return strings.ReplaceAll(m[1], "_", "-")
		}
	}
	return ""
}

// podUIDForPID reads /proc/<pid>/cgroup under procRoot (host /proc; requires
// hostPID) and returns the owning pod's UID, or "" if it is not a pod process.
func podUIDForPID(procRoot string, pid int) (string, error) {
	b, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "cgroup"))
	if err != nil {
		return "", err
	}
	return parsePodUIDFromCgroup(string(b)), nil
}
