package scheduler

// Sweep S5 regression: gang members must be ineligible as preemption victims.
// The victim sort prices a candidate as ONE slice, but preempting a single
// member trips the committed gang's child-loss teardown — the whole gang dies
// with zero grace for siblings, so the real damage is N×bytes. Before the fix
// the preemptor picked a 15Gi gang member over a 16Gi solo victim.

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func preemptVictimJob(name string) *vgpuv1alpha1.VGPUJob {
	return &vgpuv1alpha1.VGPUJob{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: vgpuv1alpha1.VGPUJobSpec{
			ClaimTemplate: vgpuv1alpha1.VGPUClaimTemplate{Spec: vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: 1 << 33}},
			Priority:      0,
			Preemptible:   true,
		},
	}
}

func preemptVictimClaim(name, jobRef string) *vgpuv1alpha1.VGPUClaim {
	return &vgpuv1alpha1.VGPUClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUClaimSpec{RequestedVRAMBytes: 1 << 33, JobRef: jobRef},
	}
}

func preemptVictimSlice(name, claimRef string, allocated int64, gangAnnotations map[string]string) *vgpuv1alpha1.VGPUSlice {
	return &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name: name, Namespace: "default",
			UID:         types.UID("uid-" + name),
			Annotations: gangAnnotations,
		},
		Spec: vgpuv1alpha1.VGPUSliceSpec{RequestedVRAMBytes: allocated, ClaimRef: claimRef, NodeName: "n1"},
		Status: vgpuv1alpha1.VGPUSliceStatus{
			Phase:          "Ready",
			AllocatedBytes: allocated,
		},
	}
}

func TestPreemptorSkipsGangMembersAsVictims(t *testing.T) {
	ctx := context.Background()
	const giB = int64(1) << 30

	// Solo victim: 16Gi. Gang member: 15Gi (CHEAPER by the sort) but carries
	// the gang reservation-ref annotation.
	soloJob, gangJob := preemptVictimJob("solo"), preemptVictimJob("gangchild")
	soloClaim := preemptVictimClaim("solo-claim", "solo")
	gangClaim := preemptVictimClaim("gangchild-claim", "gangchild")
	soloSlice := preemptVictimSlice("solo-claim-slice", "solo-claim", 16*giB, nil)
	gangSlice := preemptVictimSlice("gangchild-claim-slice", "gangchild-claim", 15*giB, map[string]string{
		vgpuv1alpha1.AnnotationReservationRef: "gg-rsv",
		vgpuv1alpha1.AnnotationGangRef:        "gg",
	})

	requesterClaim := preemptVictimClaim("vip-claim", "vip")
	requester := preemptVictimSlice("vip-claim-slice", "vip-claim", 0, nil)
	requester.Status.Phase = "Pending"
	requester.Status.AllocatedBytes = 0

	c := fake.NewClientBuilder().
		WithScheme(gangTestScheme(t)).
		WithObjects(soloJob, gangJob, soloClaim, gangClaim, soloSlice, gangSlice, requesterClaim, requester).
		WithStatusSubresource(&vgpuv1alpha1.VGPUSlice{}).
		Build()
	p := NewPreemptor(c)

	plan, err := p.TryPreempt(ctx, requester, 200, requesterClaim, 8*giB)
	if err != nil {
		t.Fatalf("TryPreempt: %v", err)
	}
	if plan == nil || len(plan.Victims) == 0 {
		t.Fatalf("expected a plan with the solo victim, got none")
	}
	for _, v := range plan.Victims {
		if v.Slice.Name == "gangchild-claim-slice" {
			t.Fatalf("gang member selected as victim — evicting it tears down the WHOLE gang with no grace (mispriced as one slice)")
		}
	}
	if plan.Victims[0].Slice.Name != "solo-claim-slice" {
		t.Fatalf("expected the solo victim, got %s", plan.Victims[0].Slice.Name)
	}
}
