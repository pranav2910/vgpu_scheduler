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

# Count VGPUGangReservations in a namespace whose status.phase matches $1.
# Robust JSON parse (the embedded-newline jsonpath form errors out under set -e).
count_rsv_by_phase() {
    local phase=$1 ns=$2
    kubectl get vgpugangreservation -n "$ns" -o json 2>/dev/null \
        | python3 -c "import sys,json;print(sum(1 for g in json.load(sys.stdin).get('items',[]) if g.get('status',{}).get('phase')=='$phase'))" 2>/dev/null \
        || echo 0
}

# Count child objects of a gang by name prefix (children are named "<gang>-N...").
# Children carry gang *annotations*, not labels, so a label selector matches nothing.
count_children_by_prefix() {
    local kind=$1 ns=$2 prefix=$3
    kubectl get "$kind" -n "$ns" --no-headers 2>/dev/null \
        | awk -v p="${prefix}-" 'index($1,p)==1' | wc -l | tr -d ' '
}

# HA helpers (Phase 3.3) ------------------------------------------------------
# Current leader pod name for a lease (holderIdentity is "<pod>_<uuid>").
lease_holder_pod() {
    local lease=$1
    kubectl -n vgpu-system get lease "$lease" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | cut -d'_' -f1
}

# Scrape a single gauge/counter value from one pod via the API-server pod proxy
# (the images are distroless, so there is no in-pod shell/curl to exec). Prints
# the metric value, or "" if absent/unreachable.
pod_metric() {
    local pod=$1 port=$2 metric=$3
    kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/${pod}:${port}/proxy/metrics" 2>/dev/null \
        | awk -v m="$metric" '$1==m {print $2; exit}'
}

# True if the named pod's /readyz returns ready via the API-server pod proxy.
pod_ready() {
    local pod=$1 port=$2
    kubectl get --raw "/api/v1/namespaces/vgpu-system/pods/${pod}:${port}/proxy/readyz" >/dev/null 2>&1
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
    # After a chaos test (controller/scheduler crash) the next test must not
    # start until the control plane has re-stabilized — re-acquired leadership,
    # re-established watches, re-seeded the scheduler cache. Wait for both
    # deployments Available, then a short settle so a freshly-elected leader is
    # actually reconciling before we submit work.
    kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=120s >/dev/null 2>&1 || true
    kubectl rollout status deployment/vgpu-scheduler  -n vgpu-system --timeout=120s >/dev/null 2>&1 || true
    sleep 5

    # Bounded wait for committed capacity to return to 0 (graceful teardown from
    # the previous test may still be draining).
    local committed elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        committed=$(committed_bytes)
        [[ "$committed" == "0" ]] && break
        sleep 2; elapsed=$((elapsed + 2))
    done
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
    # Prefix match so e.g. --only=3 runs the whole Wave 3 group (3.1, 3.2, ...).
    [[ "$id" == "$ONLY".* ]] && return 0
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

# Reset the scheduler's in-memory cache to a known-clean state before testing.
# committed_bytes==0 proves the *API* is clean, but the scheduler cache can
# briefly retain draining holds/allocations from a prior heavy run (self-heals
# in ~50s via the TTL reaper — benign, never over-admission). Restarting forces
# a re-seed from authoritative API state; the warm-up gate guarantees the
# re-seed is correct, so every battery starts deterministic regardless of what
# ran before. (Skipped under --skip-cleanup, where we're inspecting live state.)
if [[ $SKIP_CLEANUP -eq 0 ]]; then
    banner "Preflight: resetting scheduler cache to a clean baseline"
    kubectl rollout restart deployment/vgpu-scheduler -n vgpu-system >/dev/null 2>&1 || true
    kubectl rollout status deployment/vgpu-scheduler -n vgpu-system --timeout=120s >/dev/null 2>&1 || true
    # With 2 replicas (HA), only the leader seeds — scrape ALL scheduler pods by
    # label so we catch the leader's seed log regardless of which pod is leader.
    # `logs deployment/...` picks a single (possibly standby) pod and would miss it.
    seeded=0
    for _ in $(seq 1 30); do
        if kubectl logs -n vgpu-system -l control-plane=vgpu-scheduler --tail=400 --prefix 2>/dev/null \
            | grep -q "Seeded cache: re-accounted"; then
            seeded=1; break
        fi
        sleep 2
    done
    [[ "$seeded" -eq 1 ]] && ok "scheduler cache re-seeded (clean baseline)" || warn "could not confirm re-seed; proceeding anyway"
fi

# Test 2.4 — Scheduler crash mid-bind
#
# test-2-4 v4: custom-deadline submission
#
# Submits 3 gangs with reservationTimeoutSeconds=240 (overriding submit_gang's
# 60s default) so the contention window is wide enough to detect, crash, and
# observe recovery. 2 gangs win; 1 is held by the gang gate. Kill the
# scheduler mid-flight. Verify:
#   - committed gangs remain Committed (cache rebuilds correctly)
#   - deferred gang reaches a clean terminal state (Failed or Committed)
#   - capacity accounting is correct
# Post-crash "settled" check for test 2.4. Returns 0 when no reservation is still
# in a non-terminal phase AND the deferred gang is either cleanly torn down
# (Failed/Released with zero child slices/claims/jobs) or recovered to Committed.
# Defined as a real function so the predicate carries no eval'd `return`/`false`
# control flow (which would otherwise return from wait_for_pred itself).
_gang24_settled() {
    local ns=$1 dg=$2
    local p r rd
    p=$(count_rsv_by_phase Pending "$ns")
    r=$(count_rsv_by_phase Reserving "$ns")
    rd=$(count_rsv_by_phase Reserved "$ns")
    [[ $((p + r + rd)) -gt 0 ]] && return 1
    local defphase
    defphase=$(kubectl get vgpugangreservation -n "$ns" "${dg}-rsv" -o jsonpath='{.status.phase}' 2>/dev/null || echo Released)
    if [[ "$defphase" == "Failed" || "$defphase" == "Released" ]]; then
        local s c j
        s=$(count_children_by_prefix vgpuslice "$ns" "$dg")
        c=$(count_children_by_prefix vgpuclaim "$ns" "$dg")
        j=$(count_children_by_prefix vgpujob  "$ns" "$dg")
        [[ "$s" == "0" && "$c" == "0" && "$j" == "0" ]]
        return
    fi
    [[ "$defphase" == "Committed" ]]
}

test_2_4_scheduler_crash_mid_bind() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-4-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Submit 3 gangs × 4 × 10 GiB with 120s timeout (120 GiB demand into 80 GiB cluster). 2 win, 1 held. Kill scheduler mid-flight."
    log_to_report ""

    # 1. Submit 3 contended gangs inline (240s deadline overrides the 60s
    #    default in submit_gang to give us a stable contention window).
    local g
    for g in g1 g2 g3; do
        cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: $g, namespace: $ns }
