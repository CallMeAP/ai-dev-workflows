# BPP release skills — design (2026-11-26)

## Intent

Make the dev → staging release of the BPP fleet run start to finish without a human, from a 24/7
Mac mini ("Henry"), and give the user a step-by-step companion for staging → main on their own
machine. Today every release is a manual chain: pull, migrate DBs by hand in pgAdmin/DbMigrator,
run `bpp-promote-dev-to-staging`, wait, merge, update `ui_configs`, ask devs for the store release.

## Goals

- `bpp-release-staging`: full autonomy for development → staging, every step checked by critic agents
  before the next one starts; halts and pings for help on anything risky.
- `bpp-release-main`: the same chain for staging → main, run interactively by the user, one explicit
  "go" per step; the skill never touches the prod DB.
- Reuse the existing skills; no copies of their logic.
- Mac-ready: runs on macOS (the Mac mini) and on this Linux machine.

## Non-goals

- Scheduling. The Mac mini's root session owns when runs start (TODO in the skill, see below).
- The real "Henry" Teams channel. For now the ping is printed to the terminal (TODO).
- Using `bpp-db-migrator` (not ready, see its README). The migrator is
  `bpp-shared/BPP.Shared.NET/BPP.Shared.NET.DbMigrator`.
- Store submission of the go-stella app.

## Anti-goals (failure even if it "works")

- A credential value appears in a log, transcript, file the agent reads, commit or MR.
- The staging DB is migrated from a bpp-shared state other than what development's consumers pin.
- Merging while any promotion MR is red, conflicting or un-computed.
- Running SQL that no critic looked at, or SQL meant for another stage.
- A silent partial release: halted runs must say exactly where they stopped and what is already applied.
- `bpp-release-main` writing to the prod DB or merging without the user's go.

## Constraints

