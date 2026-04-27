#!/usr/bin/env bash
# ============================================================================
# Phase 2.3 TOCTOU race fix
#
# Bug: dedup gate reads annotation, then stamps it later after victim
# selection. Under concurrent sub-second reconciles, two calls can both
# pass the read before either stamps, causing 2x over-eviction.
#
# Fix: replace the two-step (read-then-stamp) pattern with a single
# atomic compare-and-swap using Kubernetes optimistic concurrency.
# Stamp the annotation FIRST. If Update succeeds, we own this preemption
# plan. If it conflicts, another reconcile won the race — return nil.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".toctou_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/scheduler/preemptor.go "$BACKUP/preemptor.go"
echo "Backup: $BACKUP"

# ============================================================================
# Replace the two-step pattern with atomic claim-the-plan logic.
# ============================================================================
python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/scheduler/preemptor.go")
src = p.read_text()

if "claimPlanOwnership" in src:
    print("  - atomic dedup already present")
    raise SystemExit(0)

# ---- Step 1: replace the read-only dedup check with atomic claim ----
# Old read-only check:
old_check = '''	// 0. In-flight dedup: if this requester already has a preemption
	// triggered within the past PreemptionInFlightWindow, skip. This
	// prevents over-eviction under concurrent reconciles where the same
	// requester would otherwise generate multiple plans before victims drain.
	if requester.Annotations != nil {
		if ts, ok := requester.Annotations[AnnotationPreemptionTriggeredAt]; ok {
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				if time.Since(t) < PreemptionInFlightWindow {
					log.Printf("[preemptor] %s/%s: preemption already in flight (triggered %v ago) — skip",
						requester.Namespace, requester.Name, time.Since(t).Round(time.Second))
					return nil, nil
				}
			}
		}
	}'''

new_check = '''	// 0. Atomic dedup gate: claim ownership of this preemption plan via
	// Kubernetes optimistic concurrency. Stamp the annotation FIRST.
	// If our Update succeeds, we own this plan and proceed.
	// If another reconcile stamped first (annotation present and recent),
	// or if our Update conflicts (resourceVersion mismatch), bail out.
	// This eliminates the TOCTOU race where two concurrent reconciles
	// could both pass a read-only gate before either stamped the annotation.
	owned, err := p.claimPlanOwnership(ctx, requester)
	if err != nil {
		// Conflict / not-found / transient error — another reconcile owns
		// the plan or the slice changed under us. Don't proceed.
		log.Printf("[preemptor] %s/%s: could not claim plan ownership: %v — skip",
			requester.Namespace, requester.Name, err)
		return nil, nil
	}
	if !owned {
		// Annotation already present and recent — another plan in flight.
		return nil, nil
	}'''

if old_check not in src:
    print("ERROR: old dedup block not found")
    raise SystemExit(1)

src = src.replace(old_check, new_check)

# ---- Step 2: remove the old "Step 6b" stamp (no longer needed; we stamped at step 0) ----
old_step6b = '''	// 6b. Stamp annotation on requester to prevent over-eviction under
	// concurrent reconciles. Best-effort: if this fails, we still proceed
	// (the cooldown on victims also helps). Annotation is on metadata, not
	// status, so we use Patch on the parent object.
	if err := p.markRequesterInFlight(ctx, requester); err != nil {
		log.Printf("[preemptor] WARN: failed to mark requester %s/%s in-flight: %v",
			requester.Namespace, requester.Name, err)
	}

	'''

# Anchor for after step 6b removal
new_step6b = '	'

if old_step6b in src:
    src = src.replace(old_step6b, new_step6b)
    print("  ✓ removed redundant step 6b annotation stamp")
else:
    print("  - step 6b not found; may already be removed")

# ---- Step 3: replace markRequesterInFlight with claimPlanOwnership ----
old_helper = '''// markRequesterInFlight stamps the requester slice with an annotation
// recording when the preemption plan was created. Subsequent TryPreempt
// calls within PreemptionInFlightWindow will skip to prevent over-eviction.
func (p *Preemptor) markRequesterInFlight(ctx context.Context, requester *vgpuv1alpha1.VGPUSlice) error {
	key := client.ObjectKey{Namespace: requester.Namespace, Name: requester.Name}
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var fresh vgpuv1alpha1.VGPUSlice
		if err := p.client.Get(ctx, key, &fresh); err != nil {
			return err
		}
		if fresh.Annotations == nil {
			fresh.Annotations = make(map[string]string)
		}
		fresh.Annotations[AnnotationPreemptionTriggeredAt] = time.Now().UTC().Format(time.RFC3339)
		return p.client.Update(ctx, &fresh)
	})
}'''

