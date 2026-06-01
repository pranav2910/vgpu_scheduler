#!/usr/bin/env python3
"""Compare the node agent's observed GPU metrics against nvidia-smi.

Invoked by validate-gpu-nvml.sh. Inputs via environment:
  METRICS_FILE  path to a file containing the scraped /metrics output
  NVSMI         nvidia-smi CSV: "uuid, total_mib, used_mib, free_mib" per line
  TOL           tolerance in bytes for the total-VRAM comparison

Exits 0 if checks 2-5 (UUID mapping, total, used+free consistency, health) all
pass, 1 otherwise. Prints a per-check PASS/FAIL line and a raw dump.
"""
import os
import re
import sys

GRN = "\033[1;32m✓\033[0m"
RED = "\033[1;31m✗\033[0m"


def series(metrics, name):
    out = {}
    pat = re.compile(r"^%s\{([^}]*)\}\s+([0-9.eE+]+)" % re.escape(name), re.M)
    for m in pat.finditer(metrics):
        labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        out[labels.get("device", "")] = float(m.group(2))
    return out


def main():
    metrics = open(os.environ["METRICS_FILE"]).read()
    tol = int(os.environ["TOL"])

    total = series(metrics, "vgpu_gpu_total_memory_bytes")
    used = series(metrics, "vgpu_gpu_used_memory_bytes")
    free = series(metrics, "vgpu_gpu_free_memory_bytes")
    healthy = series(metrics, "vgpu_gpu_healthy")

    smi = {}
    for line in os.environ["NVSMI"].strip().splitlines():
        uuid, t, u, f = [x.strip() for x in line.split(",")]
        smi[uuid] = (int(t) * 1024 * 1024, int(u) * 1024 * 1024, int(f) * 1024 * 1024)

    fails = 0

    # Check 2: every nvidia-smi UUID is observed by the node agent.
    missing = [u for u in smi if u not in total and u not in healthy]
    if not missing:
        print("  %s UUID mapping: all %d nvidia-smi GPU(s) observed by the node agent" % (GRN, len(smi)))
    else:
        print("  %s UUID mapping: node agent did not report device(s): %s" % (RED, missing))
        fails += 1

    # Check 3: total VRAM matches nvidia-smi within tolerance.
    t_ok = True
    for u, (t, _, _) in smi.items():
        obs = total.get(u)
        if obs is None:
            t_ok = False
            print("  %s total: no metric for %s" % (RED, u))
            continue
        if abs(obs - t) > tol:
            t_ok = False
            print("  %s total mismatch %s: nvml=%d nvidia-smi=%d (diff %d > tol %d)"
                  % (RED, u, int(obs), t, int(obs - t), tol))
    if t_ok:
        print("  %s total VRAM matches nvidia-smi within tolerance for all GPUs" % GRN)
    else:
        fails += 1

    # Check 4: used + free reconcile with total (used/free are actually read).
    c_ok = True
    for u in smi:
        t, uu, ff = total.get(u), used.get(u), free.get(u)
        if None in (t, uu, ff):
            c_ok = False
            print("  %s used/free missing for %s" % (RED, u))
            continue
        if abs((uu + ff) - t) > tol:
            c_ok = False
            print("  %s used+free != total for %s: %d + %d vs %d" % (RED, u, int(uu), int(ff), int(t)))
    if c_ok:
        print("  %s used+free reconcile with total (used/free are being read)" % GRN)
    else:
        fails += 1

    # Check 5: health == 1 for all observed devices.
    unhealthy = [d for d, v in healthy.items() if v != 1.0]
    if healthy and not unhealthy:
        print("  %s health: all %d device(s) report healthy=1" % (GRN, len(healthy)))
    else:
        label = unhealthy or list(healthy) or "none reported"
        print("  %s health: unhealthy/missing devices: %s" % (RED, label))
        fails += 1

    print("  ---- observed (bytes) ----")
    for u in smi:
        h = healthy.get(u, "?")
        print("     %s  total=%d used=%d free=%d healthy=%s"
              % (u, int(total.get(u, 0)), int(used.get(u, 0)), int(free.get(u, 0)), h))

    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
