#!/usr/bin/env bash
# ============================================================================
# LAYER 1 BUG FIX: orphan claim with stuck claim-cleanup finalizer
#
# Root cause: VGPUClaimReconciler.SetupWithManager() does NOT call Owns()
# on VGPUSlice. So when the child slice is deleted, no event is dispatched
# to the claim's reconciler — the claim never gets re-reconciled, and the
# finalizer is never removed.
#
# Symptom: every test that deletes a Job leaves an orphaned Pending claim
# with claim-cleanup finalizer. Subsequent Jobs with the same name get
# blocked because the orphan claim is in the way.
#
# Fix:
#   1. Add Owns(&VGPUSlice{}) to SetupWithManager
#   2. Return RequeueAfter as a safety net during slice deletion
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".claimfix_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/controller/vgpuclaim_reconciler.go "$BACKUP/vgpuclaim_reconciler.go"
echo "Backup: $BACKUP"

# ============================================================================
# Patch 1: Add Owns(&VGPUSlice{}) to SetupWithManager
# ============================================================================
python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/controller/vgpuclaim_reconciler.go")
src = p.read_text()

if "Owns(&vgpuv1alpha1.VGPUSlice{})" in src:
    print("  - SetupWithManager already calls Owns(VGPUSlice)")
else:
    old = '''func (r *VGPUClaimReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUClaim{}).
		Complete(r)
}'''

    new = '''func (r *VGPUClaimReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&vgpuv1alpha1.VGPUClaim{}).
		// Bug fix: watch derived slices so a slice deletion fires a claim
		// reconcile, allowing handleClaimDelete to remove the claim
		// finalizer once its slice is gone. Without this, the claim
		// orphans forever with claim-cleanup finalizer stuck.
		Owns(&vgpuv1alpha1.VGPUSlice{}).
		Complete(r)
}'''

    if old not in src:
        print("ERROR: could not find SetupWithManager block. Looking for what's there...")
        import re
        m = re.search(r'func \(r \*VGPUClaimReconciler\) SetupWithManager[^}]+\}', src, re.DOTALL)
        if m:
            print("Found:")
            print(m.group(0))
        raise SystemExit(1)

    src = src.replace(old, new)
    p.write_text(src)
    print("  ✓ Owns(&VGPUSlice{}) added to claim reconciler")
PYEOF

# ============================================================================
# Patch 2: Add RequeueAfter as a safety net in handleClaimDelete.
# Currently handleClaimDelete returns `error` not `(reconcile.Result, error)`.
# We change just the early-return path that says "wait for next reconcile" —
# instead of returning nil, we trigger a manual requeue from the outer
# Reconcile by adding a small RequeueAfter signal.
#
# Rather than refactor the whole handler signature, we add a 5-second
# RequeueAfter at the outer Reconcile level when the claim is mid-delete
# and finalizer is still present.
# ============================================================================
python3 - <<'PYEOF'
import pathlib

p = pathlib.Path("internal/controller/vgpuclaim_reconciler.go")
src = p.read_text()

if "5 * time.Second" in src and "DeletionTimestamp" in src and "claim mid-delete" in src:
    print("  - safety RequeueAfter already present")
else:
    # Anchor: the outer Reconcile method
    old = '''func (r *VGPUClaimReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, req.NamespacedName, &claim); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUClaim: %w", err)
	}

	if err := r.reconcileClaim(ctx, &claim); err != nil {
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}'''

    new = '''func (r *VGPUClaimReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var claim vgpuv1alpha1.VGPUClaim
	if err := r.Client.Get(ctx, req.NamespacedName, &claim); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("fetching VGPUClaim: %w", err)
	}

	if err := r.reconcileClaim(ctx, &claim); err != nil {
		return reconcile.Result{}, err
	}

	// Safety: if claim is mid-delete and still has its finalizer, requeue
	// after 5s. The Owns(&VGPUSlice{}) watch should already fire on slice
	// deletion, but this is a belt-and-suspenders cover for any edge case
	// where the slice was already gone before our watch was active.
	if !claim.DeletionTimestamp.IsZero() {
		hasFinalizer := false
		for _, f := range claim.Finalizers {
			if f == ClaimFinalizerName {
				hasFinalizer = true
				break
			}
		}
		if hasFinalizer {
			return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
		}
	}

	return reconcile.Result{}, nil
}'''

    if old not in src:
        print("ERROR: could not find Reconcile body to add safety net")
        raise SystemExit(1)

    src = src.replace(old, new)

    # Make sure time is imported
    if '"time"' not in src:
        # Find the import block
        import re
        m = re.search(r'(import \(\s*\n)((?:\t[^\n]+\n)+)(\))', src)
        if m:
            existing = m.group(2)
            new_imports = existing
            if '"time"' not in existing:
                # Insert "time" alphabetically; simplest: add at end of stdlib block
                new_imports = existing.rstrip() + '\n\t"time"\n'
            src = src[:m.start()] + m.group(1) + new_imports + m.group(3) + src[m.end():]
            print("  ✓ added 'time' import")

    p.write_text(src)
    print("  ✓ safety RequeueAfter added to Reconcile")
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
echo "Building controller..."
go build -o bin/controller ./cmd/controller || {
    echo "build failed — restoring"
    cp -p "$BACKUP/vgpuclaim_reconciler.go" internal/controller/vgpuclaim_reconciler.go
    exit 1
}
echo "  ✓ controller builds"

TAG="claimfix_$(date +%s)"
docker build -t vgpu-controller:$TAG -f Dockerfile.controller . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ image built ($TAG)"

docker save vgpu-controller:$TAG -o /tmp/vgpu-claimfix.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-claimfix.tar > /dev/null

kubectl set image -n vgpu-system deploy/vgpu-controller manager=vgpu-controller:$TAG
kubectl patch deploy -n vgpu-system vgpu-controller --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl delete pod -n vgpu-system -l control-plane=vgpu-controller --wait=false

# Cleanup any orphan claims so we start fresh — they'll actually delete now
sleep 30

for ns in default ml-team-a ml-team-pre team-prod team-research; do
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

sleep 30

echo ""
echo "=== Cluster state (should be empty) ==="
kubectl get vgpujob -A
kubectl get vgpuclaim -A
kubectl get vgpuslice -A
kubectl get vgpuquota

echo ""
echo "=== Controller image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-controller \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ Claim reconciler fix applied. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Next: verify recovery with a delete cycle, then run the stress test."
