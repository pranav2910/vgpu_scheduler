# Customer discovery — a call guide for talking to GPU/ML platform teams

The code and proof exist. The open question is **not** "can we build more?" — it's
**"do real teams feel GPU waste strongly enough to try a fix?"** This guide helps you
find that out *without pitching*.

> **The one rule (Mom Test):** ask about their **past behavior and their world**, never
> about your idea. Compliments are worthless; specifics about what they already did,
> tried, and spent are gold. If you catch yourself describing the product before the
> last section, stop.
>
> ❌ "Would you use a tool that packs GPUs?"  ❌ "Would this be useful?"  ❌ "Would you pay?"
> ✅ "How do you get a GPU today?"  ✅ "What happened the last time GPUs were full?"

Goal of each call: leave with **facts** (what happens today, how often, what it costs,
what they've tried) — not validation.

---

## 1. Who to talk to
- **ML platform / infra engineers and leads** who run GPUs on Kubernetes (own utilization & cost).
- **GPU cluster / HPC admins** (on-prem or cloud) who allocate GPUs to teams.
- **AI-startup founders / founding engineers** running their own training/inference fleet.
- **University & research-lab compute admins** sharing GPUs across students/projects.

Where to find them: Kubernetes / MLOps / Kubeflow / Ray community Slacks & Discords,
r/kubernetes & r/MLOps, CNCF events, LinkedIn ("platform engineer" / "ML infra" at
AI companies), university HPC groups, GPU-cloud user forums. Warm intros > cold.

## 2. How to open the call
Set a no-pitch frame and get them talking:
> "I'm researching how teams actually run GPUs on Kubernetes — I'm **not** selling
> anything, I just want to learn from people who live this. Could you walk me through
> how it works on your team today?"

Then mostly listen. Ask "why?" and "what happened next?" Let silences sit.

## 3. Problem discovery (past behavior, not hypotheticals)
- How does someone on your team **get a GPU** today, start to finish?
- When did GPUs last run out / jobs sat **Pending**? **What happened?** Who noticed?
- How do you figure out **how much VRAM** a job needs? What if you guess wrong?
- Has a job ever **OOM'd** or been killed by another job sharing a GPU? Walk me through it.
- Who **complains** when GPUs are full or a job won't schedule — and to whom?
- How do you know if a GPU is **half-empty** right now? Do you?

## 4. Current workflow
- Take the last real job: how did it go from "I need a GPU" to running?
- Who **approves / sizes** GPU requests? Is it self-service or ticketed?
- How do you **monitor** GPU memory and utilization today? Who looks at it?
- What do you do when the cluster is full — queue, preempt, buy more, wait?
- Multi-GPU / distributed jobs — how do those get scheduled?

## 5. Current solutions & competitors
- What have you **already tried** to share or pack GPUs? How did it go?
- Are you using **MIG / time-slicing / MPS**? What do you like / hate about each?
- Have you looked at **Run:ai, KAI, Volcano, Kueue**, or built something in-house?
- For anything you stopped using — **why** did you stop?
- If you do nothing about utilization, what's the reason — fine as-is, no time, no owner?

## 6. Cost & urgency
- Roughly **how many GPUs**, what type, on-prem or cloud?
- What do you think your **utilization** actually is? How would you find out?
- What does an **idle / stranded** GPU cost you per month, ballpark?
- Is **anyone tasked** with improving GPU utilization right now? Is there budget/timeline?
- What have you **spent** (money or eng time) trying to fix this already?

## 7. The wedge — ONLY at the very end, after discovery
Frame it as exposing blockers, not asking for praise:
> "If an open-source Kubernetes tool could show **requested vs actual** GPU memory,
> **pack smaller jobs** onto shared GPUs, **warn or evict** over-users, and
> **recommend better VRAM requests** — what would make it **impossible for you to
> try**?"

Then:
- Who else would have to **sign off** to run it on a real cluster?
- What would you need to see to run it on **one non-critical node**?
- (If interested) "Can I send you the quickstart and check back in two weeks?"

## 8. Green flags (real pain + pull)
- They name a **specific recent incident** unprompted.
- They've **already built or bought** something to fix it (Run:ai, scripts, MIG setup).
- Someone **owns** utilization / there's budget or a mandate.
- They can **quantify** waste or cost.
- They ask to **be kept updated**, offer **intros**, or want to **pilot**.

## 9. Red flags (politeness, not demand)
- "Sounds cool / useful" with **no** past action behind it.
- Can't recall a **single** time GPUs were full or a job OOM'd.
- **No one** owns utilization; it's "not really a problem."
- Only **hypothetical** interest ("we might, someday").
- They pitch *you* features but won't commit to a next step.

## 10. Scoring (fill in right after each call)
Score 0–3 each; ~13+ = strong, 8–12 = maybe, <8 = pass.

| Signal | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| Pain (recent, specific) | none | vague | one incident | recurring & painful |
| Frequency | rare | monthly | weekly | daily |
| Cost they can name | none | guess | rough $ | tracked $ |
| Owner / budget exists | no | someone cares | named owner | owner + budget |
| Already tried a fix | no | considered | tried 1 | tried several / pays |
| Concrete next step | none | "keep in touch" | will look | will pilot / intro |

| Field | |
|---|---|
| Name / role / org | |
| GPUs (count, type, cloud/on-prem) | |
| Best quote (verbatim) | |
| What they've tried | |
| Blocker to trying ours | |
| Score / tier | |
| Next step + date | |

## 11. Outreach template (no pitch)
> **Subject:** how does your team run GPUs on k8s?
>
> Hi {name} — I'm researching how ML/platform teams actually run GPUs on Kubernetes
> (utilization, sizing, contention). I'm **not** selling anything — I'd love 20 minutes
> to learn how it works on your team and what's annoying about it. I'm building in this
> space and trying to learn from people who live it. Open to a quick call this week?

## 12. Follow-up template
> Thanks for the time, {name} — the part about **{specific thing they said}** really
> stuck with me. {If relevant: here's the 5-minute quickstart you can skim — no
> pressure: <link to docs/QUICKSTART.md>.} Mind if I check back in ~2 weeks? And if
> anyone on your team wrestles with this, an intro would mean a lot.

---

**After ~10 of these, you'll know more than another backend feature could teach you.**
Talk to people first; build second.
