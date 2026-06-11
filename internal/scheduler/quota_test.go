package scheduler

import (
	"context"
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const qGiB = int64(1) << 30

func quotaObj(ns string, maxBytes int64) *vgpuv1alpha1.VGPUQuota {
	return &vgpuv1alpha1.VGPUQuota{
		ObjectMeta: metav1.ObjectMeta{Name: "q", Namespace: ns},
		Spec:       vgpuv1alpha1.VGPUQuotaSpec{TargetNamespace: ns, MaxVramBytes: maxBytes},
	}
}

// qSlice builds a slice with a unique name so multiple can coexist in the fake
// client (which keys by name).
func qSlice(name, gang string, req, alloc int64, node, phase string) *vgpuv1alpha1.VGPUSlice {
	s := &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{NodeName: node, RequestedVRAMBytes: req},
		Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase(phase), AllocatedBytes: alloc},
	}
	if gang != "" {
		s.Annotations = map[string]string{vgpuv1alpha1.AnnotationGangRef: gang}
	}
	return s
}

// buildChecker wires a fake client with the given objects.
func buildChecker(t *testing.T, objs ...client.Object) *QuotaChecker {
	t.Helper()
	b := fake.NewClientBuilder().WithScheme(gangTestScheme(t))
	if len(objs) > 0 {
		b = b.WithObjects(objs...)
	}
	return NewQuotaChecker(b.Build(), nil)
}

func TestQuota_NoQuota_AllowsEverything(t *testing.T) {
	qc := buildChecker(t) // no quota object
	if ok, _, _ := qc.Check(context.Background(), "default", 999*qGiB, "", 0); !ok {
		t.Fatalf("with no quota, everything should be allowed")
	}
}

func TestQuota_SoloSlice_CountsInFlight(t *testing.T) {
	// 40 GiB quota. An admitted-but-NOT-Ready slice (Scheduled, nodeName set)
	// holds 35 GiB. A solo 10 GiB request would push to 45 > 40 → reject.
	// This is the case the old Ready-only count missed.
	qc := buildChecker(t,
		quotaObj("default", 40*qGiB),
		qSlice("s1", "", 35*qGiB, 0, "node-a", "Scheduled"), // in-flight, not Ready
	)
	if ok, reason, _ := qc.Check(context.Background(), "default", 10*qGiB, "", 0); ok {
		t.Fatalf("expected reject (35 in-flight + 10 > 40); got allowed")
	} else if reason != "QuotaExceeded" {
		t.Fatalf("reason: got %q want QuotaExceeded", reason)
	}
	// A 5 GiB request fits (35+5=40).
	if ok, _, _ := qc.Check(context.Background(), "default", 5*qGiB, "", 0); !ok {
		t.Fatalf("expected allow (35+5=40 == quota)")
	}
}

func TestQuota_PendingAndTerminalSlicesDoNotCount(t *testing.T) {
	// Pending (no nodeName), Released, and Failed slices hold no capacity.
	qc := buildChecker(t,
		quotaObj("default", 40*qGiB),
		qSlice("pending", "", 30*qGiB, 0, "", "Pending"),         // no nodeName
		qSlice("released", "", 30*qGiB, 30*qGiB, "node-a", "Released"),
		qSlice("failed", "", 30*qGiB, 0, "node-a", "Failed"),
	)
	// None count → a 40 GiB request fits.
	if ok, _, _ := qc.Check(context.Background(), "default", 40*qGiB, "", 0); !ok {
		t.Fatalf("pending/released/failed slices must not consume quota")
	}
}

func TestQuota_GangAtomic_RejectsWholeGangPastQuota(t *testing.T) {
	// The 3.4 scenario: quota 40, Q1 fully committed (40 Ready). Gang Q2 (4×10 =
	// 40 total) must be rejected WHOLE — every member sees the same verdict.
	qc := buildChecker(t,
		quotaObj("default", 40*qGiB),
		qSlice("q1-0", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-1", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-2", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-3", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
	)
	// Each Q2 member is checked with the gang's full demand (40) → 40+40 > 40.
	if ok, reason, _ := qc.Check(context.Background(), "default", 10*qGiB, "q2", 40*qGiB); ok {
		t.Fatalf("gang Q2 should be rejected whole (used 40 + gang 40 > 40); got allowed (reason=%q)", reason)
	}
}

func TestQuota_GangAtomic_FitsWhenWholeGangFits(t *testing.T) {
	// Quota 80, Q1 using 40. Gang Q2 total 40 → 40+40 = 80 ≤ 80 → allowed.
	qc := buildChecker(t,
		quotaObj("default", 80*qGiB),
		qSlice("q1-0", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-1", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-2", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-3", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
	)
	if ok, _, _ := qc.Check(context.Background(), "default", 10*qGiB, "q2", 40*qGiB); !ok {
		t.Fatalf("gang Q2 (40) should fit alongside Q1 (40) under an 80 quota")
	}
}

func TestQuota_GangAtomic_ExcludesOwnPartialSlices(t *testing.T) {
	// Defensive: even if a Q2 member already got admitted, the gang check must
	// exclude Q2's own slices from "other usage" so the gang is counted exactly
	// once (via gangTotal), not double-counted. Quota 80, Q1=40 Ready, Q2 has
	// one stray admitted slice (10). Gang demand 40. 40(Q1) + 40(gang) = 80 ≤ 80.
	qc := buildChecker(t,
		quotaObj("default", 80*qGiB),
		qSlice("q1-0", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-1", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-2", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q1-3", "q1", 10*qGiB, 10*qGiB, "node-a", "Ready"),
		qSlice("q2-0", "q2", 10*qGiB, 10*qGiB, "node-a", "Ready"), // stray Q2 slice
	)
	// Without exclusion this would be 50 + 40 = 90 > 80 (false reject).
	if ok, _, _ := qc.Check(context.Background(), "default", 10*qGiB, "q2", 40*qGiB); !ok {
		t.Fatalf("gang check must exclude its own slices; expected allow (40 other + 40 gang = 80)")
	}
}
