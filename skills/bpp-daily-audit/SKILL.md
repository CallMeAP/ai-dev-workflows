---
name: bpp-daily-audit
description: Use when running or debugging the daily cross-repo BPP audit — phrases like "run the daily audit", "bpp-daily-audit", "audit today's commits", "audit dev/staging/main", "why did the audit open this MR", "audit report for today", "daily renovate check", "nuget sweep". Audits commits landed on development/staging/main across the BPP/Brokernet fleet with debating reviewer agents, cross-checks them against the BRO Jira board, opens labelled fix MRs or escalates, and sweeps .NET repos for NuGet updates.
---

# BPP daily audit

## Overview

One unattended pass over everything that landed on `development`, `staging` and `main` across the
BPP / Brokernet fleet since the previous run. Reviewer agents debate each change for bugs, logic
errors and mis-implemented requirements against its BRO ticket. Agreed findings that a small
targeted change can fix become MRs; everything else is escalated. A separate phase sweeps .NET repos
for NuGet updates against `development` only.

**Design spec:** `bpp-backend/docs/superpowers/specs/2026-09-08-bpp-daily-audit-design.md`.
When this skill and the spec disagree, the spec is the intent — fix the skill.

**Every run commits a report, including zero-finding days.** A run that produces no report did not
happen.

## Invocation

```
/bpp-daily-audit                # live run
/bpp-daily-audit --dry-run      # full pipeline, NO MRs, NO repo commits, report printed locally
/bpp-daily-audit --repo=bpp-backend --dry-run    # single repo, for tuning
```

**`--dry-run` is the default until the rollout says otherwise.** See Rollout state below.

## Rollout state

| Step | State |
|---|---|
| 1. Skill written | done |
| 2. `bpp-audit-reports` repo + `audit-bot` group label created | **done 2026-09-08** — repo id 86222771, label inherited group-wide (verified on `servo-ui`) |
| 3. Dry-run tuning | **done 2026-09-08** — 2 runs: single-repo (`bpp-backend`) and fleet (32 repos, 4 active). 11 findings, 2 false positives killed by debate. 8 skill defects found and fixed. Still unexercised: the Jira status-change sweep, the caps (never fired), and a fleet-wide NuGet sweep. |
| 4. Supervised live run | **next** — would open 2 deferred MRs (bpp-stella migration guide, bpp-stella-ui stale Dockerfile) |
| 5. `/sync-my-skills bpp-daily-audit` | **done 2026-09-08** — canonical + mirror |
| 6. systemd timer armed at 12:07 | pending |

Do not skip ahead. A live run before step 3 opens real MRs from untuned reviewer prompts.

## Prerequisites

- `glab` authenticated (`glab auth status`), `acli` authenticated (`acli jira auth status`), `jq`.
- A local checkout of `bpp-audit-reports` at `~/Entwicklung/bpp/bpp-audit-reports`.
- Local checkouts for any repo the NuGet sweep should cover (`dotnet restore` needs the private feed).

If `glab` or `acli` auth fails: abort, write a partial report, exit non-zero. Do not guess.

## Phases

Run in order. Each phase's detail lives in its reference file — read the file before executing that
phase, not before.

| Phase | What | Model | Reference |
|---|---|---|---|
| A | Discovery: repo map, branch probe, commit windows, Jira fetch, **rule load**, **ledger dedup** | none — bash/`glab`/`acli` | `references/discovery.md` |
| B | Review: 3 lenses per work item, parallel, driven by the fetched rules | Sonnet 5, medium | `references/reviewer-prompts.md` |
| C | Debate: cross-rebuttal of every finding — **resume the Phase B lenses, 6-minute bounded wait, fresh challengers only for the silent ones** | Sonnet 5, medium | `references/debate-protocol.md` |
| D | Adjudication: verdict + fixability | Opus 5, high | `references/adjudication.md` |
| E | Act: MR or escalation, ledger write | Opus 5, high (MR authoring only) | `references/act.md` |
| F | Report: commit to `bpp-audit-reports` | Haiku 4.5, low | `references/report-template.md` |
| G | NuGet sweep, `development` only | none + Opus 5 for the MR | `references/nuget-sweep.md` |

