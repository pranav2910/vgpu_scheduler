# vGPU Scheduler — Release Certification Report

**Commit:** HEAD of main (v0.20 candidate) · **Hardware:** 8× Tesla V100-SXM2-16GB (real NVML) · **Date:** 2026-07-07

**RESULT: 22/22 CERTIFIED, 0 fail**

Catalog + verdict rules: docs/CERTIFICATION.md. Each verdict is the final
green result on real GPU hardware, consolidated across the certification run.
CERT-18 (multi-node failures) runs separately on a 3-node cluster.

| CERT | Verdict | Evidence |
|------|---------|----------|
| CERT-01 | PASS | install→doctor→report→bundle→VERIFIED uninstall→reinstall (parallel lane) |
| CERT-02a | PASS | 4 size classes allocated (1Gi..13Gi) |
| CERT-02b | PASS | N×4 grants, 4-per-card across all 8 real cards, ledger capped |
| CERT-03 | PASS | two pods on different cards each see ONLY their own UUID in-container |
| CERT-04 | PASS | fragmentation fails LOUD with the contract message |
| CERT-04x | PASS | boundary two-sided (6Gi>hole FAILED loud, 3Gi<hole landed); message numbers TRUTHFUL (request echoed, nodeFree>=request); release->retry recovered |
| CERT-05 | PASS | gangs COMPLETE per-gang (2/2,4/4,8/8); infeasible admitted ZERO; reused name re-admitted atomically (4/4) |
| CERT-05x | PASS | same-name gangs in two namespaces both complete (3/3 each — cohort keying); doomed gang fully reclaimed on timeout; capacity unharmed |
| CERT-06 | PASS | gap<100 WAITED (not failed); gap>=100 evicted the 15Gi victim, vip landed on the emptied card, all 7 walls intact; pri-999 vs all-non-preemptible WAITED |
| CERT-06x | PASS | gap=99 waited (victim untouched); gap=100 evicted; victim ORDER correct (pri-10 evicted, pri-30 spared) |
| CERT-06b | PASS | gang 1-per-card + vip preempted victim on a FULL node + invariant |
| CERT-07 | PASS | 6Gi fit under 10Gi quota; second 6Gi denied; 4×4Gi gang admitted ZERO (gang-atomic) |
| CERT-07x | PASS | gang EXACTLY at cap admitted (<= boundary); next 1Gi denied; other namespace unaffected; LIVE raise unblocked the waiter without resubmit |
| CERT-09 | PASS | 3 cards violating simultaneously, others clean (+softwarn/evict/exempt via tier-1 receipts) |
| CERT-10 | PASS | two simultaneous loads (3+11 GiB): report==nvidia-smi ±1GiB; table==CSV |
| CERT-11 | PASS | peak learned (6Gi from a 6Gi burn); profile rec=7Gi = peak*1.15; Low-confidence safety gate HELD (no annotation from a thin profile) |
| CERT-12 | PASS | loaded 8-card reboot: re-seed, over-commit refused, allocation works (+crash-loop kills in c-load) |
| CERT-13 | PASS | 36-job churn (3 waves): invariant every wave, zero residue |
| CERT-14 | PASS | 100/100 Ready in 24s, no component restarts |
| CERT-15 | PASS | 7/7 hostile inputs rejected (zero/huge/garbage-name/negative/10Ti/gangSize-0/immutability-edit) |
| CERT-16 | PASS | audit exit 0; bundle: zero Secrets, zero private keys (parallel lane) |
| CERT-17 | PASS | panels render via datasource; numbers==report ±1%; survives restart (quiet) |
