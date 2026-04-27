#!/usr/bin/env bash
# ============================================================================
# REAL-WORLD STRESS TEST — Multi-tenant chaos
#
# This test simulates a busy GPU cluster:
#   - 2 namespaces: team-research (no quota), team-prod (32 GiB quota)
#   - Pre-fill node with 4 preemptible low-priority slices (75 GiB total)
#   - Submit 3 jobs simultaneously with varying priorities and tenancies
#
# Tests interaction between:
#   - Priority queue (higher priority dequeues first)
#   - Quota enforcement (rejected before preemption, not after)
#   - Preemption (with priority gap rule)
#   - Cross-namespace isolation
#   - Cooldown after preemption
# ============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || cd ~/vgpu-scheduler

echo "═════════════════════════════════════════════════════════════════"
echo "║  REAL-WORLD STRESS TEST — Multi-tenant chaos"
echo "═════════════════════════════════════════════════════════════════"

# ============================================================================
# Phase 0: Hard cleanup — strip all finalizers, delete everything
# ============================================================================
echo ""
echo "▶ Phase 0: Cleaning cluster state..."

kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1
kubectl get vgpuquota -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1
kubectl delete vgpujob -A --all --wait=false 2>/dev/null
kubectl delete vgpuclaim -A --all --wait=false 2>/dev/null
kubectl delete vgpuslice -A --all --wait=false 2>/dev/null
kubectl delete vgpuquota --all --wait=false 2>/dev/null

sleep 25

# Final force-strip pass for stragglers
kubectl get vgpujob -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1
kubectl get vgpuclaim -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1
kubectl get vgpuslice -A -o name 2>/dev/null | xargs -I{} kubectl patch {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' >/dev/null 2>&1

sleep 10

REMAINING=$(kubectl get vgpujob -A --no-headers 2>/dev/null | wc -l)
REMAINING=$((REMAINING + $(kubectl get vgpuclaim -A --no-headers 2>/dev/null | wc -l)))
REMAINING=$((REMAINING + $(kubectl get vgpuslice -A --no-headers 2>/dev/null | wc -l)))
if [[ $REMAINING -gt 0 ]]; then
    echo "  ⚠ Cluster not fully clean ($REMAINING resources left). Continuing anyway."
    kubectl get vgpujob,vgpuclaim,vgpuslice -A
else
    echo "  ✓ Cluster clean"
fi

# ============================================================================
# Phase 1: Create namespaces + quota
# ============================================================================
echo ""
echo "▶ Phase 1: Setting up namespaces and quota..."

kubectl create namespace team-research 2>/dev/null || true
kubectl create namespace team-prod 2>/dev/null || true

# Apply 32 GiB quota for team-prod
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUQuota
metadata: { name: team-prod-quota }
spec:
  targetNamespace: team-prod
  maxVramBytes: 34359738368
  description: "Production team — 32 GiB cap"
EOF

echo "  ✓ team-research (no quota)"
echo "  ✓ team-prod (32 GiB quota)"

# ============================================================================
# Phase 2: Pre-fill node with 4 preemptible low-priority slices in team-research
# ============================================================================
echo ""
echo "▶ Phase 2: Pre-filling node with 4 preemptible victims (75 GiB total)..."

# Three 20 GiB victims
for i in 1 2 3; do
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: victim-$i, namespace: team-research }
spec:
  priority: 100
  preemptible: true
  workloadClass: Batch
  preemptionGraceSeconds: 5
  claimTemplate:
    spec: { requestedVramBytes: 21474836480, serviceTier: BestEffort }
EOF
sleep 8
done

# One 15 GiB victim
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: victim-4, namespace: team-research }
spec:
  priority: 100
  preemptible: true
  workloadClass: Batch
  preemptionGraceSeconds: 5
  claimTemplate:
    spec: { requestedVramBytes: 16106127360, serviceTier: BestEffort }
EOF

echo "  Waiting 25s for all victims to bind..."
sleep 25

echo ""
echo "▶ Phase 2 verification — all 4 victims should be Ready:"
kubectl get vgpuslice -n team-research -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,ALLOC:.status.allocatedBytes' 2>/dev/null

READY_COUNT=$(kubectl get vgpuslice -n team-research --no-headers 2>/dev/null | grep -c "Ready" || true)
if [[ $READY_COUNT -lt 3 ]]; then
    echo ""
    echo "  ⚠ Only $READY_COUNT victims Ready. Test may not stress-test correctly."
    echo "  Continuing anyway to see what the system does."
fi

