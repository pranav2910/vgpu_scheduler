# Helm chart — removed (use the manifests directly)

There is **no supported Helm chart** right now. An earlier chart lived here but
drifted badly behind `deployments/manifests/` — it shipped 2 of 7 CRDs (missing
fields are silently pruned by Kubernetes, with no error), stale RBAC that left
the node agent unable to read pods, and unwired `values.yaml`. A `helm install`
produced a broken, silently-degraded cluster, so it was removed rather than left
as a trap. (It remains in git history for whenever a packaging gate revives it —
ideally auto-generated from the manifests so it can't drift again.)

## Install the supported way

```sh
# CRDs + namespace + RBAC + control plane + webhooks
make install-nvml     # real GPU nodes   (make install = FAKE agent, kind/CI only)

# read-only monitor pilot (no scheduler): see docs/PILOT.md
scripts/vgpu install monitor
```

Both paths apply the same, hardware-validated manifests under
`deployments/manifests/`. Webhooks require cert-manager for the CA.
