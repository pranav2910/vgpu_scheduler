#!/usr/bin/env bash
# gen-prometheus-kubeconfig.sh — mint a DEDICATED, LEAST-PRIVILEGE kubeconfig
# for the compose Prometheus's pod discovery. Never mount your admin kubeconfig
# into a container: this credential can ONLY get/list/watch pods and nodes.
#
# Writes deployments/prometheus-kubeconfig.yaml (gitignored), readable by the
# container's non-root user — safe because the token is read-only + scoped.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

kubectl create serviceaccount prometheus-sd -n kube-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<'RBAC' | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: prometheus-sd-readonly }
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: prometheus-sd-readonly }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: prometheus-sd-readonly }
subjects: [ { kind: ServiceAccount, name: prometheus-sd, namespace: kube-system } ]
RBAC

TOKEN="$(kubectl create token prometheus-sd -n kube-system --duration=8760h)"
# host.docker.internal resolves to the host from inside compose containers
# (extra_hosts: host-gateway) — the host's 6443 is the k3s API. TLS verify is
# skipped because the cert has no SAN for that name; acceptable for a
# read-only, pods+nodes-scoped token. The API connection is still TLS.
cat > deployments/prometheus-kubeconfig.yaml <<KCFG
apiVersion: v1
kind: Config
clusters:
  - name: local
    cluster:
      server: https://host.docker.internal:6443
      insecure-skip-tls-verify: true
contexts:
  - name: local
    context: { cluster: local, user: prometheus-sd }
current-context: local
users:
  - name: prometheus-sd
    user:
      token: ${TOKEN}
KCFG
chmod 644 deployments/prometheus-kubeconfig.yaml
echo "wrote deployments/prometheus-kubeconfig.yaml (SA prometheus-sd: pods+nodes read-only, 1y token)"
