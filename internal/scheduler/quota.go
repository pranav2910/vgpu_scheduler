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
// Usage is the sum of TWO sources, and both are needed for correctness:
//
//  1. The informer List — every slice the API already shows as holding
//     capacity (bound, not Released/Failed). The informer alone is NOT enough:
//     it lags the scheduler's own writes, so a slice bound milliseconds ago is
//     invisible and a burst of submissions can slip past quota.
//  2. The scheduler's own in-flight ledger (VRAMCache assumed/confirmed holds,
//     via PendingNamespaceBytes) — the binds and held gang reservations this
//     scheduler has made that the informer hasn't reflected yet. UID overlap
//     between the two sources is excluded, so nothing is counted twice.
//
// (The earlier 5s usage cache under-counted in exactly this window and was
// removed; the ledger is the complete fix.)
type QuotaChecker struct {
	client client.Client
	cache  *VRAMCache
}

// NewQuotaChecker returns a new checker bound to the given client. cache is
// the scheduler's VRAM cache — the source of in-flight (not-yet-observed)
// admissions; nil disables the in-flight component (informer-only, test use).
func NewQuotaChecker(c client.Client, cache *VRAMCache) *QuotaChecker {
	return &QuotaChecker{client: c, cache: cache}
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

	used, counted, err := q.namespaceUsage(ctx, namespace, excludeGang)
	if err != nil {
		return true, "", "" // fail open
	}

	// In-flight admissions this scheduler has made that the informer can't see
	// yet (just-bound slices, held gang reservations). UIDs already counted —
	// or deliberately excluded as the checked gang's own — are skipped.
	var pending int64
	if q.cache != nil {
		pending = q.cache.PendingNamespaceBytes(namespace, counted)
	}

	if used+pending+demand > match.Spec.MaxVramBytes {
		return false, "QuotaExceeded",
			fmtQuotaExceeded(namespace, used, pending, demand, match.Spec.MaxVramBytes)
	}
	return true, "", ""
}

// namespaceUsage sums the VRAM held by slices the API can see in the
// namespace, excluding any whose gang annotation == excludeGang. A slice holds
// capacity once the scheduler has bound it (spec.nodeName set) and until it is
// Released or Failed.
//
// It also returns the set of UIDs it accounted for BY ANY MEANS — summed,
// covered by the checked gang's gangTotal, or void (terminal) — so the caller
// can exclude exactly those from the in-flight ledger and never double-count.
// Unbound slices are deliberately NOT in the set: if one holds in-flight
// capacity (a converging gang member's reservation), only the ledger sees it.
func (q *QuotaChecker) namespaceUsage(ctx context.Context, namespace, excludeGang string) (int64, map[string]struct{}, error) {
	var slices vgpuv1alpha1.VGPUSliceList
	if err := q.client.List(ctx, &slices, client.InNamespace(namespace)); err != nil {
		return 0, nil, err
	}
	counted := make(map[string]struct{}, len(slices.Items))
	var total int64
	for i := range slices.Items {
		s := &slices.Items[i]
		if excludeGang != "" && s.Annotations != nil &&
			s.Annotations[vgpuv1alpha1.AnnotationGangRef] == excludeGang {
			// The checked gang is accounted for via gangTotal — including its
			// still-converging members' holds, so they must not also surface
			// through the in-flight ledger. Counted regardless of bound state.
			counted[string(s.UID)] = struct{}{}
			continue
		}
		if s.Spec.NodeName == "" {
			continue // not yet admitted via the API; the ledger sees any in-flight hold
		}
		counted[string(s.UID)] = struct{}{}
		switch string(s.Status.Phase) {
		case "Released", "Failed":
			continue // no longer holding capacity (counted: any leftover ledger entry is void)
		}
		total += sliceHeldBytes(s)
	}
	return total, counted, nil
}

// sliceHeldBytes is the VRAM a bound slice is accounted for: its real allocation
// once Ready, otherwise its request (admitted but not yet allocated).
func sliceHeldBytes(s *vgpuv1alpha1.VGPUSlice) int64 {
	if s.Status.AllocatedBytes > 0 {
		return s.Status.AllocatedBytes
	}
	return s.Spec.RequestedVRAMBytes
}

func fmtQuotaExceeded(ns string, used, pending, req, max int64) string {
	return "namespace " + ns + " would exceed quota: used=" + i64s(used) +
		" + inflight=" + i64s(pending) +
		" + req=" + i64s(req) + " > max=" + i64s(max) + " bytes"
}

func i64s(v int64) string {
	return _i64s(v)
}