Known-non-issues loop (spans A, B, D, E): `references/known-non-issues.md`.

Ledger formats and fingerprinting: `references/ledger.md`.

Rule set — fetch, parse, scope filter, failure handling: `references/rules-fetch.md`.

Shared fleet standards (`.net/CLAUDE.md`, `angular/CLAUDE.md` from
`lipso/internal/agentic-coding-knowledge`) — fetch, normative scope, precedence against the repo's
own `CLAUDE.md`, degrade-don't-abort: `references/shared-standards-fetch.md`.

**Five inputs are read every run**, and each does a different job:

| Input | Where from | Question | Effect |
|---|---|---|---|
| `rules.md` | `bpp-audit-reports` | *what do we check for?* | **defines** the checklist — Phase B's lenses are driven by it |
| `common-issues.md` | `bpp-audit-reports` | *what keeps going wrong?* | **raises** sensitivity: a hunt list for R1 |
| `known-non-issues.md` | `bpp-audit-reports` | *what looks wrong but isn't?* | **lowers** it: engage the prior reasoning first |
| the audited repo's own `CLAUDE.md` | the repo, via git | *what did **this** repo write down?* | R3's per-repo conventions |
| `.net/CLAUDE.md`, `angular/CLAUDE.md` | `lipso/internal/agentic-coding-knowledge` | *what does the fleet expect of a .NET / Angular repo?* | fills the gap where a repo wrote nothing down |

Putting an entry in the wrong file inverts or loses its effect. **`rules.md` is the only one whose
absence aborts the run** — every other input degrades it and is reported.

**Precedence, strongest to weakest:** a specific `be-*` / `fe-*` rule → the audited repo's own
`CLAUDE.md` (`cross-claudemd-convention-violation`) → the shared standards
(`be|fe-shared-*-standard-violation`). **The repo's own file always wins over the shared one**, and
one violated line yields exactly one finding. Only the four paths `.net/CLAUDE.md`,
`angular/CLAUDE.md`, `bpp/repos.md` and `bpp/bpp-tag-and-release/SKILL.md` are fleet-normative;
**`personal-workflows/**` is excluded** — individual developers' setups, never a standard to audit
anyone against.

**`known-non-issues.md`** It is the audit's memory of what
it already got wrong. Phase A loads it, Phase B passes the relevant entries to the reviewers, Phase D
consults it before ruling a finding real, and Phase E appends to it on every `false-positive`
**whose debate was full-context** (`debate_context: full` — see non-negotiable 12).
Without that loop the audit re-raises the same dismissed finding forever; without the gate it
suppresses a real one forever. See `references/known-non-issues.md`.

## Caps (hard)

| Cap | Value | On hit |
|---|---|---|
| repos per run | 8 | remainder → `deferred`, first in next run's queue |
| debated findings per repo | 10 | remainder → `deferred` |
| work-item diff size | 1500 changed lines | flagged for manual review, never expanded |
| MRs created per run | 5 | remainder → `deferred` |
| files per auto-MR | 5 | above this it is an escalation, not an MR |
| dynamic verifications per run | 1 | further requests downgraded to static |
| NuGet sweep repos per run | 6 | remainder → `deferred` |
| NuGet MRs per run | 2 | separate budget; never consumes the code-fix MR cap |

**A cap defers work. A cap never silently drops a finding.** Every deferred item is named in the
report and queued first next run.

## Non-negotiables

1. **Mechanical work is never a subagent.** Repo discovery, compare calls, Jira fetch, dedup and
   ledger writes are bash. Dispatching an agent to run `git log` is the single most expensive
   mistake available here.
2. **Dedup runs before dispatch.** A fingerprint already recorded as `mr`, `escalated` or
   `false-positive` never reaches a model again.
3. **Reviewers get the work-item diff plus the named changed files. Never a repository.**
4. **The local stack is only ever started for a finding on `development`.** The stack is always on
   `development`; starting it against `staging`/`main` risks an EF migration mismatch. Max 1 per run.
