---
name: interactive-questions-once
description: Use when the user wants the current pending decision asked interactively one time while the global question mode stays OFF — phrases like "ask me this once", "ask these questions interactively but keep the mode off", "one-time interactive questions", "ask me just this one", "/interactive-questions-once". Global and project-agnostic; works from any cwd. One-shot override, not a toggle.
---

# interactive-questions-once

## Overview

One-shot override: asks **one question group** (up to four questions) through `AskUserQuestion`,
applies the answers, then the session falls back to the global mode. It **never** writes the
managed block in `/home/alex/.claude/CLAUDE.md` and never switches the mode — that is what
`interactive-questions-mode-on` / `interactive-questions-mode-off` are for.

## Steps

1. Check the global mode (read-only):
   `sed -n '/interactive-questions-mode:begin/,/interactive-questions-mode:end/p' /home/alex/.claude/CLAUDE.md`
   - Says **ON** → note "mode is already ON — asking normally" and continue with step 2.
2. Collect the pending decision(s) from the current context: open questions, options you were about
   to auto-pick, items already in the "Decisions taken automatically" list that are not yet acted on.
   - **None** → reply in one line: `No pending decision to ask about — mode stays OFF.` and stop.
3. Call `AskUserQuestion` **once**: up to four related questions, concrete options, recommended
   option first and labelled "(Recommended)". More than four pending → ask the four with the most
   impact; the rest stay auto-picked and logged.
4. Wait for the answer. Apply it; if it reverses an earlier auto-pick, update that entry in the
   "Decisions taken automatically" list ("asked once — user chose X").
5. Resume under the global mode. With mode OFF: no further `AskUserQuestion`, auto-pick the
   recommended option and log it for every later decision.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Editing the managed block or the memory note `autonomous-runs-no-interactive-questions.md` | Read-only here; toggling belongs to the mode skills |
| Treating the override as sticky and asking again later in the session | One `AskUserQuestion` call, then mode OFF applies again |
| Inventing questions when nothing is pending | Say so in one line and stop |
| Splitting the group into several prompts | Batch up to four into one call |
| Options without a recommendation | Recommended option first, labelled "(Recommended)" |

## Red Flags — STOP

- About to `Edit` `/home/alex/.claude/CLAUDE.md` → STOP; this skill never changes the mode.
- About to call `AskUserQuestion` a second time after the group was answered → auto-pick and log instead.