spec:
  gangSize: 4
  minAvailable: 4
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 120
  podTemplate:
    spec:
      requestedVramBytes: 10737418240
      serviceTier: Guaranteed
EOF
    done

    sleep 2

    # 2. Wait for contention state.
    if ! wait_for_pred 60 "contention established (2 Committed + 1 Reserving)" '
        c=$(count_rsv_by_phase Committed '"$ns"');
        r=$(count_rsv_by_phase Reserving '"$ns"');
        [[ "$c" -eq 2 ]] && [[ "$r" -eq 1 ]]
    '; then
        fail "did not reach 2-committed-1-deferred state within 60s"
        kubectl get vgpugangreservation -n "$ns"
        ns_cleanup "$ns"; return 1
    fi

    # 3. Identify the deferred gang.
    local deferred_gang=""
    for g in g1 g2 g3; do
        local ph
        ph=$(kubectl get vgpugangreservation -n "$ns" "${g}-rsv" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$ph" == "Reserving" ]]; then
            deferred_gang="$g"
            break
        fi
    done
    if [[ -z "$deferred_gang" ]]; then
        fail "could not identify deferred gang"
        ns_cleanup "$ns"; return 1
    fi
    dim "deferred gang: $deferred_gang (the cohort under test)"
    log_to_report "- Deferred gang: \`$deferred_gang\`"

    local pre_committed; pre_committed=$(committed_bytes)
    dim "pre-crash committed=$pre_committed bytes"

    # 4. Kill scheduler.
    dim "killing scheduler pod..."
    kubectl delete pod -n vgpu-system -l control-plane=vgpu-scheduler --wait=false >/dev/null 2>&1 || true

    # 5. Wait for rollout. With HA (2 replicas) the kill above takes out BOTH
    #    pods, so recovery is a full cold restart + leader election + warm-up;
    #    allow more headroom than the single-replica era's 60s.
    if ! kubectl rollout status deployment/vgpu-scheduler -n vgpu-system --timeout=150s >/dev/null 2>&1; then
        fail "scheduler did not recover within 150s of crash"
        ns_cleanup "$ns"; return 1
    fi
    dim "scheduler back up; observing recovery..."

    # 6. Wait up to 240s (deadline window) for stable terminal state.
    #    Acceptable: g1, g2 stay Committed; deferred gang either Committed
    #    (recovery), Failed (deadline), or Released (failed + cleaned).
    if ! wait_for_pred 240 "stable terminal state after crash" \
        '_gang24_settled '"$ns"' '"$deferred_gang"; then
        fail "system did not reach stable terminal state within 240s after crash"
        kubectl get vgpugangjob,vgpugangreservation,vgpuslice -n "$ns"
        ns_cleanup "$ns"; return 1
    fi

    # 7. Verify post-recovery state.
    local final_committed; final_committed=$(committed_bytes)
    local g1_phase g2_phase def_phase
    g1_phase=$(kubectl get vgpugangreservation -n "$ns" g1-rsv -o jsonpath='{.status.phase}' 2>/dev/null || echo "<gone>")
    g2_phase=$(kubectl get vgpugangreservation -n "$ns" g2-rsv -o jsonpath='{.status.phase}' 2>/dev/null || echo "<gone>")
    def_phase=$(kubectl get vgpugangreservation -n "$ns" "${deferred_gang}-rsv" -o jsonpath='{.status.phase}' 2>/dev/null || echo "<gone>")

    log_to_report ""
    log_to_report "**Observed (post-recovery):**"
    log_to_report "- g1 reservation:        \`$g1_phase\`"
    log_to_report "- g2 reservation:        \`$g2_phase\`"
    log_to_report "- $deferred_gang reservation: \`$def_phase\`"
    log_to_report "- Committed bytes:       $final_committed"

    if [[ "$g1_phase" != "Committed" ]] || [[ "$g2_phase" != "Committed" ]]; then
        fail "committed gangs lost their state across crash: g1=$g1_phase g2=$g2_phase"
        ns_cleanup "$ns"; return 1
    fi

    if [[ "$def_phase" == "Committed" ]]; then
        fail "deferred gang reached Committed but cluster only has 80 GiB — over-admission"
        ns_cleanup "$ns"; return 1
    fi

    local expected_committed=85899345920  # 2 × 40 GiB
    if [[ "$final_committed" != "$expected_committed" ]]; then
        fail "capacity accounting wrong: committed=$final_committed expected=$expected_committed"
        ns_cleanup "$ns"; return 1
    fi

    ok "post-crash state stable: g1=$g1_phase, g2=$g2_phase, $deferred_gang=$def_phase, capacity=$final_committed bytes"
    log_to_report "- **Path:** ✅ Graceful failure of deferred gang; committed gangs preserved"
    ns_cleanup "$ns"
    return 0
}




# ─────────────────────────────────────────────────────────────────────────────
# Test 2.3 — Controller crash mid-gang
# The controller hosts the gang-job, claim, slice, and reservation reconcilers —
# all state lives in CRDs, none in memory. Submit a gang that fits, kill the
# controller while it's materializing, and verify the gang still converges to
# Committed after the controller recovers, with correct capacity and clean teardown.
# ─────────────────────────────────────────────────────────────────────────────
test_2_3_controller_crash_mid_gang() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-3-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Submit a 4 × 10 GiB gang (fits in 80 GiB). Kill the controller mid-materialization. Verify the gang converges to Committed after recovery, then deletes cleanly."
    log_to_report ""

    # 1. Submit a gang that fits, with a generous 180s deadline so a crash burst
    #    cannot push it past the reservation deadline — a stateless controller
    #    should recover and commit well within that budget. (submit_gang's default
    #    60s is too tight to absorb a 3-crash storm + rollout, which correctly
    #    fails closed rather than recovering — see test 2.4 for the deadline path.)
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: ctlcrash, namespace: $ns }
spec:
  gangSize: 4
  minAvailable: 4
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 180
  podTemplate:
    spec:
      requestedVramBytes: 10737418240
      serviceTier: Guaranteed
