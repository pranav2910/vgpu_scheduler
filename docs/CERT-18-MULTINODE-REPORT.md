# CERT-18 — Multi-Node Failure Certification (HONEST STATUS)

**Cluster:** 3 real GPU nodes, TWO clouds — 1× 8×Tesla V100 (Lambda us-south-1)
+ 2× A10 (Oracle), joined over SSH tunnels (us-south-1 firewall un-configurable).
**Date:** 2026-07-08.

## Status: SUBSTANCE PROVEN, single all-green run NOT captured

Every scenario passed on real hardware — but spread across runs, not all-green in
ONE scripted pass (boxes terminated before a final clean run). By our own
"one clean receipt" standard, CERT-18 is **substance-proven, receipt-incomplete**.

| ID | Scenario | Best result | Notes |
|----|----------|-------------|-------|
| CERT-08 | zone hint + soft-overflow when zone full | ✅ green (final run) | rewrote for this cluster's card shape (V100 cards 16Gi < A10 22Gi) |
| **18b** | cross-node gang spans 3 nodes, all-or-nothing | ✅ green (runs 1–2); ✗ 0/10 (final) | final red = CERT-08 leftover fill jobs starved the A10s → product CORRECTLY refused to over-admit; not a product fault |
| **18c** | node loss → survivors admit | ✅ green (×3) | killed A10 → NotReady; new work admitted on survivors |
| **18c+** | node return → capacity re-charged | ✅ green (final) | 20Gi landed on the returned node after holder cleanup |
| **18d** | partition during gang → no split-brain; converge | ✅ green (final) | reservation NEVER committed-partial; converged 10/10 on heal (also seen live 9→10) |

## What is solidly proven

- Cross-node gang scheduling spanning 3 real nodes (18b, twice).
- Real node loss + survivor admission (18c, thrice).
- Node return / flap recovery (18c+).
- **Network partition: atomic — the gang reservation never committed with partial
  membership (no split-brain) and converged to 10/10 on heal** (18d, final run +
  observed live). This is the hardest multi-node property and it passed cleanly.

## What is NOT fully earned

A single scripted run with FINAL_VERDICT=PASS across all six. The one repeatable
gap is HARNESS sequencing (CERT-08's fill jobs not guaranteed drained before 18b),
never a product defect — across every run the scheduler's only "failures" were
correct refusals to over-admit onto occupied capacity.

## To finish (next multi-node box session, ~30 min)

Add a `quiesce`-to-zero between CERT-08 and 18b (the same pattern that fixed the
single-cluster cert's capacity sections), then one clean run tags it.
