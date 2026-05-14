#!/usr/bin/env bash
# ============================================================================
# fix_preempt_bugs.sh
#
# Applies three preemptor.go bug fixes flagged in the senior-engineer review:
#
#   Bug 1: markVictimsPreempting could leave N-1 victims stranded in
#          Preempting phase if the Nth update failed. Patch adds a tracked
#          list of marked victims and a rollbackPreemptingMarks helper that
#          reverts them to Ready on partial failure.
#
#   Bug 2: Preemptor.cooldown map grew unbounded. CleanupCooldown existed
#          but had no caller. Patch makes NewPreemptor spawn a 1-minute
#          background reaper that calls it.
#
#   Bug 3: PreemptionInFlightWindow was a hardcoded 60s but
#          PreemptionGraceSeconds allows up to 3600s. A long-grace config
#          could let a second preemption wave fire while the first wave's
#          victims were still draining. Patch adds MaxGraceSeconds and a
#          new effectiveInFlightWindow(ctx, requester) that computes the
#          window dynamically: max(60s, longest grace in namespace + 30s).
#
# Idempotent: re-running after success is a no-op.
# Backs up the original to internal/scheduler/preemptor.go.bak.<timestamp>.
# Verifies with `go vet` and `go build` before exiting.
#
# Usage: run from the repo root.
#   bash fix_preempt_bugs.sh
# ============================================================================

set -euo pipefail

FILE="internal/scheduler/preemptor.go"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [[ ! -f "$FILE" ]]; then
    echo "ERROR: $FILE not found. Run this from the repo root." >&2
    exit 1
fi

if grep -q "MaxGraceSeconds = int32(3600)" "$FILE"; then
    echo "✓ Patches already applied (MaxGraceSeconds is present). Nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
BACKUP="${FILE}.bak.$(date +%s)"
cp "$FILE" "$BACKUP"
echo "Backed up original to: $BACKUP"
echo

# ---------------------------------------------------------------------------
# Apply patches via Python (sed is brittle for multi-line content).
# Each replacement asserts its anchor is present exactly once before
# touching the file — if any anchor is missing or duplicated, we abort
# and the original file is unchanged because we write atomically at the end.
# ---------------------------------------------------------------------------
python3 - "$FILE" <<'PYEOF'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()
original_len = len(src)

# ---------------------------------------------------------------------------
# Patch A — add MaxGraceSeconds constant and update the InFlightWindow comment
# ---------------------------------------------------------------------------
old_a = (
    "\tDefaultGraceSeconds   = int32(30)\n"
    "\n"
    "\t// PreemptionInFlightWindow is how long after a plan was created we\n"
    "\t// suppress new preemption attempts for the same requester. Set to\n"
    "\t// MaxGraceSeconds + buffer; any preemption with a longer custom grace\n"
    "\t// will still be correctly blocked because original victims remain in\n"
    "\t// Preempting phase (not Ready) until they drain.\n"
    "\tPreemptionInFlightWindow = 60 * time.Second"
)
new_a = (
    "\tDefaultGraceSeconds   = int32(30)\n"
    "\t// MaxGraceSeconds bounds the in-flight window so a misconfigured\n"
    "\t// VGPUJob can't lock out preemption for unbounded time.\n"
    "\tMaxGraceSeconds = int32(3600)\n"
    "\n"
    "\t// PreemptionInFlightWindow is the *floor* on the dedup gate — short\n"
    "\t// preemptions still get at least this much protection. The gate also\n"
    "\t// considers the requester's actual grace setting (see\n"
    "\t// effectiveInFlightWindow) so long-grace configs can't stack a\n"
    "\t// second wave before victims have drained.\n"
    "\tPreemptionInFlightWindow = 60 * time.Second"
)
assert src.count(old_a) == 1, "Patch A: anchor not found exactly once (file shape changed?)"
src = src.replace(old_a, new_a)

