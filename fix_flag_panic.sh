#!/usr/bin/env bash
# Fix for the duplicate `kubeconfig` flag panic.
#
# controller-runtime and klog register `-kubeconfig` on the global FlagSet via
# their init() functions. The Layer-3 script added our own flag.StringVar call
# which panics because the flag name is already taken.
#
# Fix: stop registering our own flag. controller-runtime's flag handles it,
# and ctrl.GetConfig() already honours the KUBECONFIG env var.
#
# Idempotent — safe to re-run.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[[ -f go.mod ]] || { echo "ERROR: run from project root"; exit 1; }

backup=".flagfix_$(date +%s)"
mkdir -p "$backup"
cp -p cmd/scheduler/main.go   "$backup/" 2>/dev/null || true
cp -p cmd/controller/main.go  "$backup/" 2>/dev/null || true
cp -p cmd/nodeagent/main.go   "$backup/" 2>/dev/null || true
echo "Backup: $backup"

# ── cmd/controller/main.go ──────────────────────────────────────────────────
# Just remove the unused `"flag"` import line.
sed -i '/^\t"flag"$/d' cmd/controller/main.go
echo "✓ cmd/controller/main.go — removed unused flag import"

# ── cmd/scheduler/main.go ───────────────────────────────────────────────────
python3 <<'PY'
import pathlib, re
p = pathlib.Path("cmd/scheduler/main.go")
src = p.read_text()

# Remove the flag block inside main().
src = re.sub(
    r'\tvar kubeconfig string\n'
    r'\tflag\.StringVar\(&kubeconfig, "kubeconfig".*?\n'
    r'\tflag\.Parse\(\)\n'
    r'\tif kubeconfig != "" \{\n'
    r'\t\tos\.Setenv\("KUBECONFIG", kubeconfig\)\n'
    r'\t\}\n',
    '',
    src, count=1
)
# Remove the "flag" import if present.
src = re.sub(r'\n\t"flag"\n', '\n', src, count=1)
p.write_text(src)
PY
echo "✓ cmd/scheduler/main.go — removed flag block + import"

# ── cmd/nodeagent/main.go ───────────────────────────────────────────────────
python3 <<'PY'
import pathlib, re
p = pathlib.Path("cmd/nodeagent/main.go")
src = p.read_text()

# Remove the flag block inside main().
src = re.sub(
    r'\tvar kubeconfig string\n'
    r'\tflag\.StringVar\(&kubeconfig, "kubeconfig".*?\n'
    r'\tflag\.Parse\(\)\n',
    '',
    src, count=1
)

# Replace `getConfig(kubeconfig)` with `ctrl.GetConfig()`.
src = src.replace("cfg, err := getConfig(kubeconfig)", "cfg, err := ctrl.GetConfig()")

# Delete the getConfig helper function.
src = re.sub(
    r'\n// getConfig resolves kubeconfig.*?\nfunc getConfig\(kubeconfig string\) \(\*rest\.Config, error\) \{.*?\n\}\n',
    '\n',
    src, flags=re.DOTALL
)

# Remove the "flag" and "k8s.io/client-go/rest" imports — both now unused.
src = re.sub(r'\n\t"flag"\n', '\n', src, count=1)
src = re.sub(r'\n\t"k8s\.io/client-go/rest"\n', '\n', src, count=1)

p.write_text(src)
PY
echo "✓ cmd/nodeagent/main.go — removed flag block, getConfig helper, and unused imports"

echo ""
echo "Rebuilding..."
go build -o bin/scheduler  ./cmd/scheduler  && echo "✓ scheduler"
go build -o bin/controller ./cmd/controller && echo "✓ controller"
go build -o bin/nodeagent  ./cmd/nodeagent  && echo "✓ nodeagent"

echo ""
echo "Running quick smoke test..."
timeout 2 ./bin/controller 2>&1 | head -5 || true
echo ""
echo "Done. If you see messages about kubeconfig / no cluster,"
echo "that's expected — means the flag panic is gone."