5. **Never switch, stash or check out in a user working tree.** Read with
   `git -C <repo> show origin/<branch>:<path>` after a `fetch`.
6. **The ledger is not advanced for a repo whose scan failed.** A failure must be retried, not
   silently skipped forever.
7. **NuGet MRs target `development`. Always.** Never `staging`, never `main`.
8. **Bot MRs are opened, never merged.**
9. **Never open an MR without the duplicate pre-flight** (`references/act.md`) — search open, merged
   AND closed MRs by fingerprint first. A closed-unmerged MR is a human rejection: record `rejected`,
   never silently re-open it, and never leave it recorded as `mr` (that suppresses the finding
   forever).
10. **Every MR description ends with the finding fingerprint and `🤖 Generated with Claude Code`.**
   Without the fingerprint the next run cannot see the MR and will open a duplicate.
11. **Never skip the known-non-issues file.** Not loading it is not a neutral omission — it
   guarantees repeat false positives and trains the reader to ignore the report.
12. **A context-less challenger may never close a finding.** Every finding carries `debate_context`
   ∈ `full` | `fresh` | `none` from Phase C through Phase D into the ledger. `fresh` or `none`
   floors the verdict at `needs-human` — `false-positive` is unavailable — and **no
   `known-non-issues.md` entry may be written for it, ever**. A dismissal suppresses the claim on
   every future run; it requires a debate by the agents that actually read the code.
13. **A reviewer response is never silently dropped.** Lenses dispatched must equal parsed +
   recovered-from-prose + explicitly-empty. An unparseable response is re-asked once, then
   hand-extracted; if neither works, that work item is reported **unreviewed by that lens**, never
   clean.
14. **No rules, no review.** `rules.md` unreachable or parsing to zero rules aborts the run with a
   partial report. A rule-less run checks less while reporting the same shape — the one degradation
   nobody can see afterwards.

## Common mistakes

- **Trusting `jq '.commits | length'` to detect a missing branch** — `null | length` is `0` in jq, so
  a missing branch reads as "no new commits". Probe branches explicitly first (`references/discovery.md`).
- **Building the repo set from `project_index.md`** — its GitLab-only section is stale. The
  authoritative repo list is **`bpp/repos.md`** in the knowledge repo; the repo set is that list
  **unioned** with the GitLab group filter, because both drift (measured 2026-09-09: 5 repos only the
  list has, 3 only the group has — two of those three committed that same day). Never one alone.
  See `references/discovery.md` §A1.
- **Auditing `bpp-audit-reports`** — self-audit loop. It is on the always-exclude list.
- **Concluding "X was not changed" from a compare payload** — compare output is truncated on large
  ranges. Treat counts as a lower bound; read the raw file when it matters.
- **Advancing the ledger on a partial run** — only advance per repo/branch that actually completed.
- **Opening an MR for a DTO change** — DTO/API contract changes are on the escalate-regardless list
  (they need an endpoint migration guide and FE coordination). See `references/adjudication.md`.
- **Letting a debate consensus override the escalate-regardless list** — it cannot. The list wins.
- **Auditing the whole 268-ticket board** — the board is only a spec source and a status-change
  trigger, never an iteration target.
- **Editing an audit rule in this skill instead of in `rules.md`** — the rule set lives in
  `bpp-audit-reports/rules.md` and nowhere else. A rule written here is read by nobody at runtime,
  and the two copies drift until the report cites a rule the run never applied. Same for deleting
  one: retire it in `rules.md`.
- **Renaming a rule id to make it read better** — ids are part of the finding fingerprint. A rename
  re-opens every finding that rule ever produced, escalations and dismissals included.
- **Passing backend rules to a frontend repo's reviewer** — filter by `scope` first
  (`references/rules-fetch.md`); an off-scope rule yields silence or an invented finding. The same
  filter governs the shared standards: `.net/CLAUDE.md` never reaches a UI repo's reviewer,
  `angular/CLAUDE.md` never a .NET repo's.
