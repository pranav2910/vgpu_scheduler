package controller

import (
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/webhook"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The controller stamps the workload pod with the keys the mutating webhook
// resolves the slice from. If these ever drift, the webhook stops injecting the
// GPU and pods silently run without one. Lock the contract at compile/test time.
func TestPodKeysMatchWebhookContract(t *testing.T) {
	if vgpuClaimLabel != webhook.VGPUClaimLabel {
		t.Fatalf("label drift: controller %q != webhook %q", vgpuClaimLabel, webhook.VGPUClaimLabel)
	}
	if vgpuClaimAnnotation != webhook.VGPUClaimAnnotation {
		t.Fatalf("annotation drift: controller %q != webhook %q", vgpuClaimAnnotation, webhook.VGPUClaimAnnotation)
	}
}

func TestWorkloadPodName(t *testing.T) {
	if got := workloadPodName("train"); got != "train-workload" {
		t.Fatalf("workloadPodName: got %q want %q", got, "train-workload")
	}
}

func TestBuildWorkloadPod_StampsClaimRefAndDefaults(t *testing.T) {
	r := &VGPUJobReconciler{}
	job := &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: "train", Namespace: "ns"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			PodTemplate: &corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels:      map[string]string{"team": "research"},
					Annotations: map[string]string{"note": "hi"},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{Name: "workload", Image: "img:1"}},
				},
			},
		},
	}

	pod := r.buildWorkloadPod(job, "train-claim", "node-9")

	if pod.Name != "train-workload" || pod.Namespace != "ns" {
		t.Fatalf("name/ns: got %s/%s", pod.Name, pod.Namespace)
	}
	// Webhook contract keys are always present and point at THIS job's claim.
	if pod.Labels[vgpuClaimLabel] != "train-claim" {
		t.Errorf("claim label: got %q", pod.Labels[vgpuClaimLabel])
	}
	if pod.Annotations[vgpuClaimAnnotation] != "train-claim" {
		t.Errorf("claim annotation: got %q", pod.Annotations[vgpuClaimAnnotation])
	}
	// Template metadata is preserved alongside.
	if pod.Labels["team"] != "research" || pod.Annotations["note"] != "hi" {
		t.Errorf("template metadata not preserved: labels=%v annotations=%v", pod.Labels, pod.Annotations)
	}
	// restartPolicy defaults to Never (one-shot workload).
	if pod.Spec.RestartPolicy != corev1.RestartPolicyNever {
		t.Errorf("restartPolicy: got %q want Never", pod.Spec.RestartPolicy)
	}
	if pod.Spec.Containers[0].Image != "img:1" {
		t.Errorf("container image not carried: %q", pod.Spec.Containers[0].Image)
	}
}

func TestBuildWorkloadPod_OverridesClaimKeysAndKeepsRestartPolicy(t *testing.T) {
	r := &VGPUJobReconciler{}
	job := &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: "svc", Namespace: "ns"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			PodTemplate: &corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					// A user trying to bind to someone else's claim must not win.
					Labels:      map[string]string{vgpuClaimLabel: "attacker-claim"},
					Annotations: map[string]string{vgpuClaimAnnotation: "attacker-claim"},
				},
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyOnFailure, // explicit → preserved
					Containers:    []corev1.Container{{Name: "workload", Image: "img"}},
				},
			},
		},
	}

	pod := r.buildWorkloadPod(job, "svc-claim", "node-9")

	if pod.Labels[vgpuClaimLabel] != "svc-claim" || pod.Annotations[vgpuClaimAnnotation] != "svc-claim" {
		t.Errorf("controller must override claim keys to its own claim: labels=%v annotations=%v", pod.Labels, pod.Annotations)
	}
	if pod.Spec.RestartPolicy != corev1.RestartPolicyOnFailure {
		t.Errorf("explicit restartPolicy should be preserved, got %q", pod.Spec.RestartPolicy)
	}
}

func TestDerivePhaseFromPod(t *testing.T) {
	cases := []struct {
		pod  corev1.PodPhase
		want vgpuv1alpha1.VGPUJobPhase
	}{
		{corev1.PodRunning, vgpuv1alpha1.JobPhaseRunning},
		{corev1.PodSucceeded, vgpuv1alpha1.JobPhaseSucceeded},
		{corev1.PodFailed, vgpuv1alpha1.JobPhaseFailed},
		{corev1.PodPending, vgpuv1alpha1.JobPhasePodCreating},
		{corev1.PodPhase("Unknown"), vgpuv1alpha1.JobPhasePodCreating},
	}
	for _, c := range cases {
		got, msg := derivePhaseFromPod(&corev1.Pod{Status: corev1.PodStatus{Phase: c.pod}})
		if got != c.want {
			t.Errorf("pod %s: got %s want %s", c.pod, got, c.want)
		}
		if msg == "" {
			t.Errorf("pod %s: empty message", c.pod)
		}
	}
}

// The pod MUST be pinned to the slice's node: the GPU allocation and the CDI
// spec the runtime resolves the device from exist only there. Unpinned pods
// were a coin flip on multi-node clusters — StartError (CDI device not found)
// whenever kube-scheduler picked the other machine.
func TestBuildWorkloadPod_PinnedToSliceNode(t *testing.T) {
	r := &VGPUJobReconciler{}
	job := &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: "train", Namespace: "ns"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			PodTemplate: &corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "w", Image: "img:1"}}},
			},
		},
	}
	pod := r.buildWorkloadPod(job, "train-claim", "gpu-node-7")
	if pod.Spec.NodeName != "gpu-node-7" {
		t.Fatalf("pod.Spec.NodeName = %q, want the slice's node (gpu-node-7) — unpinned pods StartError on multi-node clusters", pod.Spec.NodeName)
	}
}
