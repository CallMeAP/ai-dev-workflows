# away-mode-cleanup (personal)

Archives the away-mode state (decisions, open urgent items, the user's mail instructions) to a local file, then
moves the agent's `[<project> flows] status` Gmail threads to trash. Called by `away-mode-off`.

- Placeholders: none (literal personal skill).
- Prerequisites: claude.ai Gmail connector loaded in the session; the `away-mode` state dir in the scratchpad
  (optional — without it only the trash step runs).
- OS/shell: none (Gmail tools only).
- Install by hand: copy this folder to `~/.claude/skills/away-mode-cleanup/`.
- Verify: after a run, Gmail search `from:me to:me subject:(flows status)` returns nothing and the archive file exists.
