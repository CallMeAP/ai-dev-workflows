# Phase E — Act

## Under `--dry-run`

**Nothing is written anywhere.** No branch, no push, no MR, no commit to `bpp-audit-reports`, no
ledger write. The report is printed to the terminal and to
`$HOME/.local/state/bpp-daily-audit/dry-run-$RUN_ID.md`. A dry run that opens an MR is a bug.

## Before opening ANY MR — the duplicate pre-flight

**Never create an MR without searching for one that already covers the finding.** Run all three
checks; any hit changes the outcome.

```bash
# 1. Is an MR already open, merged or closed for this finding?
#    The fingerprint is embedded in every audit MR description (see the template below).
glab api "/projects/${enc}/merge_requests?state=all&per_page=100" \
  | jq -r --arg fp "$FINGERPRINT" '.[] | select(.description | test($fp)) | "\(.iid)\t\(.state)\t\(.web_url)"'

# 2. Does a branch from a previous attempt still exist?
glab api "/projects/${enc}/repository/branches?search=audit%2F" | jq -r '.[].name'

# 3. Is the finding still real on the current branch head? Re-verify the claim.
git -C "$LOCAL" show "origin/${TARGET_BRANCH}:${FILE}"
```

| Existing MR state | What to do |
|---|---|
| **open** | Do **not** create a second one. Record outcome `mr` pointing at it and move on. |
| **merged** | The fix probably shipped. **Re-verify the finding against the current head** — if it is gone, record `fixed`; if it survived, this is a new finding and needs a new claim, not a re-open. |
| **closed, not merged** | **A human rejected it.** See below — this is the case that silently breaks the audit. |
| none | Proceed. |

### A closed-unmerged MR is a rejection, and must not be suppressed

Real case 2026-09-08: bpp-stella !133 was opened by this audit and **closed without merging**. The
ledger recorded outcome `mr`, and the dedup rule skips anything recorded as `mr` — so the finding
would have been suppressed forever despite never being fixed, and never re-surfaced for anyone.

When a finding's MR is closed unmerged:

1. Record outcome **`rejected`**, never leave it as `mr`.
2. Do **not** silently re-open an identical MR on the next run — that is how an audit becomes noise.
3. Surface it **once** as an escalation asking for the reason, then either add a
   `known-non-issues.md` entry (if it was wrong) or keep it as an open escalation (if it was right
   but declined). A rejection nobody recorded is indistinguishable from a fix.

## `targeted-mr`

Model **Opus 5**, effort **high** — it writes code that lands on a real branch.

```bash
BRANCH="audit/$(date +%Y-%m-%d)-${REPO}-${SLUG}"
git -C "$LOCAL" fetch --quiet origin
git -C "$LOCAL" worktree add "$WORK/wt-$REPO" -b "$BRANCH" "origin/$TARGET_BRANCH"
```

Use a **worktree**, never the user's working tree — the user may be mid-task in that checkout. Remove
the worktree when done (`git worktree remove`).

### Never run `git stash` in a user repository

Not `stash push`, not `stash pop`, not "just for a moment". A worktree removes the need entirely.

Verified failure 2026-09-08 (bpp-stella): `git stash push -- <path>` matched **nothing**, because the
file being staged was untracked and `stash push` ignores untracked files without `-u`. It printed no
error. The subsequent `git stash pop` therefore popped **the user's own pre-existing stash**, which
conflicted; `git add <dir>` then staged the conflict markers and they were committed and pushed into
an MR.

Three failures compound here, and a worktree prevents all three:

1. `git stash push -- <pathspec>` silently no-ops on untracked paths.
2. `git stash pop` with no argument takes `stash@{0}` — whoever put it there.
3. `git add <directory>` happily stages conflict markers.

If a repo's working tree is dirty and you are not in a worktree, **stop** — do not stash, do not
checkout. Create the worktree.

**Before every commit, verify what is staged:** `git diff --cached --name-status` must list exactly
the files you intended, and `git grep -nE '^(<<<<<<<|>>>>>>>|=======)$' -- <staged paths>` must be
empty.

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

**The `audit-bot` label marks provenance, not authorship.** Any MR that fixes a finding this audit
raised carries it — including one a human wrote by hand after reading an escalation. The label is how
someone traces an MR back to the report that caused it; restricting it to pipeline-opened MRs would
break exactly the trail it exists to provide. When you open an MR for an audit finding yourself, add
the label and link the report.

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

**Lens:** <rule_id> · **Severity:** <high|medium|low> · **Debate:** <agreed|refined> (<full|fresh|none>)
<the rebuttal and how it was settled, if the finding was contested; if a rebuttal was rejected for an
unstated or mismatched population, say so and name both populations>

### Fix
<what this MR changes and why it is the smallest change that fixes it>

### Verification
Unit tests: <passed | failed | not run — and why>
Dynamic verification: <confirmed on development | not requested | downgraded, cap reached>

### Provenance
Run `<RUN_ID>` · report: <link to the report file in bpp-audit-reports> · ticket: <BRO-xxxx>
Finding fingerprint: `<fingerprint>`
Opened automatically by the `bpp-daily-audit` skill. Never auto-merged — review as normal.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

**Both trailing lines are mandatory.** The **fingerprint** is what the duplicate pre-flight searches
on — an MR without it is invisible to the next run, which will happily open a second one. The
**`🤖 Generated with Claude Code`** footer closes every audit MR description, hand-written ones
included.

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
**Severity:** <…> · **Lens:** <rule_id> · **Debate:** <consensus> (<full|fresh|none>)

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

## `false-positive` → append to known-non-issues, **behind the full-context gate**

```bash
[ "$DEBATE_CONTEXT" = "full" ] || { echo "no known-non-issues entry: debate_context=$DEBATE_CONTEXT"; }
```

Every finding ruled `false-positive` **whose `debate_context` is `full`** is appended to
`known-non-issues.md` in `bpp-audit-reports`, in the file's own entry format, including **what would
make it real again**. A dismissal that is not recorded is a dismissal the audit will have to make
again tomorrow, and the day after.

**A `fresh` or `none` debate never writes here**, and Phase D's verdict floor should already have
made `false-positive` unreachable for such a finding — if one arrives anyway, the verdict is wrong,
not the gate. See `references/known-non-issues.md` for the full loop and for what must never be
added, and `references/debate-protocol.md` for how `debate_context` is set.

## Ledger write

Every finding is appended to `ledger/findings.jsonl` with its outcome — `mr`, `escalated`,
`false-positive`, `needs-human` or `deferred` — regardless of what happened, and with its
**`debate_context`** copied through from Phase C. The field is what lets a later run, or a human
reading the ledger, tell whether a verdict was reached with or without the reviewing agents. A finding that reached a
model and is not in the ledger will be re-reviewed and re-reported tomorrow.

Advance `state.json` SHAs only for repo/branch pairs that completed. Then commit both the report and
the ledger to `bpp-audit-reports` `main` in a single commit:

```
audit(<RUN_ID>): N findings, M MRs, K escalations
```
