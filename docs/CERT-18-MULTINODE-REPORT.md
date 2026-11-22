# CERT-18 — Multi-Node Failure Certification: PASS

**Cluster:** 3 real GPU nodes, one cloud/region — 3× 1×A10 (23028 MiB each), Oracle,
same subnet (10.19.80.0/20), k3s server + 2 agents joined over private IPs
(wireguard-native flannel). No tunnels, no NAT tricks.
**Runner:** `scripts/cert18.sh` @ `ee97719` — ONE scripted pass, zero manual steps.
**Date:** 2026-07-08. **Verdict: `FINAL_VERDICT=PASS` — 10/10 checks green in a single run.**
Evidence: `artifacts/cert18-ee97719/` (full log + per-section receipts).

| ID | Scenario | Result | Receipt |
|----|----------|--------|---------|
| pre | 3 nodes Ready, capacity advertised, nodeagent on all 3 | ✅ | `00-nodes.txt` |
| CERT-08 | zone hint honored; hinted zone FULL → soft-overflow, still runs | ✅ | `ZONE=zone-a`, `SOFT=Ready`, `SOFTZONE=zone-b` |
| 18b | 3×13Gi gang on 22Gi nodes → forced to SPAN all 3 nodes, all-or-nothing | ✅ | admitted spanning 3 distinct nodes |
| 18c | node loss (k3s-agent stopped) → NotReady; survivors admit new work | ✅ | node `Unknown`, survivor `Ready` during loss |
| 18c+ | node return → capacity re-charged, new work lands | ✅ | 13Gi `Ready` post-return |
| 18d | **TRUE partition** (link cut) before gang submit → gang must HOLD | ✅ | `DURING: ready=0/3 reservation=Reserving` — never committed-partial |
| 18d+ | heal → same gang converges | ✅ | 3/3 `Ready`, reservation `Committed` |

## The money line

With one of three required nodes dark, the gang admitted **zero** members and the
reservation sat in `Reserving` — not `Committed`, not partially placed. On heal it
converged to 3/3 and committed. All-or-nothing held **under partition**, which is
the hardest multi-node property this suite tests.

## Why runs 1–2 were rejected (harness honesty, kept for the record)

- **Run 1 printed PASS and was retracted by us**: the 18d partition (agent-side
  iptables drop of dst:6443) landed ~2s after a 3-member gang had already fully
  assembled — the "during partition" assert was vacuous. Same-run evidence later
  showed the drop never even cut the agent (below).
- **Run 2 FAILED on purpose**: a new tripwire ("partition took effect: node must
  go NotReady") exposed that the port-level drop is **not a partition on k3s**:
  the rule measurably dropped 358 packets in 75s, yet node leases kept renewing
  every 10s — the k3s agent load-balancer fails over to a path riding the
  wireguard overlay (UDP 51820 on the wire), routing around a single-port cut.
- **Run 3 (this PASS)** uses a link cut — server-side blanket DROP of all traffic
  from the agent (dead-switch-port semantics k3s cannot route around) — and the
  suite REQUIRES observing the node NotReady, the gang held (`ready ≤ 2`, not
  Committed) during the cut, and full convergence + `Committed` after heal.

**Standing lesson:** fault injection must prove it fired. Every chaos step now
has its own "took effect" assertion; a partition test that can't show the node
dark fails loud instead of passing vacuously.

## History

The first CERT-18 attempt (2026-07-07, cross-cloud: 8×V100 Lambda + 2×A10 Oracle
over SSH tunnels — see `scripts/cert18-tunneled.sh`) proved every scenario's
substance across runs but never landed one all-green pass; boxes were terminated
mid-final-run. This same-cloud rerun retired that debt with margin: cluster
bring-up ~8 min via `multinode-server.sh`/`multinode-agent.sh`, one clean run
~15 min, total GPU spend ≈ $3.