# ============================================================================
# Phase 3: Submit 3 contending jobs SIMULTANEOUSLY
# ============================================================================
echo ""
echo "▶ Phase 3: Submitting 3 contending jobs simultaneously..."
echo "  - prod-critical:    900 priority, 35 GiB, team-prod (over quota — should be REJECTED)"
echo "  - research-large:   700 priority, 20 GiB, team-research (should preempt 1 victim)"
echo "  - research-small:    50 priority,  5 GiB, team-research (gap=50 — cannot preempt anyone)"

T0=$(date +%s)
echo "  T0: $T0"

# Submit all three with no sleep between — true concurrent contention
{
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: prod-critical, namespace: team-prod }
spec:
  priority: 900
  preemptible: false
  workloadClass: Inference
  claimTemplate:
    spec: { requestedVramBytes: 37580963840, serviceTier: Guaranteed }
EOF
} &

{
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: research-large, namespace: team-research }
spec:
  priority: 700
  preemptible: false
  workloadClass: Training
  claimTemplate:
    spec: { requestedVramBytes: 21474836480, serviceTier: Guaranteed }
EOF
} &

{
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: infrastructure.pranav2910.com/v1alpha1
kind: VGPUJob
metadata: { name: research-small, namespace: team-research }
spec:
  priority: 50
  preemptible: true
  workloadClass: Interactive
  claimTemplate:
    spec: { requestedVramBytes: 5368709120, serviceTier: BestEffort }
EOF
} &

wait

echo "  ✓ All 3 submitted concurrently"

# ============================================================================
# Phase 4: Watch the chaos unfold
# ============================================================================
echo ""
echo "▶ Phase 4: Watching for 35 seconds..."
for i in 1 2 3 4 5 6 7; do
    sleep 5
    echo ""
    echo "─── t+${i}*5s ───"
    echo "team-research slices:"
    kubectl get vgpuslice -n team-research -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' --no-headers 2>/dev/null | sort
    echo ""
    echo "team-prod slices:"
    kubectl get vgpuslice -n team-prod -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' --no-headers 2>/dev/null | sort
done

# ============================================================================
# Phase 5: Final state + analysis
# ============================================================================
echo ""
echo "═════════════════════════════════════════════════════════════════"
echo "║  FINAL STATE"
echo "═════════════════════════════════════════════════════════════════"

echo ""
echo "▶ Jobs across all namespaces:"
kubectl get vgpujob -A

echo ""
echo "▶ Slices across all namespaces:"
kubectl get vgpuslice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,ALLOC:.status.allocatedBytes' 2>/dev/null

echo ""
echo "▶ Quota status:"
kubectl get vgpuquotas

# ============================================================================
# Phase 6: Logs analysis
# ============================================================================
echo ""
echo "═════════════════════════════════════════════════════════════════"
echo "║  LOGS ANALYSIS"
echo "═════════════════════════════════════════════════════════════════"

echo ""
echo "▶ Quota rejections (looking for prod-critical being blocked):"
kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=300 2>/dev/null | \
    grep -E "QuotaExceeded|Scheduling rejected.*quota" | tail -5

echo ""
echo "▶ Preemption decisions (looking for [preemptor] PLAN lines):"
kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=300 2>/dev/null | \
    grep -E "preemptor.*PLAN|preemptor.*no eligible|preemptor.*insufficient" | tail -10

echo ""
echo "▶ Priority resolution for all 3 contenders:"
kubectl logs -n vgpu-system deploy/vgpu-scheduler --tail=300 2>/dev/null | \
    grep -E "prod-critical|research-large|research-small" | \
    grep -E "priorityFn|preemptor|Scheduling cycle|bound to|rejected" | tail -25

echo ""
echo "▶ Preempting handler logs:"
kubectl logs -n vgpu-system deploy/vgpu-controller --tail=300 2>/dev/null | \
    grep "preempting" | tail -15

echo ""
echo "═════════════════════════════════════════════════════════════════"
echo "║  EXPECTED OUTCOMES"
echo "═════════════════════════════════════════════════════════════════"
cat <<'EXPECTED'
  prod-critical (priority 900, 35 GiB, team-prod):
    EXPECTED: Pending forever — 35 GiB > 32 GiB quota. Quota check rejects
              BEFORE preemption is attempted. Slice stays Pending.

  research-large (priority 700, 20 GiB, team-research):
    EXPECTED: Bound — preempts 1 victim (20 GiB), binds within seconds.
              Logs should show [preemptor] PLAN with 1 victim freed.

  research-small (priority 50, 5 GiB, team-research):
    EXPECTED: Bound — there should be enough space after research-large
              triggers preemption. OR Pending if all space taken. Cannot
              preempt anyone (priority gap to victims is 50 < 100).

  Cross-namespace property:
    EXPECTED: prod-critical does NOT preempt team-research victims, even
              though they're eligible at gap=800. Preemption is intra-namespace.
EXPECTED

echo ""
echo "Done. Inspect output above. Did the system behave as predicted?"
