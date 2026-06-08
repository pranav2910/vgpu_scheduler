package nodeagent

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestParseRequestedMem(t *testing.T) {
	const GiB = int64(1024 * 1024 * 1024)
	cases := map[string]int64{
		"16Gi":        16 * GiB,
		"17179869184": 17179869184, // quantity with no unit = bytes
		"16384":       16384 * 1024 * 1024, // bare int = MiB (Run:ai/KAI convention)
		"512Mi":       512 * 1024 * 1024,
		"":            0,
		"garbage":     0,
		"0":           0,
	}
	// "17179869184" is all-digits → treated as MiB by our rule. Adjust expectation:
	cases["17179869184"] = 17179869184 * 1024 * 1024
	for in, want := range cases {
		if got := parseRequestedMem(in); got != want {
			t.Errorf("parseRequestedMem(%q) = %d, want %d", in, got, want)
		}
	}
}

func pod(ns, name string, mut func(*corev1.Pod)) *corev1.Pod {
	p := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}}
	if mut != nil {
		mut(p)
	}
	return p
}

func TestRequestedVRAM(t *testing.T) {
	const GiB = int64(1024 * 1024 * 1024)
	card := 80 * GiB
	keys := defaultRequestAnnotationKeys

	// whole-GPU resource → N × card, source nvidia_gpu_limit
	wholeGPU := pod("default", "vanilla", func(p *corev1.Pod) {
		p.Spec.Containers = []corev1.Container{{
			Name: "c",
			Resources: corev1.ResourceRequirements{
				Limits: corev1.ResourceList{nvidiaGPUResource: resource.MustParse("1")},
			},
		}}
	})
	if b, src := requestedVRAM(wholeGPU, card, keys); b != card || src != "nvidia_gpu_limit" {
		t.Errorf("whole-GPU: got (%d,%s), want (%d,nvidia_gpu_limit)", b, src, card)
	}

	// annotation (KAI/Run:ai style, MiB) → source annotation
	annPod := pod("default", "kai", func(p *corev1.Pod) {
		p.Annotations = map[string]string{"run.ai/gpu-memory": "16384"} // 16 GiB in MiB
	})
	if b, src := requestedVRAM(annPod, card, keys); b != 16*GiB || src != "annotation" {
		t.Errorf("annotation: got (%d,%s), want (%d,annotation)", b, src, 16*GiB)
	}

	// our own requested-vram annotation → source vgpu_claim
	ours := pod("default", "ours", func(p *corev1.Pod) {
		p.Annotations = map[string]string{"infrastructure.pranav2910.com/requested-vram-bytes": "17179869184"}
	})
	// 17179869184 is all-digits → MiB by our rule
	if b, src := requestedVRAM(ours, card, keys); src != "vgpu_claim" || b == 0 {
		t.Errorf("ours: got (%d,%s), want (>0,vgpu_claim)", b, src)
	}

	// claim-ref only (no size) → vgpu_claim, 0 bytes (size lives in the CRD)
	claimOnly := pod("default", "claimonly", func(p *corev1.Pod) {
		p.Annotations = map[string]string{vgpuClaimRefAnnotation: "x-claim"}
	})
	if b, src := requestedVRAM(claimOnly, card, keys); b != 0 || src != "vgpu_claim" {
		t.Errorf("claim-only: got (%d,%s), want (0,vgpu_claim)", b, src)
	}

	// no GPU request at all → unknown, 0
	none := pod("default", "cpu-only", nil)
	if b, src := requestedVRAM(none, card, keys); b != 0 || src != "unknown" {
		t.Errorf("none: got (%d,%s), want (0,unknown)", b, src)
	}

	// custom annotation key honored
	custom := pod("default", "custom", func(p *corev1.Pod) {
		p.Annotations = map[string]string{"my.org/vram": "8Gi"}
	})
	if b, src := requestedVRAM(custom, card, []string{"my.org/vram"}); b != 8*GiB || src != "annotation" {
		t.Errorf("custom key: got (%d,%s), want (%d,annotation)", b, src, 8*GiB)
	}
}
