---
name: bpp-release-staging
description: Use when the BPP fleet must be released from development to staging without a human — phrases like "release to staging", "run the staging release", "autonomous staging release", "henry release", "bpp release dry run", "resume the halted release", "/bpp-release-staging". Runs the saved workflow (pull, shared state, DB migrations on local/dev/staging, shared bump, promotion MRs, wait green, merge, deploy watch, ui_configs, stage SQL, Henry ping, cleanup) with critic agents between phases; halts and pings on anything risky. For staging → main use bpp-release-main.
---

# bpp-release-staging

## Overview

Releases every BPP repo from `development` to `staging`, start to finish, with no human in the loop.
Built for the 24/7 Mac mini ("Henry", Keychain secrets) and the user's Ubuntu VM (env-file secrets).
The same skill runs on both; only the secret backend differs (see Secrets setup).

The work is a saved workflow, `workflow.js` in this folder. Each phase is one worker agent; 2 critic
agents (3 for Shared state, Staging migrate, Merge, Manual SQL) check its result before the next phase
starts. Any critic `block`, or a worker that reports `halt` / not `ok`, halts the run.

Phases, in order:

| # | Phase | What happens |
|---|---|---|
| 0 | Skill update | switch `BPP_RELEASE_SKILL_UPDATE` (`on`, `off` or `report`, default `on`). `on`: every run pulls + installs the skills mirror; only changed skills this run uses get a critic diff review first. `off`: no pull, no install, the report says "skill update off". `report`: pulls into a temp clone and lists which used skills differ, never installs |
| 1 | Preflight | glab auth + Maintainer rights, dotnet, psql, secrets readable (with a timeout), disk, lock, previous state; health + deploy baseline: halt **before any write** if a release repo's endpoint is unhealthy or its last staging deploy failed (`lib/health-map.sh`) |
| 2 | Pull | `bpp-pull-all-dev`; halt if bpp-shared or bpp-backend were skipped |
| 3 | Shared state | newest `BPP.Shared.NET` package → its bpp-shared commit; record the pre-move SHA, then checkout; pending migrations for dev + staging; record each repo's `development` head |
| 4 | Local migrate | `lib/migrate-stage.sh local` |
| 5 | Dev migrate | `lib/migrate-stage.sh development`, then new bpp-backend StageSql files whose header lists `development` (pre-deploy, then post-deploy) via `lib/run-stage-sql.sh development` |
| 5b | Bump shared | `bpp-bump-shared-version` to exactly the phase 3 package |
| 6 | Promote | `bpp-promote-dev-to-staging` dev→staging; the go is given after critics approve the preview; restart guard |
| 7 | UI versions | package.json version on `development` > `staging` (and > `main`) in every UI promotion MR |
| 8 | Wait green | every promotion MR: pipeline success + `mergeable`; one retry; bounded wait; Duo path; a `skipped` pipeline after `[skip ci]` gets one empty CI commit on `development` |
| 9 | Staging migrate | `lib/migrate-stage.sh staging`, then new bpp-backend `*.pre-deploy.sql` via `lib/run-stage-sql.sh staging` |
| 10 | Merge | merge with `sha=<head from phase 3>` and `should_remove_source_branch=false`; check `development` still exists |
| 11 | Watch deploy | `staging` pipelines + deploy jobs green, then `bpp-go-health` vs the Preflight baseline: polls each new failure until healthy or fail_since + 15 min, then halts; never done while one is still unhealthy; baseline failures are listed as known |
| 12 | ui_configs | `cockpit` + `kundenportal` statements changed by this promotion; never `stella` |
| 13 | Manual SQL | `lib/find-stage-sql.sh`: bpp-backend post-deploy files run; StageSql files outside bpp-backend and all other SQL are fallback, run only when all critics approve |
| 14 | Henry ping | released MRs + versions, go-stella store version, the `stella` ui_configs statement for later |
| 15 | Report | final summary; state marked done |
| 16 | Cleanup | restore bpp-shared by SHA (HEAD ≠ pre-move SHA → `git switch development && git pull --ff-only`, verify HEAD = `origin/development`), then `bpp-cleanup-merged-worktrees` |

Scripts in `lib/` (bash 3.2-safe, macOS + Linux):

