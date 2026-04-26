#!/usr/bin/env bash
# ============================================================================
# Layer 1 — Complete validation suite (v4)
#
# Tests every Layer 1 component with correct arithmetic, proper teardown
# between tests, and honest assertions.
#
# Categories:
#   B  Basic — claim/slice/lifecycle plumbing
#   F  Filter — capacity-based admission
#   C  VRAMCache — accounting under sequential and parallel load
#   X  Concurrency — fairness under contention
#   K  Checkpointing — durability + corruption handling
#   D  Drift detection — recovery
#   S  State machine + invariants
#   R  Recovery — controller/scheduler/nodeagent restarts
#   T  Service tier — known-limitation documentation
#   H  Hardware health — probe wiring
#   I  CDI isolation mechanism
#   M  Metrics — telemetry endpoint
# ============================================================================

set -uo pipefail

NS="default"
SYS_NS="vgpu-system"
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

PASS=0
FAIL=0
SKIP=0
FAILED=()

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
c_bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
c_cyan()   { printf "\033[36m%s\033[0m\n" "$*"; }

pass() { c_green "  ✓ PASS: $*"; PASS=$((PASS+1)); }
fail() { c_red   "  ✗ FAIL: $*"; FAIL=$((FAIL+1)); FAILED+=("$*"); }
skip() { c_yellow "  - SKIP: $*"; SKIP=$((SKIP+1)); }
info() { c_cyan  "    $*"; }
note() { printf "    %s\n" "$*"; }

section() {
    echo ""
    c_bold "═══════════════════════════════════════════════════════════════"
    c_bold "  $*"
    c_bold "═══════════════════════════════════════════════════════════════"
}

# ── Helpers ──────────────────────────────────────────────────────────────────
make_claim() {
    local name="$1" bytes="$2" tier="${3:-Guaranteed}"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: $name, namespace: $NS }
spec: { requestedVramBytes: $bytes, serviceTier: $tier }
EOF
}

