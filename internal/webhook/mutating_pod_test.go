package webhook

// Regression test for the multi-GPU device pin: the CDI env edit only APPENDS
// to the OCI process env, and nvidia/cuda images bake NVIDIA_VISIBLE_DEVICES=all
// into the image — with duplicates the winner is runtime-dependent, which on an
// 8×V100 exposed every card to every pod (pod B saw pod A's GPU). The webhook
// must SET the env in the pod spec, which unambiguously overrides image env.

import (
	"context"
	"strings"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestMutatePodPinsDeviceEnvOverAnyExistingValue(t *testing.T) {
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := corev1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "job1-claim-slice", Namespace: "ns1"},
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase:        "Ready",
			AllocationID: "alloc-abc-123",
			DeviceUUID:   "GPU-CARD-SEVEN",
		},
	}
	cl := fake.NewClientBuilder().WithScheme(s).WithObjects(slice).Build()
	m := &PodMutator{Client: cl}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "w", Namespace: "ns1",
			Annotations: map[string]string{VGPUClaimAnnotation: "job1-claim"},
		},
		Spec: corev1.PodSpec{
			InitContainers: []corev1.Container{{Name: "init"}},
			Containers: []corev1.Container{
				{
					Name: "main",
					// Models the nvidia/cuda image's baked-in env (and any
					// user template that sets it): must be REPLACED, not joined.
					Env: []corev1.EnvVar{{Name: "NVIDIA_VISIBLE_DEVICES", Value: "all"}},
				},
				{Name: "sidecar"},
			},
		},
	}
	if err := m.MutatePod(context.Background(), pod); err != nil {
		t.Fatalf("MutatePod: %v", err)
	}

	check := func(c corev1.Container) {
		t.Helper()
		count := 0
		for _, e := range c.Env {
			if e.Name == "NVIDIA_VISIBLE_DEVICES" {
				count++
				if e.Value != "GPU-CARD-SEVEN" {
					t.Fatalf("container %s: NVIDIA_VISIBLE_DEVICES=%q, want the slice's card (a stale 'all' exposes every GPU on the node)", c.Name, e.Value)
				}
			}
		}
		if count != 1 {
			t.Fatalf("container %s: %d NVIDIA_VISIBLE_DEVICES entries, want exactly 1 (duplicates reintroduce runtime-dependent precedence)", c.Name, count)
		}
	}
	for _, c := range pod.Spec.Containers {
		check(c)
	}
	for _, c := range pod.Spec.InitContainers {
		check(c)
	}

	if got := pod.Annotations[CDIAnnotationKey]; !strings.Contains(got, "alloc-abc-123") {
		t.Fatalf("CDI annotation = %q, want it to reference alloc-abc-123", got)
	}
}

// Regression (Gate-3 receipt finding): the webhook must stamp the granted VRAM
// onto the pod. Monitor mode is pods-RBAC-only — it cannot read VGPUClaims — so
// without this annotation a VGPUJob pod that isn't actively using VRAM was
// entirely invisible to the waste report (source=vgpu_claim never fired live).
func TestMutatePodStampsRequestedVRAMForMonitor(t *testing.T) {
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := corev1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "job1-claim-slice", Namespace: "ns1"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{RequestedVRAMBytes: 17179869184}, // 16 GiB
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase:        "Ready",
			AllocationID: "alloc-abc-123",
			DeviceUUID:   "GPU-CARD-SEVEN",
		},
	}
	cl := fake.NewClientBuilder().WithScheme(s).WithObjects(slice).Build()
	m := &PodMutator{Client: cl}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "w", Namespace: "ns1",
			Annotations: map[string]string{VGPUClaimAnnotation: "job1-claim"},
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "main"}}},
	}
	if err := m.MutatePod(context.Background(), pod); err != nil {
		t.Fatalf("MutatePod: %v", err)
	}
	got := pod.Annotations["infrastructure.pranav2910.com/requested-vram-bytes"]
	if got != "17179869184" {
		t.Fatalf("requested-vram-bytes annotation = %q, want 17179869184 (the monitor's vgpu_claim source reads exactly this key)", got)
	}
}
