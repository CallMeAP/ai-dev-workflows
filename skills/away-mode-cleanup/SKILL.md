---
name: away-mode-cleanup
description: Use when this session's away-mode status mails should be removed from Gmail — phrases like "clean up the agent mails", "trash the status mails", "away mode cleanup", "/away-mode-cleanup". Also invoked automatically by away-mode-off. Archives decisions and the user's mail instructions locally first, then moves this session's `[<session> flows] status` threads to Gmail trash; other away sessions' threads are never touched. Project-agnostic; works from any cwd.
---

# Away-mode cleanup: archive locally, then trash this session's status threads

`S=<scratchpad>/away-mode/` (written by `away-mode`; may be missing in a new session — then skip the archive parts
that need it and say so). Registry `R=~/.claude/state/away-mode/sessions/`. User decisions 2026-11-17: whole
threads incl. the user's replies go to trash; a local copy is kept first; an open urgent item does NOT block the
cleanup (list it in chat instead). User 2026-11-25: several sessions can be away at once — trash only this
session's threads.

## Steps

0. Load the tools: `ToolSearch("select:mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread,mcp__claude_ai_Gmail__get_message,mcp__claude_ai_Gmail__trash_thread")`.
   Not loadable → stop and tell the user (see `away-mode` step 0).
1. **Session name `N`:** `$S/name.txt`; missing → as in `away-mode` step 1 (the ListAgents self line "This
   session is <name> [<ref>]" or "This process's main session is <name> [<ref>]", else cwd basename).
   **Protected ids:** the `threadId` of every file in `R` other than `R/<$S/ref.txt>.json` that is not stale.
   Stale rule: `ListAgents`; if it errors or prints no self line, treat every file as live; else a file is stale
   when its `started_at` is older than 7 days, or it is not `"fallback": true` and its `ref` is in no ListAgents
   row (never match by name alone). Do not delete files here.
2. **Find the threads:**
   - `$S/thread-ids.txt` or `$S/thread.txt` exists → the candidates are exactly those `threadId`s (all re-runs of
     this session). No name search: it would also catch threads of earlier, ended sessions with the same name,
     whose user instructions are not in this `$S` and would never be archived.
   - Only when `$S` is missing, or the user asks for it in chat: `search_threads(query="from:me to:me
     subject:(\"<N> flows\" status)", pageSize=50, view="THREAD_VIEW_SUMMARY")`, page through `pageToken`.
   Keep a candidate only if its subject matches `[<N> flows] status` exactly (optionally with the `[URGENT …]`
   prefixes), `get_thread(METADATA_ONLY)` shows its first message's snippet starting with `🤖`, and its id is not
   protected. Everything else — other sessions' threads, other self-mails, other senders — is never touched.
3. **Archive** to `<project handover dir>/away-mode-archive/<YYYY-MM-DD>-<threadId>.md` when the project has a
   handover folder (e.g. the active `RESUME.md`'s directory), else `~/.claude/away-mode-archive/`. Content:
   thread subject and date range; `$S/decisions.md` verbatim; `$S/urgent-open.md` if non-empty; for every message
   id in `$S/handled-ids.txt` (the user's mail instructions) the text above the quoted part
   (`get_message(PLAIN_TEXT)`); a one-line list of the agent mails (date + subject). Never write the user's e-mail
   address into the file.
4. **Trash:** `trash_thread(threadId)` per kept thread. Trash is recoverable in Gmail for 30 days; never delete
   permanently.
5. **Verify:** `get_thread` on each trashed id shows the `TRASH` label (name search: the same query no longer
   returns them).
6. **Chat:** threads trashed (count + subjects), archive path, any open urgent item ("trashed although open: …").
   Keep `$S` as is.

The user asks in chat for **all** status threads → match `[<anything> flows] status` in step 2 instead; protected
ids stay untouched.

## Common mistakes

| Mistake | Reality |
|---|---|
| Trashing by sender only (`from:me to:me`) | Catches the user's own notes to self. Subject pattern + `🤖` first message are both required. |
| Trashing every `[… flows] status` thread | Other sessions may still be away. Only `[<N> flows]`, never a live peer's `threadId`. |
| Searching by name when `$S` has the thread ids | Also hits earlier sessions with the same name. Use `thread-ids.txt` / `thread.txt`. |
| Trashing before archiving | `decisions.md` lives in the scratchpad and dies on reboot; archive first. |
| Permanent delete | Trash only. |
| Address in the archive file or chat | The address appears only inside Gmail tool calls. |