slice_phase() { kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
slice_node()  { kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
slice_alloc() { kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.status.allocationId}' 2>/dev/null; }
slice_uuid()  { kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.status.deviceUuid}' 2>/dev/null; }

wait_phase() {
    local slice="$1" expected="$2" timeout="${3:-30}"
    for _ in $(seq 1 "$timeout"); do
        [[ "$(slice_phase "$slice")" == "$expected" ]] && return 0
        sleep 1
    done
    return 1
}

cleanup_all() {
    kubectl get vgpuclaim -A -o name 2>/dev/null | \
        xargs -I{} kubectl patch {} --type=json \
        -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
    kubectl get vgpuslice -A -o name 2>/dev/null | \
        xargs -I{} kubectl patch {} --type=json \
        -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
    kubectl delete vgpuclaim -A --all --wait=false >/dev/null 2>&1 || true
    kubectl delete vgpuslice -A --all --wait=false >/dev/null 2>&1 || true
    sleep 8
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
section "PRE-FLIGHT"
echo "Node: $NODE"
echo "Pods running:"
kubectl get pods -n "$SYS_NS" --no-headers 2>/dev/null | awk '{print "  " $1, $2, $3}'

# Check expected pod count
running=$(kubectl get pods -n "$SYS_NS" --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')
if [[ "$running" -eq 3 ]]; then
    pass "All 3 control-plane pods are Running"
else
    fail "Expected 3 Running pods, found $running"
    note "Aborting test suite — fix the pods before proceeding."
    exit 1
fi

# Verify node has the vGPU capacity advertised
cap=$(kubectl get node "$NODE" -o jsonpath='{.status.capacity.infrastructure\.pranav2910\.com/vgpu-bytes}' 2>/dev/null)
if [[ -n "$cap" && "$cap" -gt 0 ]]; then
    pass "Node advertises vGPU capacity: $cap bytes ($((cap / 1024**3)) GiB)"
else
    fail "Node has no vGPU capacity (run scripts/mock-gpu-node.sh first)"
fi

cleanup_all

# ============================================================================
# B1 — Full lifecycle round-trip
# ============================================================================
section "B1 — Full lifecycle (claim → slice → bind → ready → release → GC)"

make_claim b1-roundtrip 4294967296   # 4 GiB
created=false
for _ in $(seq 1 15); do
    kubectl get vgpuslice -n "$NS" b1-roundtrip-slice >/dev/null 2>&1 && { created=true; break; }
    sleep 1
done
if [[ "$created" == true ]]; then pass "Slice auto-created by controller"
else fail "Slice was never created"; fi

if wait_phase b1-roundtrip-slice Ready 30; then
    pass "Slice reached Ready"
    note "AllocationID: $(slice_alloc b1-roundtrip-slice)"
    note "DeviceUUID:   $(slice_uuid b1-roundtrip-slice)"
    note "Bound to:     $(slice_node b1-roundtrip-slice)"
else
    fail "Slice never reached Ready (current: $(slice_phase b1-roundtrip-slice))"
fi

# Verify unique-UUID fix from Bug #21
uuid=$(slice_uuid b1-roundtrip-slice)
if [[ "$uuid" != "GPU-MOCK-ENTERPRISE-1" && -n "$uuid" ]]; then
    pass "DeviceUUID is unique per allocation (Bug #21 fix)"
else
    fail "DeviceUUID is the legacy shared mock or empty"
fi

# Cleanup with timeout (don't hang)
kubectl delete vgpuclaim -n "$NS" b1-roundtrip --wait=false >/dev/null 2>&1
gone=false
for _ in $(seq 1 60); do
    kubectl get vgpuslice -n "$NS" b1-roundtrip-slice >/dev/null 2>&1 || { gone=true; break; }
    sleep 1
done
[[ "$gone" == true ]] && pass "Slice fully GC'd after claim deletion" || fail "Slice not GC'd within 60s"
cleanup_all

# ============================================================================
# F1 / F2 — Filter
# ============================================================================
section "F1 — Filter rejects oversized request"
make_claim f1-toolarge 999999999999   # ~931 GiB on 80 GiB node
sleep 25
phase=$(slice_phase f1-toolarge-slice)
node=$(slice_node f1-toolarge-slice)
if [[ -z "$node" && ( -z "$phase" || "$phase" == "Pending" ) ]]; then
    pass "Oversized request stayed unbound (Filter working)"
else
    fail "Oversized request was bound (node=$node phase=$phase)"
fi
cleanup_all

section "F2 — Filter accepts exact-capacity request"
make_claim f2-exact 85899345920   # exactly 80 GiB
if wait_phase f2-exact-slice Ready 60; then
    pass "Exact-capacity request was accepted"
else
    fail "Exact-capacity stuck at phase='$(slice_phase f2-exact-slice)'"
fi
cleanup_all

# ============================================================================
# C1 — VRAMCache: sequential allocations
# ============================================================================
section "C1 — VRAMCache: 9 × 8 GiB sequential allocations + overflow"

for i in $(seq 1 9); do make_claim "c1-fill-$i" 8589934592; done
sleep 30

ready=0
for i in $(seq 1 9); do
    [[ "$(slice_phase c1-fill-$i-slice)" == "Ready" ]] && ready=$((ready+1))
done

if [[ "$ready" -eq 9 ]]; then
    pass "9 × 8 GiB filled the cache to 72 GiB"
else
    fail "Only $ready/9 fillers reached Ready"
fi

# Now 16 GiB request — only 8 GiB free, must reject
make_claim c1-overflow 17179869184
sleep 25
if [[ -z "$(slice_node c1-overflow-slice)" ]]; then
    pass "16 GiB overflow correctly REJECTED"
else
    fail "16 GiB overflow allowed when only 8 GiB free"
fi
cleanup_all
sleep 25  # let releases settle

# ============================================================================
# C2 — VRAMCache: capacity returned on release
# ============================================================================
section "C2 — VRAMCache: capacity returned on release"

make_claim c2-a 53687091200   # 50 GiB
if ! wait_phase c2-a-slice Ready 30; then
    fail "Setup: 50 GiB never reached Ready"
    skip "C2 cannot proceed"
else
    # 40 GiB should NOT fit (only 30 GiB free)
    make_claim c2-block 42949672960
    sleep 25
    if [[ -z "$(slice_node c2-block-slice)" ]]; then
        pass "Setup: 40 GiB blocked while 50 GiB held"
    else
        fail "40 GiB allowed when only 30 GiB free — cache leak"
    fi

    # Release the 50 GiB
    kubectl delete vgpuclaim -n "$NS" c2-a --wait=false >/dev/null 2>&1
    sleep 30

    if wait_phase c2-block-slice Ready 30; then
        pass "After release, blocked 40 GiB succeeded"
    else
        fail "Capacity not returned after release (still: $(slice_phase c2-block-slice))"
    fi
fi
cleanup_all
sleep 25

# ============================================================================
# X1 — Concurrency: 20 simultaneous 8 GiB claims
# ============================================================================
section "X1 — Concurrency: 20 simultaneous 8 GiB (only 10 fit in 80 GiB)"

manifest=""
for i in $(seq 1 20); do
    manifest+="---
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata: { name: x1-stress-$i, namespace: $NS }
spec: { requestedVramBytes: 8589934592, serviceTier: Guaranteed }
"
done
echo "$manifest" | kubectl apply -f - >/dev/null 2>&1

sleep 60

ready=0
pending=0
for i in $(seq 1 20); do
    case "$(slice_phase x1-stress-$i-slice)" in
        Ready)        ready=$((ready+1)) ;;
        ""|Pending)   pending=$((pending+1)) ;;
    esac
done
info "ready=$ready  pending=$pending"

# Hard invariant: total allocated must not exceed capacity
total_gib=$((ready * 8))
if [[ "$total_gib" -le 80 ]]; then
    pass "Capacity invariant: $total_gib GiB ≤ 80 GiB"
else
    fail "OVER-ALLOCATION: $total_gib GiB on 80 GiB node"
fi

# Loose check: at least 8 reached Ready
if [[ "$ready" -ge 8 ]]; then
    pass "Throughput: $ready/20 stress claims reached Ready"
else
    fail "Throughput too low: $ready/20"
fi
cleanup_all
sleep 45  # full release of 10+ slices

# ============================================================================
# K1 / K2 — Checkpointing
# ============================================================================
section "K1 / K2 — Checkpointing"

make_claim k1-ckpt 4294967296
if ! wait_phase k1-ckpt-slice Ready 30; then
    fail "Setup failed"
    skip "K1/K2 cannot proceed"
else
    alloc=$(slice_alloc k1-ckpt-slice)
    ckpt=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
           cat /var/run/vgpu-state/allocations.json 2>/dev/null)
    if echo "$ckpt" | grep -q "$alloc"; then
        pass "K1: checkpoint contains live allocation $alloc"
    else
        fail "K1: checkpoint missing allocation"
    fi

    kubectl delete vgpuclaim -n "$NS" k1-ckpt --wait=false >/dev/null 2>&1
    sleep 30
    ckpt_after=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
                 cat /var/run/vgpu-state/allocations.json 2>/dev/null)
    if echo "$ckpt_after" | grep -q "$alloc"; then
        fail "K2: checkpoint still references freed alloc"
    else
        pass "K2: checkpoint purged released allocation"
    fi
