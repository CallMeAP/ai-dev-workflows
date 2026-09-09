# Phase C — Debate

Model **Sonnet 5**, effort **medium**. **Every** finding is debated — this is a deliberate choice,
not an oversight, and it is why the reviewer and debate tiers stay off Opus.

## The debate channel — resume first, fall back second, never terminal

The debaters are the Phase B lenses, **resumed** (`SendMessage` to the agent that produced the
findings). They hold the diff, the rules and the reasoning that produced the claim; a debate between
them is the only kind whose verdict can close a finding.

Resumption is not reliable. Verified failure 2026-09-09: `SendMessage` to all four Phase B agents
produced **no response in ~15 minutes**; the round was re-run with fresh challengers that lacked
Phase B context, and two original responses then arrived *after* the report was committed — one of
them overturning an adjudicated `false-positive`. So the channel is a three-step ladder, and the
run never blocks on it.

### 1. Resume the original lenses

Send every lens the debate prompt and **stamp the deadline in the same step**:

```bash
date -u +%s > "$WORK/debate-dispatch-epoch"
echo $(( $(cat "$WORK/debate-dispatch-epoch") + 360 )) > "$WORK/debate-deadline-epoch"
```

### 2. Bounded wait — **6 minutes**, per agent, from that stamp

```bash
# a lens that has not answered by this point is silent for this round
[ "$(date -u +%s)" -ge "$(cat "$WORK/debate-deadline-epoch")" ] && echo "deadline passed"
```

**Why 6 minutes.** A resumed lens re-reads a diff already capped at 1500 lines that it still holds in
context; its Phase B pass over the same inputs returned in ~3 minutes. Six is double that, which is
generous for a live agent and short enough that a full fresh-challenger round still fits inside the
wall clock a 15-minute stall already burned. The wait is **per agent, not per round** — findings
whose own lenses answered are adjudicated on those answers; a single silent lens does not hold the
run.

Do no writes while waiting. Do not poll with `sleep` in a loop; do other read-only Phase C work
(assembling the per-finding position tables) and re-check the deadline.

### 3. Fall back to fresh challengers — for the silent lenses only

For every finding still lacking a non-origin position at the deadline, dispatch a **fresh** agent,
and give it what the resumed lens would have had:

- the finding record verbatim (`rule_id`, `claim`, `failure_scenario`, `file`, `severity`),
- the **reviewed diff** for that work item, and the named changed files,
- the in-scope rules, `known-non-issues.md` entries and the repo's `CLAUDE.md` for that work item.

A fresh challenger dispatched without the diff is not a challenger; it is an opinion.

**A late response is still evidence.** If an original lens answers after the deadline and before the
report is committed, its position is added and the finding is re-adjudicated. If it answers after the
commit, correct the report in place — as run `2026-09-09-1240` did.

## `debate_context` — the field that carries the ladder

Every finding leaving Phase C carries exactly one:

| `debate_context` | Means | Set when |
|---|---|---|
| `full` | every non-origin position came from an **original Phase B lens**, and there was at least one | resumption worked |
| `fresh` | **at least one** position came from a fresh challenger | the fallback fired for this finding |
| `none` | the finding got **no** non-origin position at all | both steps produced nothing |

It is per **finding**, not per run or per repo: in the same run one finding can be `full` and its
neighbour `fresh`. It is mandatory in the Phase C output, is echoed unchanged by Phase D, and is
written to `ledger/findings.jsonl` — the floor below cannot be lost between phases because every
phase carries the field that sets it.

### Verdict floor — a fresh challenger cannot close a finding

> **If a finding's `debate_context` is `fresh` or `none`, its verdict floor is `needs-human`: the
> adjudicator may return `real` or `needs-human`, and `false-positive` is not available to it.** A
> challenger dispatched without Phase B context may lower confidence in a finding; it may never
> close one.

### `known-non-issues.md` gate

> **A `known-non-issues.md` entry requires a full-context debate.** An entry may be appended only for
> a finding whose `debate_context` is `full`. If any position came from a fresh challenger, or the
> finding went undebated, **no entry is written — ever, regardless of verdict**. No full-context
> debate, no dismissal.

The two are belt and braces on purpose: the floor makes `false-positive` unreachable, and the gate
blocks the write even if a verdict reaches it another way. A wrong entry suppresses a real finding on
every future run, permanently and invisibly — it is the most expensive single write in the pipeline.

## Round structure

One round. Each debater receives:

- its own findings for the work item (resumed lenses only),
- the other agents' findings for the same work item,
- the same diff and file context Phase B had.

Each must, for **every** finding not its own, return exactly one of:

