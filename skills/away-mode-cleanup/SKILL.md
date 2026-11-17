---
name: away-mode-cleanup
description: Use when the agent's away-mode status mails should be removed from Gmail — phrases like "clean up the agent mails", "trash the status mails", "away mode cleanup", "/away-mode-cleanup". Also invoked automatically by away-mode-off. Archives decisions and the user's mail instructions locally first, then moves the away-mode status threads to Gmail trash. Project-agnostic; works from any cwd.
---

# Away-mode cleanup: archive locally, then trash the status threads

`S=<scratchpad>/away-mode/` (written by `away-mode`; may be missing in a new session — then skip the archive parts
that need it and say so). User decisions 2026-11-17: whole threads incl. the user's replies go to trash; a local
copy is kept first; an open urgent item does NOT block the cleanup (list it in chat instead).

## Steps

0. Load the tools: `ToolSearch("select:mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread,mcp__claude_ai_Gmail__get_message,mcp__claude_ai_Gmail__trash_thread")`.
   Not loadable → stop and tell the user (see `away-mode` step 0).
1. **Find the threads:** `search_threads(query="from:me to:me subject:(flows status)", pageSize=50,
   view="THREAD_VIEW_SUMMARY")`, page through `pageToken`. Keep a thread only if its subject matches
   `[<anything> flows] status` (optionally with the `[URGENT …]` prefixes) AND `get_thread(METADATA_ONLY)` shows its
   first message's snippet starting with `🤖`. Everything else — other self-mails, other senders — is never touched.
   Add the id in `$S/thread.txt` if it is not in the list (it is this session's thread).
2. **Archive** to `<project handover dir>/away-mode-archive/<YYYY-MM-DD>-<threadId>.md` when the project has a
   handover folder (e.g. the active `RESUME.md`'s directory), else `~/.claude/away-mode-archive/`. Content:
   thread subject and date range; `$S/decisions.md` verbatim; `$S/urgent-open.md` if non-empty; for every message
   id in `$S/handled-ids.txt` (the user's mail instructions) the text above the quoted part
   (`get_message(PLAIN_TEXT)`); a one-line list of the agent mails (date + subject). Never write the user's e-mail
   address into the file.
3. **Trash:** `trash_thread(threadId)` per kept thread. Trash is recoverable in Gmail for 30 days; never delete
   permanently.
4. **Verify:** `search_threads(<same query>)` no longer returns them.
5. **Chat:** threads trashed (count + subjects), archive path, any open urgent item ("trashed although open: …").
   Keep `$S` as is.

## Common mistakes

| Mistake | Reality |
|---|---|
| Trashing by sender only (`from:me to:me`) | Catches the user's own notes to self. Subject pattern + `🤖` first message are both required. |
| Trashing before archiving | `decisions.md` lives in the scratchpad and dies on reboot; archive first. |
| Permanent delete | Trash only. |
| Address in the archive file or chat | The address appears only inside Gmail tool calls. |
