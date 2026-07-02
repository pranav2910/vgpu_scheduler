package main

// Sweep S3 regression: a node delete + same-name re-register arrives with
// allocated=0 while its Ready slices still physically hold VRAM — and a node
// flap generates ZERO slice events, so nothing re-promoted them. The node sat
// at free=total (an over-admission window) until an incidental slice write.
// The node reconciler must re-walk the node's Ready slices on registration.

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/pranav2910/vgpu-scheduler/internal/scheduler"
)

func TestNodeReRegistrationReChargesReadySlices(t *testing.T) {
	const giB = int64(1) << 30
	ctx := context.Background()
	s := runtime.NewScheme()
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := corev1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "n1"},
		Status: corev1.NodeStatus{
			Capacity: corev1.ResourceList{vramResourceName: *resource.NewQuantity(80*giB, resource.BinarySI)},
			// Real kubelets always report Allocatable; consumedVRAMOnNode reads
			// capacity-allocatable, so omitting it fakes a fully-consumed node.
			Allocatable: corev1.ResourceList{vramResourceName: *resource.NewQuantity(80*giB, resource.BinarySI)},
			Conditions:  []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}},
		},
	}
	readySlice := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "live-claim-slice", Namespace: "default", UID: types.UID("uid-live")},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{RequestedVRAMBytes: 64 * giB, NodeName: "n1", ClaimRef: "live-claim"},
		Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: "Ready", AllocatedBytes: 64 * giB},
	}
	c := fake.NewClientBuilder().WithScheme(s).WithObjects(node, readySlice).Build()

	cache := scheduler.NewVRAMCache()
	r := &nodeCapacityReconciler{cache: cache, client: c}
	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "n1"}}

	// Initial registration: node enters the cache AND its Ready slice charges.
	if _, err := r.Reconcile(ctx, req); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if ok, _, _ := cache.CanFit("n1", 32*giB); ok {
		t.Fatalf("initial registration must re-charge the 64Gi Ready slice (80-64=16 free; 32 must not fit)")
	}

	// Node flap: delete drops it from the candidate set (and clears the ledger),
	// then the same-name node re-registers with allocated=0.
	cache.RemoveNode("n1")
	if _, err := r.Reconcile(ctx, req); err != nil {
		t.Fatalf("re-register reconcile: %v", err)
	}
	if ok, _, _ := cache.CanFit("n1", 32*giB); ok {
		t.Fatalf("OVER-ADMISSION WINDOW: re-registered node shows free=total while its Ready slice still holds 64Gi")
	}
	if ok, _, _ := cache.CanFit("n1", 8*giB); !ok {
		t.Fatalf("node must still fit small work (16Gi genuinely free)")
	}
}
