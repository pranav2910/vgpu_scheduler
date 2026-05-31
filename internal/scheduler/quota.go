package scheduler

import (
	"context"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// QuotaChecker enforces VGPUQuota at scheduling time.
//
// Quota is enforced GANG-ATOMICALLY. When a gang member is checked, the whole
// gang's demand is weighed against the namespace quota minus the usage of all
// OTHER workloads — so either the entire gang fits or none of it is admitted. A
// gang can never be partially admitted past quota.
//
// Usage is computed fresh from authoritative API state on every check (the
// scheduling path is reconcile-driven, not a hot request path), and counts
// every slice that currently HOLDS capacity — not just Ready ones. Counting
// in-flight (Scheduled/Allocating) admissions closes the window where a slice
// could slip past a stale, Ready-only usage figure. (The earlier 5s usage cache
// caused exactly that and is removed.)
type QuotaChecker struct {
	client client.Client
}

// NewQuotaChecker returns a new checker bound to the given client.
func NewQuotaChecker(c client.Client) *QuotaChecker {
	return &QuotaChecker{client: c}
}

// Check reports whether admitting `requested` bytes in `namespace` is allowed
// under any VGPUQuota that targets the namespace.
//
// For a gang member, pass gangRef (the gang's name) and gangTotal (the gang's
// full VRAM demand); the check weighs the WHOLE gang against the quota and
// excludes the gang's own slices from current usage, so every member reaches
// the same all-or-none verdict. For a solo slice, pass gangRef="" gangTotal=0.
//
// Returns: allowed, a short reason code (empty when allowed), and a message.
func (q *QuotaChecker) Check(ctx context.Context, namespace string, requested int64, gangRef string, gangTotal int64) (bool, string, string) {
	var quotas vgpuv1alpha1.VGPUQuotaList
	if err := q.client.List(ctx, &quotas); err != nil {
		// Fail open — "no quota = unlimited" semantics; logged by the caller.
		return true, "", ""
	}

	var match *vgpuv1alpha1.VGPUQuota
	for i := range quotas.Items {
		if quotas.Items[i].Spec.TargetNamespace == namespace {
			match = &quotas.Items[i]
			break
		}
	}
	if match == nil {
		return true, "", "" // no quota = unlimited
	}

	// Gang members are weighed as a whole, excluding their own slices from the
	// "other usage" tally so the gang is counted exactly once (via gangTotal).
	demand := requested
	excludeGang := ""
	if gangRef != "" && gangTotal > 0 {
		demand = gangTotal
		excludeGang = gangRef
	}

	used, err := q.namespaceUsage(ctx, namespace, excludeGang)
	if err != nil {
		return true, "", "" // fail open
	}

	if used+demand > match.Spec.MaxVramBytes {
		return false, "QuotaExceeded",
			fmtQuotaExceeded(namespace, used, demand, match.Spec.MaxVramBytes)
	}
	return true, "", ""
}

// namespaceUsage sums the VRAM currently held by slices in the namespace,
// excluding any whose gang annotation == excludeGang. A slice holds capacity
// once the scheduler has bound it (spec.nodeName set) and until it is Released
// or Failed — so in-flight (Scheduled/Allocating) admissions are counted.
func (q *QuotaChecker) namespaceUsage(ctx context.Context, namespace, excludeGang string) (int64, error) {
	var slices vgpuv1alpha1.VGPUSliceList
	if err := q.client.List(ctx, &slices, client.InNamespace(namespace)); err != nil {
		return 0, err
	}
	var total int64
	for i := range slices.Items {
		s := &slices.Items[i]
		if s.Spec.NodeName == "" {
			continue // not yet admitted — holds no capacity
		}
		switch string(s.Status.Phase) {
		case "Released", "Failed":
			continue // no longer holding capacity
		}
		if excludeGang != "" && s.Annotations != nil &&
			s.Annotations[vgpuv1alpha1.AnnotationGangRef] == excludeGang {
			continue // this gang is accounted for via gangTotal
		}
		total += sliceHeldBytes(s)
	}
	return total, nil
}

// sliceHeldBytes is the VRAM a bound slice is accounted for: its real allocation
// once Ready, otherwise its request (admitted but not yet allocated).
func sliceHeldBytes(s *vgpuv1alpha1.VGPUSlice) int64 {
	if s.Status.AllocatedBytes > 0 {
		return s.Status.AllocatedBytes
	}
	return s.Spec.RequestedVRAMBytes
}

func fmtQuotaExceeded(ns string, used, req, max int64) string {
	return "namespace " + ns + " would exceed quota: used=" + i64s(used) +
		" + req=" + i64s(req) + " > max=" + i64s(max) + " bytes"
}

func i64s(v int64) string {
	return _i64s(v)
}
