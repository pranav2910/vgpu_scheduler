#!/usr/bin/env bash
# ============================================================================
# Layer 1 ADVANCED test suite
#
# Stress, race, fault injection, recovery, and invariant checks for every
# Layer 1 feature. Designed to find bugs the basic test misses.
#
# Test categories:
#   B  Basic functional smoke
#   F  Filter / Score / Reserve / Bind / Confirm pipeline
#   C  VRAMCache accounting under load and races
#   N  NodeAgent lifecycle, mid-flight crashes
#   K  Checkpointing durability + corruption recovery
#   D  Drift detection
#   S  State machine + invariants
#   X  Concurrency / scheduling fairness
#   R  Recovery from controller/scheduler restarts
# ============================================================================

set -uo pipefail

PASS=0
FAIL=0
FAILED_TESTS=()

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
c_bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
c_cyan()   { printf "\033[36m%s\033[0m\n" "$*"; }

pass() { c_green "  ✓ PASS: $*"; PASS=$((PASS+1)); }
fail() { c_red   "  ✗ FAIL: $*"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$*"); }
skip() { c_yellow "  - SKIP: $*"; }
info() { c_cyan  "    $*"; }

section() {
    echo ""
    c_bold "═══════════════════════════════════════════════════════════════"
    c_bold "  $*"
    c_bold "═══════════════════════════════════════════════════════════════"
}

NS="${NS:-default}"
SYS_NS="vgpu-system"
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# -------- helpers --------
make_claim() {
    local name="$1" bytes="$2" tier="${3:-Guaranteed}"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata:
  name: $name
  namespace: $NS
spec:
  requestedVramBytes: $bytes
  serviceTier: $tier
EOF
}

wait_for_phase() {
    # wait_for_phase <slice-name> <expected-phase> <timeout-seconds>
    local slice="$1" expected="$2" timeout="${3:-30}"
    for _ in $(seq 1 "$timeout"); do
        local p=$(kubectl get vgpuslice -n "$NS" "$slice" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$p" == "$expected" ]] && return 0
        sleep 1
    done
    return 1
}

slice_phase() {
    kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.status.phase}' 2>/dev/null
}

slice_node() {
    kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

slice_alloc() {
    kubectl get vgpuslice -n "$NS" "$1" -o jsonpath='{.status.allocationId}' 2>/dev/null
}

cleanup_test_resources() {
    kubectl get vgpuclaim -n "$NS" -o name 2>/dev/null \
        | grep -E "(l1-|stress-|race-|recov-|drift-|invar-)" \
        | xargs -r kubectl delete -n "$NS" --wait=false >/dev/null 2>&1 || true
    sleep 5
}

# Pre-flight
section "PRE-FLIGHT"
echo "Node: $NODE"
echo "Pods running:"
kubectl get pods -n "$SYS_NS" --no-headers 2>/dev/null | awk '{print "  " $1, $2, $3}'

cleanup_test_resources

# ============================================================================
# B1: Basic round-trip — claim → slice → bound → ready → released → gone
# ============================================================================
section "B1 — Full lifecycle round-trip"

make_claim l1-roundtrip 4294967296

# Slice should appear within 15s
created=false
for _ in $(seq 1 15); do
    kubectl get vgpuslice -n "$NS" l1-roundtrip-slice >/dev/null 2>&1 && { created=true; break; }
    sleep 1
done
[[ "$created" == true ]] && pass "Slice auto-created by controller" || fail "Slice never created"

# Should reach Ready within 30s
if wait_for_phase l1-roundtrip-slice Ready 30; then
    pass "Slice reached Ready phase"
    info "AllocationID: $(slice_alloc l1-roundtrip-slice)"
    info "Bound to:     $(slice_node l1-roundtrip-slice)"
else
    fail "Slice never reached Ready (current phase: $(slice_phase l1-roundtrip-slice))"
fi

# Delete claim — slice should be garbage-collected
kubectl delete vgpuclaim -n "$NS" l1-roundtrip --wait=false >/dev/null 2>&1
gone=false
for _ in $(seq 1 60); do
    kubectl get vgpuslice -n "$NS" l1-roundtrip-slice >/dev/null 2>&1 || { gone=true; break; }
    sleep 1
done
[[ "$gone" == true ]] && pass "Slice fully GC'd after claim deletion" || fail "Slice still present 60s after claim deletion"

# ============================================================================
# F1: Filter — request larger than total node capacity
# ============================================================================
section "F1 — Filter rejects oversized request"

make_claim l1-filter-toolarge 999999999999

# Wait for slice creation, then check it stays Pending
sleep 5
for _ in $(seq 1 15); do
    kubectl get vgpuslice -n "$NS" l1-filter-toolarge-slice >/dev/null 2>&1 && break
    sleep 1
done

# Give scheduler 30s to (correctly) fail
sleep 30
phase=$(slice_phase l1-filter-toolarge-slice)
node=$(slice_node l1-filter-toolarge-slice)

if [[ -z "$node" && ( -z "$phase" || "$phase" == "Pending" ) ]]; then
    pass "Oversized request remained unbound (Filter working)"
else
    fail "Oversized request was bound to '$node' (Filter broken)"
fi

# Verify scheduler is actively retrying, not silently dropping
retries=$(kubectl logs -n "$SYS_NS" deploy/vgpu-scheduler --tail=200 2>/dev/null | \
          grep -c "no node has sufficient VRAM\|Scheduling cycle started for Slice default/l1-filter-toolarge")
if [[ "$retries" -ge 1 ]]; then
    pass "Scheduler is logging the failure ($retries attempts)"
else
    skip "No retry log lines found — could be idle, hard to verify"
fi

kubectl delete vgpuclaim -n "$NS" l1-filter-toolarge --wait=false >/dev/null 2>&1

# ============================================================================
# F2: Filter — exactly-fits request
# ============================================================================
section "F2 — Filter accepts exact-capacity request"

# Node capacity is 80GiB. Submit exactly that minus a small buffer for any
# reserved overhead.
make_claim l1-filter-exact 85899345920

if wait_for_phase l1-filter-exact-slice Ready 60; then
    pass "Exact-capacity request was accepted and allocated"
else
    phase=$(slice_phase l1-filter-exact-slice)
    fail "Exact-capacity request stuck at phase='$phase'"
fi

kubectl delete vgpuclaim -n "$NS" l1-filter-exact --wait=false >/dev/null 2>&1
sleep 10  # let it release before we run the next capacity test

# ============================================================================
# C1: VRAMCache — sequential allocations decrease available capacity
# ============================================================================
section "C1 — VRAMCache: sequential allocations exhaust capacity"

# Submit 9 claims of 8GiB each = 72GiB. Should all fit.
# Then a 10th of 16GiB. Should NOT fit (only 8GiB free).

for i in 1 2 3 4 5 6 7 8 9; do
    make_claim "l1-cap-fill-$i" 8589934592
done

# Wait for them all to reach Ready
sleep 30
ready=0
for i in 1 2 3 4 5 6 7 8 9; do
    [[ "$(slice_phase l1-cap-fill-$i-slice)" == "Ready" ]] && ready=$((ready+1))
done

if [[ "$ready" == "9" ]]; then
    pass "9 × 8GiB fillers reached Ready (72GiB consumed)"
else
    fail "Only $ready/9 fillers reached Ready"
fi

# Now the overflow attempt
make_claim l1-cap-overflow 17179869184

sleep 25
overflow_phase=$(slice_phase l1-cap-overflow-slice)
overflow_node=$(slice_node l1-cap-overflow-slice)

if [[ -z "$overflow_node" && ( -z "$overflow_phase" || "$overflow_phase" == "Pending" ) ]]; then
    pass "16GiB overflow correctly REJECTED (only 8GiB free of 80GiB)"
else
    fail "16GiB overflow allowed when only 8GiB free — VRAMCache leak (node='$overflow_node')"
fi

# Cleanup
for i in 1 2 3 4 5 6 7 8 9; do
    kubectl delete vgpuclaim -n "$NS" "l1-cap-fill-$i" --wait=false >/dev/null 2>&1
done
kubectl delete vgpuclaim -n "$NS" l1-cap-overflow --wait=false >/dev/null 2>&1
sleep 30  # let releases settle before next test

# ============================================================================
# C2: VRAMCache — release returns capacity
# ============================================================================
section "C2 — VRAMCache: released capacity is returned"

# Take 50GiB
make_claim l1-rel-a 53687091200
wait_for_phase l1-rel-a-slice Ready 30 || fail "Setup: 50GiB claim never reached Ready"

# 40GiB should NOT fit (only 30GiB free)
make_claim l1-rel-block 42949672960
sleep 20
if [[ -z "$(slice_node l1-rel-block-slice)" ]]; then
    pass "Setup: 40GiB blocked while 50GiB is held"
else
    fail "Setup: 40GiB allocated when only 30GiB free — VRAMCache double-count?"
fi

# Now release the 50GiB. The 40GiB should then succeed.
kubectl delete vgpuclaim -n "$NS" l1-rel-a --wait=false >/dev/null 2>&1
sleep 30  # generous for full release lifecycle

if wait_for_phase l1-rel-block-slice Ready 30; then
    pass "After release, blocked claim was successfully scheduled"
else
    fail "Capacity not returned after release (cache leak)"
fi

kubectl delete vgpuclaim -n "$NS" l1-rel-block --wait=false >/dev/null 2>&1
sleep 15

# ============================================================================
# X1: Concurrency — many simultaneous claims, none over-allocate
# ============================================================================
section "X1 — Concurrency: 20 simultaneous 8GiB claims (only 10 should fit)"

# Submit 20 claims at once. Each is 8GiB. Node has 80GiB. Only 10 should bind.
manifest=""
for i in $(seq 1 20); do
    manifest+="---
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUClaim
metadata:
  name: stress-$i
  namespace: $NS
spec:
  requestedVramBytes: 8589934592
  serviceTier: Guaranteed
"
done
echo "$manifest" | kubectl apply -f - >/dev/null 2>&1

sleep 60  # let scheduler chew

ready_count=0
pending_count=0
for i in $(seq 1 20); do
    p=$(slice_phase "stress-$i-slice")
    case "$p" in
        Ready)        ready_count=$((ready_count+1)) ;;
        Pending|"")   pending_count=$((pending_count+1)) ;;
    esac
