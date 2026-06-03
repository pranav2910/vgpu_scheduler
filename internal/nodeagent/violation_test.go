package nodeagent

import (
	"context"
	"testing"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const giB = int64(1) << 30

func TestEvaluate_HysteresisAndOnset(t *testing.T) {
	d := NewViolationDetector(nil, "node-a", nil, nil, time.Second)
	const uuid = "GPU-x"
	granted := 40 * giB
	over := granted + (512 << 20) // 512 MiB over → beyond the 256 MiB tolerance

	// Under budget → never flagged, no overuse.
	for i := 0; i < 3; i++ {
		if onset, ov, viol := d.evaluate(uuid, 30*giB, granted); onset || viol || ov != 0 {
			t.Fatalf("under budget should not flag: onset=%v ov=%d viol=%v", onset, ov, viol)
		}
	}

	// Over budget must PERSIST overuseStreakThreshold cycles before flagging.
	for i := 1; i <= overuseStreakThreshold; i++ {
		onset, ov, viol := d.evaluate(uuid, over, granted)
		if ov != over-granted {
			t.Fatalf("cycle %d overuse: got %d want %d", i, ov, over-granted)
		}
		wantViol := i >= overuseStreakThreshold
		if viol != wantViol {
			t.Fatalf("cycle %d: viol=%v want %v", i, viol, wantViol)
		}
		if i == overuseStreakThreshold && !onset {
			t.Fatalf("onset must fire on the threshold cycle")
		}
		if i < overuseStreakThreshold && onset {
			t.Fatalf("onset fired early at cycle %d", i)
		}
	}

	// Sustained → still violating, but onset is false (already active).
	if onset, _, viol := d.evaluate(uuid, over, granted); onset || !viol {
		t.Fatalf("sustained: onset=%v viol=%v (want false,true)", onset, viol)
	}
	// Back under budget → clears.
	if _, _, viol := d.evaluate(uuid, 10*giB, granted); viol {
		t.Fatalf("should clear once back under budget")
	}
}

func TestEvaluate_WithinToleranceNotFlagged(t *testing.T) {
	d := NewViolationDetector(nil, "node-a", nil, nil, time.Second)
	granted := 40 * giB
	// 100 MiB over — within the 256 MiB tolerance: reported as overuse, never flagged.
	for i := 0; i < overuseStreakThreshold+2; i++ {
		_, ov, viol := d.evaluate("g", granted+(100<<20), granted)
		if viol {
			t.Fatalf("within tolerance must not flag a violation")
		}
		if ov != 100<<20 {
			t.Fatalf("overuse should still report 100 MiB, got %d", ov)
		}
	}
}

func nodeAgentScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatalf("clientgo AddToScheme: %v", err)
	}
	if err := vgpuv1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("AddToScheme: %v", err)
	}
	return s
}

func mkSlice(name, node, phase string, req int64) *vgpuv1alpha1.VGPUSlice {
	return &vgpuv1alpha1.VGPUSlice{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       vgpuv1alpha1.VGPUSliceSpec{NodeName: node, RequestedVRAMBytes: req},
		Status:     vgpuv1alpha1.VGPUSliceStatus{Phase: vgpuv1alpha1.VGPUSlicePhase(phase)},
	}
}

func TestGrantedBytes_SumsBoundActiveSlicesOnNode(t *testing.T) {
	c := fake.NewClientBuilder().WithScheme(nodeAgentScheme(t)).WithObjects(
		mkSlice("a", "node-a", "Ready", 10*giB),      // counts
		mkSlice("b", "node-a", "Allocating", 10*giB), // counts (bound + active)
		mkSlice("c", "node-a", "Pending", 10*giB),    // skip (not bound)
		mkSlice("d", "node-a", "Failed", 10*giB),     // skip (terminal)
		mkSlice("e", "node-b", "Ready", 10*giB),      // skip (other node)
	).Build()
	d := NewViolationDetector(c, "node-a", nil, nil, time.Second)

	got, err := d.grantedBytes(context.Background())
	if err != nil {
		t.Fatalf("grantedBytes: %v", err)
	}
	if got != 20*giB {
		t.Fatalf("granted: got %d want %d (a + b only)", got, 20*giB)
	}
}
