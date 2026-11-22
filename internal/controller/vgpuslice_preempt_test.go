package controller

// Sweep S4 regression: preemption eviction must not be one-shot. If the pod
// delete (or owner-job resolve) fails at grace expiry, the slice must STAY
// Preempting and the reconcile must return an error (retry with backoff) —
// falling through to Releasing meant the victim pod kept physically using
// VRAM the scheduler was already re-selling, and the delete was never retried.

import (
	"context"
	"fmt"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// podDeleteFailingClient fails every Pod Delete — a transient API outage at
// exactly the wrong moment.
type podDeleteFailingClient struct {
	client.Client
	failing bool
}

func (p *podDeleteFailingClient) Delete(ctx context.Context, obj client.Object, opts ...client.DeleteOption) error {
	if _, ok := obj.(*corev1.Pod); ok && p.failing {
		return fmt.Errorf("simulated transient pod-delete outage")
	}
	return p.Client.Delete(ctx, obj, opts...)
}

func TestPreemptingSliceStaysPreemptingUntilEvictSucceeds(t *testing.T) {
	ctx := context.Background()
	scheme := selfhealScheme(t)

	job := &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: "victim", Namespace: "ns"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{Spec: vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: 1 << 33}},
			PodTemplate: &corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "workload", Image: "img"}}},
			},
		},
	}
	claim := &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "victim-claim", Namespace: "ns"},
		Spec:       vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: 1 << 33, JobRef: "victim"},
	}
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: workloadPodName("victim"), Namespace: "ns"}}
	slice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "victim-claim-slice", Namespace: "ns"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{RequestedVRAMBytes: 1 << 33, ClaimRef: "victim-claim"},
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase: "Preempting",
			Conditions: []metav1.Condition{{
				Type:               "Preempting",
				Status:             metav1.ConditionTrue,
				Reason:             "Preempted",
				Message:            "preempted by higher-priority work",
				LastTransitionTime: metav1.NewTime(time.Now().Add(-10 * time.Minute)), // grace long expired
			}},
		},
	}

	base := fake.NewClientBuilder().WithScheme(scheme).
		WithObjects(job, claim, pod, slice).
		WithStatusSubresource(&vgpuv1alpha1.VGPUSlice{}, &vgpuv1alpha1.VGPUJob{}).
		Build()
	failing := &podDeleteFailingClient{Client: base, failing: true}
	r := &VGPUSliceReconciler{Client: failing}
	req := reconcile.Request{NamespacedName: types.NamespacedName{Namespace: "ns", Name: "victim-claim-slice"}}

	// Round 1: pod delete fails → reconcile must ERROR and the slice must
	// still be Preempting (not fall through to Releasing).
	if _, err := r.Reconcile(ctx, req); err == nil {
		t.Fatalf("reconcile must surface the evict failure so it retries")
	}
	var after vgpuv1alpha1.VGPUSlice
	if err := base.Get(ctx, req.NamespacedName, &after); err != nil {
		t.Fatal(err)
	}
	if string(after.Status.Phase) != "Preempting" {
		t.Fatalf("slice left Preempting despite failed eviction: phase=%s (victim pod would keep VRAM the scheduler re-sells)", after.Status.Phase)
	}

	// Round 2: outage over → eviction lands, pod gone, slice moves Releasing.
	failing.failing = false
	if _, err := r.Reconcile(ctx, req); err != nil {
		t.Fatalf("reconcile after outage: %v", err)
	}
	if err := base.Get(ctx, req.NamespacedName, &after); err != nil {
		t.Fatal(err)
	}
	if string(after.Status.Phase) != "Releasing" {
		t.Fatalf("slice should transition Releasing after successful evict, got %s", after.Status.Phase)
	}
	var gone corev1.Pod
	if err := base.Get(ctx, types.NamespacedName{Namespace: "ns", Name: workloadPodName("victim")}, &gone); err == nil {
		t.Fatalf("victim pod must be deleted before the slice releases")
	}
	var freshJob vgpuv1alpha1.VGPUJob
	if err := base.Get(ctx, types.NamespacedName{Namespace: "ns", Name: "victim"}, &freshJob); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range freshJob.Status.Conditions {
		if c.Type == preemptedConditionType && c.Status == metav1.ConditionTrue {
			found = true
		}
	}
	if !found {
		t.Fatalf("Preempted condition must be stamped on the owning job")
	}
}