# ---------------------------------------------------------------------------
# Patch B — NewPreemptor spawns periodic cooldown reaper
# ---------------------------------------------------------------------------
old_b = (
    "// NewPreemptor constructs a Preemptor.\n"
    "func NewPreemptor(c client.Client) *Preemptor {\n"
    "\treturn &Preemptor{\n"
    "\t\tclient:   c,\n"
    "\t\tcooldown: make(map[string]time.Time),\n"
    "\t}\n"
    "}"
)
new_b = (
    "// NewPreemptor constructs a Preemptor.\n"
    "func NewPreemptor(c client.Client) *Preemptor {\n"
    "\tp := &Preemptor{\n"
    "\t\tclient:   c,\n"
    "\t\tcooldown: make(map[string]time.Time),\n"
    "\t}\n"
    "\t// Background reaper for stale cooldown entries. The map would\n"
    "\t// otherwise grow unbounded over the scheduler's lifetime — every\n"
    "\t// preempt pass adds entries and nothing was clearing them.\n"
    "\t// Lives for the process; clean shutdown is a v0.2 concern.\n"
    "\tgo func() {\n"
    "\t\tticker := time.NewTicker(time.Minute)\n"
    "\t\tdefer ticker.Stop()\n"
    "\t\tfor range ticker.C {\n"
    "\t\t\tp.CleanupCooldown()\n"
    "\t\t}\n"
    "\t}()\n"
    "\treturn p\n"
    "}"
)
assert src.count(old_b) == 1, "Patch B: anchor not found exactly once"
src = src.replace(old_b, new_b)

# ---------------------------------------------------------------------------
# Patch C — claimPlanOwnership uses dynamic in-flight window
# ---------------------------------------------------------------------------
old_c = "\t\t\t\tif time.Since(t) < PreemptionInFlightWindow {"
new_c = "\t\t\t\tif time.Since(t) < p.effectiveInFlightWindow(ctx, requester) {"
assert src.count(old_c) == 1, "Patch C: anchor not found exactly once"
src = src.replace(old_c, new_c)

# ---------------------------------------------------------------------------
# Patch D — markVictimsPreempting tracks marked victims, rolls back on failure
# ---------------------------------------------------------------------------
old_d = (
    "func (p *Preemptor) markVictimsPreempting(ctx context.Context, plan *PreemptionPlan) error {\n"
    "\tfor i := range plan.Victims {\n"
    "\t\tv := &plan.Victims[i]\n"
    "\t\tkey := client.ObjectKey{Namespace: v.Slice.Namespace, Name: v.Slice.Name}\n"
    "\n"
    "\t\terr := retry.RetryOnConflict(retry.DefaultRetry, func() error {\n"
    "\t\t\tvar fresh vgpuv1alpha1.VGPUSlice\n"
    "\t\t\tif err := p.client.Get(ctx, key, &fresh); err != nil {\n"
    "\t\t\t\treturn err\n"
    "\t\t\t}\n"
    "\t\t\tif fresh.Status.Phase != \"Ready\" {\n"
    "\t\t\t\treturn nil // someone else moved it; abort silently\n"
    "\t\t\t}\n"
    "\n"
    "\t\t\tfresh.Status.Phase = \"Preempting\"\n"
    "\n"
    "\t\t\tcond := metav1.Condition{\n"
    "\t\t\t\tType:               \"Preempting\",\n"
    "\t\t\t\tStatus:             metav1.ConditionTrue,\n"
    "\t\t\t\tReason:             \"HigherPriorityWorkload\",\n"
    "\t\t\t\tMessage: fmt.Sprintf(\"Preempted by %s/%s; grace=%ds\",\n"
    "\t\t\t\t\tplan.Requester.Namespace, plan.Requester.Name, v.GraceSeconds),\n"
    "\t\t\t\tLastTransitionTime: metav1.Now(),\n"
    "\t\t\t}\n"
    "\t\t\tfresh.Status.Conditions = upsertCondition(fresh.Status.Conditions, cond)\n"
    "\n"
    "\t\t\treturn p.client.Status().Update(ctx, &fresh)\n"
    "\t\t})\n"
    "\t\tif err != nil {\n"
    "\t\t\tlog.Printf(\"[preemptor] failed to mark victim %s/%s: %v\",\n"
    "\t\t\t\tv.Slice.Namespace, v.Slice.Name, err)\n"
    "\t\t\treturn err\n"
    "\t\t}\n"
    "\t}\n"
    "\treturn nil\n"
    "}"
)
new_d = (
    "func (p *Preemptor) markVictimsPreempting(ctx context.Context, plan *PreemptionPlan) error {\n"
    "\t// Track successfully-marked victims so we can roll them back on partial\n"
    "\t// failure. Without this, a mid-loop error would leave N-1 victims evicted\n"
    "\t// for nothing.\n"
    "\tmarked := make([]int, 0, len(plan.Victims))\n"
    "\tfor i := range plan.Victims {\n"
    "\t\tv := &plan.Victims[i]\n"
    "\t\tkey := client.ObjectKey{Namespace: v.Slice.Namespace, Name: v.Slice.Name}\n"
    "\n"
    "\t\terr := retry.RetryOnConflict(retry.DefaultRetry, func() error {\n"
    "\t\t\tvar fresh vgpuv1alpha1.VGPUSlice\n"
    "\t\t\tif err := p.client.Get(ctx, key, &fresh); err != nil {\n"
    "\t\t\t\treturn err\n"
    "\t\t\t}\n"
    "\t\t\tif fresh.Status.Phase != \"Ready\" {\n"
    "\t\t\t\treturn nil // someone else moved it; abort silently\n"
    "\t\t\t}\n"
    "\n"
    "\t\t\tfresh.Status.Phase = \"Preempting\"\n"
    "\n"
    "\t\t\tcond := metav1.Condition{\n"
    "\t\t\t\tType:               \"Preempting\",\n"
    "\t\t\t\tStatus:             metav1.ConditionTrue,\n"
    "\t\t\t\tReason:             \"HigherPriorityWorkload\",\n"
    "\t\t\t\tMessage: fmt.Sprintf(\"Preempted by %s/%s; grace=%ds\",\n"
    "\t\t\t\t\tplan.Requester.Namespace, plan.Requester.Name, v.GraceSeconds),\n"
    "\t\t\t\tLastTransitionTime: metav1.Now(),\n"
    "\t\t\t}\n"
    "\t\t\tfresh.Status.Conditions = upsertCondition(fresh.Status.Conditions, cond)\n"
    "\n"
    "\t\t\treturn p.client.Status().Update(ctx, &fresh)\n"
    "\t\t})\n"
    "\t\tif err != nil {\n"
    "\t\t\tlog.Printf(\"[preemptor] failed to mark victim %s/%s: %v\",\n"
    "\t\t\t\tv.Slice.Namespace, v.Slice.Name, err)\n"
    "\t\t\t// Roll back already-marked victims back to Ready (best-effort).\n"
    "\t\t\t// If rollback also fails, the next reconcile will heal it once\n"
    "\t\t\t// the in-flight annotation expires.\n"
    "\t\t\tp.rollbackPreemptingMarks(ctx, plan.Victims, marked)\n"
    "\t\t\treturn err\n"
    "\t\t}\n"
    "\t\tmarked = append(marked, i)\n"
    "\t}\n"
    "\treturn nil\n"
    "}"
)
assert src.count(old_d) == 1, "Patch D: anchor not found exactly once"
src = src.replace(old_d, new_d)