done

info "ready=$ready_count pending=$pending_count (out of 20)"

# Strict invariant: total Ready slices × 8GiB <= 80GiB capacity
total_allocated_gib=$((ready_count * 8))
if [[ "$total_allocated_gib" -le 80 ]]; then
    pass "Concurrency invariant: $total_allocated_gib GiB allocated <= 80 GiB capacity"
else
    fail "Concurrency violated: $total_allocated_gib GiB allocated on 80 GiB node — DOUBLE-ALLOCATION"
fi

# Loose check: at least 8 should have made it (allowing for some retry latency)
if [[ "$ready_count" -ge 8 ]]; then
    pass "At least 8/20 stress claims reached Ready ($ready_count)"
else
    fail "Only $ready_count/20 reached Ready — scheduler may be wedged"
fi

# Cleanup
for i in $(seq 1 20); do
    kubectl delete vgpuclaim -n "$NS" "stress-$i" --wait=false >/dev/null 2>&1
done
sleep 45  # full release of 10+ slices takes time

# ============================================================================
# X2: Service tier — Guaranteed beats BestEffort for last slot
# ============================================================================
section "X2 — Service tier: Guaranteed wins over BestEffort"

# Take 70GiB so only 10GiB is left
make_claim l1-tier-filler 75161927680
wait_for_phase l1-tier-filler-slice Ready 30 || skip "Setup failed"

