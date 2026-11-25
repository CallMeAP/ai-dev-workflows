---
name: away-mode-off
description: Use when the user is back and wants to end away mode — phrases like "I'm back", "away mode off", "stop the status mails", "stop pinging my inbox", "back to interactive questions", "/away-mode-off". Counterpart of away-mode. Ends away mode for this session only; questions mode goes back ON only when no other session is still away. Project-agnostic; works from any cwd.
---

# Away mode off: this session's mails and inbox check stopped, questions ON if last, one summary

`S=<scratchpad>/away-mode/` (written by `away-mode`). Registry `R=~/.claude/state/away-mode/sessions/`; own entry
`R/<ref.txt>.json`.

1. **Last inbox check first** (skip if this run was triggered by an "I'm back" mail — that tick already ran): run the away-mode tick once (ids in the thread not in `sent-ids.txt` /
   `handled-ids.txt` = user input; `@all:` / `@<session>:` lines are forwarded as in the tick). Handle and confirm anything new.
2. **Stop:** `CronDelete` the id in `cron-id.txt`, then `CronList` to confirm it is gone; `TaskStop` the id in
   `monitor-id.txt` if that Monitor is still armed (away-mode stops it when the queue is empty). Only these two — running workflows keep running.
3. **Unregister:** delete your own `R/<ref.txt>.json`, only that one.
4. **Questions mode:** after step 3, `ListAgents`, then drop stale files in `R` by the stale rule: if ListAgents
   errors or prints no self line ("This session is …" / "This process's main session is …"), delete nothing;
   else a file is stale when its `started_at` is older than 7 days, or it is not `"fallback": true` and its `ref`
   is in no ListAgents row (never match by name alone). Then list `R` again.
   No file left → invoke the `interactive-questions-mode-on` skill. Files left → other sessions are still away:
   leave the global block OFF and name them in the chat; **this session** follows the ON rule from now on
   (AskUserQuestion again), although the CLAUDE.md block says OFF.
5. **Cleanup:** invoke `away-mode-cleanup` (user, 2026-11-17). It archives `decisions.md`, open urgent items and
   the user's mail instructions locally, then moves **this session's** status threads to Gmail trash. No closing
   mail — it would be trashed at once; the summary goes to the archive file and the chat.
6. **Chat:** per workflow where it stands, results since the last mail, the full `decisions.md`, open
   `[URGENT …]` items, the archive path, questions mode ON or the global block still OFF for other sessions (name
   them; this session asks again either way); then each auto-decision the user may still want to change via
   AskUserQuestion (recommended = keep). Keep `$S` as history; a later
   `away-mode` starts a new thread.

| Mistake | Reality |
|---|---|
| Stopping workflows along with the mails | Only the cron and the Monitor stop. |
| Skipping the last inbox check | A reply sent minutes ago would be lost. |
| Switching the mode by editing CLAUDE.md | Use `interactive-questions-mode-on`. |
| Questions mode ON while another session is still away | Only the last away session switches it ON. |
| Checking peers before deleting your own entry | Delete first, then check — two sessions ending at once then still leave the mode ON. |
| Deleting or trashing another live session's entry or thread | Only your own entry, stale entries and your own threads. |
| Staying in OFF behaviour because the global block stays OFF for peers | This session is back: it asks again. |
