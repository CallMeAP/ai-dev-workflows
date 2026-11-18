# disk-check

A read-only disk report for this dev machine, plus cleanup that is gated per item.
`report.sh` → AskUserQuestion multiSelect → `apply-cache.sh`, `apply-build.sh` or the bpp-cleanup-merged-worktrees scripts.

## Placeholders

**None. This is a personal skill.** It keeps literal paths (`~/Entwicklung`, `~/Entwicklung/bpp`,
`~/.claude/skills/bpp-cleanup-merged-worktrees`). Override them with the env vars `DEV_ROOT`, `BPP_ROOT`,
`CYPRESS_CACHE_FOLDER`, `ACTIVE_MIN` (default 120), `DISK_CHECK_BUILD_LIST`, `MAX_AGE_H` (build list age
limit, default 6) and `DISK_CHECK_SCRATCH_ROOT` (tests only), or edit by hand on another machine.
A deletion root (Cypress cache, scratch root) is used only if it is canonical (no symlink), owned by you,
at least two levels deep and not `$HOME`; otherwise no path can match it and everything is SKIPped.

## Prerequisites

- bash 4+, GNU coreutils/findutils (`du -x`, `find -printf`, `-newer`, `stat -f`, `realpath -e`,
  `timeout`, `date -d`), procps (`pgrep`, `ps`), awk, git.
- `journalctl` (systemd). `tracker3` and `docker` are optional; a missing one is reported, not an error.
- The **bpp-cleanup-merged-worktrees** skill installed beside it. Section 7 runs its `cleanup.sh plan`
  (needs `glab` auth for the MR lookups, about 75 s) and `stale.sh plan`.
- Run it as the normal user. It never calls sudo. The journal vacuum and `tune2fs` are printed for the user.

## Linux / GNU assumptions

- Claude Code scratch is at `/tmp/claude-<uid>/<project>/<session-uuid>`. Session transcripts are at
  `~/.claude/projects/<project>/<uuid>.jsonl`. The current session comes from `CLAUDE_CODE_SESSION_ID`.
  A session counts as active if any process of yours has an fd or its cwd under that session's scratch
  (`/proc/<pid>/fd`, `/proc/<pid>/cwd`), or its jsonl or scratch was written within `ACTIVE_MIN`.
  With `CLAUDE_CODE_SESSION_ID` unset, every scratch dir is KEEP.
- A Cypress version counts as in use if `/proc/*/exe` or `/proc/*/maps` references `~/.cache/Cypress/<ver>`,
  or if any `node_modules/cypress` has it installed. A `package-lock.json` pin alone only adds a CAVEAT.
- The ext4 reserve is computed as statfs (free - avail) * block size. This holds for any filesystem
  that reports root-reserved blocks.

## Install

Copy the folder to `~/.claude/skills/disk-check/` (SKILL.md, README.md, report.sh, apply-cache.sh,
apply-build.sh, lib.sh).
No build step.

## Verification

```bash
cd ~/.claude/skills/disk-check
bash -n lib.sh && bash -n report.sh && bash -n apply-cache.sh && bash -n apply-build.sh && echo SYNTAX-OK
bash report.sh            # read-only; ends with SUMMARY + "runtime: N s" (expect < 180)
# negative tests: every line must be SKIP or REFUSED
bash apply-cache.sh ~/.cache/Cypress/bundles ~/.nuget /nonexistent
bash apply-cache.sh
bash apply-build.sh       # REFUSED, rc=2
```

Known limits: item 8 scans only repos directly under `~/Entwicklung/bpp` (their linked worktrees, wherever
they live); Cypress pins are read from `package-lock.json` only (no yarn/pnpm lockfiles).

Verified 2026-11-18 on Ubuntu (kernel 6.8, GNU coreutils): report ran in 95 s (exit 0). Fake-root tests
(env-overridden roots under the session scratchpad) DELETED only idle fake sessions, uninstalled fake
Cypress versions and idle untracked build dirs in a linked worktree, and SKIPped: bundles, installed and
non-version dirs, symlinks (dir and root), `..` paths, globs, "" and "/", the roots themselves, unsafe
roots (`/`, `$HOME`, `/tmp`, symlinked), sessions held by an open fd or a cwd, an unset or matching
`CLAUDE_CODE_SESSION_ID`, tracked dirs, active worktrees, main checkouts, bpp-agent paths, unlisted paths
and a build list older than 6 h. On the real roots every protected path was SKIPped and nothing was removed.
