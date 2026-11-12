---
name: pause-and-handover
description: Use when the user wants all running background work paused and a reboot-safe handover written so a fresh session can resume later — phrases like "pause everything", "stop all shells and workflows", "stop all agents", "make it reboot safe", "create a handover", "pause workflow and make it reboot safe", "I need to reboot", "write a RESUME.md". Project-agnostic; works from any cwd.
---

# Pause all background work + reboot-safe handover

## Overview

A reboot kills every background shell, subagent and Workflow, and wipes `/tmp` (including the
session scratchpad). Same-session resume (`Workflow` `resumeFromRunId`) does **not** survive a new
session (stated by the workflow tooling; unverified by this skill's author). So: **inventory first,
stop second, persist everything that lives only in this session, back it all up to a branch, then hand over.**

**Pausing never changes the working branch, the index or the files.** No commit on the working branch, no
stash, reset, rebase, amend or branch deletion. The only thing it adds is a `backup/…` branch per touched
repo (step 5), so nothing is lost if the disk or the worktree is.

## 1. Inventory BEFORE stopping (a stopped task can no longer tell you where it was)

| What | How | Record |
|---|---|---|
| Background shells | task ids from this session; output files under the scratchpad's `tasks/<id>.output` | id, command, cwd, output file, `tail -20` of progress |
| Subagents | `ListAgents` — keep only agents **this session spawned**; it also lists other local sessions, teammates and cloud sessions, which are not yours to stop | name, agentId, what it was assigned, last result |
| Workflows | task id + runId from the launch result; transcript dir `~/.claude/projects/<proj>/<session>/subagents/workflows/wf_<id>/` | scriptPath, `journal.jsonl`, which stages finished |
| OS processes they spawned | `pgrep -af 'dotnet|node|testhost|vstest'`, `ss -ltnp` | pid, ppid, cmdline, port, which task owns it |

**Reading `journal.jsonl`:** `started` lines carry `agentId`, `label`, `phase`; `result` lines carry
only `agentId` + `result`. Join them on `agentId`:

```bash
jq -s 'map(select(.type=="started")) as $s | map(select(.type=="result"))
  | map(. as $r | {label: ($s[]|select(.agentId==$r.agentId)|.label), phase: ($s[]|select(.agentId==$r.agentId)|.phase), result})' journal.jsonl
```

A `started` without a `result` = in flight when stopped. Also read any result/progress files the script writes.

## 2. Stop

0. **Ask when to stop** (AskUserQuestion, unless the user already said): for every workflow stage or long shell
   that is mid-step, offer
   - **"Let the current step finish, then stop"** — recommended when the step is a unit whose half-done
     output is thrown away (a test block, an eval batch, a build) and it ends within ~30 min; say the estimate;
   - **"Stop immediately"** — the in-flight step is set aside (`.partial`) and re-run after the resume.

   For "finish first", wait with a background until-loop on the step's own completion marker (a new
   `result` line in `journal.jsonl`, the next result file, a block count) — never with a fixed sleep — then stop.
1. `TaskStop` each task id this session launched (shells, named agents, workflows) — never a peer session or another user's teammate. Load it first with `ToolSearch select:TaskStop` if deferred. Do not `SendMessage` a workflow agent to "wrap up" (it spawns a duplicate).
2. Re-run the `pgrep` / `ss` from step 1. Kill **only** processes whose ppid/pgid chain provably leads to a stopped task's shell (a matching cmdline alone is not proof — the user may run the same command). Unrelated user processes (IDE, local stack the user started, other sessions) stay up. Unsure → leave it and list it.
3. Per touched repo/worktree: `git status -sb`, `git log @{u}..` → record dirty files and unpushed commits.
   Do not commit, stash or reset them on the working branch; step 5 backs them up.

## 3. Restore what a task swapped temporarily

Look for swapped config, `*.bak` / backup files, scripts with a `restore` subcommand, toggled write gates,
overridden connection strings. Restore if the restore path is provided by the script itself; otherwise
record the exact restore command in the handover. Never leave a write gate or a swapped credential unrecorded.

## 4. Handover file

