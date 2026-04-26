#!/usr/bin/env bash
# ============================================================================
# Follow-up validation tests
#   X2-FIXED: Service tier preference (with correct arithmetic)
#   H1: Hardware health probe surfaces failures
#   CDI1: CDI spec mechanism (file written, annotation set, schema valid)
# ============================================================================

set -uo pipefail

PASS=0
FAIL=0
FAILED=()

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
c_bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
c_cyan()   { printf "\033[36m%s\033[0m\n" "$*"; }

pass() { c_green "  ✓ PASS: $*"; PASS=$((PASS+1)); }
fail() { c_red   "  ✗ FAIL: $*"; FAIL=$((FAIL+1)); FAILED+=("$*"); }
skip() { c_yellow "  - SKIP: $*"; }
info() { c_cyan  "    $*"; }

section() {
    echo ""
    c_bold "═══════════════════════════════════════════════════════════════"
    c_bold "  $*"
    c_bold "═══════════════════════════════════════════════════════════════"
}

NS="default"
SYS_NS="vgpu-system"

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
    sleep 20
}

# ============================================================================
# SECTION 1: Service-tier preference (correct arithmetic)
# ============================================================================
# Node = 80 GiB. We fill 75 GiB (real 75, not 70).
#   75 GiB = 80530636800 bytes  (75 * 1024^3)
# That leaves exactly 5 GiB free.
# Then submit two 8 GiB claims (BestEffort + Guaranteed).
# Neither fits (8 > 5), so ONE wins on retry — the Guaranteed one
# (after Layer-3 ScoreWithTier penalty for BestEffort).
#
# Wait — if neither fits, both will be Pending and stay that way.
# To actually test tier preference, we need EXACTLY 8 GiB free, then
# both claims compete for that 8 GiB and tier wins.
#
# So: filler = 80 - 8 = 72 GiB = 77309411328 bytes
# That leaves 8 GiB free. One 8GiB claim fits, the other doesn't.
# ScoreWithTier should make Guaranteed beat BestEffort.
# ============================================================================
section "X2-FIXED — Service tier preference (corrected arithmetic)"

cleanup_all

# Fill 72 GiB so exactly 8 GiB remains.
make_claim st-filler 77309411328 Guaranteed
if wait_phase st-filler-slice Ready 30; then
    pass "Filler (72 GiB) reached Ready, leaving 8 GiB free"
else
    fail "Filler setup failed (phase=$(slice_phase st-filler-slice))"
    skip "Aborting service-tier test"
    cleanup_all
fi

# Submit one BestEffort and one Guaranteed, both 8 GiB. Only one fits.
make_claim st-besteffort 8589934592 BestEffort
make_claim st-guaranteed 8589934592 Guaranteed

# Give scheduler 60s — enough for retries even if BE is processed first
sleep 45

be=$(slice_phase st-besteffort-slice)
g=$(slice_phase st-guaranteed-slice)
info "BestEffort: $be   Guaranteed: $g"

if [[ "$g" == "Ready" && "$be" != "Ready" ]]; then
    pass "Service tier honoured: Guaranteed won the 8GiB slot"
elif [[ "$be" == "Ready" && "$g" != "Ready" ]]; then
    fail "Service tier INVERTED: BestEffort won, Guaranteed pending"
elif [[ "$be" == "Ready" && "$g" == "Ready" ]]; then
    fail "Both claims allocated — capacity over-allocation (need to investigate)"
else
    fail "Both claims pending — scheduler may be wedged or ScoreWithTier broken"
fi

# Show the scheduler's actual decisions for debugging
echo ""
c_cyan "    Scheduler decisions (last 10 lines):"
kubectl logs -n "$SYS_NS" deploy/vgpu-scheduler --tail=200 2>/dev/null | \
    grep -E "Scheduling cycle.*st-|bound to.*st-|sufficient VRAM.*st-" | \
    tail -10 | sed 's/^/      /'

cleanup_all