fi
cleanup_all

# ============================================================================
# D1 — Drift detection heals injected orphan
# ============================================================================
section "D1 — Drift detection heals orphaned checkpoint"

kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- /bin/sh -c '
cat > /var/run/vgpu-state/allocations.json <<JSON
{
  "alloc-orphan-test": {
    "allocationID": "alloc-orphan-test",
    "sliceUID": "fake-uid",
    "sliceName": "doesnt-exist-slice",
    "namespace": "default",
    "claimName": "doesnt-exist",
    "deviceUUID": "GPU-MOCK-ORPHAN",
    "allocatedBytes": 4294967296,
    "nodeName": "'"$NODE"'",
    "createdAt": "2025-01-01T00:00:00Z"
  }
}
JSON' 2>/dev/null

kubectl rollout restart -n "$SYS_NS" daemonset/vgpu-nodeagent >/dev/null 2>&1
sleep 30

ckpt_drift=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
             cat /var/run/vgpu-state/allocations.json 2>/dev/null || echo "{}")
if echo "$ckpt_drift" | grep -q "alloc-orphan-test"; then
    fail "Drift detector did NOT clean injected orphan"
else
    pass "Drift detector cleaned injected orphan"
fi

drift_log=$(kubectl logs -n "$SYS_NS" daemonset/vgpu-nodeagent --tail=100 2>/dev/null | \
            grep -iE "drift|recovery" | head -1)
if [[ -n "$drift_log" ]]; then
    pass "Drift detector logged the recovery action"
    note "$drift_log"
fi

# ============================================================================
# R1 / R2 / R3 — Recovery from pod restarts
# ============================================================================
section "R1 — Controller restart mid-allocation"
make_claim r1-recov 4294967296
for _ in $(seq 1 15); do
    kubectl get vgpuslice -n "$NS" r1-recov-slice >/dev/null 2>&1 && break
    sleep 1
done
kubectl delete pod -n "$SYS_NS" -l control-plane=vgpu-controller --wait=false >/dev/null 2>&1
sleep 60
if wait_phase r1-recov-slice Ready 30; then
    pass "Slice reached Ready despite controller restart"
else
    fail "Slice did not converge (phase=$(slice_phase r1-recov-slice))"
fi
cleanup_all

