---
name: disk-check
description: Use when the disk is full or low on space on this Linux dev machine — phrases like "disk full", "low disk space", "only X GB free", "free up space", "what eats my disk", "storage", "cleanup caches", "df shows less than expected", "clean Cypress cache", "old session scratch", "stale worktrees taking space".
---

# disk-check

## Overview

A read-only disk report first, then deletions only for the items the user approves. Four scripts
next to this file. Run each as `bash <path>`. Never paste their shell into this file, because skill
args substitute dollar-digit sequences.

- `report.sh` deletes nothing. It prints one section per check (1-8) and then a SUMMARY table with
  verdicts and reclaimable MB. It takes about 2 min (`cleanup.sh plan` queries GitLab). It does write
  two state lists: `~/.claude/state/disk-check-build-dirs.tsv` (item 8, read back by `apply-build.sh`)
  and stale.sh's own `~/.claude/state/stale-worktrees.tsv`.
- `apply-cache.sh <path>...` deletes only Cypress cache version dirs and other sessions' scratch
  dirs, and only exact paths. It re-checks each verdict right before it runs `rm`. Scratch deletion
  needs `CLAUDE_CODE_SESSION_ID` set (otherwise every scratch path is SKIPped).
- `apply-build.sh <path>...` deletes only item-8 build-output dirs listed in the build list (written by
  the last report.sh run, at most 6 h old). It re-checks: listed, bin/obj/node_modules/.angular/dist,
  inside a linked git worktree, not bpp-document-analysis, worktree still idle, nothing tracked.
- Worktrees: `~/.claude/skills/bpp-cleanup-merged-worktrees/cleanup.sh apply <path>...` and
  `stale.sh apply <path>...`. Never this skill's scripts.

Verdicts: **DELETABLE** (safe after the user's go), **ON-GO** (bigger and costs a rebuild or a
re-download, so it needs an explicit go per item), **USER-SUDO** (the user runs the printed `! sudo ...`
command), **USER** (an action that is not about disk), **KEEP**.

Checks:
1. df plus the ext4 root reserve, read from statfs without sudo.
2. GNOME tracker: CPU use and index size.
3. `~/.cache/Cypress` versions compared with every `node_modules/cypress` (incl. symlinked node_modules,
   `~/.npm/_npx`, the global npm root), with running processes, and with `package-lock.json` pins.
   A version only pinned (not installed) is DELETABLE with a CAVEAT: the next `npm ci` there re-downloads it.
   Put that caveat into the option description.
4. `/tmp/claude-<uid>` session scratch: current session, open fds and cwd of any of my processes,
   jsonl and scratch write times.
5. journal.
6. nuget, `~/.cache` (entries of 500 MB or more get an INFO row), `~/.claude`, docker.
7. merged and stale worktrees (via the bpp-cleanup-merged-worktrees scripts).
8. bin/obj/node_modules/.angular/dist in idle linked worktrees of repos directly under `~/Entwicklung/bpp`.
   A worktree whose idle check timed out is skipped and named, never counted as idle.

**Claude desktop `/storage`** (Settings → Storage, "Remove unused worktrees") is a desktop-app command
and does not exist in the CLI. It manages only the desktop app's own sessions and worktrees. Point
the user there for those. It does not cover anything this skill checks.

## Steps

1. Note free space with `df -h /`. Run `bash ~/.claude/skills/disk-check/report.sh` (timeout 240000 ms).
2. Show the SUMMARY table and the explanation lines from each section: reserve gap, tracker CPU,
   which Cypress versions are installed where, which scratch dirs are active.
3. Ask with **AskUserQuestion, `multiSelect: true`**. Put the DELETABLE rows first, labelled
   "(Recommended)", with their MB. ON-GO rows come after them without the label. AskUserQuestion takes
   **at most 4 options per question** (and at most 4 questions). When there are more than 4 rows,
   grouping is mandatory: one option per kind, e.g. "4 idle scratch dirs, 4 MB", with the paths in the
   description. Put nuget into its own single-select question ("Keep it (Recommended)" / "Clear it").
   Show USER-SUDO and USER items as commands for the user to run (`! sudo journalctl --vacuum-size=1G`,
   `tracker3 daemon --pause-miner fs`), not as options you execute.
4. Apply only what was approved, with explicit paths:
   - Cypress or scratch: `bash ~/.claude/skills/disk-check/apply-cache.sh <path> <path>`. A SKIP
     line means the verdict changed. Report it and do not retry.
   - Merged worktrees: `bash ~/.claude/skills/bpp-cleanup-merged-worktrees/cleanup.sh apply <path>`.
   - Stale worktrees: `bash ~/.claude/skills/bpp-cleanup-merged-worktrees/stale.sh apply <path>`.
   - ON-GO build output (item 8): `bash ~/.claude/skills/disk-check/apply-build.sh <path> <path>` with the
     exact paths from `~/.claude/state/disk-check-build-dirs.tsv` (column 2) that the user approved.
     Never a bare `rm -rf`, never a glob. A REFUSED for an old list means: run report.sh again.
   - ON-GO nuget: `dotnet nuget locals global-packages --clear`, and only on an explicit go.
5. Run `df -h /` again and report before → after, plus each DELETED/SKIP line verbatim.

## Common mistakes (seen in the baseline run)

- **Deleting the biggest scratch dir first.** It was the current session (5.7 GB). The report marks
  the current session and any session with open fds as KEEP. Trust that over size.
- **Calling a session idle because of jsonl time alone.** Two `claude --resume` processes were
  running. Open fds in `/tmp/claude-<uid>/<proj>/<sid>` decide it.
- **"Is Cypress in use?" answered with `pgrep -f Cypress`.** The check reads `/proc/*/exe` and `/proc/*/maps` for the
  cache path. It also names the checkouts that pin each version, worktrees included.
- **Calling the reserve gap "unverified".** statfs (`stat -f`) gives free minus avail without sudo.
  Report the number.
- **Skipping item 8.** Build output in idle worktrees was the biggest safe pool and went unmeasured.
- **Not totalling KEEP worktrees.** The by-repo sizes show where the space is, even when nothing is removable.
- **Asking in prose.** Interactive questions mode is ON. Use AskUserQuestion with multiSelect and
  put the recommended options first.
- **Relying on a number from an earlier session** ("9 stale worktrees"). Re-run the plan.
  Worktrees change by the hour.

## Red flags: stop

- Any `sudo`, `--force`, `git worktree remove --force`, `branch -D` outside cleanup.sh's own rules.
- The `stale.sh apply $(cut ...)` blanket form. Pass only the paths the user approved.
- Any path under `bpp-document-analysis*` (bpp-agent is a normal repo since 2026-11-20).
- Deleting `~/.cache/Cypress/bundles`, the current session's scratch, or `~/.claude/projects` jsonl
  (session history that `--resume` needs).
- `rm -rf` with a glob or on a path the report did not list.
- Deleting before the user answered the AskUserQuestion.
