#!/usr/bin/env bash
# ============================================================================
# vGPU Scheduler — Integration Test Suite
#
# Validates all architectural claims of Layer 1 + Layer 2 (through Phase 2.3)
# end-to-end on a live kind cluster. Each test is independent and idempotent;
# the suite cleans up between tests.
#
# Usage:
#   bash integration_test.sh                 # run everything
#   bash integration_test.sh layer1          # only Layer 1 tests
#   bash integration_test.sh phase23         # only preemption tests
#   bash integration_test.sh quick           # smoke test (5 most important)
#
# Exit code: 0 if all selected tests pass, non-zero on first failure.
#
# Pre-conditions:
#   - kubectl talks to a cluster with the vGPU scheduler installed
#   - Both vgpu-controller and vgpu-scheduler pods are Running
#   - At least 1 node with the mock 80GiB GPU resource
#
# Author: pranav2910
# ============================================================================

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

NS_PREFIX="itest"
TIMEOUT_BIND=45      # seconds to wait for a slice to reach Ready
TIMEOUT_PREEMPT=30   # seconds to wait for a Preempting transition
TIMEOUT_DELETE=45    # seconds to wait for cascade-delete

# Sizes (in bytes)
GIB=$((1024 * 1024 * 1024))
SIZE_5G=$((5 * GIB))
SIZE_10G=$((10 * GIB))
SIZE_15G=$((15 * GIB))
SIZE_20G=$((20 * GIB))
SIZE_35G=$((35 * GIB))
SIZE_70G=$((70 * GIB))

# ============================================================================
# Output formatting
# ============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=()

