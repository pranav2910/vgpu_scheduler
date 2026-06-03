package nodeagent

import "testing"

func TestParsePodUIDFromCgroup(t *testing.T) {
	const uid = "3f1e6b7c-1234-5678-9abc-def012345678"
	cases := []struct {
		name    string
		content string
		want    string
	}{
		{
			name:    "cgroupv1 cgroupfs",
			content: "12:devices:/kubepods/burstable/pod3f1e6b7c-1234-5678-9abc-def012345678/abc123",
			want:    uid,
		},
		{
			name:    "cgroupv1 systemd (underscores)",
			content: "1:name=systemd:/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod3f1e6b7c_1234_5678_9abc_def012345678.slice/cri-containerd-xyz.scope",
			want:    uid,
		},
		{
			name:    "cgroupv2 systemd",
			content: "0::/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod3f1e6b7c_1234_5678_9abc_def012345678.slice/cri-containerd-xyz.scope",
			want:    uid,
		},
		{
			name:    "guaranteed qos cgroupfs",
			content: "0::/kubepods/pod3f1e6b7c-1234-5678-9abc-def012345678/container",
			want:    uid,
		},
		{
			name:    "non-pod process",
			content: "0::/system.slice/sshd.service",
			want:    "",
		},
		{
			name:    "empty",
			content: "",
			want:    "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := parsePodUIDFromCgroup(c.content); got != c.want {
				t.Fatalf("got %q want %q", got, c.want)
			}
		})
	}
}
