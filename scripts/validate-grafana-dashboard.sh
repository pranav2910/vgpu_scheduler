#!/usr/bin/env bash
# validate-grafana-dashboard.sh — proves the Gate-5 dashboard without a cluster:
# JSON validity, required panels, the $price variable, provisioning files, and
# the killer check: every PromQL expr references ONLY metrics that actually
# exist in internal/telemetry/metrics.go (no phantom panels).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo "  ${C_GRN}✓${C_RST} $*"; PASS=$((PASS+1)); }
bad() { echo "  ${C_RED}✗ $*${C_RST}"; FAIL=$((FAIL+1)); }

D=deployments/grafana/dashboards/vgpu-waste.json
python3 -m json.tool "$D" >/dev/null 2>&1 && ok "dashboard JSON parses" || bad "dashboard JSON invalid"

python3 - "$D" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
panels = [p for p in d["panels"] if p.get("type") != "row"]
checks = []
checks.append(("uid is vgpu-waste", d.get("uid") == "vgpu-waste"))
checks.append((f"{len(panels)} data panels (need >= 12)", len(panels) >= 12))
titles = " | ".join(p["title"].lower() for p in panels)
for need in ["requested", "waste / month", "utilization", "top wasting pods",
             "top wasting namespaces", "per-gpu", "node"]:
    checks.append((f"panel present: {need}", need in titles))
tv = {v["name"] for v in d.get("templating", {}).get("list", [])}
checks.append(("$price variable present", "price" in tv))

# no-phantom-metrics: every vgpu_* token in every expr must exist in metrics.go
inv = set(re.findall(r'Name: "(vgpu_[a-z_]+)"', open("internal/telemetry/metrics.go").read()))
bad_refs = set()
for p in panels:
    for t in p.get("targets", []):
        for m in re.findall(r"vgpu_[a-z_]+", t.get("expr", "")):
            if m not in inv:
                bad_refs.add(f'{p["title"]}: {m}')
checks.append(("every panel expr uses only REAL metric names", not bad_refs))
for c, okk in checks:
    print(("OK " if okk else "BAD ") + c + ("" if okk or c != "every panel expr uses only REAL metric names" else " -> " + "; ".join(sorted(bad_refs))))
sys.exit(0 if all(okk for _, okk in checks) else 1)
PYEOF
[[ $? -eq 0 ]] && ok "structural + no-phantom-metrics checks (see OK lines above)" || bad "structural/phantom check failed"

[[ -f deployments/grafana/provisioning/datasources/prometheus.yaml ]] && ok "datasource provisioning present" || bad "datasource provisioning missing"
[[ -f deployments/grafana/provisioning/dashboards/provider.yaml ]] && ok "dashboard provider present" || bad "dashboard provider missing"
grep -q "kubeconfig" deployments/prometheus.yml && ok "prometheus uses kubeconfig pod discovery" || bad "prometheus config stale"
grep -q "grafana/dashboards" deployments/docker-compose.yaml && ok "compose mounts the dashboards dir" || bad "compose mount missing"

echo; echo "  PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
