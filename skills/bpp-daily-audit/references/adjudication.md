# Phase D — Adjudication

Model **Opus 5**, effort **high**. This is the only stage that authorises a write. One adjudicator
per work item; it receives the debate output, the diff, and the ticket.

## Output per finding

```json
{
  "verdict": "real",
  "fixability": "targeted-mr",
  "reason": "why, in one or two sentences",
  "debate_context": "full",
  "rebuttals_rejected": [],
  "dynamic_verification_requested": false,
  "mr_brief": "what the patch must change, precisely enough to author it"
}
```

`verdict` ∈ `real` | `false-positive` | `needs-human`.
`fixability` ∈ `targeted-mr` | `escalate` (meaningless when the verdict is `false-positive`).
`debate_context` is **copied verbatim from Phase C** — never recomputed, never omitted. It carries
the verdict floor below into Phase E and the ledger.
`rebuttals_rejected` names every rebuttal the checks below discarded, with the reason
(`no-citation`, `unstated-population`, `mismatched-population`) — so the report can show that a
finding survived an attack rather than never facing one.

## Two checks before any verdict

### 1. The verdict floor — a fresh challenger cannot close a finding

> **If `debate_context` is `fresh` or `none`, the verdict floor is `needs-human`: return `real` or
> `needs-human`. `false-positive` is not available for this finding.** A challenger dispatched
> without Phase B context may lower confidence in a finding; it may never close one.

The floor is mechanical and checkable per finding: read `debate_context`, which Phase C set from the
`agent_kind` of every position (`references/debate-protocol.md`). It is not a judgement call and no
strength of argument lifts it — the fresh challenger's argument may well be right, and
`needs-human` is where a right-but-context-less argument belongs.

Consequence for Phase E: with `false-positive` unreachable, **no `known-non-issues.md` entry can be
written for that finding**. That is the intent. A dismissal entry suppresses the claim on every
future run, so it requires a debate by the agents that actually read the code.

Real case 2026-09-09: fresh challengers replaced four silent lenses, one produced the miscounted
rebuttal below, the finding was ruled `false-positive` and an entry was written — a real finding
suppressed forever, caught only because the original lens's `hold` happened to arrive minutes later.

### 2. The population check — counting rebuttals

> **A rebuttal arguing from a ratio, base rate or frequency must state the population it measured.
> The adjudicator MUST verify that the stated population is the class the finding actually claims.
> An unstated or mismatched population means the rebuttal is REJECTED and the finding stands as
> stated — it does not mean the finding is confirmed, only that the rebuttal did nothing.**

Procedure, per counting rebuttal:

1. Read the finding's claim and name the class it is about.
2. Read the rebuttal's `population` field. Absent → reject, record `unstated-population`.
3. Compare. A **superset** (a broader set that dilutes the class), a **subset** that drops the
   contested members, or a **different** class → reject, record `mismatched-population`.
4. A rejected rebuttal is struck from the consensus. Recompute: with it gone, an `agreed` finding is
   `agreed`, not `disputed`. Then adjudicate the finding on its own merits and the surviving
   positions — a struck rebuttal is not evidence for the finding either.

**Worked example — run `2026-09-09-1240`.** Finding: two OAuth return keys
(`returnSuccessTitle`, `returnFailedTitle`) added to `de.json` with no `…Message` sibling.

| | Population | Count | With `Message` sibling |
|---|---|---|---|
| Rebuttal measured | **all** `*Title` keys in `de.json` | **158** | 9 → "6 % oddity, no convention" |
| Finding claims | `*(Success\|Failed\|Failure\|Error)*Title` — action outcomes | **12** | **9** → the convention holds |

The rebuttal's population is a superset dominated by **labels** (`maklerSign.cardTitle`,
`bvs.calculator.isCharterTitle`, `claim.deleteClaimTitle`) that never had body text. Its own 9 pairs
*are* the action-outcome class — the count confirmed the convention it set out to refute. Correct
handling: **reject the rebuttal** (`mismatched-population`), finding stands. It was then ruled
`needs-human` on its own merits — the consuming template lives in `brokernet-cockpit-ui`, which no
lens read — which is a separate call from the rebuttal failing.

## Verdict guidance