# ---------------------------------------------------------------------------
# Patch E — append rollbackPreemptingMarks + effectiveInFlightWindow at EOF
# ---------------------------------------------------------------------------
appendage = (
    "\n"
    "// rollbackPreemptingMarks reverts already-marked victims from Preempting\n"
    "// back to Ready. Called when markVictimsPreempting fails partway through.\n"
    "// Best-effort: failures are logged but not propagated, since the caller\n"
    "// is already returning an error and the in-flight annotation will expire,\n"
    "// allowing the next reconcile to retry cleanly.\n"
    "func (p *Preemptor) rollbackPreemptingMarks(ctx context.Context, victims []VictimSelection, indices []int) {\n"
    "\tfor _, idx := range indices {\n"
    "\t\tv := &victims[idx]\n"
    "\t\tkey := client.ObjectKey{Namespace: v.Slice.Namespace, Name: v.Slice.Name}\n"
    "\t\terr := retry.RetryOnConflict(retry.DefaultRetry, func() error {\n"
    "\t\t\tvar fresh vgpuv1alpha1.VGPUSlice\n"
    "\t\t\tif err := p.client.Get(ctx, key, &fresh); err != nil {\n"
    "\t\t\t\treturn err\n"
    "\t\t\t}\n"
    "\t\t\tif fresh.Status.Phase != \"Preempting\" {\n"
    "\t\t\t\treturn nil // someone else already moved it\n"
    "\t\t\t}\n"
    "\t\t\tfresh.Status.Phase = \"Ready\"\n"
    "\t\t\t// Strip the Preempting condition we added.\n"
    "\t\t\tout := fresh.Status.Conditions[:0]\n"
    "\t\t\tfor _, c := range fresh.Status.Conditions {\n"
    "\t\t\t\tif c.Type != \"Preempting\" {\n"
    "\t\t\t\t\tout = append(out, c)\n"
    "\t\t\t\t}\n"
    "\t\t\t}\n"
    "\t\t\tfresh.Status.Conditions = out\n"
    "\t\t\treturn p.client.Status().Update(ctx, &fresh)\n"
    "\t\t})\n"
    "\t\tif err != nil {\n"
    "\t\t\tlog.Printf(\"[preemptor] WARN: rollback of victim %s/%s failed: %v (will heal on next reconcile)\",\n"
    "\t\t\t\tv.Slice.Namespace, v.Slice.Name, err)\n"
    "\t\t}\n"
    "\t}\n"
    "}\n"
    "\n"
    "// effectiveInFlightWindow returns the dedup-gate duration for this requester.\n"
    "// PreemptionInFlightWindow is a floor; the actual window is the longer of\n"
    "// that floor and the longest grace period configured on any preemptible\n"
    "// VGPUJob in the requester's namespace, plus a 30-second buffer.\n"
    "//\n"
    "// Without this, a job with grace=600s could be the victim of a preemption,\n"
    "// and 60s later (when the static window expired) a second preemption wave\n"
    "// could fire on top of the first while the original victims were still\n"
    "// draining.\n"
    "func (p *Preemptor) effectiveInFlightWindow(ctx context.Context, requester *vgpuv1alpha1.VGPUSlice) time.Duration {\n"
    "\tfloor := PreemptionInFlightWindow\n"
    "\n"
    "\tvar jobs vgpuv1alpha1.VGPUJobList\n"
    "\tif err := p.client.List(ctx, &jobs, client.InNamespace(requester.Namespace)); err != nil {\n"
    "\t\treturn floor\n"
    "\t}\n"
    "\tmaxGrace := DefaultGraceSeconds\n"
    "\tfor i := range jobs.Items {\n"
    "\t\tj := &jobs.Items[i]\n"
    "\t\tif !j.Spec.Preemptible {\n"
    "\t\t\tcontinue\n"
    "\t\t}\n"
    "\t\tgrace := DefaultGraceSeconds\n"
    "\t\tif j.Spec.PreemptionGraceSeconds != nil {\n"
    "\t\t\tgrace = *j.Spec.PreemptionGraceSeconds\n"
    "\t\t}\n"
    "\t\tif grace > MaxGraceSeconds {\n"
    "\t\t\tgrace = MaxGraceSeconds\n"
    "\t\t}\n"
    "\t\tif grace > maxGrace {\n"
    "\t\t\tmaxGrace = grace\n"
    "\t\t}\n"
    "\t}\n"
    "\tdynamic := time.Duration(maxGrace+30) * time.Second\n"
    "\tif dynamic > floor {\n"
    "\t\treturn dynamic\n"
    "\t}\n"
    "\treturn floor\n"
    "}\n"
)