log_info()    { echo -e "${BLUE}ℹ${RESET}  $*"; }
log_pass()    { echo -e "${GREEN}✓${RESET}  $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail()    { echo -e "${RED}✗${RESET}  $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("$1"); }
log_skip()    { echo -e "${YELLOW}⊘${RESET}  $*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
log_section() { echo ""; echo -e "${BOLD}═══ $* ═══${RESET}"; }
log_test()    { echo ""; echo -e "${BOLD}▶ $*${RESET}"; }

# ============================================================================
# Helper functions
# ============================================================================

# Wait until predicate evaluates to true, or timeout.
# wait_for <timeout_seconds> <description> <predicate-bash-command>
wait_for() {
    local timeout=$1; shift
    local desc=$1; shift
    local cmd=$*
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Get slice phase (or empty string)
slice_phase() {
    local ns=$1 name=$2
    kubectl get vgpuslice -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null
}

# Get slice node binding
slice_node() {
    local ns=$1 name=$2
    kubectl get vgpuslice -n "$ns" "$name" -o jsonpath='{.status.boundNode}' 2>/dev/null
}

# Count slices in a namespace by phase
count_slices_by_phase() {
    local ns=$1 phase=$2
    kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null \
        | awk -v p="$phase" '$3 == p' | wc -l
}

# Check whether a string appears in scheduler logs since a timestamp
scheduler_log_contains() {
    local since=$1 pattern=$2
    kubectl logs -n vgpu-system deploy/vgpu-scheduler --since="${since}s" 2>/dev/null \
        | grep -q -E "$pattern"
}

# Submit a VGPUJob with given parameters
# Args: namespace, name, priority, preemptible(true|false), workloadClass,
#       requested_bytes, tier(BestEffort|Burstable|Guaranteed), [grace_seconds]
submit_job() {
    local ns=$1 name=$2 priority=$3 preemptible=$4 wclass=$5 bytes=$6 tier=$7
    local grace=${8:-30}

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata:
  name: $name
  namespace: $ns
spec:
  priority: $priority
  preemptible: $preemptible
  workloadClass: $wclass
  preemptionGraceSeconds: $grace
  claimTemplate:
    spec:
      requestedVramBytes: $bytes
      serviceTier: $tier
EOF
}

# Apply a VGPUQuota
submit_quota() {
    local name=$1 target_ns=$2 max_bytes=$3
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUQuota
metadata:
  name: $name
spec:
  targetNamespace: $target_ns
  maxVramBytes: $max_bytes
EOF
}

# Aggressive cleanup of a namespace
cleanup_namespace() {
    local ns=$1
    kubectl get vgpujob,vgpuclaim,vgpuslice -n "$ns" -o name 2>/dev/null \
        | xargs -I{} kubectl patch {} -n "$ns" --type=json \
            -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null
    kubectl delete vgpujob,vgpuclaim,vgpuslice -n "$ns" --all --wait=false 2>/dev/null
    sleep 5
    kubectl delete namespace "$ns" --wait=false 2>/dev/null
}

# Cleanup all test resources cluster-wide
global_cleanup() {
    log_info "Cleaning up all test resources..."
    for ns in $(kubectl get ns -o name 2>/dev/null | grep "$NS_PREFIX-" | awk -F/ '{print $2}'); do
        cleanup_namespace "$ns"
    done
    # Quotas are cluster-scoped — strip+delete by prefix
    for q in $(kubectl get vgpuquota -o name 2>/dev/null | grep "$NS_PREFIX-"); do
        kubectl patch "$q" --type=json \
            -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null
        kubectl delete "$q" --wait=false 2>/dev/null
    done
    sleep 10
}

# Run a single test function with isolation
run_test() {
    local test_name=$1
    local test_func=$2
    log_test "$test_name"

    # Per-test namespace
    local ns="${NS_PREFIX}-$(echo "$test_name" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
    ns=$(echo "$ns" | cut -c1-63)
    kubectl create namespace "$ns" 2>/dev/null

    if "$test_func" "$ns"; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
    fi

    cleanup_namespace "$ns"
}

# ============================================================================
# Pre-flight checks
# ============================================================================

preflight() {
    log_section "Pre-flight checks"

    if ! kubectl get pods -n vgpu-system -l control-plane=vgpu-scheduler 2>/dev/null | grep -q Running; then
        log_fail "vgpu-scheduler pod is not Running"
        return 1
    fi
    log_pass "vgpu-scheduler is Running"

    if ! kubectl get pods -n vgpu-system -l control-plane=vgpu-controller 2>/dev/null | grep -q Running; then
        log_fail "vgpu-controller pod is not Running"
        return 1
    fi
    log_pass "vgpu-controller is Running"

    if ! kubectl get crd vgpujobs.infrastructure.pranav2910.com >/dev/null 2>&1; then
        log_fail "VGPUJob CRD not installed"
        return 1
    fi
    log_pass "Required CRDs installed"

    return 0
}

# ============================================================================
# LAYER 1 TESTS
# ============================================================================

# CLAIM: Filter rejects requests larger than node capacity (~80 GiB).
test_filter_rejects_oversized() {
    local ns=$1
    submit_job "$ns" "huge" 100 false Batch $((100 * GIB)) BestEffort

    if wait_for 30 "huge slice should NOT bind" \
        "[[ \$(slice_phase $ns huge-claim-slice) == 'Ready' ]]"; then
        log_info "FAIL: 100 GiB request bound to a node — filter broken"
        return 1
    fi

    # We expect Pending/empty phase forever
    local phase
    phase=$(slice_phase "$ns" huge-claim-slice)
    [[ "$phase" != "Ready" ]] || return 1
    return 0
}

# CLAIM: A normal-sized claim binds successfully.
test_basic_bind() {
    local ns=$1
    submit_job "$ns" "basic" 100 false Batch $SIZE_5G Guaranteed

    if wait_for $TIMEOUT_BIND "basic slice should bind" \
        "[[ \$(slice_phase $ns basic-claim-slice) == 'Ready' ]]"; then
        return 0
    fi
    return 1
}

# CLAIM: Job priority overrides tier-based priority.
test_priority_override() {
    local ns=$1

    # Submit a Guaranteed BestEffort-tier job with priority=900
    # If priority works, this should bind ahead of a separately-submitted
    # Guaranteed-tier job with priority=10.
    # Hard to validate without contention; instead check the priorityFn log.
    local since=$(date +%s)
    submit_job "$ns" "highprio" 800 false Inference $SIZE_5G BestEffort

    sleep 5
    if scheduler_log_contains 30 "$ns/highprio-claim-slice.*priority=800.*overrides tier"; then
        return 0
    fi
    log_info "FAIL: priorityFn log does not show 'overrides tier' for priority=800"
    return 1
}

# CLAIM: Wait-time aging adds priority over time.
test_wait_time_aging() {
    local ns=$1
    submit_job "$ns" "aged" 100 false Batch $SIZE_5G BestEffort
    sleep 5
    submit_job "$ns" "fresh" 100 false Batch $SIZE_5G BestEffort

    # Both should bind regardless. We check the priorityFn log for "aging=" entries.
    sleep 8
    if scheduler_log_contains 30 "aging="; then
        return 0
    fi
    log_info "FAIL: no 'aging=' entries in scheduler logs"
    return 1
}

# ============================================================================
# PHASE 2.1A TESTS — VGPUJob materializes Claim
# ============================================================================

# CLAIM: Submitting a VGPUJob materializes a VGPUClaim with JobRef set.
test_job_creates_claim() {
    local ns=$1
    submit_job "$ns" "j1" 100 false Batch $SIZE_5G BestEffort

    if ! wait_for 15 "claim should exist" \
        "kubectl get vgpuclaim -n $ns j1-claim >/dev/null 2>&1"; then
        return 1
    fi

    local jobref
    jobref=$(kubectl get vgpuclaim -n "$ns" j1-claim -o jsonpath='{.spec.jobRef}')
    if [[ "$jobref" != "j1" ]]; then
        log_info "FAIL: claim's jobRef is '$jobref', expected 'j1'"
        return 1
    fi
    return 0
}

# CLAIM: VGPUJob phase mirrors VGPUClaim phase.
test_job_phase_mirroring() {
    local ns=$1
    submit_job "$ns" "j2" 100 false Batch $SIZE_5G Guaranteed

    if ! wait_for $TIMEOUT_BIND "slice should bind" \
        "[[ \$(slice_phase $ns j2-claim-slice) == 'Ready' ]]"; then
        return 1
    fi

    sleep 3
    local job_phase
    job_phase=$(kubectl get vgpujob -n "$ns" j2 -o jsonpath='{.status.phase}')
    if [[ "$job_phase" != "Scheduled" && "$job_phase" != "Bound" ]]; then
        log_info "FAIL: Job phase is '$job_phase' but slice is Ready"
        return 1
    fi
    return 0
}

# ============================================================================
# PHASE 2.2A TESTS — VGPUQuota
# ============================================================================

# CLAIM: Quota blocks claims that would exceed maxVramBytes.
test_quota_blocks_overage() {
    local ns=$1
    local quota_name="${NS_PREFIX}-quotablock-q"

    submit_quota "$quota_name" "$ns" $SIZE_15G

    submit_job "$ns" "small1" 100 false Batch $SIZE_10G Guaranteed
    if ! wait_for $TIMEOUT_BIND "first 10G should bind" \
        "[[ \$(slice_phase $ns small1-claim-slice) == 'Ready' ]]"; then
        kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
        return 1
    fi

    # 10 + 10 = 20, but quota is 15 → second should be rejected.
    submit_job "$ns" "small2" 100 false Batch $SIZE_10G Guaranteed
    sleep 15

    local phase
    phase=$(slice_phase "$ns" small2-claim-slice)
    if [[ "$phase" == "Ready" ]]; then
        log_info "FAIL: 10+10>15 quota but second slice bound anyway"
        kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
        return 1
    fi

    if ! scheduler_log_contains 60 "QuotaExceeded.*$ns"; then
        log_info "FAIL: no QuotaExceeded log entry for namespace $ns"
        kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
        return 1
    fi

    kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
    return 0
}

# CLAIM: Namespace without quota is unlimited.
test_no_quota_unlimited() {
    local ns=$1
    submit_job "$ns" "unlimited1" 100 false Batch $SIZE_10G Guaranteed
    submit_job "$ns" "unlimited2" 100 false Batch $SIZE_10G Guaranteed

    if ! wait_for $TIMEOUT_BIND "both should bind without quota" \
        "[[ \$(slice_phase $ns unlimited1-claim-slice) == 'Ready' && \$(slice_phase $ns unlimited2-claim-slice) == 'Ready' ]]"; then
        return 1
    fi
    return 0
}

# ============================================================================
# PHASE 2.3 TESTS — Preemption
# ============================================================================

# CLAIM: Higher-priority non-preemptible workload preempts lower-priority
# preemptible victim and binds in the freed slot.
test_preemption_basic() {
    local ns=$1

    # Fill node with 4 uniform 20 GiB preemptible victims (80 GiB total)
    for i in 1 2 3 4; do
        submit_job "$ns" "v$i" 100 true Batch $SIZE_20G BestEffort 5
        sleep 8
    done

    if ! wait_for $TIMEOUT_BIND "all 4 victims should be Ready" \
        "[[ \$(count_slices_by_phase $ns Ready) -eq 4 ]]"; then
        log_info "FAIL: setup failed — only $(count_slices_by_phase "$ns" Ready) victims Ready"
        return 1
    fi

    # Submit requester
    submit_job "$ns" "req" 700 false Inference $SIZE_20G Guaranteed 5

    # Wait for requester to bind
    if ! wait_for $((TIMEOUT_BIND + TIMEOUT_PREEMPT)) "requester should bind via preemption" \
        "[[ \$(slice_phase $ns req-claim-slice) == 'Ready' ]]"; then
        return 1
    fi

    # Smart-selector check: exactly 1 victim should be Released
    local released=$(count_slices_by_phase "$ns" Released)
    local ready_victims
    ready_victims=$(kubectl get vgpuslice -n "$ns" --no-headers 2>/dev/null \
        | grep "^v[1-4]-" | awk '$3 == "Ready"' | wc -l)

    if [[ $released -ne 1 ]]; then
        log_info "FAIL: $released victims Released, expected 1 (over-eviction?)"
        return 1
    fi

    if [[ $ready_victims -ne 3 ]]; then
        log_info "FAIL: $ready_victims survivors, expected 3"
        return 1
    fi

    # Check the PLAN log
    if ! scheduler_log_contains 120 "preemptor.*PLAN.*victims=1"; then
        log_info "FAIL: no '[preemptor] PLAN ... victims=1' log entry"
        return 1
    fi

    return 0
}

# CLAIM: Priority gap less than 100 cannot trigger preemption.
test_priority_gap_blocks_preemption() {
    local ns=$1

    # Fill node with 4 priority-100 preemptible victims
    for i in 1 2 3 4; do
        submit_job "$ns" "v$i" 100 true Batch $SIZE_20G BestEffort 5
        sleep 8
    done

    if ! wait_for $TIMEOUT_BIND "all 4 victims should be Ready" \
        "[[ \$(count_slices_by_phase $ns Ready) -eq 4 ]]"; then
        return 1
    fi

    # Submit a requester with priority=150 (gap of 50 to victims, BELOW the 100 threshold)
    submit_job "$ns" "subgap" 150 false Inference $SIZE_20G Guaranteed 5

    sleep 30
    local phase
    phase=$(slice_phase "$ns" subgap-claim-slice)
    if [[ "$phase" == "Ready" ]]; then
        log_info "FAIL: subgap requester bound — preemption fired despite gap < 100"
        return 1
    fi

    if ! scheduler_log_contains 60 "no eligible victims.*subgap-claim-slice"; then
        log_info "FAIL: no 'no eligible victims' log entry for sub-gap requester"
        return 1
    fi
    return 0
}

# CLAIM: Non-preemptible victims are not preempted.
test_non_preemptible_protected() {
    local ns=$1

    # Fill with 3 non-preemptible victims at priority 100
    for i in 1 2 3; do
        submit_job "$ns" "np$i" 100 false Batch $SIZE_20G BestEffort
        sleep 8
    done

    if ! wait_for $TIMEOUT_BIND "3 victims Ready" \
        "[[ \$(count_slices_by_phase $ns Ready) -eq 3 ]]"; then
        return 1
    fi

    # High priority requester
    submit_job "$ns" "highp" 900 false Inference $SIZE_20G Guaranteed
    sleep 25

    local phase
    phase=$(slice_phase "$ns" highp-claim-slice)
    if [[ "$phase" == "Ready" ]]; then
        log_info "FAIL: high-priority bound (would have required preempting non-preemptible)"
        return 1
    fi

    local released=$(count_slices_by_phase "$ns" Released)
    if [[ $released -gt 0 ]]; then
        log_info "FAIL: $released victims Released — non-preemptible should be protected"
        return 1
    fi
    return 0
}

# CLAIM: Quota check fires BEFORE preemption (quota-blocked job doesn't evict).
test_quota_blocks_before_preemption() {
    local ns=$1
    local quota_name="${NS_PREFIX}-prequota-q"

    # Quota = 15 GiB. Total need 35GiB will violate.
    submit_quota "$quota_name" "$ns" $SIZE_15G

    # Pre-fill node with preemptible victims in a DIFFERENT namespace.
    local victim_ns="${ns}-victims"
    kubectl create namespace "$victim_ns" 2>/dev/null
    for i in 1 2; do
        submit_job "$victim_ns" "vv$i" 100 true Batch $SIZE_20G BestEffort 5
        sleep 8
    done

    wait_for 30 "victims Ready" \
        "[[ \$(count_slices_by_phase $victim_ns Ready) -ge 1 ]]"

    # Submit a 35 GiB high-priority job in quota-restricted namespace
    submit_job "$ns" "blocked" 900 false Inference $SIZE_35G Guaranteed
    sleep 25

    # blocked should NOT be Ready (quota-blocked)
    local phase
    phase=$(slice_phase "$ns" blocked-claim-slice)
    if [[ "$phase" == "Ready" ]]; then
        log_info "FAIL: 35GiB job bound in 15GiB quota namespace"
        cleanup_namespace "$victim_ns"
        kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
        return 1
    fi

    # No victims should have been preempted (cross-ns preemption forbidden)
    local victim_released=$(count_slices_by_phase "$victim_ns" Released)
    if [[ $victim_released -gt 0 ]]; then
        log_info "FAIL: $victim_released victims preempted across namespace boundary"
        cleanup_namespace "$victim_ns"
        kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
        return 1
    fi

    if ! scheduler_log_contains 60 "QuotaExceeded.*$ns"; then
        log_info "FAIL: no QuotaExceeded log for $ns"
        cleanup_namespace "$victim_ns"
        kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
        return 1
    fi

    cleanup_namespace "$victim_ns"
    kubectl delete vgpuquota "$quota_name" --wait=false 2>/dev/null
    return 0
}

# CLAIM: Preempting phase is observable with HigherPriorityWorkload condition.
test_preempting_phase_observable() {
    local ns=$1

    # Fill with one preemptible victim (long grace so we can observe Preempting phase)
    submit_job "$ns" "obs-vic" 100 true Batch $SIZE_70G BestEffort 30

    if ! wait_for $TIMEOUT_BIND "victim Ready" \
        "[[ \$(slice_phase $ns obs-vic-claim-slice) == 'Ready' ]]"; then
        return 1
    fi

    # Trigger preemption with a high-prio requester
    submit_job "$ns" "obs-req" 900 false Inference $SIZE_70G Guaranteed 30

    # Within 10s, victim should be in Preempting phase
    if ! wait_for 15 "victim should be Preempting" \
        "[[ \$(slice_phase $ns obs-vic-claim-slice) == 'Preempting' ]]"; then
        log_info "FAIL: victim never entered Preempting phase"
        return 1
    fi

    # Check the condition
    local condition_type
    condition_type=$(kubectl get vgpuslice -n "$ns" obs-vic-claim-slice \
        -o jsonpath='{.status.conditions[?(@.type=="Preempting")].reason}' 2>/dev/null)
    if [[ "$condition_type" != "HigherPriorityWorkload" ]]; then
        log_info "FAIL: Preempting condition reason is '$condition_type', expected 'HigherPriorityWorkload'"
        return 1
    fi

    return 0
}

# ============================================================================
# LAYER 1 RECOVERY TEST — orphan claim cascade
# ============================================================================

# CLAIM: Deleting a VGPUJob cascades to delete the Claim and Slice cleanly,
# leaving no orphan resources.
test_cascade_delete() {
    local ns=$1
    submit_job "$ns" "cascade" 100 false Batch $SIZE_5G Guaranteed

    if ! wait_for $TIMEOUT_BIND "slice should bind" \
        "[[ \$(slice_phase $ns cascade-claim-slice) == 'Ready' ]]"; then
        return 1
    fi

    kubectl delete vgpujob -n "$ns" cascade --wait=false >/dev/null 2>&1

    # Wait for cascade to finish
    if ! wait_for $TIMEOUT_DELETE "all 3 resources should be gone" \
        "! kubectl get vgpujob -n $ns cascade >/dev/null 2>&1 && \
         ! kubectl get vgpuclaim -n $ns cascade-claim >/dev/null 2>&1 && \
         ! kubectl get vgpuslice -n $ns cascade-claim-slice >/dev/null 2>&1"; then
        log_info "FAIL: orphan resources still present after cascade"
        kubectl get vgpujob,vgpuclaim,vgpuslice -n "$ns" 2>&1 | head -10
        return 1
    fi
    return 0
}

# ============================================================================
# Test runner
# ============================================================================

# Test catalog: <name> <function> <suite>
declare -a ALL_TESTS=(
    "filter rejects oversized request|test_filter_rejects_oversized|layer1"
    "basic claim binds successfully|test_basic_bind|layer1"
    "job priority overrides tier|test_priority_override|layer1"
    "wait-time aging logged|test_wait_time_aging|layer1"

    "VGPUJob materializes claim|test_job_creates_claim|phase21a"
    "Job phase mirrors claim phase|test_job_phase_mirroring|phase21a"

    "Quota blocks overage|test_quota_blocks_overage|phase22a"
    "No quota means unlimited|test_no_quota_unlimited|phase22a"

    "Basic preemption with smart selector|test_preemption_basic|phase23"
    "Priority gap < 100 blocks preemption|test_priority_gap_blocks_preemption|phase23"
    "Non-preemptible victims are protected|test_non_preemptible_protected|phase23"
    "Quota wins over preemption|test_quota_blocks_before_preemption|phase23"
    "Preempting phase is observable|test_preempting_phase_observable|phase23"

    "Job deletion cascades cleanly|test_cascade_delete|recovery"
)

QUICK_SET=(
    "test_basic_bind"
    "test_job_creates_claim"
    "test_quota_blocks_overage"
    "test_preemption_basic"
    "test_cascade_delete"
)

usage() {
    cat <<EOF
Usage: $0 [suite]

Suites:
  all       Run all tests (default)
  layer1    Run only Layer 1 tests
  phase21a  Run only Phase 2.1a tests
  phase22a  Run only Phase 2.2a tests
  phase23   Run only Phase 2.3 (preemption) tests
  recovery  Run only recovery / cascade-delete tests
  quick     Run a 5-test smoke suite

Examples:
  $0
  $0 phase23
  $0 quick
EOF
}

main() {
    local suite="${1:-all}"

    case "$suite" in
        -h|--help) usage; exit 0 ;;
    esac

    log_section "vGPU Scheduler Integration Test Suite"
    echo "  Suite: $suite"
    echo "  Cluster: $(kubectl config current-context)"
    echo ""

    if ! preflight; then
        echo ""
        log_fail "Pre-flight checks failed — aborting"
        exit 1
    fi

    log_section "Initial cleanup"
    global_cleanup

    log_section "Running tests"

    for entry in "${ALL_TESTS[@]}"; do
        IFS='|' read -r name func test_suite <<<"$entry"

        if [[ "$suite" == "quick" ]]; then
            local in_quick=false
            for q in "${QUICK_SET[@]}"; do
                if [[ "$q" == "$func" ]]; then in_quick=true; break; fi
            done
            $in_quick || continue
        elif [[ "$suite" != "all" && "$suite" != "$test_suite" ]]; then
            continue
        fi

        run_test "$name" "$func"
    done

    log_section "Final cleanup"
    global_cleanup

    log_section "RESULTS"
    echo "  Passed:  $PASS_COUNT"
    echo "  Failed:  $FAIL_COUNT"
    echo "  Skipped: $SKIP_COUNT"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for t in "${FAILED_TESTS[@]}"; do
            echo "  - $t"
        done
        exit 1
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✓ All selected tests passed${RESET}"
    exit 0
}

main "$@"