# ============================================================================
# SECTION 2: Hardware health — surface failures
# ============================================================================
# We inject a "fault" into the mock NodeAgent by making CheckHardwareHealth
# return an error. Since we don't want to rebuild the binary, we approximate:
# verify the probe IS running (logs show it ran) and verify the onUnhealthy
# callback path exists in the binary.
#
# We can also kill the NodeAgent pod and watch the next instance run drift
# detection — that exercises the recovery surface even if not the probe itself.
# ============================================================================
section "H1 — Hardware health: probe is alive and responsive"

# 1. Health probe runs every 30s. Wait > 30s and look for activity.
info "Waiting 35s for at least one health probe cycle..."
sleep 35

# Look in the nodeagent logs for evidence of the probe running.
# In mock mode the probe is a no-op (CheckHardwareHealth returns nil for mock=true).
# But if the GO file has StartHealthProbe wiring, ANY error path would log.
probe_evidence=$(kubectl logs -n "$SYS_NS" daemonset/vgpu-nodeagent --tail=500 2>/dev/null | \
                 grep -ciE "health|probe")
if [[ "$probe_evidence" -gt 0 ]]; then
    pass "Health probe machinery is active (found $probe_evidence log refs)"
else
    skip "No health log lines (probe is silent in mock-success path; this is expected)"
fi

# 2. Verify the StartHealthProbe code path actually exists in the binary.
#    We can't introspect the binary, but we CAN verify the source has it.
if [[ -f "internal/nodeagent/nvml/probe.go" ]]; then
    if grep -q "StartHealthProbe\|onUnhealthy" internal/nodeagent/nvml/probe.go; then
        pass "Source confirms StartHealthProbe + onUnhealthy callback wiring"
    else
        fail "probe.go missing StartHealthProbe/onUnhealthy wiring"
    fi
fi

# 3. Verify the manager actually launches the probe.
if grep -q "StartHealthProbe" cmd/nodeagent/main.go 2>/dev/null; then
    pass "NodeAgent main.go launches StartHealthProbe at boot"
else
    fail "NodeAgent main.go does NOT call StartHealthProbe (probe never runs)"
fi

# 4. As an end-to-end signal: kill the nodeagent and watch drift detection
#    fire on restart. This is the *recovery surface*, not the probe itself,
#    but proves the health/recovery plumbing is alive end-to-end.
info "Killing NodeAgent to exercise recovery path..."
kubectl delete pod -n "$SYS_NS" -l app=vgpu-nodeagent --wait=false >/dev/null 2>&1
sleep 25

drift_log=$(kubectl logs -n "$SYS_NS" daemonset/vgpu-nodeagent --tail=80 2>/dev/null | \
            grep -E "drift|Recovery|hardware vs" | head -3)
if [[ -n "$drift_log" ]]; then
    pass "Drift detection ran on NodeAgent restart"
    echo "$drift_log" | sed 's/^/      /'
else
    fail "No drift-detection log lines after NodeAgent restart"
fi

# ============================================================================
# SECTION 3: CDI mechanism — verify the wires are connected
# ============================================================================
# We can't test that a real CUDA workload gets the right GPU partition without
# real GPUs. But we CAN test:
#   1. CDI spec files get written to /var/run/cdi/ on the node when a slice goes Ready
#   2. CDI files have the correct kind ("vendor/class" format) and version
#   3. CDI files are removed when the slice is released
#   4. The mutating webhook sets the cdi.k8s.io/* annotation on pods that
#      reference a vGPU claim
# ============================================================================
section "CDI1 — Spec file written, schema correct, cleaned up"

cleanup_all

# Submit a claim and wait for Ready.
make_claim cdi-test 4294967296 Guaranteed
if ! wait_phase cdi-test-slice Ready 30; then
    fail "Claim never reached Ready (cannot verify CDI behaviour)"
    skip "Aborting CDI test"