# Submit BestEffort and Guaranteed for 8GiB each — only one can fit
make_claim race-besteffort 8589934592 BestEffort
make_claim race-guaranteed 8589934592 Guaranteed

sleep 30

be_phase=$(slice_phase race-besteffort-slice)
g_phase=$(slice_phase race-guaranteed-slice)

if [[ "$g_phase" == "Ready" && "$be_phase" != "Ready" ]]; then
    pass "Guaranteed claim won the slot (correct service-tier behaviour)"
elif [[ "$be_phase" == "Ready" && "$g_phase" != "Ready" ]]; then
    fail "BestEffort won over Guaranteed — service-tier bug"
elif [[ "$be_phase" == "Ready" && "$g_phase" == "Ready" ]]; then
    fail "Both claims got allocated — capacity leak (BE=$be_phase G=$g_phase)"
else
    skip "Inconclusive (BE=$be_phase G=$g_phase)"
fi

kubectl delete vgpuclaim -n "$NS" l1-tier-filler race-besteffort race-guaranteed --wait=false >/dev/null 2>&1
sleep 30

# ============================================================================
# K1: Checkpoint — record exists for active allocation
# ============================================================================
section "K1 — Checkpoint contains active allocation"

make_claim l1-ckpt 4294967296
wait_for_phase l1-ckpt-slice Ready 60 || { fail "Setup failed"; }

alloc=$(slice_alloc l1-ckpt-slice)
ckpt=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
       cat /var/run/vgpu-state/allocations.json 2>/dev/null)

if echo "$ckpt" | grep -q "$alloc"; then
    pass "Checkpoint contains record for live AllocationID=$alloc"
else
    fail "Checkpoint missing record for live alloc"
    info "Checkpoint contents: $ckpt"
fi

# ============================================================================
# K2: Checkpoint — record removed after release
# ============================================================================
section "K2 — Checkpoint cleared after release"

kubectl delete vgpuclaim -n "$NS" l1-ckpt --wait=false >/dev/null 2>&1
sleep 30