EOF

    # 2-3. Chaos burst: the full pipeline commits in <4s, so a single well-timed
    #      kill is racy. Instead, crash the controller 3× across the first ~6s so
    #      at least one crash deterministically lands mid-materialization.
    dim "crashing controller 3× during materialization..."
    local i pre_phase
    for i in 1 2 3; do
        pre_phase=$(kubectl get vgpugangreservation -n "$ns" ctlcrash-rsv -o jsonpath='{.status.phase}' 2>/dev/null || echo "<none>")
        dim "  crash $i — reservation phase: ${pre_phase:-<none>}"
        kubectl delete pod -n vgpu-system -l control-plane=vgpu-controller --wait=false >/dev/null 2>&1 || true
        sleep 2
    done
    log_to_report "- Controller crashed 3× during materialization window"

    # 4. Wait for the controller to stabilize after the burst. HA (2 replicas)
    #    means each kill is a full cold restart of both pods + leader election;
    #    allow generous headroom.
    if ! kubectl rollout status deployment/vgpu-controller -n vgpu-system --timeout=150s >/dev/null 2>&1; then
        fail "controller did not recover within 150s of the crash burst"
        ns_cleanup "$ns"; return 1
    fi
    dim "controller stabilized; observing convergence..."

    # 5. Gang must converge to Committed (it fits) after the controller recovers.
    if ! wait_for_pred 120 "gang converges to Committed after controller crash" '
        ph=$(kubectl get vgpugangreservation -n '"$ns"' ctlcrash-rsv -o jsonpath="{.status.phase}" 2>/dev/null);
        [[ "$ph" == "Committed" ]]
    '; then
        fail "gang did not converge to Committed after controller crash"
        kubectl get vgpugangjob,vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi

    # 6. Verify exactly 4 Ready slices and correct capacity.
    local ready; ready=$(kubectl get vgpuslice -n "$ns" -o json 2>/dev/null \
        | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin).get("items",[]) if s.get("status",{}).get("phase")=="Ready"))' 2>/dev/null || echo 0)
    if [[ "$ready" != "4" ]]; then
        fail "expected 4 Ready slices after recovery, got $ready"
        kubectl get vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi
    local committed; committed=$(committed_bytes)
    local expected=42949672960  # 4 × 10 GiB
    if [[ "$committed" != "$expected" ]]; then
        fail "capacity wrong after controller crash: committed=$committed expected=$expected"
        ns_cleanup "$ns"; return 1
    fi
    ok "gang converged to Committed after controller crash: 4 Ready slices, capacity=$committed bytes"
    log_to_report "- Post-recovery: gang Committed, 4 Ready slices, committed=$committed bytes"

    # 7. Delete and verify clean teardown post-recovery.
    kubectl delete vgpugangjob ctlcrash -n "$ns" --wait=false >/dev/null 2>&1 || true
    if ! wait_for_pred 90 "clean teardown after recovery" '
        objs=$(kubectl get vgpugangjob,vgpugangreservation,vgpujob,vgpuclaim,vgpuslice -n '"$ns"' --no-headers 2>/dev/null | wc -l | tr -d " ");
        [[ "$objs" -eq 0 ]]
    '; then
        fail "objects not cleaned up after gang deletion post-recovery"
        kubectl get vgpugangjob,vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi
    ok "post-recovery deletion cleaned up fully; capacity returned to baseline"
    log_to_report "**Path:** ✅ Controller crash is invisible to the gang — CRD-driven state converges after restart."
    ns_cleanup "$ns"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2.6 — Object deletion during in-flight scheduling
# Submit an oversized gang (4 × 30 GiB = 120 GiB into 80 GiB) so it sits in
# Reserving (never reaches quorum) with children materialized and up to 2 held
# cache reservations. Delete the VGPUGangJob mid-flight. Assert the whole tree
# cascade-deletes with no orphans and capacity returns to baseline.
# ─────────────────────────────────────────────────────────────────────────────
test_2_6_delete_during_inflight() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-6-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Submit oversized gang (4 × 30 GiB into 80 GiB → stays Reserving). Delete the VGPUGangJob while in-flight. Verify full cascade cleanup."
    log_to_report ""

    # 1. Submit oversized gang — it will materialize children and sit in Reserving.
    submit_gang "$ns" "race" 4 32212254720   # 30 GiB each

    # 2. Wait until it's genuinely in-flight: Reserving AND children materialized.
    if ! wait_for_pred 30 "gang in-flight (Reserving + ≥1 child slice)" '
        ph=$(kubectl get vgpugangreservation -n '"$ns"' race-rsv -o jsonpath="{.status.phase}" 2>/dev/null);
        sl=$(kubectl get vgpuslice -n '"$ns"' --no-headers 2>/dev/null | wc -l | tr -d " ");
        [[ "$ph" == "Reserving" ]] && [[ "$sl" -ge 1 ]]
    '; then
        fail "gang never reached in-flight (Reserving) state within 30s"
        kubectl get vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi
    local inflight_slices; inflight_slices=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    dim "in-flight: reservation=Reserving, $inflight_slices child slice(s) materialized"
    log_to_report "- In-flight snapshot: reservation Reserving, $inflight_slices child slices"

    # 3. Delete the gang mid-flight.
    dim "deleting VGPUGangJob mid-reservation..."
    kubectl delete vgpugangjob race -n "$ns" --wait=false >/dev/null 2>&1 || true

    # 4. Full cascade cleanup: every object kind drops to zero.
    if ! wait_for_pred 120 "full cascade cleanup after in-flight delete" '
        objs=$(kubectl get vgpugangjob,vgpugangreservation,vgpujob,vgpuclaim,vgpuslice -n '"$ns"' --no-headers 2>/dev/null | wc -l | tr -d " ");
        [[ "$objs" -eq 0 ]]
    '; then
        fail "objects not fully cleaned up after in-flight gang deletion"
        kubectl get vgpugangjob,vgpugangreservation,vgpujob,vgpuclaim,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi

    # 5. Capacity (and any held cache reservations) returned to baseline.
    local final_committed; final_committed=$(committed_bytes)
    if [[ "$final_committed" != "0" ]]; then
        fail "capacity did not return to 0 after in-flight delete: committed=$final_committed"
        ns_cleanup "$ns"; return 1
    fi

    ok "in-flight gang deletion fully cleaned up; no orphans, capacity=0"
    log_to_report ""
    log_to_report "**Observed:** all child jobs/claims/slices + reservation cascade-deleted; committed bytes = 0."
    log_to_report "**Path:** ✅ Mid-flight deletion races cleanly to a clean cluster."
    ns_cleanup "$ns"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2.7 — Gang + preemption interaction
