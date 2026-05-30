#!/usr/bin/env bash
# ============================================================================
# real_world_test.sh — Wave 1
#
# Tier 1: Correctness under contention (atomicity)
# Tier 2: No resource leaks
#
# Locked design:
#   - Skip Tier 6 (real GPU)
#   - Stop on first failure
#   - Markdown report in real_world_report.md
#
# This script is FAIL-CLOSED. Any unexpected state aborts with a clear reason
# and writes the partial report. No silent passes.
#
# Usage:
#   bash real_world_test.sh                  # full wave 1
#   bash real_world_test.sh --only=1.1       # single test
#   bash real_world_test.sh --skip-cleanup   # leave resources for inspection
#
# Run from repo root.
# ============================================================================

set -euo pipefail

C_BLU=$'\033[1;34m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'

REPORT="real_world_report.md"
ONLY=""
SKIP_CLEANUP=0
NS_PREFIX="rwtest"
GPU_BYTES_TOTAL=85899345920   # 80 GiB — must match the node's vgpu-bytes capacity

for arg in "$@"; do
    case "$arg" in
        --only=*)        ONLY="${arg#*=}" ;;
        --skip-cleanup)  SKIP_CLEANUP=1 ;;
        --report=*)      REPORT="${arg#*=}" ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//' | head -25
            exit 0
            ;;
        *) echo "ERROR: unknown arg '$arg'" >&2; exit 1 ;;
    esac
done

# ============================================================================
# Pre-flight
# ============================================================================
[[ -f go.mod ]] || { echo "ERROR: run from repo root"; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl missing"; exit 1; }

if ! kubectl get crd vgpugangjobs.infrastructure.pranav2910.com >/dev/null 2>&1; then
    echo "ERROR: VGPUGangJob CRD not installed. Run rollout_phase24a.sh first." >&2
    exit 1
fi

# ============================================================================
# Globals
# ============================================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
declare -a FAILED_TESTS=()

START_TIME=$(date +%s)

# ============================================================================
# Report writer
# ============================================================================
init_report() {
    cat > "$REPORT" <<EOF
# vGPU Scheduler — Real-World Validation Report

**Run start:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Cluster:** $(kubectl config current-context 2>/dev/null || echo unknown)
**GPU capacity:** ${GPU_BYTES_TOTAL} bytes (80 GiB) advertised on node

---

EOF
}
log_to_report() { printf '%s\n' "$*" >> "$REPORT"; }

finalize_report() {
    local end_time=$(date +%s)
    local total=$((end_time - START_TIME))
    cat >> "$REPORT" <<EOF

---

## Summary

- **Total tests run:** $TESTS_RUN
- **Passed:** $TESTS_PASSED
- **Failed:** $TESTS_FAILED
- **Total runtime:** ${total}s
- **End time:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
EOF
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        log_to_report ""
        log_to_report "**Failed tests:**"
        for t in "${FAILED_TESTS[@]}"; do
            log_to_report "- $t"
        done
    fi
}

# ============================================================================
# Output helpers
# ============================================================================
banner() { echo; echo "${C_BLU}═══ $* ═══${C_RST}"; }
ok()     { echo "  ${C_GRN}✓${C_RST} $*"; }
warn()   { echo "  ${C_YEL}!${C_RST} $*"; }
fail()   { echo "  ${C_RED}✗${C_RST} $*"; }
dim()    { echo "  ${C_DIM}$*${C_RST}"; }

# ============================================================================
# Cluster helpers
# ============================================================================

# Sum the AllocatedBytes of every Ready slice cluster-wide. This is the
# authoritative measure of "capacity in use" for leak detection — independent
# of any cache state — read straight from the API.
committed_bytes() {
    kubectl get vgpuslice -A -o json 2>/dev/null \
        | python3 -c '
import sys, json
total = 0
for s in json.load(sys.stdin)["items"]:
    if s.get("status", {}).get("phase") == "Ready":
        total += int(s.get("status", {}).get("allocatedBytes", 0) or 0)
print(total)
'
}

# Count gangs in a given phase, optionally filtered by namespace.
count_gangs_by_phase() {
    local phase=$1
    local ns=${2:-}
    if [[ -n "$ns" ]]; then
        kubectl get vgpugangjob -n "$ns" -o json 2>/dev/null \
            | python3 -c "import sys,json;print(sum(1 for g in json.load(sys.stdin)['items'] if g.get('status',{}).get('phase')=='$phase'))"
    else
        kubectl get vgpugangjob -A -o json 2>/dev/null \
            | python3 -c "import sys,json;print(sum(1 for g in json.load(sys.stdin)['items'] if g.get('status',{}).get('phase')=='$phase'))"
    fi
}

# Wait for a predicate to evaluate true, OR until timeout. Returns 0 on success,
# 1 on timeout. The predicate is a bash command in a string.
wait_for_pred() {
    local timeout=$1 desc=$2 pred=$3
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$pred" >/dev/null 2>&1; then return 0; fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    fail "timeout waiting for: $desc"
    return 1
}

# Submit a single VGPUGangJob via stdin. Args: namespace name gang_size mem_per_member_bytes
submit_gang() {
    local ns=$1 name=$2 size=$3 bytes_per=$4
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: $name, namespace: $ns }
spec:
  gangSize: $size
  minAvailable: $size
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 60
  podTemplate:
    spec:
      requestedVramBytes: $bytes_per
      serviceTier: Guaranteed
EOF
}