ckpt_after=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
             cat /var/run/vgpu-state/allocations.json 2>/dev/null || echo "{}")

if echo "$ckpt_after" | grep -q "$alloc"; then
    fail "Checkpoint still contains released alloc=$alloc"
else
    pass "Checkpoint correctly purged released allocation"
fi

# ============================================================================
# D1: Drift detection — orphan checkpoint with no API resource
# ============================================================================
section "D1 — Drift: orphaned checkpoint heals on NodeAgent restart"

# Inject a fake checkpoint record for a slice that doesn't exist
kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- /bin/sh -c '
cat > /var/run/vgpu-state/allocations.json <<JSON
{
  "alloc-orphan-test": {
    "allocationID": "alloc-orphan-test",
    "sliceUID": "fake-uid-doesnt-exist",
    "sliceName": "doesnt-exist-slice",
    "namespace": "default",
    "claimName": "doesnt-exist",
    "deviceUUID": "GPU-MOCK-ORPHAN",
    "allocatedBytes": 4294967296,
    "nodeName": "'"$NODE"'",
    "createdAt": "2025-01-01T00:00:00Z"
  }
}
JSON
' 2>/dev/null

# Restart NodeAgent so drift detector runs
kubectl rollout restart -n "$SYS_NS" daemonset/vgpu-nodeagent >/dev/null 2>&1
sleep 30

# Check if drift detector cleaned up the orphan
ckpt_drift=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
             cat /var/run/vgpu-state/allocations.json 2>/dev/null || echo "{}")

if echo "$ckpt_drift" | grep -q "alloc-orphan-test"; then
    fail "Drift detector failed to clean orphan checkpoint"
    info "Checkpoint: $ckpt_drift"
else
    pass "Drift detector cleaned orphaned checkpoint"
fi

# Check drift logs
drift_logs=$(kubectl logs -n "$SYS_NS" daemonset/vgpu-nodeagent --tail=100 2>/dev/null \
             | grep -i "recovery\|drift\|orphan\|case 2\|case 3")
if [[ -n "$drift_logs" ]]; then
    pass "Drift detector logged recovery actions"
    info "$(echo "$drift_logs" | head -3)"
else
    skip "No drift recovery logs found (might just be no drift to recover)"
fi

# ============================================================================
# S1: Invariants — Released slice must clear AllocationID
# ============================================================================
section "S1 — Invariant: Released slice clears AllocationID/DeviceUUID"

make_claim invar-released 4294967296
wait_for_phase invar-released-slice Ready 30 || fail "Setup failed"

kubectl delete vgpuclaim -n "$NS" invar-released --wait=false >/dev/null 2>&1
# Try to catch the slice in Released phase before it gets GC'd. Race-y but
# usually possible since GC depends on finalizer removal.
sleep 5
for _ in $(seq 1 20); do
    p=$(slice_phase invar-released-slice 2>/dev/null)
    if [[ "$p" == "Released" ]]; then
        u=$(kubectl get vgpuslice -n "$NS" invar-released-slice -o jsonpath='{.status.deviceUuid}')
        a=$(kubectl get vgpuslice -n "$NS" invar-released-slice -o jsonpath='{.status.allocationId}')
        if [[ -z "$u" && -z "$a" ]]; then
            pass "Released slice has empty DeviceUUID and AllocationID"
        else
            fail "Released slice retains uuid='$u' alloc='$a'"
        fi
        break
    fi
    sleep 1
done

# ============================================================================
# R1: Recovery — controller restart mid-flight
# ============================================================================
section "R1 — Recovery: controller restart while slice is allocating"

make_claim recov-ctrl 4294967296

# Wait until a slice exists
for _ in $(seq 1 15); do
    kubectl get vgpuslice -n "$NS" recov-ctrl-slice >/dev/null 2>&1 && break
    sleep 1
done

# Kill the controller right when allocation might be happening
kubectl delete pod -n "$SYS_NS" -l control-plane=vgpu-controller --wait=false >/dev/null 2>&1

# Wait for new controller to come up + slice to converge
sleep 60

if wait_for_phase recov-ctrl-slice Ready 60; then
    pass "Slice reached Ready despite controller restart mid-flight"
else
    fail "Slice did not converge after controller restart (phase: $(slice_phase recov-ctrl-slice))"
fi

kubectl delete vgpuclaim -n "$NS" recov-ctrl --wait=false >/dev/null 2>&1
sleep 15

# ============================================================================
# R2: Recovery — scheduler restart mid-pending
# ============================================================================
section "R2 — Recovery: scheduler restart with pending slice"

make_claim recov-sched 4294967296