- Location: `handovers/<YYYY-MM-DD>-<slug>/RESUME.md` in the nearest `handovers/` dir at or above cwd; none → `~/.claude/handovers/<YYYY-MM-DD>-<slug>/RESUME.md`.
- Same track already has a RESUME.md → **prepend** `# UPDATE <date> (read this first)`; do not create a second file.
- Copy next to it everything that lives only in `/tmp` or the scratchpad: workflow script, `journal.jsonl` (or the joined per-agent results), result files, task output tails. Re-check with `ls` that the copies exist.
- No secrets, no tokens, no customer/prod payload data. Reference where they live instead. Before copying journals/output tails, `grep -inE 'password|token|secret|connectionstring|bearer|apikey'` them and redact hits; drop raw prod payloads.

Sections, in order:

0. **First steps after reboot** — exact commands (cd, fetch, checkout, stack start), copy-pasteable.
1. **State per track** — repo, branch, local HEAD **and** remote HEAD (`git ls-remote origin <branch>`; they differ when commits are unpushed), MR/PR ids, dirty/unpushed.
2. **What was stopped and where** — per shell/agent/workflow stage: done / in flight / not started.
3. **Exact resume procedure** — per the resume caveats in step 6 of this skill.
4. **Decisions already made by the user** — so the next session never re-asks them.
5. **Decisions taken automatically** — copy the list if interactive-questions mode was OFF.
6. **Open items** and pending outward-facing actions not yet authorized.
7. **Rules in force** — write gates, no-touch repos, review/merge rules from this session.

## 5. Backup branch per touched repo (work + handover)

Every repo/worktree that has unpushed commits or uncommitted changes gets one snapshot commit pushed to a
new `backup/<branch>-<YYYYMMDD-HHMM>` branch. The snapshot holds HEAD's commits, every uncommitted change
(tracked and new untracked, never gitignored files) **and the handover folder under `handover/`**. It is
built with a temporary index, so HEAD, the real index and the working files stay exactly as they were.
Write the handover (step 4) first; re-run this step if the handover changes afterwards.

**Secret-type config files never go into a backup**, even when git tracks them. Many repos track
`appsettings.local.json` with empty secrets that are filled in locally; a filled copy counts as an edited
file. So every changed path matching `SECRET_FILES` is put back to its committed version in the snapshot
(or left out if it is new), and the same names are skipped in the handover folder. List what was left out in RESUME.md.

```bash
R=<repo or worktree>; H=<handover dir>          # the dir holding RESUME.md
SECRET_FILES='(^|/)(appsettings[^/]*\.local\.json|[^/]*\.local\.json|\.env(\.[^/]*)?|[^/]*secrets?[^/]*|[^/]*\.(pem|key|p12|pfx|jks|keystore))$'
cd "$R"
BR=$(git rev-parse --abbrev-ref HEAD); [ "$BR" = HEAD ] && BR="detached-$(git rev-parse --short HEAD)"
B="backup/${BR//\//-}-$(date +%Y%m%d-%H%M)"
IDX=$(mktemp); cp "$(git rev-parse --git-path index)" "$IDX"
GIT_INDEX_FILE="$IDX" git add -A                 # tracked + untracked, .gitignore respected; files untouched
GIT_INDEX_FILE="$IDX" git diff --cached --name-only HEAD | grep -E "$SECRET_FILES" \
  | grep -vE '\.(example|template)(\.[^/]*)?$' | while IFS= read -r p; do
  if git cat-file -e "HEAD:$p" 2>/dev/null; then GIT_INDEX_FILE="$IDX" git reset -q HEAD -- "$p"   # committed version
  else GIT_INDEX_FILE="$IDX" git rm -q --cached -- "$p"; fi                                       # new: leave out
  echo "left out of backup: $p"
done
find "$H" -type f -size -5M ! -name '*.dump' ! -name '*.partial' | grep -vE "$SECRET_FILES" | while IFS= read -r f; do
  h=$(git hash-object -w "$f")
  GIT_INDEX_FILE="$IDX" git update-index --add --cacheinfo "100644,$h,handover/${f#"$H"/}"
done
T=$(GIT_INDEX_FILE="$IDX" git write-tree); rm -f "$IDX"
C=$(git commit-tree "$T" -p HEAD -m "backup: pause snapshot of $BR incl. handover ($(date -Iseconds))")
git diff --stat HEAD "$C" | tail -3
# JSON-aware: also matches "ClientSecret": "…", "ApiKey": "…", Password=… in connection strings
git diff HEAD "$C" | grep -inE '(BEGIN [A-Z ]*PRIVATE KEY|glpat-|ghp_|sk-ant-|xox[baprs]-|eyJ[A-Za-z0-9_-]{20,}\.)|"?[A-Za-z_]*(password|passwd|pwd|secret|token|apikey|api_key|accesskey|connectionstring)[A-Za-z_]*"?\s*[:=]\s*"?[^"[:space:],;<>{}]{6,}' | head -40
git push origin "$C:refs/heads/$B" && git ls-remote origin "$B"
```