# Gang members are non-preemptible by design: evicting one member would break
# gang atomicity, so the system must NOT preempt a gang member even for a strictly
# higher-priority request. Fill the cluster with a non-preemptible gang, submit a
# higher-priority standalone VGPUJob, and assert the gang stays fully intact and
# the high-priority request simply fails to schedule (no member enters Preempting).
# ─────────────────────────────────────────────────────────────────────────────
test_2_7_gang_vs_preemption() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-7-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Non-preemptible gang (4 × 20 GiB) fills the cluster. Submit a higher-priority (900) standalone job needing 20 GiB. Assert no gang member is preempted; gang stays Running; high-prio request fails to schedule."
    log_to_report ""

    # 1. Fill the cluster with a non-preemptible gang (submit_gang sets priority 500,
    #    preemptible false). 4 × 20 GiB = 80 GiB = whole cluster.
    submit_gang "$ns" "filler" 4 21474836480
    if ! wait_for_pred 60 "filler gang Committed (cluster full)" '
        ph=$(kubectl get vgpugangreservation -n '"$ns"' filler-rsv -o jsonpath="{.status.phase}" 2>/dev/null);
        [[ "$ph" == "Committed" ]]
    '; then
        fail "filler gang did not commit within 60s"
        kubectl get vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi
    dim "filler gang Committed; cluster is full (80 GiB)"

    # 2. Submit a higher-priority (900) standalone VGPUJob needing 20 GiB.
    #    Priority delta is 400 (≥100), but the only occupants are non-preemptible
    #    gang members — so it must NOT trigger preemption.
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: highprio, namespace: $ns }
spec:
  priority: 900
  preemptible: false
  workloadClass: Inference
  preemptionGraceSeconds: 30
  claimTemplate:
    spec:
      requestedVramBytes: 21474836480
      serviceTier: Guaranteed
EOF
    dim "submitted higher-priority (900) standalone job; observing for 25s..."

    # 3. Observe for 25s: no gang member may enter Preempting, gang stays intact,
    #    high-prio slice must not become Ready.
    local breached=0 t=0
    while [[ $t -lt 25 ]]; do
        local preempting
        preempting=$(kubectl get vgpuslice -n "$ns" -o json 2>/dev/null \
            | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin).get("items",[]) if s.get("status",{}).get("phase")=="Preempting"))' 2>/dev/null || echo 0)
        if [[ "$preempting" != "0" ]]; then breached=1; break; fi
        sleep 5; t=$((t + 5))
    done
    if [[ "$breached" -eq 1 ]]; then
        fail "a gang member entered Preempting — gang atomicity violated by preemption"
        kubectl get vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi

    # 4. Verify the gang is still fully intact and capacity unchanged.
    local rsv_phase ready committed
    rsv_phase=$(kubectl get vgpugangreservation -n "$ns" filler-rsv -o jsonpath='{.status.phase}' 2>/dev/null || echo "<gone>")
    ready=$(kubectl get vgpuslice -n "$ns" -o json 2>/dev/null \
        | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin).get("items",[]) if s.get("status",{}).get("phase")=="Ready" and s["metadata"]["name"].startswith("filler-")))' 2>/dev/null || echo 0)
    committed=$(committed_bytes)
    if [[ "$rsv_phase" != "Committed" || "$ready" != "4" ]]; then
        fail "filler gang not intact after high-prio submission: phase=$rsv_phase ready=$ready"
        kubectl get vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi

    # 5. The high-priority request must NOT have scheduled (no capacity, no eviction).
    local hp_phase
    hp_phase=$(kubectl get vgpuslice -n "$ns" highprio-claim-slice -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [[ "$hp_phase" == "Ready" ]]; then
        fail "high-priority job scheduled despite a full, non-preemptible cluster (over-admission)"
        ns_cleanup "$ns"; return 1
    fi
    if [[ "$committed" != "85899345920" ]]; then
        fail "capacity changed unexpectedly: committed=$committed (expected 80 GiB held by gang)"
        ns_cleanup "$ns"; return 1
    fi

    ok "gang intact (4 Ready), no member preempted; high-prio request correctly unscheduled (phase=$hp_phase)"
    log_to_report "- Filler gang: Committed, 4 Ready slices (intact)"
    log_to_report "- High-priority job slice: \`$hp_phase\` (not scheduled — correct)"
    log_to_report "**Path:** ✅ Gang atomicity beats single-slice priority; non-preemptible members are never evicted."
    ns_cleanup "$ns"
    return 0
}

# Test 2.9 — Child deleted after commit (fail-loud)
# A committed gang is all-or-nothing. Deleting ONE child VGPUJob out from under
# a Committed gang must NOT leave the gang advertised Committed forever while
# the survivors hold VRAM (the pre-fix machine had no exit from Committed: the
# tally showed 1 missing + no transition + a 5s requeue, for the life of the
# object). Expected: reservation → Failed (reason "child lost after commit",
# confirmed by a direct API read) → teardown of survivors → Released; committed
# capacity returns to zero; no orphan slices.
# ─────────────────────────────────────────────────────────────────────────────
test_2_9_child_loss_after_commit() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-9-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null

    log_to_report "**Setup:** Commit a 2 × 20 GiB gang, then \`kubectl delete\` one child VGPUJob. Assert the reservation fails loud (child lost after commit), survivors are torn down, committed capacity returns to zero."
    log_to_report ""

    # 1. Commit a 2-member gang (40 GiB total — fits comfortably).
    submit_gang "$ns" "victim" 2 21474836480
    if ! wait_for_pred 60 "victim gang Committed" '
        ph=$(kubectl get vgpugangreservation -n '"$ns"' victim-rsv -o jsonpath="{.status.phase}" 2>/dev/null);
        [[ "$ph" == "Committed" ]]
    '; then
        fail "gang did not commit within 60s"
        kubectl get vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi
    dim "gang Committed (2/2); deleting child job victim-0 out from under it..."

    # 2. Delete one child VGPUJob (cascades to its claim + slice).
    kubectl delete vgpujob victim-0 -n "$ns" --wait=false >/dev/null 2>&1

    # 3. The reservation must fail LOUD with the child-lost reason — not sit
    #    Committed. (Failed may race straight through to Released; accept both
    #    but require the reason.)
    if ! wait_for_pred 60 "reservation fails loud (child lost after commit)" '
        ph=$(kubectl get vgpugangreservation -n '"$ns"' victim-rsv -o jsonpath="{.status.phase}" 2>/dev/null);
        rsn=$(kubectl get vgpugangreservation -n '"$ns"' victim-rsv -o jsonpath="{.status.failureReason}" 2>/dev/null);
        [[ ( "$ph" == "Failed" || "$ph" == "Released" ) && "$rsn" == *"child lost after commit"* ]]
    '; then
        fail "reservation did not fail loud after child deletion (stuck Committed = the bug)"
        kubectl get vgpugangreservation,vgpuslice,vgpujob -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi
    dim "reservation failed loud (child lost); awaiting teardown → Released + capacity return..."

    # 4. Teardown completes: Released, committed capacity back to zero.
    if ! wait_for_pred 90 "teardown completes (Released, committed capacity 0)" '
        ph=$(kubectl get vgpugangreservation -n '"$ns"' victim-rsv -o jsonpath="{.status.phase}" 2>/dev/null || echo "Released");
        cb=$(committed_bytes);
        [[ "$ph" == "Released" && "$cb" == "0" ]]
    '; then
        fail "teardown incomplete after child-loss failure (survivors still holding capacity)"
        kubectl get vgpugangreservation,vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi

    # 5. No orphan slices may remain holding VRAM.
    local leftover
    leftover=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null | grep -cv '^$' || true)
    if [[ "${leftover:-0}" != "0" ]]; then
        fail "orphan slices remain after child-loss teardown ($leftover)"
        kubectl get vgpuslice -n "$ns" 2>/dev/null
        ns_cleanup "$ns"; return 1
    fi

    ok "child loss after commit fails LOUD: Failed (child lost) → teardown → Released; capacity reclaimed; no orphans"
    log_to_report "- Reservation: \`Failed → Released\` with reason \`child lost after commit\`"
    log_to_report "- Survivor torn down; committed capacity returned to 0; no orphan slices"
    log_to_report "**Path:** ✅ A committed gang that loses a child fails loud and releases its capacity — it can no longer sit Committed forever holding VRAM."
    ns_cleanup "$ns"
    return 0
}

