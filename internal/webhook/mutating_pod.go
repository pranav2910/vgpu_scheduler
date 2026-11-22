package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strconv"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/pranav2910/vgpu-scheduler/internal/security"
)

const (
	// VGPUClaimAnnotation carries the claim name the pod is bound to.
	VGPUClaimAnnotation = "infrastructure.pranav2910.com/claim-ref"
	// VGPUClaimLabel is the K8s label used by the webhook's objectSelector.
	// Required because admission webhooks can only select on labels, not annotations.
	VGPUClaimLabel = "vgpu-claim"
	// CDIAnnotationPrefix is the containerd CDI injection annotation prefix.
	// Bug #39: we inject via the CDI annotation that containerd honours,
	// not via NVIDIA_VISIBLE_DEVICES (the legacy container-toolkit path).
	CDIAnnotationKey = "cdi.k8s.io/vgpu-pranav2910-com"
)

// PodMutator carries a K8s client so the webhook can resolve the bound slice.
type PodMutator struct {
	Client client.Client
}

// MutatePod injects the CDI device reference resolved from the bound slice.
func (m *PodMutator) MutatePod(ctx context.Context, pod *corev1.Pod) error {
	// Claim can come from an annotation (preferred, carries the name) or
	// from the matching label (which only asserts "this pod wants a vGPU").
	claimName, exists := pod.Annotations[VGPUClaimAnnotation]
	if !exists {
		// Fall back to the label — in which case the label value IS the claim name.
		claimName = pod.Labels[VGPUClaimLabel]
	}
	if claimName == "" {
		return nil
	}

	if err := security.ValidatePodSecurity(pod); err != nil {
		return err
	}
	if m.Client == nil {
		return fmt.Errorf("pod mutator not wired with a K8s client")
	}

	sliceName := claimName + "-slice"
	var slice vgpuv1alpha1.VGPUSlice
	if err := m.Client.Get(ctx, types.NamespacedName{Name: sliceName, Namespace: pod.Namespace}, &slice); err != nil {
		return fmt.Errorf("resolving vGPU slice %s/%s: %w", pod.Namespace, sliceName, err)
	}
	if slice.Status.AllocationID == "" {
		return fmt.Errorf("vGPU slice %s/%s not yet allocated (phase=%s)", pod.Namespace, sliceName, slice.Status.Phase)
	}

	// Bug #39: CDI injection via annotation, not env var.
	// Format: "<vendor>/<class>=<device-name>"
	cdiDevice := fmt.Sprintf("infrastructure.pranav2910.com/vgpu=%s", slice.Status.AllocationID)
	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}
	// Merge with any existing CDI annotation value.
	if existing, ok := pod.Annotations[CDIAnnotationKey]; ok && existing != "" {
		pod.Annotations[CDIAnnotationKey] = existing + "," + cdiDevice
	} else {
		pod.Annotations[CDIAnnotationKey] = cdiDevice
	}

	// Pin the pod to ITS OWN card by SETTING NVIDIA_VISIBLE_DEVICES in the pod
	// spec. The CDI edit above only APPENDS an env entry to the OCI process —
	// but nvidia/cuda base images bake NVIDIA_VISIBLE_DEVICES=all into the
	// IMAGE, and with duplicate entries the winner is runtime-dependent. On a
	// multi-GPU node that ambiguity exposed every card to every pod (caught
	// live on an 8×V100: pod B saw pod A's GPU; single-GPU boxes made the bug
	// invisible because "all" ≡ the one card). Pod-spec env unambiguously
	// OVERRIDES image env in Kubernetes, so this pin always wins.
	if slice.Status.DeviceUUID != "" {
		pinEnv(pod, "NVIDIA_VISIBLE_DEVICES", slice.Status.DeviceUUID)
	}

	// Also surface the allocation for workloads that want to read it.
	// Informational only — not used for device binding.
	payload, _ := json.Marshal(map[string]string{
		"allocationId": slice.Status.AllocationID,
		"deviceUuid":   slice.Status.DeviceUUID,
		"sliceName":    slice.Name,
	})
	pod.Annotations["infrastructure.pranav2910.com/allocation-info"] = string(payload)

	// Stamp the pod's granted VRAM so MONITOR MODE can attribute it (source=
	// vgpu_claim). The monitor is deliberately pods-RBAC-only — it cannot read
	// VGPUClaims — so the request must live ON the pod. Gate-3 receipt finding:
	// without this stamp, a VGPUJob pod that isn't actively using VRAM was
	// entirely invisible to the waste report ("works on VGPUJob pods" DoD).
	pod.Annotations["infrastructure.pranav2910.com/requested-vram-bytes"] =
		strconv.FormatInt(slice.Spec.RequestedVRAMBytes, 10)

	log.Printf("Pod %s/%s mutated for vGPU claim %s (alloc=%s)",
		pod.Namespace, pod.Name, claimName, slice.Status.AllocationID)
	return nil
}

// pinEnv upserts name=value into every container and initContainer: replaces
// an existing entry (a user/template-set value must not fight the platform's
// device pin) and appends where absent.
func pinEnv(pod *corev1.Pod, name, value string) {
	upsert := func(c *corev1.Container) {
		for i := range c.Env {
			if c.Env[i].Name == name {
				c.Env[i].Value = value
				c.Env[i].ValueFrom = nil
				return
			}
		}
		c.Env = append(c.Env, corev1.EnvVar{Name: name, Value: value})
	}
	for i := range pod.Spec.Containers {
		upsert(&pod.Spec.Containers[i])
	}
	for i := range pod.Spec.InitContainers {
		upsert(&pod.Spec.InitContainers[i])
	}
}