- Standing rules change only inside these skills: `bpp-release-staging` may write to the dev and
  staging DBs (via the wrapper scripts only) and merge staging promotion MRs. Everywhere else the old
  rules hold (no DB writes, merges are the user's).
- Git: worktrees for any code change, no amend/rebase/reset/stash/force — except the one
  `git reset --hard` that `bpp-checkout-shared-at-stage` does by design on the bpp-shared checkout.
- Skills must not hard-code `/home/alex`; use `$HOME`. Scripts must be BSD/GNU-safe: no `sed -i`
  without a portable wrapper, no `grep -P`, no GNU-only `date`/`readlink -f`/`timeout` assumptions
  (macOS lacks `timeout` unless coreutils is installed — check and document).
- DbMigrator applies all pending migrations immediately (no plan mode); after it, services must be
  recreated (the merge/deploy does that on staging).
- Merging to staging = staging deploy. Migrations run before the merge, so they must work with the
  old code for a few minutes; a migration that drops/renames something the old code uses is a blocker.

## Approaches considered

- **A. Skill + saved workflow (picked).** `bpp-release-staging` = SKILL.md + a saved workflow script
  (one phase per step, critic agents between phases) calling existing skills, plus a small `lib/` of
  portable scripts. `bpp-release-main` = plain interactive skill. Reuses what works, critics are real
  gates, unattended and hands-on paths stay separate.
- B. One bash driver, agents only for conflict fixes and critics. Cheaper and more deterministic, but
  re-implements bumps and conflict handling from `bpp-promote-dev-to-staging`; drifts.
- C. Flags on `bpp-promote-dev-to-staging`. No new skill, but a 655-line skill grows a second job and
  unattended runs get mixed with interactive ones.

## Decisions (user)

| Topic | Decision |
|---|---|
| Autonomy | staging fully automatic; main = sibling skill with explicit go per step |
| Where main runs | user's machine; user runs DbMigrator on prod by hand with their own connection string |
| Main prep | `bpp-release-main` runs `bpp-checkout-shared-at-stage` (staging state) first |
| DB creds | one skill, two backends: macOS Keychain (Mac mini) or `~/.bpp-release.env` (user's Ubuntu VM); wrapper scripts inject them as env vars; agent never sees them |
| Trigger | Mac mini root session; TODO in skill: ask and check the schedule at install |
| Blockers | halt + "Henry" ping for help (printed for now, TODO) |
| Orchestration | ultracode / large workflow with critic agents on every stage |
| Manual SQL | `StageSql/` convention (below) runs automatically; fallback scans over every feature MR merged into `development` since the last staging release (SQL in MR descriptions, `.sql` files outside the convention) run only if all critics approve, else halt + ping |
| Convention rollout | part of this work: create `StageSql/` + README in bpp-backend; add a short note pointing to it in every bpp repo's README / CLAUDE.md; docs-only commits pushed straight to `development` |
| UI repos | check the package.json version is set correctly in every UI promotion MR |
| Build place | here, Mac-ready; runs on the user's Ubuntu VM (env-file backend) and the Mac mini (Keychain); install checklist ships with the skill |
| Service restarts | migrate first, then merge. New migrations only come with a new bpp-shared package, and the shared bump changes the `<BppSharedVersion>` line in every .NET consumer's `Directory.Build.props`, so every consumer gets a promotion MR and a redeploy (user, 2026-11-26). Guard: when migrations are pending, every DB-using consumer with a `staging` branch must have a promotion MR, else halt. The Java services (`bpp-mail`, `bpp-js-report-connector`) have no Postgres config (checked 2026-11-26) |
| Shared pins | staging run starts with `bpp-bump-shared-version`; it migrates from the bpp-shared commit of that newest package (`+<sha>`) |
| Duo blocks | critics judge Duo's findings: all agree non-issue → the agent closes the MR with a note why, merges `development` into `staging` in a worktree and pushes `staging`; confirmed critical or unclear → halt + Henry ping (Bypass needs a human) |
| Skill updates | switch `BPP_RELEASE_SKILL_UPDATE` (`on`, `off` or `report`, default `on`), read from the environment (on the VM set in `~/.claude/settings.json` under `"env"`, which Claude Code passes to every tool process). `on` (Mac mini): each run pulls the mirror (`agentic-coding-knowledge` main) and installs it; if any skill this run uses changed since the last run, critics review the diff first; any block → halt + ping. `off` (Ubuntu VM, `{"env": {"BPP_RELEASE_SKILL_UPDATE": "off"}}` merged into `~/.claude/settings.json`): no pull, no install, the report says "skill update off"; the VM is where skills are written, an install would overwrite unsynced local edits. `report`: pull into a temp clone, list which used skills differ, never install |
| Disk | after a finished staging run: `bpp-cleanup-merged-worktrees` (plan, then apply the REMOVE/LANDED rows it lists; never `--force`) |

## StageSql convention (approved)

- Folder: `bpp-backend/BPP.Backend.NET/BPP.Backend.NET.Sql/StageSql/`, with a README.
- One file per change: `YYYY-MM-DD_<ticket>_<short-name>.<pre-deploy|post-deploy>.sql`.
- Header lines: `-- stages: development,staging,main` (where it must run) and `-- idempotent: yes`.
- Plain SQL, no `BEGIN`/`COMMIT` (`run-stage-sql.sh` wraps the file in one transaction), safe to run twice.
- "New in this release" = files added between `staging` and `development` (compare), so no tracking table.
- `pre-deploy` runs right after the stage migration, before the merge; `post-deploy` after the deploy.
- Development: in phase 5, right after `migrate-stage.sh development`, the new files whose `stages:`
  header lists `development` run via `run-stage-sql.sh development`, pre-deploy first, then
  post-deploy (the dev code is already deployed).
- Only bpp-backend's `StageSql/` runs automatically. A `StageSql/` file outside bpp-backend is never
  skipped silently: it is a fallback candidate (critic-gated) in phase 13.
- Every file run is recorded per stage in the state file (`state.sh add-sql <stage> <file-id>`); a
  rerun skips recorded files, so SQL never runs twice.
- SQL anywhere else (MR description, other `.sql` files) is a fallback: critic-gated on staging.
- `bpp-release-main` prints the `main` files for the user to run in pgAdmin; it never runs them.

## Design

### Files

```
~/.claude/skills/bpp-release-staging/
  SKILL.md              # when to use, rules, phase list, halt policy, TODOs, install checklist
  workflow.js           # saved workflow (also copied to ~/.claude/workflows/ at install)
  lib/secret-env.sh     # get_secret <stage>: Keychain on macOS, ~/.bpp-release.env on Linux
  lib/migrate-stage.sh  # migrate-stage.sh <local|development|staging>: runs DbMigrator with injected conn string
  lib/run-stage-sql.sh  # run-stage-sql.sh <development|staging> <file.sql>: psql -v ON_ERROR_STOP=1 -1 -f
  lib/find-stage-sql.sh # lists SQL candidates per source (convention / description / diff) as JSON
  lib/state.sh          # read/write run state (spec phase label, done items, halt reason, heads,
                        #   package, SQL files applied per stage: set-heads/set-package/add-sql/has-sql)
  lib/henry-ping.sh     # prints the ping block; TODO: post to the Henry channel
~/.claude/skills/bpp-release-main/
  SKILL.md              # interactive, go per step, no DB writes
```

### Secrets

- Keychain service names: `bpp-db-development`, `bpp-db-staging` (value = full Npgsql connection
  string). Created once by the user at install (`security add-generic-password -s ... -a bpp -w`).
- `migrate-stage.sh` exports `ConnectionStrings__DefaultConnection` only inside its own process and
  `exec`s `dotnet run`. `run-stage-sql.sh` converts it to libpq env vars (`PGHOST`, `PGPASSWORD`, …) in
  its own process. Neither prints, logs or writes the value; both refuse any stage not in their list
  (`main` is not in the list).
- Output of both scripts is filtered for the password string before it reaches stdout (defence if
  Npgsql echoes the connection string in an error).
- Local stage uses bpp-shared DbMigrator's own `appsettings` default connection (local DB), no secret.
- **Two secret backends, one skill** (user, 2026-11-26): `secret-env.sh` uses Keychain on macOS and
  an env file on Linux; `BPP_RELEASE_SECRETS=keychain|envfile` overrides the OS choice.
  - env file: `~/.bpp-release.env`, lines `BPP_DB_DEVELOPMENT="<npgsql conn string>"` and
    `BPP_DB_STAGING="..."`; no `BPP_DB_MAIN`. Parsed line by line (never `source`d, so nothing in it
    executes); only the requested stage's line is read.
  - The script refuses the file unless mode is `600` and the owner is the current user, and halts
    with a clear message (never prints the content).
  - Setup steps for the user's Ubuntu VM go in SKILL.md: create with `umask 077`, fill in an editor
    (no password on the command line), check `stat`, add Claude `permissions.deny` for
    `Read(~/.bpp-release.env)` and `Bash(cat ~/.bpp-release.env*)`, keep it outside git and synced
    folders, test with `run-stage-sql.sh --readonly staging --check`.
  - Same autonomy on the VM as on the Mac mini; there the user starts the run by hand.
- Recommended at install: one DB role per stage with DDL + DML on the bpp schema only.
- **Keychain and unattended runs (unverified on the Mac mini; must be checked at install):**
  - The first read of a Keychain entry by a program often shows an "Allow access?" popup. A job
    started by cron or a background service cannot click it, so the read fails or hangs.
  - The login Keychain locks after a reboot or logout until someone logs in. While locked, an
    unattended job cannot read any entry.
  - So: create each entry with the reading tool pre-allowed (`security add-generic-password ... -T
    /usr/bin/security`), make sure the Mac mini logs in automatically after a reboot (or the Keychain
    is otherwise unlocked for the session the job runs in), and do one real cron run with nobody at
    the Mac.
  - `secret-env.sh` must never wait for a popup: it calls `security` with a timeout. A missing,
    denied or locked entry is a preflight blocker (halt + Henry ping naming the Keychain cause), not a
    hang.

### Phases (`bpp-release-staging`)

Each phase writes its result to the state file; a critic stage (2–3 independent critic agents,
majority must approve) reads that result before the next phase. Any critic "block" → halt.

0. **Skill update** — switch `BPP_RELEASE_SKILL_UPDATE` (on|off|report, default on). `on`: every run
   pulls the mirror's `main` and installs it; only when a skill this run uses changed does a critic
   review of its diff come first. `off`: no pull, no install. `report`: list differing skills only.
1. **Preflight** — glab auth + Maintainer rights, dotnet, psql, Keychain entries readable without a
   popup (names only, with a timeout), disk, no other release run holds the lock file, previous run
   state (resume or start fresh).
   **Health + deploy baseline, before any write (added 2026-11-27 after the dry run):** release repos
   = repos whose `development` head differs from `staging`, plus repos with an open promotion MR.
   For each: its hosts (`lib/health-map.sh hosts`, from `origin/staging`'s compose file: Traefik
   `Host()` rules plus network aliases, `container_name` and `hostname`, because Gatus checks some
   services by internal name, e.g. `staging-bpp-mail`; repos without a clone via the compose file
   downloaded with glab) and
   its latest staging deploy job (newest job named like `deploy` across the last 5 staging pipelines).
   Gatus staging statuses (`bpp-go-health/health.sh json`) are mapped to repos with
   `lib/health-map.sh map`. **Halt before any write** when an endpoint of a release repo is unhealthy
   or a release repo's latest staging deploy failed (reason: repo, endpoint, job id, first error line).
   Unhealthy endpoints of other repos are "known" and only reported; release repos without a Gatus
   endpoint are "unmapped" (report only). Promotion MRs with a `skipped` head pipeline are reported.
   The baseline is taken before any local write (before `state.sh new`, the state archive and
   `add-applied`); it is stored with `state.sh set-baseline` right after `state.sh new` (dry run:
   files only) for phase 11.
   Why: the 2026-11-27 dry run halted in phase 11 on the Agent Service, which had been down since
   before the run (bpp-agent staging deploy never succeeded: missing Portainer secret). A real run
   would have migrated staging and merged 27 MRs first, leaving ui_configs/StageSql undone.
2. **Pull** — `bpp-pull-all-dev`. Halt if bpp-shared or bpp-backend were skipped.
3. **Shared state** — resolve the newest `BPP.Shared.NET` package (the one `bpp-bump-shared-version`
   will pick) and its bpp-shared commit (`+<sha>`), check it out (same mechanism as
   `bpp-checkout-shared-at-stage`; the HEAD before the move is recorded first as `pre_move_sha`,
   `state.sh set-pre-move-sha`, dry run: a file) and list the migrations the dev and staging DBs lack (query
   `__EFMigrationsHistory` with `run-stage-sql.sh --readonly`). Critics check: every new migration is
   safe with the old staging code (no drop/rename of a column/table/enum value the old code uses).
4. **Local migrate** — `migrate-stage.sh local` from that bpp-shared state. Halt on failure.
5. **Dev migrate** — `migrate-stage.sh development`, then the new bpp-backend StageSql files whose
   `stages:` header lists `development` (pre-deploy first, then post-deploy; the dev code is already
   deployed) via `run-stage-sql.sh development`, skipping files recorded as applied on development.
   Halt on failure.
5b. **Bump shared** — `bpp-bump-shared-version` to exactly the package from phase 3 (halt if a newer
   one appeared). Runs after the dev migration on purpose: the bump commits redeploy every .NET
   consumer on dev, so they restart with the new schema. Halt if it reports skipped or unverified
   consumers.
6. **Promote** — `bpp-promote-dev-to-staging` (direction dev→staging). The "go" its preview asks for
   is given by the workflow after critics approve the preview. Includes bumps, conflict back-merge
   (its step 6b), migration-guide audit. Restart guard: when phase 3 found pending migrations, every
   .NET consumer with a `staging` branch must have a promotion MR; one missing → halt.
7. **UI versions** — for every UI promotion MR: package.json version on `development` > `staging`
   (and > `main`), lock entries match (the promote skill's post-bump check, re-run). Halt on mismatch.
8. **Wait green** — poll every promotion MR: pipeline success, `detailed_merge_status=mergeable`.
   One retry of a failed job; still red → halt. Bounded wait (e.g. 90 min) → halt on timeout.
   Duo `requested_changes` on a promotion MR → Duo path from the decisions table.
   A `skipped` head pipeline is not green. When the MR head commit message carries `[skip ci]` /
   `[ci skip]`, one empty commit "chore: run CI after a skipped commit" is pushed to that repo's
   `development` (worktree, no force; dry run prints it) and recorded in applied; still skipped → halt.
   (2026-11-27: 18 promotion MRs had skipped pipelines after a `[skip ci]` docs commit.)
9. **Staging migrate** — `migrate-stage.sh staging`, then the new bpp-backend `*.pre-deploy.sql`
   files for staging via `run-stage-sql.sh staging`, skipping files recorded as applied on staging.
   Only bpp-backend files run here. Halt on failure.
10. **Merge** — merge all staging promotion MRs with `sha=<head recorded in phase 3>` and
    `should_remove_source_branch=false` (see memory "Staging MRs: force_remove_source_branch"), then
    verify `development` still exists in each repo.
11. **Watch deploy** — each merged repo's `staging` pipeline and deploy job to success; then
    `bpp-go-health` for staging compared with the Preflight baseline (`lib/health-map.sh diff`). Halt
    on a failed pipeline/deploy, or on an endpoint that was healthy (or absent) at baseline and is
    still unhealthy once its `fail_since` + 15 minutes has passed: each new failure is polled every
    3 minutes until it is healthy or past that point (bounded); the phase never ends "done" while one
    is still unhealthy. Endpoints already unhealthy at baseline are listed as known, no halt.
    Wait green returns the `development` heads after any empty CI commit, so Merge uses them.
12. **ui_configs** — run the `staging` statements marked "changed by this promotion" for `cockpit`
    and `kundenportal` (the promote skill's SQL) through `run-stage-sql.sh staging`; then the read-only
    check SELECT. **Never `stella`** — it waits for the store release.
13. **Manual SQL** — `find-stage-sql.sh`:
    - convention: bpp-backend `StageSql/*.post-deploy.sql` added in this promotion whose `stages:`
      header lists staging → run (skipping files recorded as applied on staging).
    - any `StageSql/` file outside bpp-backend (pre- or post-deploy) → fallback candidate below,
      never skipped silently.
    - fallback, over every feature MR merged into `development` since the last staging release (all
      promoted repos): SQL blocks in MR descriptions and changed `.sql` files outside `StageSql/`
      (excluding `CypressSql/`, `SeedSql/`, `InsertSql/`, `SyncSql/` and migrations) → critics judge
      (right stage, idempotent, not destructive, not already applied); all approve → run; else halt +
      ping.
14. **Henry ping** — print: what was released (MR list, versions), the go-stella app version that now
    needs submitting/unlocking in App Store + Play Store, and the `stella` `ui_configs` statement to
    run after the store release.
15. **Report** — final summary; state file marked done.
16. **Cleanup** — restore bpp-shared by SHA (when HEAD differs from `pre_move_sha` and the tree is
    clean: `git switch development && git pull --ff-only`, then verify HEAD == `origin/development`;
    dirty or mismatch → halt, never stash/force; no move recorded → nothing to restore), then
    `bpp-cleanup-merged-worktrees` (plan, apply only its REMOVE/LANDED rows).

### Halt + ping

- `henry-ping.sh <severity> <title> <body>` prints a clearly delimited block. TODO in SKILL.md: post
  to the Henry Teams channel once it exists (the bpp-cypress `notify:message` API pipeline is a
  possible model).
- A halt records phase, reason, and what is already applied (e.g. "staging DB migrated, MRs not
  merged"). A rerun starts again at phase 0 and re-checks every phase; there is no jump to the
  halted phase. Preflight reads the old state and reports when a human must decide first.
- The state file records every SQL file applied per stage (`state.sh add-sql`); `state.sh new` keeps
  that list from a run that did not finish, and phases 5, 9 and 13 skip recorded files, so a rerun
  never runs SQL twice.

### `bpp-release-main`

Interactive, on the user's machine, AskUserQuestion go before each step:
1. `bpp-pull-all-dev`. 2. `bpp-checkout-shared-at-stage` (staging state) and print the migration
delta for main. 3. Wait: the user runs DbMigrator on prod by hand; skill asks for "done". 4.
`bpp-promote-dev-to-staging` staging→main (its own preview/go). 5. UI version check. 6. Wait green.
7. Go → merge main MRs. 8. Watch main deploy + health. 9. Print `ui_configs` + manual SQL for main
(user runs them in pgAdmin). 10. Restore bpp-shared (`bpp-checkout-shared-at-stage` restore mode).
11. Henry ping text printed.

### TODOs shipped in the skill

- Henry channel: replace the printed ping with a real post.
- At install on the Mac mini: ask the user for the run schedule and check the root session's cron
  entry runs this skill as a workflow; create the Keychain entries; run the install checklist
  (tools present, `$HOME` paths, saved workflow copied, one dry run).
- Install checklist, Keychain part (printed in SKILL.md, for the colleague who installs it):
  create each entry with `security` pre-allowed (`-T /usr/bin/security`); set up auto-login or
  another way to keep the Keychain unlocked after a reboot; reboot once and run the preflight from
  cron with nobody at the Mac; it must read both entries without a popup.

## Calls made after the builder check (mine, correctable)

- **development moves mid-run:** phase 3 records each repo's `development` head; phase 10 merges with
  `sha=<recorded head>` so GitLab refuses an MR that moved. A refused merge or a new shared pin /
  migration since phase 3 → halt; the next run starts again at phase 0 and re-records the heads in phase 3. Exception: phases 5b
  (Bump shared) and 6 (Promote) move `development` on purpose, so each re-records the heads it
  moved, with `git log <old>..<new>` proof that the only new commits are the run's own. Merge uses
  these re-recorded heads (in dry-run nothing moves, so the phase 3 heads stay).
- **Critic voting:** any critic "block" halts. All must approve.
- **bpp-shared checkout on the Mac mini** is reserved for Henry; the staging skill restores it at
  the end and on every halt, **by SHA** (2026-11-27): phase 3's `reset --hard` keeps the branch name
  `development`, so "restore when not on development" would leave the checkout at the old package
  commit. Restore whenever HEAD differs from the recorded `pre_move_sha`.
- **Mac-safety:** shared skills are not ported. The install checklist requires Homebrew `bash` 5,
  `coreutils` (`gtimeout`, aliased as `timeout`) and `gnu-sed` first on `PATH` for the job; the
  only edit to shared skills is replacing hard-coded `/home/alex` with `$HOME` (e.g.
  `bpp-pull-all-dev`). New `lib/` scripts are written portable anyway.
- **Merge rights:** `staging` merge/push = Maintainers (checked on bpp-backend 2026-11-26). The Mac
  mini's glab identity must be Maintainer in every promoted repo — install checklist; preflight checks it.
- **Install checklist also covers:** which macOS user runs the job (Keychain is per user — not
  `root`), dev/staging DB reachable from the Mac mini (VPN/tunnel?), local Postgres with a `bpp` DB
  for phase 4, GitLab NuGet auth for `dotnet run`, the same `~/Entwicklung/bpp` checkouts.

## Left to the builder

- Exact critic prompts and schemas; how many critics per phase (2–3).
- Polling intervals and timeouts (suggested above).
- Read-only mode for `run-stage-sql.sh` (e.g. `--readonly` sets `default_transaction_read_only=on`).
- Lock file location and format; state file format (JSON under `~/.claude/state/bpp-release/`).
- Dry-run mode (`--dry-run`) that does every read-only step and prints the write steps instead.
  Decided: dry-run still does local git updates (the pull, the bpp-shared checkout + restore, the
  skills mirror pull + install) because it needs current code; only DB writes, GitLab writes (MR
  create/merge/push, the shared bump) and SQL are replaced by prints.