# Test 2.8 — Scheduler leader failover (HA, Phase 3.3)
# Fill the cluster with 2 gangs (80 GiB) + a 3rd gang that cannot fit. Kill the
# active scheduler leader. The hot standby must take over and, crucially,
# re-account the already-committed 80 GiB during warm-up BEFORE it is Ready —
# so it does NOT admit the 3rd gang into occupied capacity. Asserts the five HA
# invariants: no over-admission, no duplicate binds, no stuck reservations,
# cache_warmup_complete before readyz on the new leader, and a clean
# leader_active transfer. Then proves the new leader is fully functional by
# freeing capacity and watching the waiting gang schedule.
test_2_8_scheduler_leader_failover() {
    require_clean_baseline
    local ns="${NS_PREFIX}-2-8-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null
    dim "namespace: $ns"

    # Pre-flight: 2 replicas with exactly one leader.
    local replicas
    replicas=$(kubectl -n vgpu-system get deploy vgpu-scheduler -o jsonpath='{.spec.replicas}')
    if [[ "$replicas" -lt 2 ]]; then
        fail "scheduler not running >=2 replicas (got $replicas) — HA requires a hot standby"
        ns_cleanup "$ns"; return 1
    fi

    # 1. Fill the cluster: 2 gangs x 4 x 10 GiB = 80 GiB.
    submit_gang "$ns" "g1" 4 10737418240
    submit_gang "$ns" "g2" 4 10737418240
    if ! wait_for_pred 90 "2 gangs committed (cluster full)" \
        '[[ "$(committed_bytes)" == "85899345920" ]]'; then
        fail "could not fill cluster with 2 gangs pre-failover (committed=$(committed_bytes))"
        ns_cleanup "$ns"; return 1
    fi
    # 2. A 3rd gang that cannot fit — must stay un-admitted. Long reservation
    #    deadline so it is still Reserving (not deadline-Failed) after the
    #    failover window, letting step 9 prove the new leader can schedule it.
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: g3, namespace: $ns }
spec:
  gangSize: 4
  minAvailable: 4
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 600
  podTemplate:
    spec:
      requestedVramBytes: 10737418240
      serviceTier: Guaranteed
