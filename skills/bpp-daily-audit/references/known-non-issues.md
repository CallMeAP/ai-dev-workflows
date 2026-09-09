# The two memory files

`bpp-audit-reports` carries two lists the audit reads every run. They pull in **opposite directions**,
and putting an entry in the wrong one inverts its effect:

| File | Meaning | Effect on a reviewer |
|---|---|---|
| `common-issues.md` | *keeps going wrong* — recurring real defect patterns | **raises** sensitivity: hunt for it |
| `known-non-issues.md` | *looks wrong, isn't* — already ruled out | **lowers** sensitivity: engage the prior reasoning first |

Neither is the checklist. That is `rules.md` — the standing set of checks, read every run and the
only one of the three whose absence aborts the run (`references/rules-fetch.md`). A standing check
belongs there, a recurring defect here in `common-issues.md`, a dismissal in `known-non-issues.md`.

Both are loaded in Phase A. `common-issues.md` entries go to **R1** as an explicit hunt list (and to
R3 when the pattern is a convention). `known-non-issues.md` entries go to whichever lens raised the
original finding.

An entry graduates from a finding to `common-issues.md` when the same shape is confirmed in two or
more repos, or twice in one repo — Phase E proposes it, a human confirms it.

# The known-non-issues loop

`known-non-issues.md` lives at the root of `bpp-audit-reports`. It is the audit's memory of findings
it already raised that turned out not to be defects. Without it the audit re-raises the same
dismissed claim every day and the report stops being read.

## Phase A — load it

```bash
KNI=~/Entwicklung/bpp/bpp-audit-reports/known-non-issues.md
[ -f "$KNI" ] || echo "WARNING: known-non-issues.md missing — report this as a degradation"
```

A missing file is a **degradation**, not a silent skip: say so in the report.

## Phase B — pass the relevant entries to reviewers

Give each reviewer the entries whose **repo/scope matches the work item**, plus every entry in the
"Patterns, not single findings" section (those are repo-agnostic). Do not paste the whole file into
every prompt — it grows without bound, and irrelevant entries dilute the lens.

Tell reviewers plainly: *an entry is context, not a prohibition. If you believe a listed non-issue is
now real, raise it and say what changed.*

## Phase D — consult before ruling

Before returning `verdict: real`, check whether a matching entry exists. If it does, the adjudicator
must either:

- **engage it** — state what changed in the code or the ticket that makes the old reasoning no longer
  hold, and rule `real`; or
- **defer to it** — rule `false-positive`, and note in the report that a known non-issue recurred
  (useful signal: it means the reviewer prompt keeps producing it).

Never rule `real` by ignoring an entry, and never rule `false-positive` by citing an entry without
reading it.

## Phase E — append on every false positive

Every finding whose outcome is `false-positive` gets an entry appended, using the file's format:
rule_id heading, repo/scope, first-raised run and fingerprint, the claim, **why it is not an issue**
(with the citations the rebuttal used), and **what would make it real again**.

That last field matters most: an entry without it becomes a permanent blind spot.

Under `--dry-run`, nothing is appended — the same as every other write.

## A counter-risk is not a finding generator

Each `common-issues.md` entry names how its own fix can be applied wrongly. That counter-risk is
there so a reviewer recognises a *concrete* bad instance — not so every application of the fix gets
flagged.

Observed 2026-09-08: the `AsSplitQuery` counter-risk (split queries share no snapshot across
statements) produced a finding against five correct split-query fixes. It was rebutted — the trade-off
is inherent, documented, and accepted; the "inconsistent" value it can produce was already a normal
handled state; and the proposed transaction fix would have reinstated the 30 s timeout the commits
existed to remove.

**Rule:** report a counter-risk only when the specific instance shows concrete harm — an actually
order-dependent query with no `OrderBy`, not merely the presence of `.AsSplitQuery()`. A generic
trade-off belongs in `common-issues.md` once, never as a recurring per-repo finding.

## What must NOT go in the file

- A finding ruled `needs-human`. It is unresolved, not dismissed. Leave it as an open escalation; a
  pointer stub in the file is allowed only if it says explicitly that it is not yet a non-issue.
- A finding nobody actually adjudicated.
- A real defect somebody decided not to fix. That is accepted risk and belongs in the escalation
  record and the ticket, not in a list that suppresses future detection.