- **Flagging a repo against the *shared* `CLAUDE.md` when its own file says otherwise** — the repo's
  own file wins, always. A shared-standard finding is valid only where the repo's file is silent.
  Both shared files are repo-provenanced copies (`.net/` is `bpp-backend`'s verbatim, `angular/` is
  `brokernet-cockpit-ui`'s and already one standard behind it), so they carry repo-specific facts
  that are not fleet standards — a connector repo is not deficient for having no `PROJECT.md`.
- **Quoting `personal-workflows/**` at anyone** — that tree is individual developers' own setups. A
  finding sourced from it flags someone for not following a convention they never agreed to.
- **Substituting fresh challengers and then adjudicating as if the debate were normal** — a fresh
  challenger has neither the diff-reading nor the rules the origin lens had. Verified 2026-09-09:
  resumed lenses returned nothing in ~15 minutes, fresh challengers replaced them, one produced a
  miscounted rebuttal, and a real finding was ruled `false-positive` **and written into
  `known-non-issues.md`** — which suppresses it on every future run. Mark the finding `fresh` and
  floor it at `needs-human` (`references/debate-protocol.md`).
- **Accepting a rebuttal's percentage without checking what it counted** — the same case: the
  challenger counted **all 158 `*Title` keys** in `de.json`, found 9 paired with a `*Message`, and
  called the convention a 6 % oddity. Over the class the finding actually claimed —
  `*(Success|Failed|Failure|Error)*Title`, **12 keys** — **9 of 12** are paired. Its own 9 pairs were
  that class. A rebuttal with no stated population, or the wrong one, is **rejected**; the finding
  then stands unrebutted, which is not the same as confirmed.
- **Treating an unparseable reviewer response as "no findings"** — two reviewers invented a
  `ReportFindings` tool that does not exist and returned prose (2026-09-09). Both were recovered by
  hand; a stricter parser would have dropped the medium-severity bpp-file escalation and reported the
  repo clean. Re-ask, then hand-extract, then report it unreviewed — never silently empty.

## Red flags — STOP

- About to open an MR while `--dry-run` is set → stop; dry-run writes nothing.
- About to start the local stack for a `staging` or `main` finding → stop; static only.
- About to bump `<BppSharedVersion>` in the NuGet sweep → stop; that belongs to `bpp-bump-shared-version`.
- About to auto-MR a major version bump → stop; report it, licences flip on majors.
- Run finished with no report written → stop; the report is the deliverable.
- About to open an MR without having searched `state=all` for the fingerprint → stop; check first.
- About to re-open an MR a human closed unmerged → stop; that is a rejection, not a gap.
- About to rule a finding `false-positive` without appending it to `known-non-issues.md` → stop; the
  dismissal is only useful if the next run inherits it.
- About to rule `false-positive`, or write a `known-non-issues.md` entry, for a finding whose
  `debate_context` is `fresh` or `none` → stop; the floor is `needs-human` and the file is gated.
- About to block the run waiting for resumed Phase B agents past the 6-minute deadline → stop; fall
  back to fresh challengers, and mark every finding they touch `fresh`.
- About to let a "only N of M, so it is not a convention" rebuttal change an outcome without reading
  its `population` → stop; an unstated or mismatched population is a rejected rebuttal.
- About to report a repo clean when one of its lenses returned prose you could not parse → stop; that
  is unreviewed, not clean.
- About to dismiss a finding *because* it appears in `known-non-issues.md`, without engaging its
  reasoning → stop; an entry is context, not a gag order.
- About to dispatch a reviewer with no rules loaded, or after a failed `rules.md` fetch → stop; abort
  and write the partial report. A rule-less run is not a lighter run, it is an unreported one.
- About to add a rule to this skill's text → stop; it belongs in `bpp-audit-reports/rules.md`.
- About to abort the run because a shared standards file was unreachable → stop; those degrade and
  are reported. Only `rules.md` aborts (`references/shared-standards-fetch.md` argues why).
- About to write to `agentic-coding-knowledge` → stop; that repo is read-only to the audit, and its
  checkout carries unrelated dirty files.