EOF
    sleep 5
    local g3_phase; g3_phase=$(gang_phase "$ns" g3)
    dim "pre-failover: committed=$(committed_bytes) g3=$g3_phase"

    # 3. Identify leader + standby via the lease.
    local leader standby
    leader=$(lease_holder_pod vgpu-scheduler-lock)
    if [[ -z "$leader" ]]; then
        fail "could not resolve scheduler leader from lease"
        ns_cleanup "$ns"; return 1
    fi
    standby=$(kubectl -n vgpu-system get pods -l control-plane=vgpu-scheduler \
        -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "^${leader}$" | head -1)
    dim "leader=$leader standby=$standby"

    # 4. Invariant 5 (pre): exactly the leader reports leader_active=1.
    if [[ "$(pod_metric "$leader" 8081 vgpu_scheduler_leader_active)" != "1" ]]; then
        fail "pre-failover leader $leader does not report leader_active=1"
        ns_cleanup "$ns"; return 1
    fi
    if [[ -n "$standby" && "$(pod_metric "$standby" 8081 vgpu_scheduler_leader_active)" == "1" ]]; then
        fail "standby $standby reports leader_active=1 — two leaders"
        ns_cleanup "$ns"; return 1
    fi

    # 5. Kill the leader.
    dim "killing leader pod $leader ..."
    kubectl -n vgpu-system delete pod "$leader" --wait=false >/dev/null 2>&1 || true

    # 6. The lease must move off the killed leader. The winner may be the hot
    #    standby (fast) or a fresh replacement pod (the election winner is
    #    non-deterministic); either is valid HA — assert only that a *new*
    #    leader emerges, then bind to whoever it is.
    if ! wait_for_pred 90 "lease fails over to a new leader" \
        "h=\$(lease_holder_pod vgpu-scheduler-lock); [[ -n \"\$h\" && \"\$h\" != \"$leader\" ]]"; then
        fail "leader lease did not fail over within 90s (holder=$(lease_holder_pod vgpu-scheduler-lock))"
        ns_cleanup "$ns"; return 1
    fi
    local new_leader; new_leader=$(lease_holder_pod vgpu-scheduler-lock)
    dim "new leader = $new_leader ($([[ "$new_leader" == "$standby" ]] && echo "hot standby took over" || echo "replacement pod won election"))"

    # 7. Invariant 4 + 5: new leader warms up, flips leader_active, and only then
    #    reports Ready.
    if ! wait_for_pred 90 "new leader warmed up + leader_active=1" \
        "[[ \"\$(pod_metric $new_leader 8081 vgpu_scheduler_cache_warmup_complete)\" == \"1\" && \"\$(pod_metric $new_leader 8081 vgpu_scheduler_leader_active)\" == \"1\" ]]"; then
        fail "new leader $new_leader did not warm up + claim leader_active within 90s"
        ns_cleanup "$ns"; return 1
    fi
    if ! pod_ready "$new_leader" 8082; then
        fail "new leader $new_leader warmed up but /readyz is not Ready"
        ns_cleanup "$ns"; return 1
    fi
    # The killed leader's series is gone; confirm no second pod still claims leadership.
    local other_active=0
    for p in $(kubectl -n vgpu-system get pods -l control-plane=vgpu-scheduler -o jsonpath='{.items[*].metadata.name}'); do
        [[ "$p" == "$new_leader" ]] && continue
        [[ "$(pod_metric "$p" 8081 vgpu_scheduler_leader_active)" == "1" ]] && other_active=1
    done
    if [[ "$other_active" == "1" ]]; then
        fail "more than one pod reports leader_active=1 after failover (split brain)"
        ns_cleanup "$ns"; return 1
    fi
    ok "failover: leader_active transferred cleanly to $new_leader; warm-up completed before Ready"

    # 8. Invariants 1 + 2: no over-admission, no duplicate binds. The new leader
    #    cold-started, re-accounted 80 GiB, and must NOT have admitted g3.
    local cb ready_slices
    cb=$(committed_bytes)
    ready_slices=$(kubectl get vgpuslice -n "$ns" -o json 2>/dev/null \
        | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin)["items"] if s.get("status",{}).get("phase")=="Ready"))')
    if [[ "$cb" -gt "$GPU_BYTES_TOTAL" ]]; then
        fail "OVER-ADMISSION after failover: committed=$cb > capacity=$GPU_BYTES_TOTAL"
        ns_cleanup "$ns"; return 1
    fi
    if [[ "$cb" != "$GPU_BYTES_TOTAL" || "$ready_slices" != "8" ]]; then
        fail "post-failover inconsistency: committed=$cb (want $GPU_BYTES_TOTAL), readySlices=$ready_slices (want 8)"
        ns_cleanup "$ns"; return 1
    fi
    if [[ "$(gang_phase "$ns" g3)" == "Running" ]]; then
        fail "g3 became Running after failover — over-admission into occupied capacity"
        ns_cleanup "$ns"; return 1
    fi
    ok "no over-admission / no duplicate binds: committed=$cb, 8 Ready slices, g3 still not admitted"

    # 9. Invariant 3 + functional proof: free 40 GiB (delete g1); the new leader
    #    must schedule the waiting g3 into the freed capacity (no stuck gang).
    kubectl delete vgpugangjob -n "$ns" g1 >/dev/null 2>&1 || true
    if ! wait_for_pred 90 "new leader schedules waiting g3 after capacity frees" \
        "[[ \"\$(gang_phase $ns g3)\" == \"Running\" ]]"; then
        fail "g3 did not schedule on the new leader after g1 freed capacity (g3=$(gang_phase "$ns" g3)) — stuck reservation or dead leader"
        ns_cleanup "$ns"; return 1
    fi
    cb=$(committed_bytes)
    if [[ "$cb" -gt "$GPU_BYTES_TOTAL" ]]; then
        fail "OVER-ADMISSION after g3 scheduled: committed=$cb > $GPU_BYTES_TOTAL"
        ns_cleanup "$ns"; return 1
    fi
    ok "new leader fully functional: g3 scheduled after g1 freed capacity, committed=$cb (<= $GPU_BYTES_TOTAL)"

    log_to_report "- 2-replica scheduler; killed leader \`$leader\`, standby \`$standby\` took over"
    log_to_report "- New leader re-accounted 80 GiB during warm-up before Ready; no over-admission of g3"
    log_to_report "- leader_active transferred cleanly; g3 scheduled only after capacity was freed"
    log_to_report "**Path:** ✅ HA failover preserves safety (no over-admission), atomicity, and liveness."
    ns_cleanup "$ns"
    return 0
}

# ============================================================================
# WAVE 3 — Complex / adversarial scenarios (does it sustain what it claims?)
# Each combines subsystems or sustained load to stress a headline claim that
# the per-feature Wave 1/2 tests don't exercise together.
# ============================================================================

