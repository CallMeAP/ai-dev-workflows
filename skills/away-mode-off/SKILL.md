---
name: away-mode-off
description: Use when the user is back and wants to end away mode — phrases like "I'm back", "away mode off", "stop the status mails", "stop pinging my inbox", "back to interactive questions", "/away-mode-off". Counterpart of away-mode. Project-agnostic; works from any cwd.
---

# Away mode off: questions ON, mails and inbox check stopped, one summary

`S=<scratchpad>/away-mode/` (written by `away-mode`).

1. **Last inbox check first** (skip if this run was triggered by an "I'm back" mail — that tick already ran): run the away-mode tick once (ids in the thread not in `sent-ids.txt` /
   `handled-ids.txt` = user input). Handle and confirm anything new.
2. **Stop:** `CronDelete` the id in `cron-id.txt`, then `CronList` to confirm it is gone; `TaskStop` the id in
   `monitor-id.txt` if that Monitor is still armed (away-mode stops it when the queue is empty). Only these two — running workflows keep running.
3. **Questions mode ON:** invoke the `interactive-questions-mode-on` skill.
4. **Cleanup:** invoke `away-mode-cleanup` (user, 2026-11-17). It archives `decisions.md`, open urgent items and
   the user's mail instructions locally, then moves the away-mode status threads to Gmail trash. No closing mail —
   it would be trashed at once; the summary goes to the archive file and the chat.
5. **Chat:** per workflow where it stands, results since the last mail, the full `decisions.md`, open
   `[URGENT …]` items, the archive path; then each auto-decision the user may still want to change via
   AskUserQuestion (recommended = keep). Keep `$S` as history; a later `away-mode` starts a new thread.

| Mistake | Reality |
|---|---|
| Stopping workflows along with the mails | Only the cron and the Monitor stop. |
| Skipping the last inbox check | A reply sent minutes ago would be lost. |
| Switching the mode by editing CLAUDE.md | Use `interactive-questions-mode-on`. |
