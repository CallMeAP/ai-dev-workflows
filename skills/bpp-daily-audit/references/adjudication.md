# Phase D — Adjudication

Model **Opus 5**, effort **high**. This is the only stage that authorises a write. One adjudicator
per work item; it receives the debate output, the diff, and the ticket.

## Output per finding

```json
{
  "verdict": "real",
  "fixability": "targeted-mr",
  "reason": "why, in one or two sentences",
  "dynamic_verification_requested": false,
  "mr_brief": "what the patch must change, precisely enough to author it"
}
```

`verdict` ∈ `real` | `false-positive` | `needs-human`.
`fixability` ∈ `targeted-mr` | `escalate` (meaningless when the verdict is `false-positive`).

## Verdict guidance

| Debate consensus | Default verdict |
|---|---|
| `agreed`, high severity | `real` |
| `agreed`, low severity, no failure scenario worth the churn | `real` + `escalate` (report it, don't MR it) |
| `withdrawn` | `false-positive` |
| `disputed` | `needs-human` unless the adjudicator can settle it from the code in hand |
| `refined` | judge the refined claim, not the original |

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