# Test 3.1 — Heterogeneous gangs under heavy over-subscription.
# Demand 180 GiB (40+40+20+80) into 80. Claim under test: SAFETY (committed
# never exceeds capacity at ANY instant) + LIVENESS (something packs in) +
# stability (no flapping at steady state) when gang sizes are mixed.
test_3_1_heterogeneous_packing() {
    require_clean_baseline
    local ns="${NS_PREFIX}-3-1-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null
    dim "namespace: $ns — demand 180 GiB into 80 (mixed sizes 40/40/20/80)"

    submit_gang "$ns" "a" 4 10737418240   # 40 GiB
    submit_gang "$ns" "b" 4 10737418240   # 40 GiB
    submit_gang "$ns" "c" 2 10737418240   # 20 GiB
    submit_gang "$ns" "d" 8 10737418240   # 80 GiB

    # Continuously sample the safety invariant for 75s.
    local max=0 cb samples=0 last5=()
    local deadline=$(( $(date +%s) + 75 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        cb=$(committed_bytes); samples=$((samples + 1))
        if [[ "$cb" -gt "$GPU_BYTES_TOTAL" ]]; then
            fail "OVER-ADMISSION: committed=$cb > $GPU_BYTES_TOTAL (sample $samples)"
            kubectl get vgpugangreservation -n "$ns"
            ns_cleanup "$ns"; return 1
        fi
        [[ "$cb" -gt "$max" ]] && max=$cb
        last5+=("$cb"); [[ ${#last5[@]} -gt 5 ]] && last5=("${last5[@]:1}")
        sleep 3
    done

    cb=$(committed_bytes)
    if [[ "$cb" -eq 0 ]]; then
        fail "LIVENESS: nothing committed from 4 feasible gangs after 75s"
        kubectl get vgpugangreservation -n "$ns"
        ns_cleanup "$ns"; return 1
    fi
    # Stability: the last 5 samples should be identical (settled, not flapping).
    local stable=1 v
    for v in "${last5[@]}"; do [[ "$v" == "$cb" ]] || stable=0; done
    if [[ "$stable" -ne 1 ]]; then
        warn "committed still moving at end (${last5[*]}) — not yet settled, but never over-admitted"
    fi
    ok "heterogeneous safety held: max committed=$max <= $GPU_BYTES_TOTAL over $samples samples; settled committed=$cb"
    log_to_report "- Mixed gangs (40/40/20/80) into 80 GiB: max observed committed = $max bytes, never exceeded capacity."
    log_to_report "**Path:** ✅ Safety holds under heterogeneous over-subscription; cluster packs (committed=$cb), no over-admission."
    ns_cleanup "$ns"
    return 0
}

# Test 3.2 — Anti-starvation: an impossible gang must not block feasible ones.
# X needs 160 GiB (8×20) — it can NEVER fit, and would hog the serialized
# admission slot. Y1,Y2 (40 each) DO fit together. Claim: the gate backs X off
# so Y1+Y2 make progress while X is still actively contending (not after X dies).
test_3_2_impossible_gang_no_starvation() {
    require_clean_baseline
    local ns="${NS_PREFIX}-3-2-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null
    dim "namespace: $ns — impossible X(8×20=160) + feasible Y1,Y2(40 each)"

    # X: impossible, LONG deadline so it keeps contending the whole test.
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: x, namespace: $ns }
spec:
  gangSize: 8
  minAvailable: 8
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 600
  podTemplate:
    spec:
      requestedVramBytes: 21474836480   # 20 GiB × 8 = 160 GiB (never fits)
      serviceTier: Guaranteed
EOF
    submit_gang "$ns" "y1" 4 10737418240   # 40 GiB
    submit_gang "$ns" "y2" 4 10737418240   # 40 GiB

    # Both feasible gangs must reach Running while X is still Reserving.
    if ! wait_for_pred 150 "Y1 and Y2 both Running despite impossible X" '
        [[ "$(gang_phase '"$ns"' y1)" == "Running" ]] && [[ "$(gang_phase '"$ns"' y2)" == "Running" ]]
    '; then
        fail "STARVATION: feasible gangs did not both reach Running within 150s (y1=$(gang_phase "$ns" y1) y2=$(gang_phase "$ns" y2) x=$(gang_phase "$ns" x))"
        kubectl get vgpugangreservation -n "$ns"
        ns_cleanup "$ns"; return 1
    fi
    local xphase cb
    xphase=$(gang_phase "$ns" x)
    cb=$(committed_bytes)
    if [[ "$cb" -gt "$GPU_BYTES_TOTAL" ]]; then
        fail "OVER-ADMISSION while packing around impossible gang: committed=$cb"
        ns_cleanup "$ns"; return 1
    fi
    if [[ "$xphase" == "Running" ]]; then
        fail "impossible gang X reached Running — that is physically impossible (160>80)"
        ns_cleanup "$ns"; return 1
    fi
    ok "no starvation: Y1+Y2 Running (committed=$cb), impossible X correctly NOT admitted (phase=$xphase)"
    log_to_report "- Impossible gang (160 GiB) did not block two feasible 40 GiB gangs; X stayed \`$xphase\`."
    log_to_report "**Path:** ✅ Serialized-admission backoff prevents an un-assemblable gang from starving the cluster."
    ns_cleanup "$ns"
    return 0
}

# Test 3.3 — Sustained mixed-workload soak: 6 rounds of submit→settle→delete.
# Claim: the system SUSTAINS over time — safety holds every round, and capacity
# returns to exactly 0 after each round (no cache/accounting leak across cycles).
test_3_3_soak_no_leak() {
    require_clean_baseline
    local ns="${NS_PREFIX}-3-3-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null
    dim "namespace: $ns — 6 rounds of mixed submit/delete, leak + safety check"

    local round
    for round in 1 2 3 4 5 6; do
        # Vary the mix per round so accounting paths differ.
        submit_gang "$ns" "r${round}a" 4 10737418240             # 40
        submit_gang "$ns" "r${round}b" 4 10737418240             # 40
        submit_gang "$ns" "r${round}c" 2 10737418240             # 20 (over-subscribe → 100>80)

        # Sample safety for ~18s.
        local cb t=0
        while [[ $t -lt 18 ]]; do
            cb=$(committed_bytes)
            if [[ "$cb" -gt "$GPU_BYTES_TOTAL" ]]; then
                fail "OVER-ADMISSION in soak round $round: committed=$cb > $GPU_BYTES_TOTAL"
                ns_cleanup "$ns"; return 1
            fi
            sleep 3; t=$((t + 3))
        done

        # Tear the round down and require capacity back to 0 (leak check).
        kubectl delete vgpugangjob -n "$ns" --all --wait=false >/dev/null 2>&1 || true
        if ! wait_for_pred 60 "round $round capacity returns to 0" '[[ "$(committed_bytes)" == "0" ]]'; then
            fail "LEAK: capacity did not return to 0 after round $round (committed=$(committed_bytes))"
            kubectl get vgpuslice -n "$ns"
            ns_cleanup "$ns"; return 1
        fi
        dim "  round $round OK (safety held, capacity reclaimed to 0)"
    done

    ok "soak survived 6 mixed rounds: safety held every round, zero capacity leak between cycles"
    log_to_report "- 6 submit/settle/delete rounds: no over-admission, capacity returned to 0 each round (no leak)."
    log_to_report "**Path:** ✅ Accounting is stable over sustained churn — no drift, no leak."
    ns_cleanup "$ns"
    return 0
}

# Test 3.4 — Quota + gang atomicity composition.
# Namespace quota = 40 GiB. Q1 (40) fits → commits. Q2 (40) would breach quota
# (80>40) → must be rejected WHOLE, never partially admitted. Claim: quota
# enforcement composes with gang all-or-nothing.
test_3_4_quota_gang_atomicity() {
    require_clean_baseline
    local ns="${NS_PREFIX}-3-4-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null
    dim "namespace: $ns — VGPUQuota maxVramBytes=40 GiB"

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUQuota
metadata: { name: ns-quota, namespace: $ns }
spec:
  targetNamespace: $ns
  maxVramBytes: 42949672960   # 40 GiB
  description: "Wave3 quota+gang composition test"
EOF
    sleep 2

    submit_gang "$ns" "q1" 4 10737418240   # 40 GiB — fits quota exactly
    if ! wait_for_pred 90 "Q1 (40 GiB) commits within quota" '[[ "$(gang_phase '"$ns"' q1)" == "Running" ]]'; then
        fail "Q1 (40 GiB) did not commit under a 40 GiB quota (phase=$(gang_phase "$ns" q1))"
        kubectl get vgpugangjob,vgpuquota -n "$ns"
        ns_cleanup "$ns"; return 1
    fi

    submit_gang "$ns" "q2" 4 10737418240   # 40 GiB — would push namespace to 80 > 40
    # Observe for 30s: Q2 must NOT commit, and committed must stay at 40 (Q1 only).
    local t=0 cb q2_ready
    while [[ $t -lt 30 ]]; do
        cb=$(committed_bytes)
        if [[ "$cb" -gt 42949672960 ]]; then
            fail "QUOTA BREACH: committed=$cb > quota 42949672960 (Q2 partially admitted?)"
            ns_cleanup "$ns"; return 1
        fi
        q2_ready=$(kubectl get vgpuslice -n "$ns" -o json 2>/dev/null | python3 -c '
import sys,json
n=sum(1 for s in json.load(sys.stdin)["items"]
      if s.get("metadata",{}).get("annotations",{}).get("gang.vgpu.pranav2910.com/gang")=="q2"
      and s.get("status",{}).get("phase")=="Ready")
print(n)')
        if [[ "${q2_ready:-0}" -gt 0 ]]; then
            fail "ATOMICITY+QUOTA: Q2 has $q2_ready Ready slice(s) — partial admission past quota"
            ns_cleanup "$ns"; return 1
        fi
        sleep 3; t=$((t + 3))
    done

    if [[ "$(gang_phase "$ns" q2)" == "Running" ]]; then
        fail "Q2 reached Running despite exceeding namespace quota"
        ns_cleanup "$ns"; return 1
    fi
    ok "quota+gang compose: Q1 Running (committed=$(committed_bytes)=40 GiB), Q2 correctly held out (phase=$(gang_phase "$ns" q2))"
    log_to_report "- Quota 40 GiB: Q1 committed; Q2 (would breach) held out whole, 0 partial slices."
    log_to_report "**Path:** ✅ Quota enforcement composes with gang atomicity — no partial over-quota admission."
    ns_cleanup "$ns"
    return 0
}

# Test 3.5 — HA under live contention: kill the scheduler leader TWICE while two
# 80 GiB gangs contend for an 80 GiB cluster. Claim: stacking leader churn on
# top of contention never over-admits and still converges to a single winner.
test_3_5_leader_churn_under_contention() {
    require_clean_baseline
    local ns="${NS_PREFIX}-3-5-$(date +%s)"
    kubectl create namespace "$ns" >/dev/null
    dim "namespace: $ns — two 80 GiB gangs contend; leader killed 2× mid-flight"

    # Long deadlines so the loser keeps waiting (Reserving) through the churn
    # instead of deadline-failing for an unrelated reason.
    local g
    for g in g1 g2; do
        cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUGangJob
metadata: { name: $g, namespace: $ns }
spec:
  gangSize: 8
  minAvailable: 8
  priority: 500
  workloadClass: Training
  preemptible: false
  reservationTimeoutSeconds: 300
  podTemplate:
    spec:
      requestedVramBytes: 10737418240
      serviceTier: Guaranteed
EOF
    done

    # Establish the winner BEFORE churning: exactly one 80 GiB gang commits.
    if ! wait_for_pred 90 "one 80 GiB gang commits (contention resolved)" '
        c=$(count_rsv_by_phase Committed '"$ns"'); [[ "$c" -eq 1 ]] && [[ "$(committed_bytes)" == "85899345920" ]]
    '; then
        fail "contention did not resolve to one committed gang pre-churn (committed=$(count_rsv_by_phase Committed "$ns"), bytes=$(committed_bytes))"
        kubectl get vgpugangreservation -n "$ns"; ns_cleanup "$ns"; return 1
    fi
    dim "winner established; now killing the leader twice under load"

    # Kill the active scheduler leader twice, sampling safety throughout.
    local kills=0 cb
    while [[ $kills -lt 2 ]]; do
        local leader; leader=$(lease_holder_pod vgpu-scheduler-lock)
        if [[ -n "$leader" ]]; then
            dim "  killing leader $leader (kill #$((kills+1)))"
            kubectl -n vgpu-system delete pod "$leader" --wait=false >/dev/null 2>&1 || true
            kills=$((kills + 1))
        fi
        # sample safety a few times between kills
        local s=0
        while [[ $s -lt 5 ]]; do
            cb=$(committed_bytes)
            if [[ "$cb" -gt "$GPU_BYTES_TOTAL" ]]; then
                fail "OVER-ADMISSION during leader churn: committed=$cb > $GPU_BYTES_TOTAL"
                ns_cleanup "$ns"; return 1
            fi
            sleep 3; s=$((s + 1))
        done
    done

    # Let the dust settle and require convergence: exactly one 80 GiB gang wins.
    kubectl -n vgpu-system rollout status deployment/vgpu-scheduler --timeout=150s >/dev/null 2>&1 || true
    if ! wait_for_pred 180 "converges to exactly one committed 80 GiB gang" '
        c=$(count_rsv_by_phase Committed '"$ns"');
        cb=$(committed_bytes);
        [[ "$c" -eq 1 ]] && [[ "$cb" == "85899345920" ]]
    '; then
        fail "did not converge to exactly one committed gang after churn (committed=$(count_rsv_by_phase Committed "$ns"), bytes=$(committed_bytes))"
        kubectl get vgpugangreservation -n "$ns"
        ns_cleanup "$ns"; return 1
    fi
    ok "HA holds under contention: 2 leader kills mid-flight, never over-admitted, converged to 1 winner (80 GiB)"
    log_to_report "- Two 80 GiB gangs + 2 leader kills: never over-admitted; converged to exactly one committed gang."
    log_to_report "**Path:** ✅ Safety + liveness survive leadership churn stacked on contention."
    ns_cleanup "$ns"
    return 0
}

# Functional tests first, then the destructive chaos tests LAST (standard
# practice): a crashed controller/scheduler needs time to re-stabilize, and
# running chaos last means that re-stabilization can't bleed into other tests.
run_test "1.1" "Concurrent gangs (atomicity)"      test_1_1_concurrent_gangs
run_test "1.2" "Race on full-cluster slots"        test_1_2_race_full_cluster
run_test "2.1" "Capacity returns after Running"    test_2_1_capacity_returns_after_running
run_test "2.2" "Failed gang teardown"              test_2_2_failed_gang_teardown
run_test "2.6" "Delete during in-flight scheduling" test_2_6_delete_during_inflight
run_test "2.7" "Gang vs preemption (atomicity)"    test_2_7_gang_vs_preemption
run_test "2.9" "Child deleted after commit (fail-loud)" test_2_9_child_loss_after_commit
# Wave 3 — complex / adversarial (non-destructive ones here; chaos with the rest)
run_test "3.1" "Heterogeneous gangs (safety+liveness)" test_3_1_heterogeneous_packing
run_test "3.2" "Impossible gang (anti-starvation)"     test_3_2_impossible_gang_no_starvation
run_test "3.3" "Sustained soak (no leak)"              test_3_3_soak_no_leak
run_test "3.4" "Quota + gang atomicity"                test_3_4_quota_gang_atomicity
# Destructive chaos LAST.
run_test "2.4" "Scheduler crash mid-bind"          test_2_4_scheduler_crash_mid_bind
run_test "2.3" "Controller crash mid-gang"         test_2_3_controller_crash_mid_gang
run_test "2.8" "Scheduler leader failover (HA)"    test_2_8_scheduler_leader_failover
run_test "3.5" "Leader churn under contention (HA)" test_3_5_leader_churn_under_contention

finalize_report

echo
banner "Wave 1 complete"
echo "  ${C_GRN}Passed:${C_RST}  $TESTS_PASSED"
echo "  ${C_RED}Failed:${C_RST}  $TESTS_FAILED"
echo "  Report:  $REPORT"
