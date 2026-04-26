#!/usr/bin/env bash
# =============================================================================
# Patch for controller-runtime v0.16+ API breakage
#
# In controller-runtime v0.16.0, the Options struct changed:
#   OLD:  ctrl.Options{MetricsBindAddress: ":8081", ...}
#   NEW:  ctrl.Options{Metrics: metricsserver.Options{BindAddress: ":8081"}, ...}
#
# This script patches all three main.go files.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$ROOT/go.mod" ]]; then
    echo "ERROR: must be run from project root"
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$ROOT/.metrics_patch_backup_${STAMP}"
mkdir -p "$BACKUP"

echo "Patching controller-runtime MetricsBindAddress → Metrics.BindAddress..."

for f in cmd/scheduler/main.go cmd/controller/main.go cmd/nodeagent/main.go; do
    full="$ROOT/$f"
    if [[ ! -f "$full" ]]; then
        echo "  SKIP: $f not found"
        continue
    fi

    # Backup
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$full" "$BACKUP/$f"

    # 1. Add the metricsserver import if not already present.
    if ! grep -q 'metrics/server' "$full"; then
        # Insert a new import line right after the ctrl import.
        sed -i 's|\(ctrl "sigs.k8s.io/controller-runtime"\)|\1\n\tmetricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"|' "$full"
    fi

    # 2. Rewrite the struct field. Handles optional trailing comment.
    #    Matches:  MetricsBindAddress:     ":8081",
    #    Matches:  MetricsBindAddress: "0", // disabled — ...
    sed -i -E 's|MetricsBindAddress:[[:space:]]+("[^"]*"),(.*)$|Metrics: metricsserver.Options{BindAddress: \1},\2|' "$full"

    echo "  ✓ $f"
done

echo ""
echo "Running go build ./..."
cd "$ROOT"
if go build ./...; then
    echo ""
    echo "✅ Build succeeded."
    echo "   Patch backup: $BACKUP"
else
    echo ""
    echo "⚠️  Still failing. Restore with:"
    echo "      cp -rp $BACKUP/* $ROOT/"
    exit 1
fi