new_helper = '''// claimPlanOwnership atomically reserves the right to generate a preemption
// plan for this requester. Returns:
//   (true,  nil) — we won the race and stamped the annotation; proceed.
//   (false, nil) — another reconcile already has a fresh annotation; skip.
//   (false, err) — resource changed under us (conflict) or other error;
//                  caller should treat this as "skip to be safe".
//
// This is the atomic alternative to a separate read-then-stamp dedup,
// which had a TOCTOU race window where two concurrent reconciles could
// both pass a read-only gate before either stamped the annotation.
func (p *Preemptor) claimPlanOwnership(ctx context.Context, requester *vgpuv1alpha1.VGPUSlice) (bool, error) {
	key := client.ObjectKey{Namespace: requester.Namespace, Name: requester.Name}
	var fresh vgpuv1alpha1.VGPUSlice
	if err := p.client.Get(ctx, key, &fresh); err != nil {
		return false, err
	}

	// If a recent annotation already exists, we don't own this plan.
	if fresh.Annotations != nil {
		if ts, ok := fresh.Annotations[AnnotationPreemptionTriggeredAt]; ok {
			if t, perr := time.Parse(time.RFC3339, ts); perr == nil {
				if time.Since(t) < PreemptionInFlightWindow {
					return false, nil
				}
			}
		}
	}

	// Stamp it. Update uses optimistic concurrency: if another reconcile
	// has modified `fresh` since our Get (e.g. by stamping the annotation
	// themselves), this Update returns a conflict and we treat it as
	// "we lost the race".
	if fresh.Annotations == nil {
		fresh.Annotations = make(map[string]string)
	}
	fresh.Annotations[AnnotationPreemptionTriggeredAt] = time.Now().UTC().Format(time.RFC3339)

	if err := p.client.Update(ctx, &fresh); err != nil {
		// Conflict or other error — caller treats as "skip".
		return false, err
	}
	return true, nil
}'''

if old_helper not in src:
    print("ERROR: old markRequesterInFlight helper not found")
    raise SystemExit(1)

src = src.replace(old_helper, new_helper)
print("  ✓ replaced markRequesterInFlight with atomic claimPlanOwnership")

# ---- Step 4: check whether retry import is still needed ----
# claimPlanOwnership doesn't use retry.RetryOnConflict — but other functions
# in preemptor.go might. Don't remove the import.
p.write_text(src)
print("  ✓ atomic dedup gate installed")
PYEOF

# ============================================================================
# Verify build
# ============================================================================
echo ""
echo "Running go vet..."
if ! go vet ./...; then
    echo "ERROR: go vet failed. Backup at: $BACKUP"
    exit 1
fi

echo ""
echo "Building scheduler..."
go build -o bin/scheduler ./cmd/scheduler || {
    echo "build failed — restoring"
    cp -p "$BACKUP/preemptor.go" internal/scheduler/preemptor.go
    exit 1
}
echo "  ✓ scheduler builds"

# ============================================================================
# Image + deploy
# ============================================================================
TAG="p23toctou_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ image built ($TAG)"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-p23toctou.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23toctou.tar > /dev/null

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false

# Cleanup any state
for ns in default ml-team-a ml-team-pre team-prod team-research recovery-test; do
    kubectl get vgpujob,vgpuclaim,vgpuslice -n $ns -o name 2>/dev/null | \
        xargs -I{} kubectl patch {} -n $ns --type=json \
            -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null
done
kubectl get vgpuquota -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} --type=json \
        -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null

kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 45

echo ""
echo "=== Cluster state ==="
kubectl get vgpujob -A
kubectl get vgpuclaim -A
kubectl get vgpuslice -A
kubectl get vgpuquota

echo ""
echo "=== Pods ==="
kubectl get pods -n vgpu-system

echo ""
echo "=== Scheduler image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ TOCTOU fix applied. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Now re-run the stress test:"
echo "  bash stress_test_realworld.sh 2>&1 | tee stress_test_FINAL2.log"