- `secret-env.sh` — `get_secret <development|staging>`; only the wrappers below call it.
- `migrate-stage.sh <local|development|staging>` — bpp-shared DbMigrator with the injected connection string.
- `run-stage-sql.sh [--readonly] <development|staging> (<file.sql> | --check | --query 'SQL')` — psql in one transaction.
- `find-stage-sql.sh` — SQL candidates (convention / diff / MR description) as JSON.
- `health-map.sh` — `hosts <repo>=<dir|compose file>…` (Traefik hosts, network aliases, container_name and
  hostname from `origin/staging`'s compose file; a downloaded compose file for repos without a clone),
  `map <statuses.json> <hosts.tsv> <repos>` (Gatus endpoint ↔ repo, release_unhealthy / known /
  unmapped), `diff <baseline map> <now map>` (new vs known unhealthy). Gatus JSON comes from
  `bpp-go-health/health.sh json`.
- `state.sh` — run state and lock: `set-phase <spec label>` (`0` … `5b` … `16`), `set-heads <json>`,
  `set-package <version>`, `set-baseline <json>`, `set-pre-move-sha <sha>`, `add-sql` / `has-sql <stage> <file-id>`, `get [key]`.
  `henry-ping.sh <info|blocker> <title> <body>` — prints the ping block.

## Rules

These change the standing rules **only while this skill runs**. Everywhere else the old rules hold
(no DB writes, merges are the user's).

- The run may write to the **development** and **staging** DBs, and only through
  `lib/migrate-stage.sh` and `lib/run-stage-sql.sh`. Never `main`: no script accepts it.
- The run may merge the **staging** promotion MRs (phase 10), and in the Duo path push `staging`.
- Never print, cat, echo or log a secret. Never call `get_secret` directly. Never read
  `~/.bpp-release.env`. DB access only via the wrappers; their output is filtered for the password.
- Git: worktrees for repo changes; no amend, rebase, reset, stash or force. The one exception is the
  `git reset --hard` that `bpp-checkout-shared-at-stage` does on the bpp-shared checkout by design.
- Merge with `sha=<recorded head>` and `should_remove_source_branch=false`; a refused merge halts.
- Never merge a promotion MR that is red, conflicting or not yet computed.
- Never run SQL no critic looked at, or SQL whose `stages:` header does not list `staging`.
- Never run the `stella` ui_configs statement; it waits for the store release.
- Any critic `block` halts. All critics must approve.
- A halt always says where it stopped and what is already applied (e.g. "staging DB migrated, MRs not merged").

## How to run

Run from the root session as a workflow. `runId` is the start time, `yyyy-mm-dd-hhmm`
(the script does not read the clock).

Dry run first on every new machine, and after any change to this skill:

```
Workflow({scriptPath: "$HOME/.claude/skills/bpp-release-staging/workflow.js",
          args: {mode: "dry-run", runId: "2026-11-26-0900"}})
```

`dry-run` still does local git updates, because it needs current code: the pull (`bpp-pull-all-dev`),
the bpp-shared checkout and its restore, and the skills mirror pull + install. Only DB writes
(local/dev/staging migrate), GitLab writes (MR create/merge/close, push, the shared bump, the promote
go) and SQL are replaced by prints. Then the real run:

```
Workflow({scriptPath: "$HOME/.claude/skills/bpp-release-staging/workflow.js",
          args: {mode: "run", runId: "2026-11-26-0930"}})
```

It returns `{status: done|halted, phase, summary, uiConfigsSql, henryPing}`. Print `henryPing` and
`summary` to the user verbatim.

At install the workflow is also copied to `~/.claude/workflows/`:
`cp "$HOME/.claude/skills/bpp-release-staging/workflow.js" "$HOME/.claude/workflows/bpp-release-staging.js"`.

Tests for the `lib/` scripts and this file: `bash "$HOME/.claude/skills/bpp-release-staging/tests/run.sh"`.
Lint: `shellcheck -x "$HOME/.claude/skills/bpp-release-staging/lib/"*.sh` (`-x` follows the sourced files).

## Halt + resume

- State file: `~/.claude/state/bpp-release/state.json` (spec phase label, applied items, halt reason,
  heads, package, and `sql_applied`: every SQL file run per stage).
  Lock: `~/.claude/state/bpp-release/lock` (holds the runId; every phase refreshes it).
- Read it with `bash "$HOME/.claude/skills/bpp-release-staging/lib/state.sh" get`.
- On a halt the halt agent runs `state.sh halt <reason>`, `henry-ping.sh blocker …`, restores
  bpp-shared by SHA (only when HEAD differs from the recorded pre-move SHA; a dirty tree is reported,
  never stashed or forced) and runs `state.sh unlock <runId>`. The workflow returns `halted`.
- Rerun the workflow (new `runId`) to continue. A rerun starts again at phase 0 and re-checks every
  phase; there is no jump to the halted phase. Preflight archives the old state and reports when a
  human must decide first (pass `args.ack` once decided). Migrations are idempotent, open promotion
  MRs are reused and merged MRs are not merged again.
- SQL never runs twice: `state.sh new` keeps the `sql_applied` list of a run that did not finish, and
  phases 5, 9 and 13 skip every file `state.sh has-sql <stage> <file-id>` reports as applied.
- If `development` moved, or a new shared package / migration appeared since phase 3, the run halts;
  the rerun re-records heads and package in phase 3.
- A second run while a lock is fresh is refused (`state.sh lock` exit 7). A lock with a heartbeat older
  than 3 hours is taken over and reported as stale.

## Secrets setup

Two backends, one skill. `secret-env.sh` uses the Keychain on macOS and the env file elsewhere;
`BPP_RELEASE_SECRETS=keychain|envfile` overrides that. Values are full Npgsql connection strings for
`development` and `staging`. There is no `main` entry, on purpose.

Recommended: one DB role per stage with DDL + DML on the bpp schema only.

### Ubuntu VM (env file, the user's own machine)

Only on the user's VM. The user starts the run by hand there; the autonomy is the same as on the Mac mini.

1. Create the file empty with owner-only rights:

   ```bash
   (umask 077 && touch ~/.bpp-release.env)
   chmod 600 ~/.bpp-release.env
   ```

2. Fill it in an editor, never on the command line (that would put the password into shell history):

   ```bash
   nano ~/.bpp-release.env
   ```

   Content, exactly two lines, double quotes allowed:

   ```
   BPP_DB_DEVELOPMENT="Host=<host>;Port=5432;Database=<db>;Username=<user>;Password=<password>"
   BPP_DB_STAGING="Host=<host>;Port=5432;Database=<db>;Username=<user>;Password=<password>"
   ```

   No `BPP_DB_MAIN`. The file is read line by line and never `source`d, so nothing in it runs.

3. Check mode and owner. It must be `600` and your user, else the scripts refuse it (exit 4):

   ```bash
   stat -c '%a %U' ~/.bpp-release.env    # expect: 600 <your user>
   ```

4. Stop Claude from reading it. Add to `~/.claude/settings.json`:

   ```json
   {
     "permissions": {
       "deny": [
         "Read(~/.bpp-release.env)",
         "Bash(cat ~/.bpp-release.env*)"
       ]
     }
   }
   ```

   Merge into an existing `permissions.deny` list instead of replacing it.

5. Keep it outside git and outside synced folders (Dropbox, Nextcloud, the skills repo). Your home
   directory root is fine; do not copy it anywhere.

6. Test, read-only (prints only "connection OK, <n> migrations applied"):

   ```bash
   bash ~/.claude/skills/bpp-release-staging/lib/run-stage-sql.sh --readonly staging --check
   bash ~/.claude/skills/bpp-release-staging/lib/run-stage-sql.sh --readonly development --check
   ```

   Exit 3 = line missing, 4 = wrong mode or owner. Fix and rerun; never paste the file into a chat.

7. Turn the skill update off (`BPP_RELEASE_SKILL_UPDATE`: on|off|report, default on). Set it in
   `~/.claude/settings.json` under `"env"`. Merge it into the existing file; do not replace the file.
   If `"env"` already exists, add only the one key to it:

   ```json
   {
     "env": {
       "BPP_RELEASE_SKILL_UPDATE": "off"
     }
   }
   ```

   Why: the VM is where the skills are written. Phase 0 installs the mirror over
   `~/.claude/skills`, and that would overwrite unsynced local edits (work not yet pushed with
   `sync-my-skills`). With `off`, phase 0 skips the mirror pull and the install, and the report says
   "skill update off". Use `report` instead to only list which used skills differ from the mirror
   (temp clone, nothing installed). The Mac mini keeps `on` (the default; set nothing there).

   Claude Code reads `env` from settings.json itself and passes it to every session and every
   tool process it starts, however `claude` was launched. So it does not depend on `~/.bashrc`
   (whose interactive guard skips the rest of the file in non-interactive shells). Start a new
   session after the edit, then check:

   ```bash
   echo "${BPP_RELEASE_SKILL_UPDATE:-on}"    # expect: off
   ```

Another path: `BPP_RELEASE_ENV_FILE=/path/to/file` (same mode and owner rules).

### Mac mini (Keychain, "Henry")

1. As the macOS user that runs the job (not `root`; the Keychain is per user), create each entry with
   `security` pre-allowed so no "Allow access?" popup comes up. `-w` last with no value makes
   `security` prompt for it, so the password does not go into shell history:

   ```bash
   security add-generic-password -s bpp-db-development -a bpp -T /usr/bin/security -w
   security add-generic-password -s bpp-db-staging     -a bpp -T /usr/bin/security -w
   ```

2. Test, read-only:

   ```bash
   bash ~/.claude/skills/bpp-release-staging/lib/run-stage-sql.sh --readonly staging --check
   ```

3. Skill update: the Mac mini keeps `on` (the default). Do not set `BPP_RELEASE_SKILL_UPDATE` there;
   each run pulls and installs the mirror, so the Mac runs the published skills.

**Keychain and unattended runs (unverified on the Mac mini; check at install):**

- The first read of an entry by a program often shows an "Allow access?" popup. A job started by cron
  or a background service cannot click it, so the read fails or hangs. `-T /usr/bin/security` above
  pre-allows the reading tool.
- The login Keychain locks after a reboot or logout until someone logs in. While locked, no
  unattended job can read any entry. Set up auto-login for the job's user (or another way to keep
  the Keychain unlocked in the session the job runs in).
- `secret-env.sh` never waits for a popup: it calls `security` under a timeout
  (`BPP_KEYCHAIN_TIMEOUT`, default 10 s) and returns exit 5. Preflight treats that as a blocker
  (halt + Henry ping naming the Keychain cause), not a hang.
- Prove it: reboot once, then let cron start the preflight with nobody at the Mac. It must read both
  entries without a popup.

## Install checklist

Mac mini (the colleague who installs it ticks every line; the VM needs the lines not marked *Mac*):

- [ ] Ask the user for the run schedule; check the root session's cron entry starts this skill as a
      workflow (`Workflow({scriptPath: …, args: {mode: "run", runId}})`). *Mac*
- [ ] Homebrew `bash` 5, `coreutils` (`gtimeout`, aliased as `timeout`) and `gnu-sed` first on the
      job's `PATH`. *Mac*
- [ ] The macOS user that runs the job is a normal user, not `root` (Keychain is per user). *Mac*
- [ ] Keychain entries created with `-T /usr/bin/security`; auto-login after reboot set up. *Mac*
- [ ] `jq`, `psql`, `dotnet`, `glab` installed; `glab auth status` OK.
- [ ] dev and staging DBs reachable from this machine (VPN or tunnel?); both `--check` commands pass.
- [ ] Local Postgres with a `bpp` DB for phase 4 (`migrate-stage.sh local`).
- [ ] GitLab NuGet auth works for `dotnet run` of the bpp-shared DbMigrator.
- [ ] The glab identity is **Maintainer** in every promoted repo (`staging` merge/push needs it).
- [ ] The same `~/Entwicklung/bpp` checkouts exist (`bpp-project-index` → missing local checkouts).
- [ ] Saved workflow copied to `~/.claude/workflows/`; no hard-coded home paths in the skills used.
- [ ] `bash "$HOME/.claude/skills/bpp-release-staging/tests/run.sh"` passes.
- [ ] One `dry-run` → returns `done`.
- [ ] One unattended cron run after a reboot, nobody at the Mac. *Mac*

## TODOs

- **Henry channel:** `henry-ping.sh` only prints the ping. Replace it with a real post to the Henry
  Teams channel once it exists (the bpp-cypress `notify:message` API pipeline is a possible model).
- **Schedule:** the Mac mini's root session owns when runs start. At install, ask the user for the
  schedule and check the cron entry; nothing in this skill schedules itself.

## StageSql convention

Manual SQL that a stage needs besides EF migrations lives in
`bpp-backend/BPP.Backend.NET/BPP.Backend.NET.Sql/StageSql/` (README there).

- One file per change: `YYYY-MM-DD_<ticket>_<short-name>.<pre-deploy|post-deploy>.sql`,
  e.g. `2026-11-26_BRO-1234_fill-new-column.post-deploy.sql`.
- Header lines:

  ```sql
  -- stages: development,staging,main
  -- idempotent: yes
  ```

- Plain SQL, no `BEGIN`/`COMMIT` (`run-stage-sql.sh` wraps the file in one transaction and refuses
  files with their own transaction lines); safe to run twice.
- "New in this release" = files added between `staging` and `development`; no tracking table.
- Development: in phase 5, right after the dev migration, every new file whose `stages:` header
  lists `development` runs on the dev DB, pre-deploy first, then post-deploy (the dev code is already
  deployed).
- Staging: `pre-deploy` runs right after the staging migration, before the merge (phase 9);
  `post-deploy` after the deploy (phase 13). A file runs only when its `stages:` header lists `staging`.
- Only bpp-backend's `StageSql/` runs this way. A `StageSql/` file outside bpp-backend is never
  skipped silently: phase 13 treats it as a fallback candidate (critic-gated).
- A file recorded as applied on a stage (`state.sh has-sql`) is skipped there on every later run.
- SQL anywhere else (MR descriptions, `.sql` files outside `StageSql/`) is a fallback: it runs only
  when all critics approve, else halt + ping. Never scanned: `CypressSql/`, `SeedSql/`,
  `InsertSql/`, `SyncSql/`, `Migrations/`.
- `bpp-release-main` only prints the `main` files for the user to run in pgAdmin; it never runs them.