- **Secret scan first.** Read every hit. A real credential value (not a placeholder, test fixture or committed
  dev default) → do **not** push that repo; record it in RESUME.md and tell the user. The scan is a text
  search, not a guarantee: the `SECRET_FILES` rule is the main protection, the scan the second line.
- **No size or data surprises:** files over 5 MB, DB dumps and `.partial` files stay out; never customer/prod data.
- **Auto-created MR:** some hosts open an MR for any new branch. Check
  `merge_requests?source_branch=<B>&state=all` once after the push; close it (or mark it a draft titled
  "backup, do not merge") and say so.
- Record each backup branch + commit in RESUME.md section 1 (then re-run this step so the backup carries the final handover).
- Restore later with `git switch -c <name> origin/<B>`, or take single files with `git checkout origin/<B> -- <path>`.

## 6. Resume caveats (put them in RESUME.md section 3)

- **Workflow:** a fresh session cannot `resumeFromRunId`. Keep the copied script; describe a continuation
  script that skips completed stages and receives their results via `args` (from the joined journal).
  Name which stages are complete, which must re-run from scratch.
- **Background shells:** must be re-launched. State whether the command is idempotent; if not, record its resume point (last processed item, offset, file).
- **Subagents:** cannot be resumed; restate their assignment and what they already delivered.

## 7. Memory

Add or update a `type: project` memory file in the current project's memory dir (`~/.claude/projects/<cwd with / replaced by ->/memory/`) pointing at the RESUME.md
(`**Why:**` scratch and same-session resume do not survive a reboot; `**How to apply:**` read RESUME.md
first, never re-ask its decisions), plus a one-line entry in that dir's `MEMORY.md`. Update an existing
handover entry for the same track instead of adding a second one.

## 8. Final reply

What was stopped (counts + names), where each stopped, the backup branch per repo, handover path, what the user must do **before**
reboot (e.g. push nothing / restore X / check Y) and **after** (open a session in <dir>, say "read <path> and resume").

## Red flags — STOP

| Thought | Reality |
|---|---|
| "Stop first, inventory after" | A stopped task's progress is gone. Inventory first. |
| "I'll commit/stash the WIP on the branch so it's safe" | Never touch the working branch. Snapshot it to a `backup/…` branch with a temporary index (step 5). |
| "Unpushed commits are safe on disk" | One disk, one copy. Push them to a backup branch. |
| "The handover folder is not in git, fine" | It goes into each backup snapshot under `handover/`. |
| "appsettings.local.json is tracked, so backing it up is fine" | A locally filled copy holds real secrets. `SECRET_FILES` keeps the committed version in the snapshot. |
| "Just stop the workflow now" | Ask first: finish the current step, or stop immediately (step 2.0). |
| "The workflow can just be resumed later" | Not in a fresh session. Copy script + journal now. |
| "Results are in the scratchpad, fine" | `/tmp` dies on reboot. Copy them next to RESUME.md. |
| "`pkill dotnet` cleans up" | Kills the user's own processes. Kill only provable task children. |
| "HEAD is what my local ref says" | Record local HEAD and `ls-remote`; the handover is read after a fetch. |
| "ListAgents shows it, so I stop it" | Other sessions and teammates appear there too. Stop only what this session started. |
| "New RESUME.md for the same track" | Prepend an UPDATE block instead. |