if not src.endswith("\n"):
    src += "\n"
src += appendage

# Sanity check: file actually grew (appended 100+ lines plus inline edits).
assert len(src) > original_len + 2000, f"File didn't grow as expected: {original_len} -> {len(src)}"

path.write_text(src)
print(f"Applied 5 edits to {path} ({original_len} -> {len(src)} bytes)")
PYEOF

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo
echo "Running gofmt..."
gofmt -l "$FILE" | tee /tmp/gofmt_out
if [[ -s /tmp/gofmt_out ]]; then
    echo "WARNING: gofmt suggested changes. Running gofmt -w to apply them."
    gofmt -w "$FILE"
fi

echo "Running go vet ./internal/scheduler/..."
go vet ./internal/scheduler/...

echo "Running go build ./..."
go build ./...

echo
echo "============================================================"
echo "✅ All three preemptor.go bugs fixed and verified."
echo "============================================================"
echo "  Bug 1 (partial-preempt rollback)  — fixed via patches D + E"
echo "  Bug 2 (cooldown map leak)         — fixed via patch B"
echo "  Bug 3 (in-flight window vs grace) — fixed via patches A + C + E"
echo
echo "  Backup of original: $BACKUP"
echo
echo "Recommended next steps:"
echo "  1. git diff $FILE     # review the changes"
echo "  2. go test ./...      # run unit tests"
echo "  3. bash integration_test.sh phase23   # rerun preemption suite"
