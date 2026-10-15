---
name: interactive-questions-mode-on
description: Use when the user wants open questions and decisions asked interactively again instead of auto-decided — phrases like "interactive questions on", "ask me again", "questions mode on", "turn questions back on", "/interactive-questions-mode-on". Global and project-agnostic; works from any cwd. Counterpart of interactive-questions-mode-off.
---

# interactive-questions-mode-on

## Overview

Switches the **global** question mode to **ON**: every open question or decision goes through
`AskUserQuestion` and the agent waits for the answer. The mode persists across sessions as a
managed block in `/home/alex/.claude/CLAUDE.md` and applies **immediately** in the current session.
`interactive-questions-mode-off` writes the same block with the OFF text. Exactly one block exists.

## The managed block

Markers (exact lines, shared with the OFF skill):
`<!-- interactive-questions-mode:begin -->` and `<!-- interactive-questions-mode:end -->`.

Placement when creating it: at the end of the `## Before coding` section (after its bullet list,
directly before the next `## ` heading). When it already exists, replace its content **in place** —
never move it, never add a second one.

ON content (between the markers, verbatim):

```markdown
**Interactive questions mode: ON** (toggle with `interactive-questions-mode-off`). Overrides the
question rules above. Every open question or decision goes through AskUserQuestion — concrete
options, recommended one first, batch up to four related questions per prompt — then wait for the
answer. This applies in unattended and subagent-driven runs too, wherever AskUserQuestion is available.
```

## Steps

1. `grep -n 'interactive-questions-mode:' /home/alex/.claude/CLAUDE.md`
   - **One begin + one end** → Read the file, `Edit` the lines between the markers to the ON content.
   - **None** → `Edit`: insert begin marker, ON content, end marker at the placement above.
   - **Anything else** (one marker, duplicates) → collapse to one pair holding the ON content; delete
     only stray markers and old mode text, never other lines; report it.
2. Verify: `grep -c 'interactive-questions-mode:begin' /home/alex/.claude/CLAUDE.md` and
   `grep -c 'interactive-questions-mode:end' /home/alex/.claude/CLAUDE.md` must each print `1`;
   `grep -n 'Interactive questions mode: ON' /home/alex/.claude/CLAUDE.md` must hit inside the pair.
3. Memory note — only if it exists:
   `/home/alex/.claude/projects/-home-alex-Entwicklung-bpp/memory/autonomous-runs-no-interactive-questions.md`
   - frontmatter `description:` → `Governed by the interactive-questions-mode block in ~/.claude/CLAUDE.md; currently ON (ask via AskUserQuestion). The rules below apply only while the mode is OFF.`
   - first body line: if it already starts with `Governed by`, replace that line; otherwise insert a
     new first body line (never overwrite the original rule text) → `Governed by the interactive-questions-mode block in ~/.claude/CLAUDE.md — currently ON: ask via AskUserQuestion and wait. Rules below apply only when the mode is OFF.`
   - Keep the rest of the note. Do not create memory files anywhere.
4. Reply in one line: `Interactive questions mode is ON — persists across sessions until toggled with interactive-questions-mode-off; active now.`
5. From this point in the session, follow the ON rule.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Appending a new block when one exists | Replace in place; grep counts must stay at 1 |
| Rewording the markers | Exact strings — the OFF skill finds the block by them |
| Editing the rest of CLAUDE.md (e.g. the "Ask when genuinely unclear" bullet) | Touch only the managed block |
| Using `sed -i` / shell rewrite on CLAUDE.md | Use the Edit tool, then verify with grep |
| Creating the memory note when missing | Skip it; mention it in the reply |
| Saying "ON" without the grep check | Verify first, then confirm |

## Red Flags — STOP

- grep shows 2+ begin markers after your edit → fix before confirming.
- About to change anything outside the markers in CLAUDE.md → STOP.
- Mode is ON but you are still auto-picking options in this session → ask instead.