| Debate consensus | Default verdict |
|---|---|
| `agreed`, high severity | `real` |
| `agreed`, low severity, no failure scenario worth the churn | `real` + `escalate` (report it, don't MR it) |
| `withdrawn` | `false-positive` — **only if `debate_context` is `full`**; otherwise `needs-human` |
| `disputed` | `needs-human` unless the adjudicator can settle it from the code in hand |
| `refined` | judge the refined claim, not the original |

Both checks run **before** this table, and the floor overrides every row of it.

A `disputed` finding the adjudicator *can* settle from the supplied code should be settled — say
which side is right and why. `needs-human` is for genuine ambiguity, not for avoiding a call.

## Escalate-regardless list

**No debate consensus and no adjudicator judgement overrides these. They are always `escalate`,
never `targeted-mr`:**

1. **An EF Core migration is required.** Schema changes need review, ordering and a deploy plan.
2. **A DTO or API contract change.** These require an endpoint migration guide and FE coordination
   (`npm run generate:models`); shipping one silently breaks the GUI's generated models.
3. **Any change inside `bpp-shared`.** It ships as a NuGet package; a fix there is a fleet-wide pin
   bump, not a targeted MR.
4. **The fix spans more than one repository.**
5. **Security-relevant** — authorization gates, credentials, data exposure, tenant isolation.
6. **The fix would touch more than 5 files** (`files_touched_by_fix`, honestly estimated).

### Open question — rule 3 is broader than its rationale

Rule 3 says "any change inside `bpp-shared`", because a shared change ships as a NuGet package and a
fix there is a fleet-wide pin bump. That rationale does **not** apply to a change confined to
`BPP.Shared.NET.Tests` — a test-only fix ripples to nobody and needs no consumer bump.

Raised 2026-09-08 by a real finding (a weak enum-mapping test in `bpp-shared`) that rule 3 forced to
escalate despite being a one-file test fix.

**The rule is NOT relaxed until a human decides.** Narrowing a guard mid-run so that a write becomes
permissible is precisely the failure mode the escalate-regardless list exists to prevent. Adjudicate
by the rule as written, and put the proposed refinement in the report.

Proposed wording for review: *"any change inside `bpp-shared` outside its test projects."*

An escalation is not a lesser outcome. It is the correct outcome for anything that needs a human to
sequence it.

## Dynamic verification

Optional, opt-in per finding, and tightly bounded.

**Never for the Angular UIs.** `brokernet-cockpit-ui` and `bpp-stella-ui` are not reliably buildable
or startable on this machine (user directive 2026-09-08). Findings there are static-analysis-only —
do not attempt a local build, `npm start`, or a screenshot to confirm them.

**Permitted only when the finding is on `development`.** The local stack is always on
`development`; starting it against `staging` or `main` risks an EF migration mismatch against the
local database. A `staging` or `main` finding is static-analysis-only — no exceptions.

- Maximum **1 per run**. Further requests are downgraded to static and noted in the report.
- Uses the `bpp-start-local-stack` skill. Record whether the stack was already running via
  `bpp-status-local-stack`; if it was not, stop it afterwards with `bpp-stop-local-stack`. Leaving a
  stack the run started is a side effect the user did not ask for.
- The verification result — confirmed, not reproduced, or inconclusive — goes into the finding and
  into the MR or escalation. "Not reproduced" downgrades the verdict to `needs-human`; it does not
  silently drop the finding.

## Red flags — STOP

- About to mark a DTO property addition `targeted-mr` because "it is additive and non-breaking" →
  it is still an escalation; the GUI has to pick the field up.
- About to start the stack for a `staging` finding → static only.
- About to let three agreeing reviewers override the escalate-regardless list → the list wins.
- About to return `needs-human` for every disputed finding without reading the rebuttals → settle
  what the code in hand can settle.
- About to rule `false-positive` on a finding whose `debate_context` is `fresh` or `none` → stop;
  the floor is `needs-human`. A context-less challenger does not get to close a finding.
- About to accept a percentage or "only N of M" rebuttal without reading its `population` → stop;
  check the reference class first. An unstated population is a rejected rebuttal.
- About to treat a rejected rebuttal as *confirmation* of the finding → stop; the rebuttal failed,
  that is all. Adjudicate the finding on its own merits.
