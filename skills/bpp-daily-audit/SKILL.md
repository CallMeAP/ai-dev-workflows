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
| 3. Dry-run tuning | **partially done 2026-09-08** — single-repo run on `bpp-backend` (2 real findings, 1 needs-human, 1 false positive killed by debate). Fleet discovery, `repos.md` cross-check, status-change sweep and ledger dedup still unexercised. |
| 4. Supervised live run | pending |
| 5. `/sync-my-skills bpp-daily-audit` | pending |
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
| A | Discovery: repo map, branch probe, commit windows, Jira fetch, **ledger dedup** | none — bash/`glab`/`acli` | `references/discovery.md` |
| B | Review: 3 lenses per work item, parallel | Sonnet 5, medium | `references/reviewer-prompts.md` |
| C | Debate: cross-rebuttal of every finding | Sonnet 5, medium | `references/debate-protocol.md` |
| D | Adjudication: verdict + fixability | Opus 5, high | `references/adjudication.md` |
| E | Act: MR or escalation, ledger write | Opus 5, high (MR authoring only) | `references/act.md` |
| F | Report: commit to `bpp-audit-reports` | Haiku 4.5, low | `references/report-template.md` |
| G | NuGet sweep, `development` only | none + Opus 5 for the MR | `references/nuget-sweep.md` |

Known-non-issues loop (spans A, B, D, E): `references/known-non-issues.md`.

Ledger formats and fingerprinting: `references/ledger.md`.

**Two memory files in `bpp-audit-reports` are read every run**, and they pull in opposite directions:
`common-issues.md` (patterns that *keep going wrong* — a hunt list for R1, raising sensitivity) and
`known-non-issues.md` (things that *look wrong but aren't* — lowering it). Putting an entry in the
wrong file inverts its effect.

**`known-non-issues.md`** It is the audit's memory of what
it already got wrong. Phase A loads it, Phase B passes the relevant entries to the reviewers, Phase D
consults it before ruling a finding real, and Phase E appends to it on every `false-positive`.
Without that loop the audit re-raises the same dismissed finding forever. See
`references/known-non-issues.md`.

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
9. **Never skip the known-non-issues file.** Not loading it is not a neutral omission — it
   guarantees repeat false positives and trains the reader to ignore the report.

## Common mistakes

- **Trusting `jq '.commits | length'` to detect a missing branch** — `null | length` is `0` in jq, so
  a missing branch reads as "no new commits". Probe branches explicitly first (`references/discovery.md`).
- **Building the repo set from `project_index.md`** — its GitLab-only section is stale. Discovery is
  GitLab-side plus the mandatory `bpp/repos.md` cross-check.
- **Auditing `bpp-audit-reports`** — self-audit loop. It is on the always-exclude list.
- **Concluding "X was not changed" from a compare payload** — compare output is truncated on large
  ranges. Treat counts as a lower bound; read the raw file when it matters.
- **Advancing the ledger on a partial run** — only advance per repo/branch that actually completed.
- **Opening an MR for a DTO change** — DTO/API contract changes are on the escalate-regardless list
  (they need an endpoint migration guide and FE coordination). See `references/adjudication.md`.
- **Letting a debate consensus override the escalate-regardless list** — it cannot. The list wins.
- **Auditing the whole 268-ticket board** — the board is only a spec source and a status-change
  trigger, never an iteration target.

## Red flags — STOP

- About to open an MR while `--dry-run` is set → stop; dry-run writes nothing.
- About to start the local stack for a `staging` or `main` finding → stop; static only.
- About to bump `<BppSharedVersion>` in the NuGet sweep → stop; that belongs to `bpp-bump-shared-version`.
- About to auto-MR a major version bump → stop; report it, licences flip on majors.
- Run finished with no report written → stop; the report is the deliverable.
- About to rule a finding `false-positive` without appending it to `known-non-issues.md` → stop; the
  dismissal is only useful if the next run inherits it.
- About to dismiss a finding *because* it appears in `known-non-issues.md`, without engaging its
  reasoning → stop; an entry is context, not a gag order.