# Read a gang's current phase. Returns "" if not present.
gang_phase() {
    local ns=$1 name=$2
    kubectl get vgpugangjob -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

# Wait until every gang in a namespace is in a terminal state (Running, Failed,
# or Completed). Returns 0 when all settle, 1 on timeout.
wait_all_settled() {
    local ns=$1 timeout=$2
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local pending
        pending=$(kubectl get vgpugangjob -n "$ns" -o json 2>/dev/null \
            | python3 -c '
import sys,json
TERMINAL={"Running","Failed","Completed"}
items=json.load(sys.stdin)["items"]
print(sum(1 for g in items if g.get("status",{}).get("phase","") not in TERMINAL))
')
        if [[ "$pending" == "0" ]]; then return 0; fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    return 1
}

# Cleanup: delete namespace, wait for full removal so capacity returns.
ns_cleanup() {
    local ns=$1
    [[ $SKIP_CLEANUP -eq 1 ]] && { warn "--skip-cleanup: leaving namespace $ns for inspection"; return; }
    kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
    # Wait up to 60s for the namespace + all its objects to be gone (capacity returns)
    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        if ! kubectl get namespace "$ns" >/dev/null 2>&1; then return 0; fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    warn "namespace $ns still terminating after 60s (orphan finalizer?)"
}

# Verify the cluster is in a clean baseline state. Aborts the run if not.
# Called at the top of every test so we never start on dirty state.
require_clean_baseline() {
    local committed
    committed=$(committed_bytes)
    if [[ "$committed" != "0" ]]; then
        fail "cluster is NOT clean: $committed bytes still committed before test"
        kubectl get vgpuslice -A
        log_to_report ""
        log_to_report "**ABORT:** baseline check failed before test (cluster not clean: $committed bytes committed)"
        finalize_report
        exit 1
    fi
}

# ============================================================================
# Test framework
# ============================================================================
should_run() {
    local id=$1
    [[ -z "$ONLY" ]] && return 0
    [[ "$ONLY" == "$id" ]] && return 0
    return 1
}

run_test() {
    local id=$1 name=$2 fn=$3
    if ! should_run "$id"; then return 0; fi
    TESTS_RUN=$((TESTS_RUN + 1))
    banner "Test $id — $name"
    local start=$(date +%s)
    log_to_report "## Test $id — $name"; log_to_report ""
    if "$fn"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        local elapsed=$(($(date +%s) - start))
        ok "PASSED in ${elapsed}s"
        log_to_report "**Result:** ✅ PASSED in ${elapsed}s"; log_to_report ""
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$id $name")
        local elapsed=$(($(date +%s) - start))
        fail "FAILED in ${elapsed}s — stopping per --stop-on-failure"
        log_to_report "**Result:** ❌ FAILED in ${elapsed}s"; log_to_report ""
        finalize_report
        exit 1
    fi
}

# ============================================================================
# TIER 1 — Correctness under contention
# ============================================================================

# Test 1.1 — Concurrent gangs (atomicity)
# Submit 5 gangs of 4×10 GiB simultaneously into 80 GiB. Demand = 200 GiB.
# Expected: exactly 2 commit, 3 fail. Committed capacity never exceeds 80 GiB.
test_1_1_concurrent_gangs() {
    require_clean_baseline
    local ns="${NS_PREFIX}-1-1-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** 5 gangs × 4 members × 10 GiB submitted simultaneously into 80 GiB cluster (200 GiB demand)."
    log_to_report ""
    dim "namespace: $ns"

    # Submit all 5 gangs as fast as possible (sequential kubectl-applies, ~50ms each)
    local t0=$(date +%s%N)
    for i in 1 2 3 4 5; do
        submit_gang "$ns" "g$i" 4 10737418240
    done
    local t1=$(date +%s%N)
    dim "submit latency: $(( (t1 - t0) / 1000000 ))ms for 5 gangs"

    # Capacity-policing assertion: every 2 seconds, sample committed_bytes.
    # If it ever exceeds 80 GiB, the atomicity invariant is violated.
    local max_observed=0
    local samples=0
    local elapsed=0
    while [[ $elapsed -lt 90 ]]; do
        local cb
        cb=$(committed_bytes)
        if [[ "$cb" -gt "$max_observed" ]]; then max_observed=$cb; fi
        if [[ "$cb" -gt $GPU_BYTES_TOTAL ]]; then
            fail "OVER-ADMISSION: committed=$cb > capacity=$GPU_BYTES_TOTAL"
            log_to_report "**FAIL:** Committed bytes exceeded capacity at sample $samples: $cb > $GPU_BYTES_TOTAL"
            ns_cleanup "$ns"; return 1
        fi
        samples=$((samples + 1))
        if wait_all_settled "$ns" 2 2>/dev/null; then break; fi
        elapsed=$((elapsed + 2))
    done

    # All gangs settled (or timed out). Tally outcomes.
    if ! wait_all_settled "$ns" 30; then
        fail "some gangs did not settle within total timeout"
        kubectl get vgpugangjob -n "$ns"
        ns_cleanup "$ns"; return 1
    fi

    local running failed
    running=$(count_gangs_by_phase Running "$ns")
    failed=$(count_gangs_by_phase Failed "$ns")

    log_to_report "**Observed:**"
    log_to_report "- Gangs Running: $running (expected: 2)"
    log_to_report "- Gangs Failed:  $failed (expected: 3)"
    log_to_report "- Max committed bytes observed during run: $max_observed / $GPU_BYTES_TOTAL"
    log_to_report "- Capacity samples taken: $samples"
    log_to_report ""

    dim "running=$running failed=$failed max_committed=$max_observed"

    if [[ "$running" -ne 2 ]] || [[ "$failed" -ne 3 ]]; then
        fail "expected 2 Running + 3 Failed; got $running Running, $failed Failed"
        kubectl get vgpugangjob -n "$ns"
        log_to_report "**FAIL:** wrong outcome distribution"
        ns_cleanup "$ns"; return 1
    fi

    if [[ "$max_observed" -gt $GPU_BYTES_TOTAL ]]; then
        fail "over-admission detected: max=$max_observed > $GPU_BYTES_TOTAL"
        return 1
    fi

    ok "atomicity invariant held: max committed = $max_observed bytes (≤ $GPU_BYTES_TOTAL)"
    log_to_report "**PASS:** No over-admission. Exactly 2 of 5 gangs committed; remaining 3 failed cleanly."
    ns_cleanup "$ns"
    return 0
}

# Test 1.2 — Race on identical-sized slots
# 4 gangs of 2×40 GiB simultaneously (each gang asks for the WHOLE cluster).
# Expected: exactly 1 commits, 3 fail.
test_1_2_race_full_cluster() {
    require_clean_baseline
    local ns="${NS_PREFIX}-1-2-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** 4 gangs × 2 members × 40 GiB submitted simultaneously. Each gang requires the full 80 GiB."

    local t0=$(date +%s%N)
    for i in 1 2 3 4; do
        submit_gang "$ns" "g$i" 2 42949672960   # 40 GiB
    done
    local t1=$(date +%s%N)
    dim "submit latency: $(( (t1 - t0) / 1000000 ))ms"

    # Capacity-police as in 1.1
    local max_observed=0
    local elapsed=0
    while [[ $elapsed -lt 90 ]]; do
        local cb; cb=$(committed_bytes)
        if [[ "$cb" -gt "$max_observed" ]]; then max_observed=$cb; fi
        if [[ "$cb" -gt $GPU_BYTES_TOTAL ]]; then
            fail "OVER-ADMISSION: $cb > $GPU_BYTES_TOTAL"
            ns_cleanup "$ns"; return 1
        fi
        if wait_all_settled "$ns" 2 2>/dev/null; then break; fi
        elapsed=$((elapsed + 2))
    done

    if ! wait_all_settled "$ns" 30; then
        fail "gangs did not settle"
        kubectl get vgpugangjob -n "$ns"
        ns_cleanup "$ns"; return 1
    fi

    local running failed
    running=$(count_gangs_by_phase Running "$ns")
    failed=$(count_gangs_by_phase Failed "$ns")

    # Identify the winner so we can characterize fairness in the report
    local winner
    winner=$(kubectl get vgpugangjob -n "$ns" -o json \
        | python3 -c '
import sys, json
for g in json.load(sys.stdin)["items"]:
    if g.get("status", {}).get("phase") == "Running":
        print(g["metadata"]["name"]); break
')

    log_to_report ""
    log_to_report "**Observed:**"
    log_to_report "- Gangs Running: $running (expected: 1)"
    log_to_report "- Gangs Failed:  $failed (expected: 3)"
    log_to_report "- Winner:        ${winner:-<none>}"
    log_to_report "- Max committed: $max_observed / $GPU_BYTES_TOTAL"
    log_to_report ""

    dim "running=$running failed=$failed winner=${winner:-<none>}"

    if [[ "$running" -ne 1 ]] || [[ "$failed" -ne 3 ]]; then
        fail "expected 1 Running + 3 Failed; got $running Running, $failed Failed"
        kubectl get vgpugangjob -n "$ns"
        ns_cleanup "$ns"; return 1
    fi

    ok "race resolved: 1 winner ($winner), 3 losers, no over-admission"
    log_to_report "**PASS:** Race resolved cleanly. Single committer, no over-admission, no stuck gangs."
    ns_cleanup "$ns"
    return 0
}

# ============================================================================
# TIER 2 — No resource leaks
# ============================================================================

# Test 2.1 — Capacity returns after gang completes
test_2_1_capacity_returns_after_running() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-1-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Submit a single 4×20 GiB gang (80 GiB), wait Running, delete, verify full cleanup."

    submit_gang "$ns" "leak-test" 4 21474836480

    if ! wait_for_pred 60 "gang reaches Running" \
        '[[ "$(gang_phase '"$ns"' leak-test)" == "Running" ]]'; then
        fail "gang did not reach Running"
        kubectl describe vgpugangjob -n "$ns" leak-test | tail -20
        ns_cleanup "$ns"; return 1
    fi

    local committed_during; committed_during=$(committed_bytes)
    dim "during Running: $committed_during bytes committed"

    if [[ "$committed_during" -ne $GPU_BYTES_TOTAL ]]; then
        warn "expected exactly $GPU_BYTES_TOTAL committed during Running, observed $committed_during"
    fi

    # Delete the gang and verify everything tears down
    kubectl delete vgpugangjob -n "$ns" leak-test --wait=true --timeout=60s >/dev/null

    # Capacity should drop back to 0 within 60s
    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        local cb; cb=$(committed_bytes)
        if [[ "$cb" == "0" ]]; then break; fi
        sleep 2; elapsed=$((elapsed + 2))
    done

    local final_committed; final_committed=$(committed_bytes)
    local remaining_slices remaining_claims remaining_jobs remaining_rsv
    remaining_slices=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null | wc -l)
    remaining_claims=$(kubectl get vgpuclaim -n "$ns" --no-headers 2>/dev/null | wc -l)
    remaining_jobs=$(kubectl get vgpujob -n "$ns" --no-headers 2>/dev/null | wc -l)
    remaining_rsv=$(kubectl get vgpugangreservation -n "$ns" --no-headers 2>/dev/null | wc -l)

    log_to_report ""
    log_to_report "**Observed after deletion:**"
    log_to_report "- Committed bytes:         $final_committed (expected: 0)"
    log_to_report "- Residual VGPUSlices:     $remaining_slices (expected: 0)"
    log_to_report "- Residual VGPUClaims:     $remaining_claims (expected: 0)"
    log_to_report "- Residual VGPUJobs:       $remaining_jobs (expected: 0)"
    log_to_report "- Residual reservations:   $remaining_rsv (expected: 0)"
    log_to_report ""

    dim "after delete: committed=$final_committed slices=$remaining_slices claims=$remaining_claims jobs=$remaining_jobs rsv=$remaining_rsv"

    if [[ "$final_committed" != "0" ]] || [[ "$remaining_slices" -ne 0 ]] \
       || [[ "$remaining_claims" -ne 0 ]] || [[ "$remaining_jobs" -ne 0 ]] \
       || [[ "$remaining_rsv" -ne 0 ]]; then
        fail "leak detected"
        kubectl get vgpuslice,vgpuclaim,vgpujob,vgpugangreservation -n "$ns"
        log_to_report "**FAIL:** leak detected after gang deletion"
        ns_cleanup "$ns"; return 1
    fi

    ok "no leaks: capacity returned to 0, all child objects gone"
    log_to_report "**PASS:** Full cleanup. Capacity returned to baseline. No orphaned children."
    ns_cleanup "$ns"
    return 0
}

# Test 2.2 — Failed gang teardown
test_2_2_failed_gang_teardown() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-2-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Submit a gang that exceeds cluster capacity (4×30 GiB = 120 GiB into 80 GiB). Wait Failed. Verify cleanup."

    submit_gang "$ns" "fail-test" 4 32212254720   # 30 GiB; 4×30=120 > 80

    if ! wait_for_pred 90 "gang reaches Failed" \
        '[[ "$(gang_phase '"$ns"' fail-test)" == "Failed" ]]'; then
        fail "gang did not reach Failed within 90s"
        kubectl describe vgpugangjob -n "$ns" fail-test | tail -30
        ns_cleanup "$ns"; return 1
    fi

    local rsv_phase rsv_reason
    rsv_phase=$(kubectl get vgpugangreservation -n "$ns" fail-test-rsv -o jsonpath='{.status.phase}' 2>/dev/null)
    rsv_reason=$(kubectl get vgpugangreservation -n "$ns" fail-test-rsv -o jsonpath='{.status.failureReason}' 2>/dev/null)

    # test-2-2-timing fix applied: poll for teardown completion instead of
    # fixed sleep. The reservation reconciler drives cascade-delete via
    # foreground propagation, which can take 10-20s. It transitions
    # Failed -> Released once all children are confirmed gone.
    local final_committed remaining_slices remaining_claims remaining_jobs
    local waited=0
    while [[ $waited -lt 60 ]]; do
        remaining_slices=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        remaining_claims=$(kubectl get vgpuclaim -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        remaining_jobs=$(kubectl get vgpujob -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$remaining_slices" == "0" && "$remaining_claims" == "0" && "$remaining_jobs" == "0" ]]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    final_committed=$(committed_bytes)

    log_to_report ""
    log_to_report "**Observed:**"
    log_to_report "- Reservation phase:       $rsv_phase (expected: Failed)"
    log_to_report "- Reservation failureReason: \`$rsv_reason\`"
    log_to_report "- Committed bytes:         $final_committed (expected: 0)"
    log_to_report "- Residual VGPUSlices:     $remaining_slices (expected: 0)"
    log_to_report "- Residual VGPUClaims:     $remaining_claims (expected: 0)"
    log_to_report "- Residual VGPUJobs:       $remaining_jobs (expected: 0)"
    log_to_report ""

    dim "rsv_phase=$rsv_phase committed=$final_committed slices=$remaining_slices claims=$remaining_claims jobs=$remaining_jobs"

    if [[ "$rsv_phase" != "Failed" ]] || [[ -z "$rsv_reason" ]]; then
        fail "reservation should be Failed with non-empty failureReason"
        log_to_report "**FAIL:** reservation phase or reason missing"
        ns_cleanup "$ns"; return 1
    fi
    if [[ "$final_committed" != "0" ]]; then
        fail "capacity not returned: $final_committed bytes still committed"
        log_to_report "**FAIL:** capacity leak after Failed gang"
        ns_cleanup "$ns"; return 1
    fi
    if [[ "$remaining_slices" -ne 0 ]] || [[ "$remaining_claims" -ne 0 ]] || [[ "$remaining_jobs" -ne 0 ]]; then
        fail "child objects not cleaned up after Failed gang"
        kubectl get vgpuslice,vgpuclaim,vgpujob -n "$ns"
        log_to_report "**FAIL:** orphans after Failed gang"
        ns_cleanup "$ns"; return 1
    fi

    ok "Failed gang cleaned up correctly: reason=\"$rsv_reason\""
    log_to_report "**PASS:** Failed gang torn down cleanly. No orphans, capacity preserved."
    ns_cleanup "$ns"
    return 0
}

# ============================================================================
# Main
# ============================================================================
init_report
banner "Real-world validation — Wave 1 (Tiers 1+2)"
dim "report: $REPORT"

# Sanity: cluster must be clean before we start
init_committed=$(committed_bytes)
if [[ "$init_committed" != "0" ]]; then
    fail "cluster has $init_committed bytes committed before tests start"
    fail "delete leftover slices and re-run, or run with --skip-cleanup OFF in prior runs"
    kubectl get vgpuslice -A
    exit 1
fi
ok "baseline: 0 bytes committed (cluster clean)"

run_test "1.1" "Concurrent gangs (atomicity)"      test_1_1_concurrent_gangs
run_test "1.2" "Race on full-cluster slots"        test_1_2_race_full_cluster
run_test "2.1" "Capacity returns after Running"    test_2_1_capacity_returns_after_running
run_test "2.2" "Failed gang teardown"              test_2_2_failed_gang_teardown

finalize_report

echo
banner "Wave 1 complete"
echo "  ${C_GRN}Passed:${C_RST}  $TESTS_PASSED"
echo "  ${C_RED}Failed:${C_RST}  $TESTS_FAILED"
echo "  Report:  $REPORT"
