# Phase E — Act

## Under `--dry-run`

**Nothing is written anywhere.** No branch, no push, no MR, no commit to `bpp-audit-reports`, no
ledger write. The report is printed to the terminal and to
`$HOME/.local/state/bpp-daily-audit/dry-run-$RUN_ID.md`. A dry run that opens an MR is a bug.

## `targeted-mr`

Model **Opus 5**, effort **high** — it writes code that lands on a real branch.

```bash
BRANCH="audit/$(date +%Y-%m-%d)-${REPO}-${SLUG}"
git -C "$LOCAL" fetch --quiet origin
git -C "$LOCAL" worktree add "$WORK/wt-$REPO" -b "$BRANCH" "origin/$TARGET_BRANCH"
```

Use a **worktree**, never the user's working tree — the user may be mid-task in that checkout. Remove
the worktree when done (`git worktree remove`).

`TARGET_BRANCH` is the branch the bug lives on: `development`, `staging` or `main`.

### Before pushing

Run the repo's unit tests when the project builds cheaply (`dotnet test` on the unit test project,
`npm test` for a UI repo). Record the outcome honestly in the MR description **including "not run"
and including a failure**. Never claim a test passed that was not run. If the tests fail because of
the patch, do not open the MR — escalate the finding with the failure output.

### MR

| Field | Value |
|---|---|
| Source | `audit/<YYYY-MM-DD>-<repo>-<slug>` |
| Target | the branch the bug is on |
| Draft | **no** |
| Title | `AUDIT-BOT: <summary> (BRO-xxxx)` — omit the key for unkeyed findings |
| Label | `audit-bot` |
| Reviewer | `apittrich` |

```bash
glab api --method POST "/projects/${enc}/merge_requests" \
  -f source_branch="$BRANCH" -f target_branch="$TARGET_BRANCH" \
  -f title="$TITLE" -f labels="audit-bot" -f description="$DESC" \
  -f reviewer_ids="$APITTRICH_ID"
```

### Description template

```markdown
### Finding
<claim>

**Failure scenario:** <concrete inputs -> wrong result>

**Lens:** <rule_id> · **Severity:** <high|medium|low> · **Debate:** <agreed|refined>
<the rebuttal and how it was settled, if the finding was contested>

### Fix
<what this MR changes and why it is the smallest change that fixes it>

### Verification
Unit tests: <passed | failed | not run — and why>
Dynamic verification: <confirmed on development | not requested | downgraded, cap reached>

### Provenance
Run `<RUN_ID>` · report: <link to the report file in bpp-audit-reports> · ticket: <BRO-xxxx>
Opened automatically by the `bpp-daily-audit` skill. Never auto-merged — review as normal.
```

### Back-merge checklist — `staging` and `main` targets only

A fix that lands on `staging` or `main` and not on `development` is silently reverted by the next
promotion. Append to the description, **mandatory**:

```markdown
### ⚠ Back-merge required
This MR targets `<staging|main>`. After merge, the same fix MUST reach `development`:
- [ ] cherry-picked or back-merged into `development`
- [ ] verified present on `development` (a clean auto-merge is not proof — read the file)
```

## `escalate` / `needs-human`

Write `escalations/<YYYY-MM-DD-HHMM>-<repo>-<slug>.md`:

```markdown
# <claim>

**Run:** <RUN_ID> · **Repo:** <repo> · **Branch:** <branch> · **Ticket:** <BRO-xxxx>
**Severity:** <…> · **Lens:** <rule_id> · **Debate:** <consensus>

## Failure scenario
…

## Why this is not a targeted MR
<which escalate-regardless rule applies, or why the debate could not settle it>

## What it needs
<the concrete follow-up: an endpoint migration guide, a bpp-shared bump + fleet pin, a migration,
a cherry-pick to development, a human decision on X>

## Debate record
<positions, verbatim, including the rebuttals>
```

## `false-positive` → append to known-non-issues

Every finding ruled `false-positive` is appended to `known-non-issues.md` in `bpp-audit-reports`,
in the file's own entry format, including **what would make it real again**. A dismissal that is not
recorded is a dismissal the audit will have to make again tomorrow, and the day after.

See `references/known-non-issues.md` for the full loop and for what must never be added.

## Ledger write

Every finding is appended to `ledger/findings.jsonl` with its outcome — `mr`, `escalated`,
`false-positive`, `needs-human` or `deferred` — regardless of what happened. A finding that reached a
model and is not in the ledger will be re-reviewed and re-reported tomorrow.

Advance `state.json` SHAs only for repo/branch pairs that completed. Then commit both the report and
the ledger to `bpp-audit-reports` `main` in a single commit:

```
audit(<RUN_ID>): N findings, M MRs, K escalations
```