| Response | Meaning | Requires |
|---|---|---|
| `concur` | the finding is real as stated | — |
| `rebut` | the finding is wrong | a concrete counter-argument: the code path, guard or call site that makes it not fire |
| `refine` | real, but the claim or severity is wrong | the corrected claim and/or severity |
| `abstain` | outside this lens's competence | — |

And for **its own** findings, on seeing the rebuttals: `hold` or `concede`.

## Rules

- **Spot-check a citation before acting on it.** A cited file, guide or line number is an assertion,
  not a fact — verify it exists on `origin/<branch>` (`git show origin/<branch>:<path>`) before it
  changes an outcome. Real case 2026-09-08: a concurrence cited two migration guides that exist only
  in an unmerged sibling worktree.
- **A rebuttal must cite something.** "I don't think that's an issue" is not a rebuttal; it is an
  abstain. A rebuttal without a named code path or guard is discarded and treated as `abstain`.
- **A counting rebuttal must state its population** — see the next section. This is the same rule as
  "must cite something", applied to arithmetic.
- **Dissent is preserved, never averaged.** The output carries every position. Phase D reads the
  disagreement; it does not receive a score.
- **Conceding is cheap and expected.** An agent that concedes a wrong finding costs nothing; an agent
  that defends one costs a false-positive MR.
- No second round. If the debaters still disagree after one round, that *is* the signal — Phase D
  reads a contested finding as a candidate for `needs-human`.

## Counting rebuttals must state their population

> **A rebuttal that argues from a ratio, a base rate or a frequency MUST state the population it
> measured — what was counted, and over what set — in a `population` field beside the argument. A
> count with no stated population is not a rebuttal; it is discarded and treated as `abstain`.**

The adjudicator then checks that the stated population is the class the finding actually claims
(`references/adjudication.md`). Getting the reference class wrong is the easiest way to produce a
number that is arithmetically correct and argumentatively worthless.

**Worked example — run `2026-09-09-1240`, the case this rule exists for.** The finding: two OAuth
return keys (`returnSuccessTitle`, `returnFailedTitle`) were added to `de.json` with no `…Message`
sibling, against the convention for action-outcome keys.

- The rebuttal counted **all 158 `*Title` keys** in the file, found **9** with a `*Message` sibling,
  and called the pairing a **6 % oddity** — no population stated, only the ratio.
- That population is dominated by **labels** (`maklerSign.cardTitle`, `bvs.calculator.isCharterTitle`,
  `claim.deleteClaimTitle`) which never had body text and never could.
- The class the finding claims is action-outcome keys: `*(Success|Failed|Failure|Error)*Title`. Over
  **that** population — **12 keys** — **9 have a `Message`/`Description` sibling**. The rebuttal's own
  9 pairs *are* that class: its count confirmed the convention it set out to refute.
- Correct handling: rebuttal **rejected**, finding **stands** (and was then ruled `needs-human` on its
  own merits, because the consuming template lives in another repo). Rejecting a rebuttal is not the
  same as confirming a finding.

## Output contract

```json
{
  "work_item": "bpp-backend/development/BRO-1234",
  "findings": [
    {
      "fingerprint_input": { "repo": "…", "branch": "…", "file": "…", "rule_id": "…", "claim": "…" },
      "origin": "r1",
      "debate_context": "full",
      "positions": [
        { "agent": "r2", "agent_kind": "original", "response": "concur" },
        {
          "agent": "r3",
          "agent_kind": "original",
          "response": "rebut",
          "argument": "ContractStateCheckerUtil.ValidateContractNotNullOrThrow at line 190 already throws on null, so the dereference at 214 is unreachable.",
          "population": null
        }
      ],
      "origin_final": "concede",
      "consensus": "disputed"
    }
  ]
}
```

- `agent_kind` ∈ `original` | `fresh` on **every** position. `debate_context` is derived from them
  mechanically: any `fresh` → `fresh`; no non-origin position → `none`; otherwise `full`. If the two
  disagree, the positions win and `debate_context` was computed wrong.
- `population` is **required** on any `rebut` or `refine` whose argument contains a count, ratio or
  rate, and `null` otherwise. It states what was counted and over what set, e.g.
  `"12 keys matching *(Success|Failed|Failure|Error)*Title in de.json"`.
- `consensus` ∈ `agreed` (origin holds, no unrebutted rebuttal) | `withdrawn` (origin conceded) |
  `disputed` (origin holds against a cited rebuttal) | `refined` (claim or severity changed).

`withdrawn` findings still reach the ledger as `false-positive`, so the same claim is not
re-generated and re-debated tomorrow — **but only when `debate_context` is `full`**. A `withdrawn`
finding whose concession was extracted by a fresh challenger is floored at `needs-human` like any
other; a context-less agent talking an origin lens out of its own finding is exactly the failure the
floor exists to catch.
