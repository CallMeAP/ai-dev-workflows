---
name: bpp-release-main
description: Use when releasing BPP from staging to main (production) step by step with the user — phrases like "release to main", "promote staging to main", "prod release", "main deployment", "bpp-release-main", "do the main release with me". Interactive companion to bpp-release-staging; asks for a go before every step, never writes to any DB, never runs DbMigrator, merges only after the user's go.
---

# BPP release: staging → main (interactive)

## Overview

The hands-on sibling of `bpp-release-staging`. It runs on the user's own machine (Ubuntu VM or a
Mac), in an interactive session, and walks the 11 steps below in order. It needs no DB secret: the
user runs DbMigrator and every SQL statement on prod by hand (DbMigrator with their own connection
string, SQL in pgAdmin). It does not use `~/.bpp-release.env` or the Keychain.

## Rules

- **Go per step.** Before each step, ask with `AskUserQuestion`: options "Go" (recommended),
  "Skip this step", "Stop here". Do nothing for that step until the answer is "Go". Skills this one
  calls keep their own preview/go on top of it.
- **No DB writes, ever.** This skill never runs DbMigrator, never runs SQL against any stage DB and
  never calls the staging skill's DB wrapper scripts. It prints SQL; the user runs it in pgAdmin
  (plain SQL, no psql meta-commands, the user adds `BEGIN`/`ROLLBACK`/`COMMIT` around it).
- **Merges are the user's.** Main MRs are merged only in step 7, after its go.
- Every API merge passes `should_remove_source_branch=false`; afterwards check that `staging` still
  exists in each repo.
- Git: worktrees for any code change; no amend/rebase/reset/stash/force. The only `reset --hard`
  is the one `bpp-checkout-shared-at-stage` does on the bpp-shared checkout by design.
- Paths use `$HOME` / `~`, never a hard-coded home directory.
- Print every SQL block and the ping in full in the chat. Never only point at a file.
- If a step fails: stop, show the error verbatim, ask how to go on. Never retry a write on your own.

## Steps

### Step 1. Pull development everywhere

Run `bpp-pull-all-dev`. Show its per-repo summary. bpp-shared or bpp-backend skipped → say so; the
user decides whether to go on (step 2 and step 9 read them).

### Step 2. bpp-shared at staging state + migration delta for main

Run `bpp-checkout-shared-at-stage` with stage `staging`. It moves the bpp-shared checkout to the
commit staging consumes and prints the migrations staging has that main lacks. Show the delta in
full and the restore command it prints. No migrations → say "no migrations for main" and step 3 only
covers the pre-deploy SQL.

Point out any migration that drops or renames a column, table or enum value: the old main code runs
against the new schema for a few minutes before the deploy.

### Step 3. Wait: the user migrates prod by hand

Tell the user to run DbMigrator from the bpp-shared checkout of step 2 against the main DB with their
own connection string. Then print the `pre-deploy` StageSql files for main (they run right after the
migration, before the merge):

```bash
git -C "$HOME/Entwicklung/bpp/bpp-backend" fetch origin main staging
mkdir -p "$HOME/.claude/state/bpp-release"
OUT="$HOME/.claude/state/bpp-release/main-sql.json"
bash "$HOME/.claude/skills/bpp-release-staging/lib/find-stage-sql.sh" \
  --repo "$HOME/Entwicklung/bpp/bpp-backend" --from origin/main --to origin/staging --stage main > "$OUT"
SQLDIR=$(jq -r '.[0].sql_file // empty' "$OUT"); [ -n "$SQLDIR" ] && SQLDIR=$(dirname "$SQLDIR")
```
 For each entry with `source: convention` and
`timing: pre-deploy`, print its path and the full content of its `sql_file`. Entries with
`source: diff` (SQL outside `StageSql/`, or a StageSql file with a bad header) are listed as "check
by hand, not part of the convention". Remove `$SQLDIR` afterwards (`rm -r "$SQLDIR"`, only when it is
non-empty).

Ask with `AskUserQuestion`: "Prod migrated and pre-deploy SQL run?" — options "Done" (recommended),
"Stop here". Go on only on "Done".

### Step 4. Create the main promotion MRs

Run `bpp-promote-dev-to-staging` in direction **staging → main** (title `Staging -> Main`, label
`main-deployment`). It shows its own preview and waits for its own go. It also prints the
`ui_configs` SQL; keep that block for step 9. Show its report and the open-MR list URL.

### Step 5. UI version check

For every UI promotion MR of step 4 (cockpit, kundenportal / stella-web, other `-ui` repos): the
`package.json` version on `staging` must be above `main` (`sort -V`), and the lock entries must
match it (the promote skill's post-bump check, re-run on `staging`). staging → main has no go-stella
app bump; the app version staging carries goes to main as is. Show a table `repo | staging | main |
lock ok`. Any mismatch → stop and ask.

### Step 6. Wait for green

Poll every main promotion MR, about every 2 min, bounded to 90 min:
pipeline `success` and `detailed_merge_status` = `mergeable`. Wait with `timeout 120 tail -f
/dev/null`, never a `cat /dev/zero` trick. A failed job → show the job log tail, ask whether to
retry it once. Duo `requested_changes` → the user must click Bypass in GitLab (no API); say which MR.
Show the final status table.

### Step 7. Merge the main MRs

Only after the go. For each MR, merge with the head SHA seen green in step 6:

```bash
glab api --method PUT "projects/$ENC/merge_requests/$IID/merge" \
  -f sha="$HEAD_SHA" -f should_remove_source_branch=false
glab api "projects/$ENC/repository/branches/staging" >/dev/null && echo "staging kept: $REPO"
```

A refused merge (SHA moved, not mergeable) → stop for that repo and report; never force.

### Step 8. Watch the main deploy + health

Each merged repo's `main` pipeline to success (bounded, same wait as step 6). Then run
`bpp-go-health` for `main`. Report failed pipelines and unhealthy services; the user decides.

### Step 9. Print ui_configs + manual SQL for main

Print, in full, for the user to run in pgAdmin on the main DB:

1. The `ui_configs` statements for `main` marked "changed by this promotion" from step 4
   (cockpit/kundenportal now that the images are live; `stella` only after the store release), then
   the read-only check `SELECT ui_type, version_number, updated_at FROM ui_configs WHERE
   is_soft_deleted = false ORDER BY ui_type;`.
2. The `post-deploy` StageSql files for main: rerun the `find-stage-sql.sh` call from step 3 and
   print each `source: convention`, `timing: post-deploy` entry's path and content. Remove the temp
   dir afterwards.

No SQL for main → say "no manual SQL for main". Ask the user to confirm when it ran.

### Step 10. Restore bpp-shared

Run `bpp-checkout-shared-at-stage` in **restore mode** (`git switch development && git pull` on the
bpp-shared checkout, with its own guards). Show the resulting HEAD.

### Step 11. Henry ping

Write the ping body to `~/.claude/state/bpp-release/main-ping.txt` (released repos + MR links,
versions, go-stella app version for App Store + Play Store, the `stella` `ui_configs` statement still
to run after the store release, anything skipped or open). Then print it:

```bash
bash "$HOME/.claude/skills/bpp-release-staging/lib/henry-ping.sh" info "BPP main release" \
  "$HOME/.claude/state/bpp-release/main-ping.txt"
```

Copy the whole printed block into the final chat message. TODO: post to the Henry Teams channel once
it exists (same TODO as in `bpp-release-staging`).
