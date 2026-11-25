# away-mode-cleanup (personal)

Archives the away-mode state (decisions, open urgent items, the user's mail instructions) to a local file, then
moves this session's `[<session name> flows] status` Gmail threads to trash. Threads of other sessions still in
away mode (registry `~/.claude/state/away-mode/sessions/`) are never touched. Called by `away-mode-off`.

- Placeholders: none (literal personal skill).
- Prerequisites: claude.ai Gmail connector loaded in the session; the `away-mode` state dir in the scratchpad
  (optional — without it only the trash step runs, by session name).
- OS/shell: none (Gmail tools only).
- Install by hand: copy this folder to `~/.claude/skills/away-mode-cleanup/`.
- Verify: after a run, Gmail search `from:me to:me subject:("<session name> flows" status)` returns nothing, other
  sessions' threads are still there, and the archive file exists.
