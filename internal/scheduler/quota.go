package scheduler

import (
	"context"
	"sync"
	"time"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// QuotaChecker enforces VGPUQuota at scheduling time.
//
// It maintains a small in-memory cache of namespace VRAM usage so the hot
// scheduling path stays O(1). The cache is refreshed lazily on each Filter
// call (cheap) or invalidated externally when slice phases change.
type QuotaChecker struct {
	client client.Client

	mu      sync.RWMutex
	usage   map[string]int64 // namespace → used bytes
	lastRefresh time.Time
}

// NewQuotaChecker returns a new checker bound to the given client.
func NewQuotaChecker(c client.Client) *QuotaChecker {
	return &QuotaChecker{
		client: c,
		usage:  make(map[string]int64),
	}
}

// Check reports whether a request to allocate `requested` bytes in `namespace`
// is allowed under any VGPUQuota that targets the namespace.
//
// Returns:
//   allowed (bool) — true if no quota or quota would not be exceeded
//   reason (string) — short machine-readable code (empty when allowed)
//   message (string) — human-readable explanation
func (q *QuotaChecker) Check(ctx context.Context, namespace string, requested int64) (bool, string, string) {
	// Find any quota for this namespace. Cluster-scoped, so we List all.
	var quotas vgpuv1alpha1.VGPUQuotaList
	if err := q.client.List(ctx, &quotas); err != nil {
		// Fail open — if quota lookup fails, don't block scheduling.
		// Logged in caller. This matches "no quota = unlimited" semantics.
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
		return true, "", "" // No quota = unlimited
	}

	// Compute current namespace usage.
	used, err := q.namespaceUsage(ctx, namespace)
	if err != nil {
		return true, "", "" // fail open
	}

	if used+requested > match.Spec.MaxVramBytes {
		return false, "QuotaExceeded",
			fmtQuotaExceeded(namespace, used, requested, match.Spec.MaxVramBytes)
	}

	return true, "", ""
}

// namespaceUsage returns the sum of allocatedBytes for Ready slices in the
// given namespace. Uses a 5-second cache to avoid hammering the API.
func (q *QuotaChecker) namespaceUsage(ctx context.Context, namespace string) (int64, error) {
	q.mu.RLock()
	cached, hit := q.usage[namespace]
	staleness := time.Since(q.lastRefresh)
	q.mu.RUnlock()

	if hit && staleness < 5*time.Second {
		return cached, nil
	}

	// Refresh.
	var slices vgpuv1alpha1.VGPUSliceList
	if err := q.client.List(ctx, &slices, client.InNamespace(namespace)); err != nil {
		return 0, err
	}
	var total int64
	for _, s := range slices.Items {
		if s.Status.Phase == "Ready" {
			total += s.Status.AllocatedBytes
		}
	}

	q.mu.Lock()
	q.usage[namespace] = total
	q.lastRefresh = time.Now()
	q.mu.Unlock()

	return total, nil
}

// Invalidate clears the cached usage for a namespace, forcing a refresh on
// the next Check call. Useful when a slice transitions to/from Ready.
func (q *QuotaChecker) Invalidate(namespace string) {
	q.mu.Lock()
	delete(q.usage, namespace)
	q.mu.Unlock()
}

func fmtQuotaExceeded(ns string, used, req, max int64) string {
	return "namespace " + ns + " would exceed quota: used=" + i64s(used) +
		" + req=" + i64s(req) + " > max=" + i64s(max) + " bytes"
}

func i64s(v int64) string {
	// Avoid importing strconv just for this; sprintf-style would also pull fmt.
	// strconv is already in go.sum so use it.
	return _i64s(v)
}
