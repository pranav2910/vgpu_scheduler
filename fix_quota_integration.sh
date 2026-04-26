#!/usr/bin/env bash
# ============================================================================
# Phase 2.2a follow-up: integrate QuotaChecker into Schedule().
# The original script's anchor pattern didn't match. This uses the real one.
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

STAMP=$(date +%s)
BACKUP=".pluginfix_${STAMP}"
mkdir -p "$BACKUP"
cp -p internal/scheduler/plugin.go "$BACKUP/plugin.go"
cp -p cmd/scheduler/main.go "$BACKUP/main.go"
echo "Backup: $BACKUP"

# ============================================================================
# 1. Inject quota check into Schedule(), using the REAL anchor.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("internal/scheduler/plugin.go")
src = p.read_text()

if "QuotaChecker.Check(" in src:
    print("  - Quota check already integrated in Schedule()")
else:
    # Real anchor matches what's actually there.
    anchor = '''func (s *SliceScheduler) Schedule(ctx context.Context, nn types.NamespacedName, sliceUID string, reqBytes int64, bestEffort bool) (string, error) {
	log.Printf("Scheduling cycle started for Slice %s (req: %d bytes)", nn, reqBytes)'''

    if anchor not in src:
        print("ERROR: could not find Schedule entry point in plugin.go")
        print("Looking for variations...")
        import re
        m = re.search(r'func \(s \*SliceScheduler\) Schedule\([^)]+\) \(string, error\) \{', src)
        if m:
            print(f"Found function start: {m.group(0)}")
            print("But the next-line log format must differ. Manual edit required.")
        raise SystemExit(1)

    injection = anchor + '''

	// Layer 2 Phase 2.2a: enforce VGPUQuota before searching for nodes.
	// "no quota = unlimited" — Check returns allowed=true when no quota matches.
	if s.QuotaChecker != nil {
		if ok, reason, msg := s.QuotaChecker.Check(ctx, nn.Namespace, reqBytes); !ok {
			log.Printf("Scheduling rejected for Slice %s by quota: %s — %s",
				nn, reason, msg)
			return "", &SchedulingError{Reason: reason, Message: msg}
		}
	}'''

    src = src.replace(anchor, injection)
    p.write_text(src)
    print("  ✓ Quota check integrated into Schedule()")
PYEOF

# ============================================================================
# 2. Verify main.go has the QuotaChecker wiring. Use NewSliceScheduler as anchor.
# ============================================================================
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

if "SetQuotaChecker" in src:
    print("  - SetQuotaChecker call already present")
else:
    # Find a line that creates the scheduler. The constructor is NewSliceScheduler.
    import re
    m = re.search(r'(\w+\s*:?=\s*scheduler\.NewSliceScheduler\([^)]+\))', src)
    if not m:
        print("ERROR: could not find NewSliceScheduler call in main.go")
        print("Locating any reference to scheduler.New:")
        for line_num, line in enumerate(src.splitlines(), 1):
            if "scheduler.New" in line:
                print(f"  L{line_num}: {line.strip()}")
        raise SystemExit(1)

    construction_line = m.group(1)
    var_name = construction_line.split(":")[0].split("=")[0].strip()
    print(f"  Found scheduler variable: {var_name}")

    addition = construction_line + (
        f"\n\t// Layer 2 Phase 2.2a: wire VGPUQuota enforcement.\n"
        f"\t{var_name}.SetQuotaChecker(scheduler.NewQuotaChecker(mgr.GetClient()))"
    )
    src = src.replace(construction_line, addition, 1)
    p.write_text(src)
    print(f"  ✓ SetQuotaChecker wired into {var_name}")
PYEOF

# ============================================================================
# 3. Verify it compiles.
# ============================================================================
echo ""
echo "Running go vet..."
go vet ./... 2>&1 | head -20

echo ""
echo "Building scheduler..."
go build -o bin/scheduler ./cmd/scheduler || {
    echo "build failed — restoring backup"
    cp -p "$BACKUP/plugin.go" internal/scheduler/plugin.go
    cp -p "$BACKUP/main.go" cmd/scheduler/main.go
    exit 1
}
echo "  ✓ scheduler builds"

# ============================================================================
# 4. Rebuild image + redeploy.
# ============================================================================
TAG="p22afix$(date +%s)"
docker build -t vgpu-scheduler:$TAG -f Dockerfile.scheduler . > /tmp/build.log 2>&1 || {
    echo "image build failed:"; tail -10 /tmp/build.log; exit 1
}
echo "  ✓ image built ($TAG)"

docker save vgpu-scheduler:$TAG -o /tmp/vgpu-p22afix.tar
docker exec -i vgpu-test-control-plane ctr -n=k8s.io images import - < /tmp/vgpu-p22afix.tar > /dev/null

kubectl set image -n vgpu-system deploy/vgpu-scheduler manager=vgpu-scheduler:$TAG
kubectl patch deploy -n vgpu-system vgpu-scheduler --type=json \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' >/dev/null
kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false

# Clean state
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl get vgpuquota -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 30

echo ""
echo "=== Pods ==="
kubectl get pods -n vgpu-system

echo ""
echo "=== Scheduler image ==="
kubectl get pod -n vgpu-system -l control-plane=vgpu-scheduler \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

echo ""
echo "✅ Quota enforcement wired. Tag: $TAG. Backup: $BACKUP"
echo ""
echo "Now run the test scenarios."
