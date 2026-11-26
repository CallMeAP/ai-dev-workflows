# BPP Release Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `bpp-release-staging` (autonomous dev → staging release with critic gates) and
`bpp-release-main` (interactive staging → main companion), plus the StageSql convention and its docs.

**Architecture:** Each skill is a SKILL.md. The staging skill also ships a saved Workflow script (one
phase per release step, critic agents between phases) and a `lib/` of small portable bash scripts that
hold every DB write and every secret. Existing skills (`bpp-pull-all-dev`, `bpp-bump-shared-version`,
`bpp-checkout-shared-at-stage`, `bpp-promote-dev-to-staging`, `bpp-go-health`,
`bpp-cleanup-merged-worktrees`) are called, not copied.

**Tech Stack:** bash (3.2-safe in `lib/`), jq, psql, dotnet (bpp-shared DbMigrator), glab, Claude Code
Workflow script (plain JS), macOS `security` / Linux env file.

**Spec:** `docs/superpowers/specs/2026-11-26-bpp-release-design.md` (read it with this plan).

## Global Constraints

- Skill root: `$HOME/.claude/skills/bpp-release-staging/` and `$HOME/.claude/skills/bpp-release-main/`. No literal `/home/alex` anywhere in new files.
- `lib/` scripts: bash 3.2-compatible (no `declare -A`, no `mapfile`), no `sed -i`, no `grep -P`, no `readlink -f`; `timeout` via `${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout)}`.
- Secrets: Keychain services `bpp-db-development`, `bpp-db-staging`; env file `~/.bpp-release.env` with `BPP_DB_DEVELOPMENT=` / `BPP_DB_STAGING=`; override `BPP_RELEASE_SECRETS=keychain|envfile`. No `main` stage in any write script.
- A secret value never reaches stdout, stderr, a file, argv or a log. Output of wrappers is filtered for the password.
- Env file is parsed line by line, never `source`d; mode must be `600`, owner the current user.
- State: `$HOME/.claude/state/bpp-release/state.json`; lock: `$HOME/.claude/state/bpp-release/lock`.
- StageSql folder: `bpp-backend/BPP.Backend.NET/BPP.Backend.NET.Sql/StageSql/`; file name `YYYY-MM-DD_<ticket>_<short-name>.<pre-deploy|post-deploy>.sql`; headers `-- stages: …` and `-- idempotent: yes`.
- Fallback-scan excludes: `CypressSql/`, `SeedSql/`, `InsertSql/`, `SyncSql/`, `Migrations/`.
- Git: worktrees for repo changes; no amend/rebase/reset/stash/force (only `bpp-checkout-shared-at-stage`'s own `reset --hard`). Explicit `git add <path>`. Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Code comments short and plain.

## Review Focus

1. Npgsql/psql echoes the connection string in an error → wrapper output must not contain the password (test in Task 2).
2. Env file with wrong mode, missing stage line, CRLF line endings or quotes → clear refusal / correct value, never a partial string (Task 1).
3. Keychain popup or locked Keychain → `secret-env.sh` returns non-zero within the timeout instead of hanging (Task 1, stubbed `security`).
4. A second run starting while one holds the lock, or a stale lock from a crashed run → refused / reported, never two runs writing (Task 3).
5. `.sql` file in a StageSql folder whose `stages:` header omits staging, or a pre-deploy file treated as post-deploy → not run in that slot (Task 4).

---

### Task 1: Secret backend `lib/secret-env.sh`

**Files:**
- Create: `~/.claude/skills/bpp-release-staging/lib/secret-env.sh`
- Test: `~/.claude/skills/bpp-release-staging/tests/test-secret-env.sh`, shared helper `tests/assert.sh`, runner `tests/run.sh`

**Interfaces:**
- Produces: `get_secret <development|staging>` (function, sourced) → prints the connection string to stdout **only for capture by the caller** (`conn=$(get_secret staging)`), exit 0; exit 2 unknown stage (incl. `main`), 3 not found, 4 env file mode/owner wrong, 5 Keychain timeout/denied. Backend: `BPP_RELEASE_SECRETS` else `uname`=Darwin → keychain, else envfile. Env file path `${BPP_RELEASE_ENV_FILE:-$HOME/.bpp-release.env}`. Keychain: `security find-generic-password -s bpp-db-<stage> -a bpp -w` under timeout `${BPP_KEYCHAIN_TIMEOUT:-10}`s.
- `tests/assert.sh`: `assert_eq <expected> <actual> <msg>`, `assert_status <code> <cmd...>`, `assert_not_contains <needle> <haystack> <msg>`; `tests/run.sh` runs every `tests/test-*.sh`, exits non-zero on any failure.

- [ ] **Step 1: Write failing tests** — temp `HOME`, fixture env file:
  - mode 600, `BPP_DB_STAGING="Host=h;Password=p1"` → `get_secret staging` = `Host=h;Password=p1`.
  - CRLF line and single quotes → same clean value.
  - mode 644 → status 4, stderr mentions `600`, stderr does not contain `p1`.
  - `get_secret main` → status 2.
  - missing line → status 3.
  - `BPP_RELEASE_SECRETS=keychain` with a stub `security` on `PATH` that sleeps 30 and `BPP_KEYCHAIN_TIMEOUT=1` → status 5 within 3 s.
  - file containing `$(touch pwned)` as a value → `pwned` not created.
- [ ] **Step 2:** `bash tests/run.sh` → FAIL (`secret-env.sh` missing).
- [ ] **Step 3:** Implement `secret-env.sh` per the interface.
- [ ] **Step 4:** `bash tests/run.sh` → all PASS; `shellcheck lib/secret-env.sh` → no errors.

### Task 2: DB wrappers `lib/migrate-stage.sh`, `lib/run-stage-sql.sh`

**Files:**
- Create: `lib/migrate-stage.sh`, `lib/run-stage-sql.sh`, `lib/redact.sh`
- Test: `tests/test-db-wrappers.sh` (stub `dotnet` and `psql` on `PATH` that echo their env/argv)

**Interfaces:**
- Consumes: `get_secret` (Task 1).
- Produces:
  - `redact.sh`: `redact_stream <secret>` filter — replaces the password part (`Password=…;`) and the whole connection string with `***`.
  - `migrate-stage.sh <local|development|staging> [--shared-dir DIR]` — DIR default `$HOME/Entwicklung/bpp/bpp-shared`; runs `dotnet run --project <DIR>/BPP.Shared.NET/BPP.Shared.NET.DbMigrator` with `ConnectionStrings__DefaultConnection` exported in its own process only (not for `local`); output piped through `redact_stream`; exit = dotnet's exit.
  - `run-stage-sql.sh [--readonly] <development|staging> (<file.sql> | --check | --query 'SQL')` — converts the Npgsql string to `PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD` in-process; write mode runs `psql -X -v ON_ERROR_STOP=1 -1 -f <file>`; `--readonly` sets `PGOPTIONS='-c default_transaction_read_only=on'`; `--check` prints `connection OK, <n> migrations applied` (count from `__EFMigrationsHistory`); refuses a file containing `BEGIN`/`COMMIT` lines (exit 6).

- [ ] **Step 1: Failing tests:**
  - stub `dotnet` prints `$ConnectionStrings__DefaultConnection` → wrapper stdout does not contain the password, contains `***`.
  - stub `psql` prints `PGPASSWORD` and fails → output has no password, exit non-zero.
  - `migrate-stage.sh main` → exit 2, no stub called.
  - `run-stage-sql.sh staging file-with-BEGIN.sql` → exit 6.
  - `--readonly` → stub sees `default_transaction_read_only=on` in `PGOPTIONS`.
  - argv of the stub never contains the password.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Implement the three scripts.
- [ ] **Step 4:** `bash tests/run.sh` → PASS; shellcheck clean.

### Task 3: Run state, lock and ping `lib/state.sh`, `lib/henry-ping.sh`

**Files:**
- Create: `lib/state.sh`, `lib/henry-ping.sh`
- Test: `tests/test-state.sh`

**Interfaces:**
- Produces:
  - `state.sh lock <run_id>` (exit 0 got or refreshed the lock; 7 held by another run whose heartbeat is younger than 3 h; an older lock is taken over and reported on stderr; no run_id → 2), `state.sh unlock <run_id>` (removes only its own lock, else 7). The holder is the run_id, not a pid, because each workflow Bash call is a short-lived shell. Changes to the lock file run under a `lock.d` mkdir mutex, so two runs never both take a stale lock.
  - `state.sh get` → JSON `{run_id, phase, status: running|halted|done, applied: [..], halt_reason, heads: {repo: sha}, package}`; `state.sh set-phase <n>`, `state.sh add-applied <text>`, `state.sh halt <reason>`, `state.sh done`, `state.sh new <run_id>`.
  - `henry-ping.sh <info|blocker> <title> <body-file-or-text>` prints a block starting `===== HENRY PING (<severity>) =====` and ending `===== END HENRY PING =====`, with a `TODO: post to Henry Teams channel` line; exit 0.

- [ ] **Step 1: Failing tests:** second `lock` while the first holder's pid lives → 7; lock with a dead pid → 0 and stderr says `stale`; `halt` then `get` → status `halted`, reason kept; ping output has both delimiters.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement (jq for JSON). **Step 4:** PASS + shellcheck.

### Task 4: SQL finder `lib/find-stage-sql.sh`

**Files:**
- Create: `lib/find-stage-sql.sh`
- Test: `tests/test-find-stage-sql.sh` (builds a throwaway git repo with `staging` and `development` branches)

**Interfaces:**
- Produces: `find-stage-sql.sh --repo <dir> --from origin/staging --to origin/development --stage staging [--mr-json FILE]` → JSON array of `{source: convention|diff|mr-description, path|mr, timing: pre-deploy|post-deploy|unknown, stages: [..], idempotent: bool, sql_file}`; MR-description blocks are written to temp `.sql` files (`sql_file`). Convention entries only when `stages` contains the stage. `--mr-json` = list of merged feature MRs (`[{iid, project, description}]`) fetched by the workflow with glab.

- [ ] **Step 1: Failing tests:** added `StageSql/2026-11-26_BRO-1_x.post-deploy.sql` with `-- stages: staging` → one `convention` post-deploy entry; same with `-- stages: main` → none; `SeedSql/a.sql` → none; `Other/b.sql` → `diff`, timing `unknown`; MR description with a ```` ```sql ```` block → `mr-description` entry with its file; a file deleted on `development` → none.
- [ ] **Step 2–4:** FAIL → implement → PASS + shellcheck.

### Task 5: Saved workflow `workflow.js`

**Files:**
- Create: `~/.claude/skills/bpp-release-staging/workflow.js`

**Interfaces:**
- Consumes: Tasks 1–4 scripts (by path `$HOME/.claude/skills/bpp-release-staging/lib/...`, agents expand `$HOME`), existing skills by name.
- Produces: invoked as `Workflow({scriptPath: "<skill>/workflow.js", args: {mode: "run"|"dry-run", runId: "<yyyy-mm-dd-hhmm>"}})`; returns `{status: done|halted, phase, summary, uiConfigsSql, henryPing}`.

Shape (the decisions the implementer cannot make alone):
- `meta.phases` = Skill update, Preflight, Pull, Shared state, Local migrate, Dev migrate, Bump shared, Promote, UI versions, Wait green, Staging migrate, Merge, Watch deploy, ui_configs, Manual SQL, Henry ping, Report, Cleanup — the spec's phases 0–16 in the spec's order (2, 3, 4, 5, 5b, 6 …).
- Each phase = one worker `agent()` with schema `{ok: boolean, halt: boolean, reason: string, summary: string, applied: string[], evidence: string[]}`, then `parallel()` of 2 critic agents (3 for Shared state, Staging migrate, Merge, Manual SQL) with schema `{block: boolean, reason: string}`; any `block` or worker `halt`/`!ok` → a halt agent runs `state.sh halt` + `henry-ping.sh blocker …` + bpp-shared restore, and the workflow returns `halted`.
- Worker prompts name the exact skill/script, the state commands to run, and the phase's halt conditions copied from the spec. Every worker prompt states: never print secrets; never call `get_secret` directly; DB only via the wrappers.
- `dry-run`: write phases (local/dev/staging migrate, bump, promote "go", merge, SQL) are replaced by a worker that prints what it would run; read-only phases run for real.
- Critics get the worker's result JSON plus the phase's spec rules and are told to default to `block: true` when evidence is missing.
- Merge phase uses the `heads` recorded in Shared state (`sha=` on merge) and `should_remove_source_branch=false`; Duo path per spec decisions table. Bump shared and Promote move `development` by design, so (not in dry-run) they re-record `heads` with `git log <old>..<new>` proof that the only new commits are the run's own; Merge uses those.
- Worker rule on `state.sh halt` / `state.sh unlock` / `henry-ping.sh`: workers run none of them, except the Henry ping worker runs `henry-ping.sh info` and the Cleanup worker runs `state.sh unlock`; the critics of each phase get the same rule.
- No `Date.now()` / `Math.random()` (runId comes from args).
- Lock: Preflight runs `state.sh lock <runId>` (exit 7 → halt); every later phase worker runs it again first as a heartbeat; Cleanup and the halt agent run `state.sh unlock <runId>`. `henry-ping.sh` reads a body file only from `~/.claude/state/bpp-release/`; any other body is printed as text.

- [ ] **Step 1:** `node --check` cannot parse `export const meta`; instead write `tests/test-workflow-shape.sh` that greps: every spec phase title present in `meta.phases`, no `Date.now`/`Math.random`, no `/home/alex`, the strings `should_remove_source_branch=false`, `--readonly`, `henry-ping.sh`. Run → FAIL.
- [ ] **Step 2:** Write `workflow.js`.
- [ ] **Step 3:** `bash tests/run.sh` → PASS; `node -e` parse check after stripping `export ` (`sed 's/^export //' workflow.js > /tmp/x.mjs && node --check /tmp/x.mjs` — scratchpad path) → no syntax error.

### Task 6: `bpp-release-staging/SKILL.md`

**Files:** Create `~/.claude/skills/bpp-release-staging/SKILL.md`.

Must contain (exact sections): frontmatter `name: bpp-release-staging` + trigger description; Overview; Rules (the changed standing rules, scoped to this skill only); How to run (the Workflow call from Task 5, `dry-run` first on a new machine); Halt + resume (state file, rerun resumes); Secrets setup — **Ubuntu VM** (the six env-file steps from the spec, incl. the `permissions.deny` JSON) and **Mac mini** (Keychain + the Keychain unattended-run warnings); Install checklist (spec's TODO list: schedule question for the root session, Homebrew bash/coreutils/gnu-sed, macOS user, DB reachability, local Postgres `bpp`, NuGet auth, Maintainer rights, `~/Entwicklung/bpp` checkouts, one dry run, one unattended cron run after a reboot); TODOs (Henry channel, schedule); StageSql convention summary.

- [ ] **Step 1:** test `tests/test-skill-md.sh` greps for each section heading, `permissions`, `-T /usr/bin/security`, `dry-run`, no `/home/alex`. Run → FAIL. **Step 2:** write. **Step 3:** PASS.

### Task 7: `bpp-release-main/SKILL.md`

**Files:** Create `~/.claude/skills/bpp-release-main/SKILL.md`.

Interactive, AskUserQuestion go before each step, the spec's 11 main steps in order; never runs DbMigrator, `run-stage-sql.sh`, or any DB write; prints main StageSql files + ui_configs SQL for pgAdmin; restores bpp-shared at the end; prints the Henry ping.

- [ ] **Step 1:** test greps: 11 numbered steps, `bpp-checkout-shared-at-stage`, `AskUserQuestion`, no `migrate-stage.sh`/`run-stage-sql.sh` invocation. FAIL → write → PASS.

### Task 8: `$HOME` in reused skills

**Files:** Modify `~/.claude/skills/bpp-pull-all-dev/SKILL.md`, `bpp-cleanup-merged-worktrees/cleanup.sh`, `stale.sh`, `bpp-project-index/refresh.sh`, `bpp-project-index/SKILL.md`, `bpp-bump-shared-version/SKILL.md` (BUMP_HOLD path).

- [ ] **Step 1:** `grep -rn '/home/alex' <those files>` → list.
- [ ] **Step 2:** Replace each with `$HOME` (in shell) or `~` (prose); nothing else.
- [ ] **Step 3:** grep → empty; `bash -n` on each changed `.sh`; `bash ~/.claude/skills/bpp-cleanup-merged-worktrees/cleanup.sh plan` still prints a plan.

### Task 9: StageSql convention in bpp-backend + docs note in every bpp repo

**Files:**
- Create in bpp-backend (worktree off `origin/development`): `BPP.Backend.NET/BPP.Backend.NET.Sql/StageSql/README.md` (the convention from the spec, with one example file name and header).
- Modify per repo (all manifest repos with a `development` branch, `^bpp-` and `-ui$` frontends): add a short "Stage SQL" section to `CLAUDE.md` if present, else `README.md`, pointing to the bpp-backend README URL.

- [ ] **Step 1:** List target repos from `~/.claude/bpp-fleet/manifest.tsv` (`state=active`, has `development`), print the list.
- [ ] **Step 2:** bpp-backend: worktree, write README, commit `docs: add StageSql convention for manual stage SQL`, push to `development`.
- [ ] **Step 3:** Each other repo: worktree off `origin/development`, add the section (5–8 lines), commit `docs: point to StageSql convention`, push to `development`; rejected push → fetch, merge `origin/development`, push again; never force.
- [ ] **Step 4:** Verify per repo: `git ls-remote origin development` = pushed SHA. Remove the worktrees.

### Task 10: Publish and verify

- [ ] **Step 1:** `bash ~/.claude/skills/bpp-release-staging/tests/run.sh` → all PASS.
- [ ] **Step 2:** Dry run on this VM (needs the user's `~/.bpp-release.env`; if missing, stop and ask): `Workflow({scriptPath, args: {mode: "dry-run", runId}})` → returns `done` with read-only phases real and write phases printed; report output verbatim.
- [ ] **Step 3:** Commit spec + plan in ai-dev-workflows (`docs/superpowers/...`), then run `sync-my-skills` for `bpp-release-staging`, `bpp-release-main` and the Task 8 skills.