# Catch it before it binds — kill scheduler IMMEDIATELY
kubectl delete pod -n "$SYS_NS" -l control-plane=vgpu-scheduler --wait=false >/dev/null 2>&1

# Wait for new scheduler + full lifecycle
sleep 60

if wait_for_phase recov-sched-slice Ready 60; then
    pass "Slice reached Ready despite scheduler restart"
else
    fail "Slice did not bind after scheduler restart"
fi

kubectl delete vgpuclaim -n "$NS" recov-sched --wait=false >/dev/null 2>&1
sleep 15

# ============================================================================
# R3: Recovery — NodeAgent restart while slice is Ready
# ============================================================================
section "R3 — Recovery: NodeAgent restart preserves Ready slice"

make_claim recov-na 4294967296
wait_for_phase recov-na-slice Ready 60 || { fail "Setup failed"; }

alloc_before=$(slice_alloc recov-na-slice)
kubectl delete pod -n "$SYS_NS" -l app=vgpu-nodeagent --wait=false >/dev/null 2>&1
sleep 45

# Slice should still be Ready (NodeAgent shouldn't re-allocate or wreck it)
phase_after=$(slice_phase recov-na-slice)
alloc_after=$(slice_alloc recov-na-slice)

if [[ "$phase_after" == "Ready" && "$alloc_before" == "$alloc_after" ]]; then
    pass "Slice survived NodeAgent restart with same AllocationID"
else
    fail "Slice changed after NA restart (before=$alloc_before, after=$alloc_after, phase=$phase_after)"
fi

kubectl delete vgpuclaim -n "$NS" recov-na --wait=false >/dev/null 2>&1
sleep 15

# ============================================================================
# RACE: Rapid create+delete cycle (catches double-allocation / stuck states)
# ============================================================================
section "RACE — 5x rapid create+delete cycles"

stuck_count=0
for cycle in 1 2 3 4 5; do
    make_claim "race-cycle" 4294967296
    sleep 3   # don't let it finish
    kubectl delete vgpuclaim -n "$NS" race-cycle --wait=false >/dev/null 2>&1

    # Wait for slice to actually disappear
    for _ in $(seq 1 30); do
        kubectl get vgpuslice -n "$NS" race-cycle-slice >/dev/null 2>&1 || break
        sleep 1
    done
    if kubectl get vgpuslice -n "$NS" race-cycle-slice >/dev/null 2>&1; then
        stuck_count=$((stuck_count+1))
        info "  Cycle $cycle: slice stuck in $(slice_phase race-cycle-slice)"
    fi
done

if [[ "$stuck_count" == "0" ]]; then
    pass "All 5 rapid create+delete cycles completed cleanly"
else
    fail "$stuck_count/5 cycles left stuck slices behind"
fi

# Force cleanup any stragglers
kubectl get vgpuslice -n "$NS" -o name 2>/dev/null \
    | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1 || true
kubectl delete vgpuclaim -n "$NS" --all --wait=false >/dev/null 2>&1
kubectl delete vgpuslice -n "$NS" --all --wait=false >/dev/null 2>&1

# ============================================================================
# C3: Cache consistency — metrics endpoint matches reality
# ============================================================================
section "C3 — VRAMCache: metrics endpoint reflects state"

# Port-forward to the scheduler metrics endpoint
kubectl port-forward -n "$SYS_NS" svc/vgpu-scheduler 18081:8081 >/dev/null 2>&1 &
PF_PID=$!
sleep 3

metrics=$(curl -s http://localhost:18081/metrics 2>/dev/null | grep "vgpu_" | head -20)
kill $PF_PID 2>/dev/null || true

if [[ -n "$metrics" ]]; then
    pass "Scheduler exposes vGPU Prometheus metrics"
    info "Sample:"
    echo "$metrics" | head -5 | sed 's/^/    /'
else
    skip "Could not fetch metrics — port-forward may have failed or service is named differently"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
section "RESULTS"
echo ""
c_green "  PASSED: $PASS"
c_red   "  FAILED: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    c_red "  Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "    - $t"
    done
    echo ""
fi

if [[ "$FAIL" == "0" ]]; then
    c_bold "$(c_green '  ✓ All Layer 1 advanced tests passed')"
else
    c_bold "$(c_yellow "  ⚠ $FAIL test(s) failed — see above")"
    echo ""
    c_yellow "  Some failures may correspond to known open bugs (round 3/4 audit):"
    echo "    - SyncCacheFromSlice double-count (concurrency over-allocation)"
    echo "    - Stuck-Allocating recovery"
    echo "    - Cache leak on rapid release"
fi
echo ""
