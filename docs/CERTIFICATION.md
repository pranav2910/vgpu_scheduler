# Release Certification — the named test catalog

Every release tag must pass `scripts/certify-release.sh` on real GPU hardware.
One command, one evidence pack, every claim re-proven. Categories mirror what
commercial GPU schedulers certify: conformance, composition, isolation,
failure/chaos, performance, input hostility, security.

Run: `HOST=user@gpu-box bash scripts/certify-release.sh`
(best on a multi-GPU node, e.g. 8×V100; single-GPU boxes run a reduced set)

| ID | Test name | What it proves |
|----|-----------|----------------|
| **CERT-01** | Install lifecycle | `vgpu install monitor` → READY; `doctor` = 0 failures with live NVML; **verified** uninstall (incl. cluster RBAC, zero residue); reinstall works |
| **CERT-02** | Slicing multi-value pack | Grants at 1 Gi / 3.75 Gi / 7.5 Gi / 13 Gi all allocate, coexist per-card within capacity, and release cleanly — VRAM-byte slicing at four size classes, not one demo value |
| **CERT-03** | Cross-card isolation | Two pods forced onto different physical cards each see ONLY their own GPU UUID inside the container (CDI + NVIDIA_VISIBLE_DEVICES pin) |
| **CERT-04** | Fragmentation honesty | With per-card holes smaller than the request but node-total larger: allocation FAILS LOUD with the exact "Fragmented capacity" message — never silent, never over-committed |
| **CERT-04x** | Fragmentation deep-matrix | Two-sided boundary (bigger-than-hole FAILS loud, smaller-than-hole LANDS); the error message's numbers are arithmetically truthful (cardFree < request ≤ nodeFree); release → retry recovers |
| **CERT-05** | Gang atomicity multi-size | Gangs of 2, 4, and 8 admit all-or-nothing; an infeasible gang admits ZERO members and reclaims its reservation on timeout; a completed gang's name can be REUSED safely (regression S1) |
| **CERT-05x** | Gang deep-matrix | Same gang name in TWO namespaces simultaneously — both complete (cohort keying); infeasible gang FULLY reclaimed on timeout; capacity unharmed after |
| **CERT-06** | Preemption matrix | (victim 10, vip 200) → evicted + vip lands; (victim 50, vip 120: gap < 100) → NOT evicted; non-preemptible victim → immune; **full-pack variant**: vip with zero free holes must go through the preemptor and land on the freed card |
| **CERT-06x** | Preemption boundary + order | Gap **exactly 100** evicts; gap 99 waits; with victims at priority 10 and 30, the pri-10 one is evicted and pri-30 spared (lowest-first selection) |
| **CERT-07** | Quota enforcement | Namespace quota rejects the job that would exceed it; a gang whose TOTAL exceeds quota admits zero members (gang-atomic, fail-closed) |
| **CERT-07x** | Quota deep-matrix | Gang EXACTLY at cap admits (≤ boundary); next 1 Gi denied; other namespaces unaffected; LIVE quota raise unblocks the waiting job without resubmission |
| **CERT-08** | Topology preference | Zone-hinted job lands in the preferred zone when feasible; still schedules (soft) when not; TopologyPreferenceSatisfied condition truthful |
| **CERT-08x** | Topology dual-zone | Two concurrent jobs hinted at DIFFERENT zones each land in their own zone; unhinted job unaffected |
| **CERT-09** | Enforcement ladder | Over-user detected (~90 s streak) → softwarn labels/events, NOT killed; evict mode → killed via Eviction API; exempt namespace → immune even in evict mode; 3 cards violating SIMULTANEOUSLY, others clean |
| **CERT-10** | Attribution truth | 40-proc CUDA fork-storm on a compliant pod → ZERO false violations; report used-bytes == nvidia-smi ±1 GiB at three different load levels; table = CSV = JSON |
| **CERT-11** | Right-sizing loop | Workload burning a KNOWN size → profile learns the peak; recommendation ≈ peak×1.15; autoResize raises an undersized re-submit; override annotation respected |
| **CERT-12** | Crash/restart storm | Agent killed ×3 under load → checkpoint re-seed each time; scheduler leader killed mid-burst → zero over-admission; containerd restarted → running pod keeps its GPU; **full node reboot with loaded multi-card ledger** → re-seed + over-commit refused + normal allocation works |
| **CERT-13** | Churn endurance | 72 random-size jobs churned in 6 waves → per-card invariant after every wave, honest rejections counted, ZERO residue after release-all |
| **CERT-14** | Burst admission | 100×1 Gi jobs in one apply → all Ready, time recorded, zero component restarts |
| **CERT-15** | Input hostility | Zero/negative/absurd VRAM, gangSize 0/-1/10⁶, spec-edit after admission, garbage names → every one rejected LOUD at CLI or webhook; nothing corrupts state |
| **CERT-16** | Security posture | `vgpu security audit` exit 0 against live RBAC; support-bundle contains no Secret material (grep-verified) |
| **CERT-17** | Dashboard truth | Grafana panels render through the provisioned datasource; numbers match `vgpu report` ±1 %; dashboard survives restart |
| **CERT-18** | Multi-node failures *(needs ≥2 GPU nodes — `scripts/cert18.sh`)* | Cross-node gang forced to SPAN nodes; whole-node kill → survivors admit, return re-charges; TRUE network partition (link cut, verified NotReady) before gang submit → gang HELD (never committed-partial), converges + commits on heal. **Certified 2026-07-08 on 3× A10 — docs/CERT-18-MULTINODE-REPORT.md** |
| **CERT-19** | Dogfood / UX honesty (`scripts/dogfood-ux.sh`, any live cluster) | The CLI's story must match cluster truth at every step of the human journey: missing-job status points at the fix; submit's claim == cluster bytes; profile NEVER advises "0 B" (says "none yet" or a real value) and its `requested` matches the live claim; re-submitting an existing name is REFUSED loudly with the current grant and nothing mutates; a direct kubectl resize is DENIED with the delete-and-resubmit recipe; a deleted job's profile is labeled SAVED history. Born from the 2026-07-09 dogfooding session that caught 3 bugs behavior tests structurally missed |

**Known limitation (found by CERT-06 on 8×V100, 2026-07-07):** the preemptor
triggers on NODE-level capacity shortfall. A request that fits the node total
but no single card (card-fragmented) FAILS LOUD rather than preempting — honest
per the fragmentation contract, invisible on single-GPU nodes, and a roadmap
item (card-aware preemption) for multi-GPU nodes.

**Verdict rule:** FINAL_VERDICT=PASS requires every non-optional CERT green.
Evidence lands in `artifacts/certify-<sha>/` (one file per CERT). The suite is
built from the receipt scripts that already validated v0.16–v0.19, plus the
multi-value and hostility sections added for certification.
