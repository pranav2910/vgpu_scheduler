#!/usr/bin/env bash
# ============================================================================
# Phase 2.3 — over-eviction fix
#
# Bug: under concurrent submissions, TryPreempt may be called multiple times
# for the same requester before victims drain. Each call selects fresh victims
# greedily, causing 2x or 3x over-eviction.
#
# Fix: stamp annotation on requester slice when PLAN created. Subsequent
# TryPreempt calls see the annotation (< 60s old) and return nil — letting
# the original plan's grace timer complete.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".preemptdedup_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/scheduler/preemptor.go "$BACKUP/preemptor.go"
echo "Backup: $BACKUP"

# ============================================================================
# Patch preemptor.go: add an annotation-based dedup gate at the top of
# TryPreempt. Two changes:
#   1. After "p.mu.Unlock()" of the cooldown check, before listing slices,
#      check the requester's annotation. If recent, return nil.
#   2. After "markVictimsPreempting" succeeds, stamp the requester's
#      annotation with the current time.
# ============================================================================
python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/scheduler/preemptor.go")
src = p.read_text()

if "preemption-triggered-at" in src:
    print("  - dedup annotation already present")
else:
    # ---- Change 1: add annotation constant ----
    constants_anchor = '''const (
	PreemptionCooldown    = 60 * time.Second
	PreemptionPriorityGap = int32(100)
	DefaultGraceSeconds   = int32(30)
)'''

    if constants_anchor not in src:
        print("ERROR: constants block not found")
        raise SystemExit(1)

    constants_new = '''const (
	PreemptionCooldown    = 60 * time.Second
	PreemptionPriorityGap = int32(100)
	DefaultGraceSeconds   = int32(30)

	// PreemptionInFlightWindow is how long after a plan was created we
	// suppress new preemption attempts for the same requester. Set to
	// MaxGraceSeconds + buffer; any preemption with a longer custom grace
	// will still be correctly blocked because original victims remain in
	// Preempting phase (not Ready) until they drain.
	PreemptionInFlightWindow = 60 * time.Second

	// AnnotationPreemptionTriggeredAt is set on a requester slice when its
	// preemption plan is generated. Subsequent TryPreempt calls within the
	// in-flight window are no-ops to prevent over-eviction.
	AnnotationPreemptionTriggeredAt = "infrastructure.pranav2910.com/preemption-triggered-at"
)'''

    src = src.replace(constants_anchor, constants_new)

    # ---- Change 2: insert dedup check at top of TryPreempt ----
    # Anchor: the cooldown check on requester. We insert BEFORE it.
    cooldown_anchor = '''	// 1. Cooldown on requester's claim.
	if requesterClaim != nil {'''

    if cooldown_anchor not in src:
        print("ERROR: cooldown anchor not found")
        raise SystemExit(1)

    dedup_block = '''	// 0. In-flight dedup: if this requester already has a preemption
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
	}

	// 1. Cooldown on requester's claim.
	if requesterClaim != nil {'''

    src = src.replace(cooldown_anchor, dedup_block)

    # ---- Change 3: after marking victims, stamp annotation on requester ----
    # Anchor: the line right after markVictimsPreempting succeeds, before
    # the cooldown bookkeeping.
    mark_anchor = '''	// 6. Mark victims as Preempting.
	if err := p.markVictimsPreempting(ctx, plan); err != nil {
		return nil, fmt.Errorf("marking victims: %w", err)
	}

	// 7. Cooldown each victim's claim.'''

    if mark_anchor not in src:
        print("ERROR: mark/cooldown anchor not found")
        raise SystemExit(1)

    mark_new = '''	// 6. Mark victims as Preempting.
	if err := p.markVictimsPreempting(ctx, plan); err != nil {
		return nil, fmt.Errorf("marking victims: %w", err)
	}

	// 6b. Stamp annotation on requester to prevent over-eviction under
	// concurrent reconciles. Best-effort: if this fails, we still proceed
	// (the cooldown on victims also helps). Annotation is on metadata, not
	// status, so we use Patch on the parent object.
	if err := p.markRequesterInFlight(ctx, requester); err != nil {
		log.Printf("[preemptor] WARN: failed to mark requester %s/%s in-flight: %v",
			requester.Namespace, requester.Name, err)
	}

	// 7. Cooldown each victim's claim.'''

    src = src.replace(mark_anchor, mark_new)

    # ---- Change 4: implement markRequesterInFlight helper ----
    # Insert just before CleanupCooldown.
    helper_anchor = "// CleanupCooldown prunes stale cooldown entries."

    if helper_anchor not in src:
        print("ERROR: CleanupCooldown anchor not found")
        raise SystemExit(1)

    new_helper = '''// markRequesterInFlight stamps the requester slice with an annotation
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
}

// CleanupCooldown prunes stale cooldown entries.'''

    src = src.replace(helper_anchor, new_helper)

    p.write_text(src)
    print("  ✓ in-flight dedup added to Preemptor")
PYEOF

# ============================================================================
# Build + deploy
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

TAG="p23dedup_$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ image built ($TAG)"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-p23dedup.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p23dedup.tar > /dev/null

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false

# Cleanup state from prior tests
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuquota -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 30

# Final force-strip pass for stragglers
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
sleep 10

echo ""
echo "=== Pods ==="
kubectl get pods -n vgpu-system

echo ""
echo "=== Scheduler image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ Dedup fix applied. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Now re-run the stress test to verify single-victim selection."