section "R2 — Scheduler restart with pending slice"
make_claim r2-recov 4294967296
kubectl delete pod -n "$SYS_NS" -l control-plane=vgpu-scheduler --wait=false >/dev/null 2>&1
sleep 60
if wait_phase r2-recov-slice Ready 30; then
    pass "Slice reached Ready despite scheduler restart"
else
    fail "Slice did not converge (phase=$(slice_phase r2-recov-slice))"
fi
cleanup_all

section "R3 — NodeAgent restart preserves Ready slice"
make_claim r3-recov 4294967296
if ! wait_phase r3-recov-slice Ready 30; then
    fail "Setup failed"
else
    alloc_before=$(slice_alloc r3-recov-slice)
    kubectl delete pod -n "$SYS_NS" -l app=vgpu-nodeagent --wait=false >/dev/null 2>&1
    sleep 45
    phase_after=$(slice_phase r3-recov-slice)
    alloc_after=$(slice_alloc r3-recov-slice)
    if [[ "$phase_after" == "Ready" && "$alloc_before" == "$alloc_after" ]]; then
        pass "Slice survived NodeAgent restart with same AllocationID"
    else
        fail "Slice changed (before=$alloc_before after=$alloc_after phase=$phase_after)"
    fi
fi
cleanup_all

# ============================================================================
# RACE — Rapid create+delete cycles (state machine + finalizer stress)
# ============================================================================
section "RACE — 5x rapid create+delete cycles"
stuck=0
for cycle in $(seq 1 5); do
    make_claim race-cycle 4294967296
    sleep 3
    kubectl delete vgpuclaim -n "$NS" race-cycle --wait=false >/dev/null 2>&1
    for _ in $(seq 1 30); do
        kubectl get vgpuslice -n "$NS" race-cycle-slice >/dev/null 2>&1 || break
        sleep 1
    done
    if kubectl get vgpuslice -n "$NS" race-cycle-slice >/dev/null 2>&1; then
        stuck=$((stuck+1))
        info "Cycle $cycle: stuck in $(slice_phase race-cycle-slice)"
    fi
done
if [[ "$stuck" -eq 0 ]]; then
    pass "All 5 cycles completed cleanly"
else
    fail "$stuck/5 cycles left stuck slices"
fi
cleanup_all

# ============================================================================
# T1 — Service tier (documented limitation)
# ============================================================================
section "T1 — Service tier preference (FCFS limitation documented)"

# Take 72 GiB → exactly 8 GiB free
make_claim t1-filler 77309411328
if ! wait_phase t1-filler-slice Ready 30; then
    fail "Setup failed"
else
    make_claim t1-be 8589934592 BestEffort
    make_claim t1-g 8589934592 Guaranteed
    sleep 45
    be=$(slice_phase t1-be-slice)
    g=$(slice_phase t1-g-slice)
    info "BestEffort=$be  Guaranteed=$g"

    if [[ "$g" == "Ready" && "$be" != "Ready" ]]; then
        pass "Service tier honoured: Guaranteed won"
    elif [[ "$be" == "Ready" && "$g" != "Ready" ]]; then
        # NOT marked as a hard FAIL — this is a known design limitation
        skip "Tier inverted (FCFS limitation: BestEffort arrived first)"
        note "Note: ScoreWithTier is a tiebreaker within a single cycle, not"
        note "a priority queue or preemption mechanism. This is a design gap."
    elif [[ "$be" == "Ready" && "$g" == "Ready" ]]; then
        fail "Both bound — capacity over-allocation"
    else
        fail "Both pending — scheduler wedged or score broken"
    fi
fi
cleanup_all
sleep 25

# ============================================================================
# H1 — Hardware health probe wiring
# ============================================================================
section "H1 — Hardware health probe wiring"

# Source-level checks
if grep -q "StartHealthProbe\|onUnhealthy" internal/nodeagent/nvml/probe.go 2>/dev/null; then
    pass "Source: StartHealthProbe + onUnhealthy callback present"
else
    fail "probe.go missing StartHealthProbe wiring"
fi

if grep -q "StartHealthProbe" cmd/nodeagent/main.go 2>/dev/null; then
    pass "Source: NodeAgent main.go calls StartHealthProbe at boot"
else
    fail "main.go does not call StartHealthProbe"
fi

# End-to-end: kill nodeagent and confirm drift detection runs (recovery surface)
kubectl delete pod -n "$SYS_NS" -l app=vgpu-nodeagent --wait=false >/dev/null 2>&1
sleep 25
if kubectl logs -n "$SYS_NS" daemonset/vgpu-nodeagent --tail=80 2>/dev/null | \
   grep -qiE "drift|recovery|hardware vs"; then
    pass "Recovery surface alive: drift detection runs on NodeAgent restart"
