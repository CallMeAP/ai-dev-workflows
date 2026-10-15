---
name: pause-and-handover
description: Use when the user wants all running background work paused and a reboot-safe handover written so a fresh session can resume later — phrases like "pause everything", "stop all shells and workflows", "stop all agents", "make it reboot safe", "create a handover", "pause workflow and make it reboot safe", "I need to reboot", "write a RESUME.md". Project-agnostic; works from any cwd.
---

# Pause all background work + reboot-safe handover

## Overview

A reboot kills every background shell, subagent and Workflow, and wipes `/tmp` (including the
session scratchpad). Same-session resume (`Workflow` `resumeFromRunId`) does **not** survive a new
session (stated by the workflow tooling; unverified by this skill's author). So: **inventory first,
stop second, persist everything that lives only in this session, then hand over.**

**Pausing never commits, pushes, stashes, resets or deletes branches.** It records state; it does not change it.

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

1. `TaskStop` each task id this session launched (shells, named agents, workflows) — never a peer session or another user's teammate. Load it first with `ToolSearch select:TaskStop` if deferred. Do not `SendMessage` a workflow agent to "wrap up" (it spawns a duplicate).
2. Re-run the `pgrep` / `ss` from step 1. Kill **only** processes whose ppid/pgid chain provably leads to a stopped task's shell (a matching cmdline alone is not proof — the user may run the same command). Unrelated user processes (IDE, local stack the user started, other sessions) stay up. Unsure → leave it and list it.
3. Per touched repo/worktree: `git status -sb`, `git log @{u}..` → record dirty files and unpushed commits. Do not fix them.

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
3. **Exact resume procedure** — per the resume caveats in step 5 of this skill.
4. **Decisions already made by the user** — so the next session never re-asks them.
5. **Decisions taken automatically** — copy the list if interactive-questions mode was OFF.
6. **Open items** and pending outward-facing actions not yet authorized.
7. **Rules in force** — write gates, no-touch repos, review/merge rules from this session.

## 5. Resume caveats (put them in RESUME.md section 3)

- **Workflow:** a fresh session cannot `resumeFromRunId`. Keep the copied script; describe a continuation
  script that skips completed stages and receives their results via `args` (from the joined journal).
  Name which stages are complete, which must re-run from scratch.
- **Background shells:** must be re-launched. State whether the command is idempotent; if not, record its resume point (last processed item, offset, file).
- **Subagents:** cannot be resumed; restate their assignment and what they already delivered.

## 6. Memory

Add or update a `type: project` memory file in the current project's memory dir (`~/.claude/projects/<cwd with / replaced by ->/memory/`) pointing at the RESUME.md
(`**Why:**` scratch and same-session resume do not survive a reboot; `**How to apply:**` read RESUME.md
first, never re-ask its decisions), plus a one-line entry in that dir's `MEMORY.md`. Update an existing
handover entry for the same track instead of adding a second one.

## 7. Final reply

What was stopped (counts + names), where each stopped, handover path, what the user must do **before**
reboot (e.g. push nothing / restore X / check Y) and **after** (open a session in <dir>, say "read <path> and resume").

## Red flags — STOP

| Thought | Reality |
|---|---|
| "Stop first, inventory after" | A stopped task's progress is gone. Inventory first. |
| "I'll commit/stash the WIP so it's safe" | Pausing never changes git state. Record it. |
| "The workflow can just be resumed later" | Not in a fresh session. Copy script + journal now. |
| "Results are in the scratchpad, fine" | `/tmp` dies on reboot. Copy them next to RESUME.md. |
| "`pkill dotnet` cleans up" | Kills the user's own processes. Kill only provable task children. |
| "HEAD is what my local ref says" | Record local HEAD and `ls-remote`; the handover is read after a fetch. |
| "ListAgents shows it, so I stop it" | Other sessions and teammates appear there too. Stop only what this session started. |
| "New RESUME.md for the same track" | Prepend an UPDATE block instead. |
