#!/bin/bash

echo "🔍 Starting vGPU-Scheduler Project Health Check..."
echo "--------------------------------------------------"

FILES=(
  "api/v1alpha1/conditions.go"
  "api/v1alpha1/vgpuclaim_types.go"
  "api/v1alpha1/vgpuslice_types.go"
  "internal/state/transitions.go"
  "internal/state/invariants.go"
  "internal/controller/vgpuclaim_reconciler.go"
  "internal/scheduler/cache.go"
  "internal/scheduler/filter.go"
  "internal/scheduler/score.go"
  "internal/scheduler/plugin.go"
  "internal/nodeagent/nvml/allocator.go"
  "internal/nodeagent/cdi/generator.go"
  "internal/nodeagent/manager.go"
  "cmd/controller/main.go"
  "cmd/nodeagent/main.go"
  "cmd/scheduler/main.go"
  "internal/webhook/mutating_pod.go"
  "Makefile"
  "Dockerfile.controller"
  "Dockerfile.nodeagent"
  "Dockerfile.scheduler"
  "internal/webhook/webhook_handlers.go"
  "internal/webhook/validating_vgpuclaim.go"
  "internal/security/policy.go"
  "internal/controller/status.go"
  "internal/controller/finalizers.go"
  "internal/controller/vgpuslice_reconciler.go"
  "internal/state/transitions.go"
  "internal/state/invariants.go"
  "internal/state/phases.go"
  "internal/telemetry/metrics.go"
  "deployments/manifests/namespace.yaml"
  "deployments/manifests/rbac/scheduler_rbac.yaml"
  "deployments/manifests/rbac/controller_rbac.yaml"
  "deployments/manifests/rbac/nodeagent_rbac.yaml"
  "deployments/manifests/webhooks/service.yaml"
  "deployments/manifests/webhooks/mutating.yaml"
  "deployments/manifests/webhooks/validating.yaml"
  "deployments/manifests/webhooks/certificate.yaml"
  "deployments/manifests/crds/infrastructure.pranav2910.com_vgpuclaims.yaml"
  "deployments/manifests/crds/infrastructure.pranav2910.com_vgpuslices.yaml"
)

MISSING=0
EMPTY=0

for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "❌ MISSING: $file"
    MISSING=$((MISSING+1))
  elif [ ! -s "$file" ]; then
    echo "⚠️  EMPTY:   $file (File exists but has 0 bytes)"
    EMPTY=$((EMPTY+1))
  else
    echo "✅ OK:      $file"
  fi
done

echo "--------------------------------------------------"
if [ $MISSING -gt 0 ] || [ $EMPTY -gt 0 ]; then
  echo "🚨 Check complete: Found $MISSING missing files and $EMPTY empty files."
  echo "Please fix the missing/empty files above before running the build."
  exit 1
fi

echo "All core files exist and have content!"
echo "🛠️  Now running 'make build' to verify the Go code syntax is flawless..."
echo "--------------------------------------------------"

make build

if [ $? -eq 0 ]; then
  echo "--------------------------------------------------"
  echo "✅ SYSTEM PERFECT: All files exist, and the Go compiler successfully built your Controller, Scheduler, and NodeAgent binaries."
else
  echo "--------------------------------------------------"
  echo "❌ COMPILER ERROR: Your files exist, but the Go compiler found a syntax error (likely a bad copy-paste). Look at the 'make build' output above."
fi