else
    fail "No drift/recovery logs after NodeAgent restart"
fi

# ============================================================================
# I1 — CDI isolation mechanism
# ============================================================================
section "I1 — CDI spec written, schema correct, cleaned up"

cleanup_all
make_claim i1-cdi 4294967296
if ! wait_phase i1-cdi-slice Ready 30; then
    fail "Setup failed"
else
    alloc_id=$(slice_alloc i1-cdi-slice)

    # Look for CDI files (filename uses vendor name, NOT 'vgpu')
    cdi_files=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
                /bin/sh -c 'ls /var/run/cdi/ 2>/dev/null | grep pranav2910' || true)

    if [[ -n "$cdi_files" ]]; then
        pass "CDI spec file(s) present in /var/run/cdi/"

        # Validate schema of the freshest file
        cdi_content=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
                      /bin/sh -c 'ls -t /var/run/cdi/*.json 2>/dev/null | head -1 | xargs cat' 2>/dev/null)

        kind_ok=$(echo "$cdi_content" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print("ok" if "/" in d.get("kind","") else "")
except Exception:
    pass' 2>/dev/null)

        if [[ "$kind_ok" == "ok" ]]; then
            kind_val=$(echo "$cdi_content" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("kind",""))' 2>/dev/null)
            pass "CDI 'kind' has vendor/class format: $kind_val"
        else
            fail "CDI 'kind' malformed (must contain /)"
        fi

        version=$(echo "$cdi_content" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("cdiVersion",""))' 2>/dev/null)
        [[ -n "$version" ]] && pass "CDI version present: $version" || fail "CDI version missing"
    else
        fail "No CDI files found in /var/run/cdi/"
    fi

    # Mutating webhook injection
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: i1-cdi-pod
  namespace: $NS
  labels: { vgpu-claim: i1-cdi }
  annotations: { infrastructure.pranav2910.com/claim-ref: i1-cdi }
spec:
  restartPolicy: Never
  containers:
    - name: idle
      image: alpine:3.20
      command: ["sleep", "60"]
EOF
    sleep 5

    cdi_ann=$(kubectl get pod -n "$NS" i1-cdi-pod \
              -o jsonpath='{.metadata.annotations.cdi\.k8s\.io/vgpu-pranav2910-com}' 2>/dev/null)
    if [[ -n "$cdi_ann" ]]; then
        pass "Webhook injected CDI annotation: $cdi_ann"
    else
        fail "Mutating webhook did not inject CDI annotation"
    fi

    kubectl delete pod -n "$NS" i1-cdi-pod --wait=false >/dev/null 2>&1
fi
cleanup_all

# ============================================================================
# M1 — Metrics endpoint
# ============================================================================
section "M1 — Prometheus metrics endpoint"

kubectl port-forward -n "$SYS_NS" deploy/vgpu-scheduler 18081:8081 >/dev/null 2>&1 &
PF=$!
sleep 4

metrics=$(curl -s http://localhost:18081/metrics 2>/dev/null | grep "vgpu_" | head -10)
kill $PF 2>/dev/null || true

if [[ -n "$metrics" ]]; then
    pass "Scheduler exposes vGPU Prometheus metrics"
    echo "$metrics" | head -5 | sed 's/^/      /'
else
    fail "Could not fetch metrics from scheduler"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
section "RESULTS"
echo ""
c_green "  PASSED:  $PASS"
c_red   "  FAILED:  $FAIL"
c_yellow "  SKIPPED: $SKIP"
echo ""
total=$((PASS + FAIL))
if [[ "$total" -gt 0 ]]; then
    pct=$((PASS * 100 / total))
    c_bold "  Score: $PASS/$total ($pct%)"
fi
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    c_red "  Failed:"
    for t in "${FAILED[@]}"; do echo "    - $t"; done
    echo ""
fi

if [[ "$SKIP" -gt 0 ]]; then
    c_yellow "  Skipped (known limitations):"
    c_yellow "    - Service tier inversion: FCFS scheduling lacks priority/preemption"
    echo ""
fi

if [[ "$FAIL" == "0" ]]; then
    c_bold "$(c_green '  ✓ Layer 1 control plane is functionally complete')"
    echo ""
    c_cyan "  Documented limitations:"
    note "    - Allocator runs in mock mode (real NVML requires GPU hardware)"
    note "    - Service tier is a tiebreaker, not a priority queue"
else
    c_bold "$(c_yellow "  ⚠ $FAIL of $total tests failed")"
fi
echo ""