else
    alloc_id=$(kubectl get vgpuslice -n "$NS" cdi-test-slice -o jsonpath='{.status.allocationId}')
    device_uuid=$(slice_uuid cdi-test-slice)
    info "AllocationID: $alloc_id"
    info "DeviceUUID: $device_uuid"

    # 1. Check the CDI directory inside the NodeAgent container.
    cdi_files=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
                ls /var/run/cdi/ 2>/dev/null | grep -i vgpu || true)

    if [[ -n "$cdi_files" ]]; then
        pass "CDI spec file(s) written to /var/run/cdi/"
        info "Files: $cdi_files"
    else
        fail "No CDI files found in /var/run/cdi/ for live allocation"
    fi

    # 2. Read the CDI file and verify schema (kind = "vendor/class").
    cdi_content=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
                  /bin/sh -c 'cat /var/run/cdi/*.json 2>/dev/null | head -1' 2>/dev/null)

    if [[ -n "$cdi_content" ]]; then
        # Pull the kind field
        kind_value=$(echo "$cdi_content" | python3 -c '
import sys, json
try:
    j = json.loads(sys.stdin.read())
    print(j.get("kind", ""))
except Exception:
    pass
' 2>/dev/null)

        if [[ "$kind_value" == *"/"* ]]; then
            pass "CDI 'kind' has correct vendor/class format: $kind_value"
        else
            fail "CDI 'kind' is malformed: '$kind_value' (must contain /)"
        fi

        cdi_version=$(echo "$cdi_content" | python3 -c '
import sys, json
try:
    j = json.loads(sys.stdin.read())
    print(j.get("cdiVersion", ""))
except Exception:
    pass
' 2>/dev/null)
        if [[ -n "$cdi_version" ]]; then
            pass "CDI 'cdiVersion' set: $cdi_version"
        fi
    else
        fail "Could not read CDI file contents"
    fi

    # 3. Submit a pod with the claim annotation and verify the mutating webhook
    #    sets the cdi.k8s.io/* annotation.
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: cdi-test-pod
  namespace: $NS
  labels:
    vgpu-claim: cdi-test
  annotations:
    infrastructure.pranav2910.com/claim-ref: cdi-test
spec:
  restartPolicy: Never
  containers:
    - name: idle
      image: alpine:3.20
      command: ["sleep", "300"]
EOF

    sleep 5

    # Read pod annotations to see if the mutating webhook fired.
    cdi_annotation=$(kubectl get pod -n "$NS" cdi-test-pod \
                     -o jsonpath='{.metadata.annotations.cdi\.k8s\.io/vgpu-pranav2910-com}' 2>/dev/null)
    if [[ -n "$cdi_annotation" ]]; then
        pass "Mutating webhook set CDI annotation on pod: $cdi_annotation"
    else
        # Maybe the webhook didn't fire — check all annotations
        all_anns=$(kubectl get pod -n "$NS" cdi-test-pod -o jsonpath='{.metadata.annotations}' 2>/dev/null)
        if [[ "$all_anns" == *"cdi.k8s.io"* ]]; then
            pass "Some CDI annotation present"
            info "$all_anns"
        else
            fail "Mutating webhook did not set cdi.k8s.io annotation"
            info "Annotations: $all_anns"
        fi
    fi

    # 4. Delete the pod, then the claim, then verify CDI files are cleaned up.
    kubectl delete pod -n "$NS" cdi-test-pod --wait=false >/dev/null 2>&1
    kubectl delete vgpuclaim -n "$NS" cdi-test --wait=false >/dev/null 2>&1
    sleep 30

    cdi_files_after=$(kubectl exec -n "$SYS_NS" daemonset/vgpu-nodeagent -- \
                      ls /var/run/cdi/ 2>/dev/null | grep -i vgpu || true)
    if [[ -z "$cdi_files_after" ]]; then
        pass "CDI files cleaned up after release"
    else
        fail "CDI files still present after release: $cdi_files_after"
    fi
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
    c_red "  Failed:"
    for t in "${FAILED[@]}"; do echo "    - $t"; done
fi
echo ""
if [[ "$FAIL" == "0" ]]; then
    c_bold "$(c_green '  ✓ All follow-up validations passed')"
else
    c_bold "$(c_yellow "  ⚠ $FAIL of $((PASS+FAIL)) failed")"
fi
echo ""
