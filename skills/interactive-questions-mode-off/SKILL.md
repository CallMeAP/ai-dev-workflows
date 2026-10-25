---
name: interactive-questions-mode-off
description: Use when the user wants Claude to stop asking questions and decide on its own — phrases like "interactive questions off", "don't ask me", "stop asking", "auto-pick recommended", "power through", "just decide", "/interactive-questions-mode-off". Switches the global, cross-session question mode to OFF. Project-agnostic; works from any cwd.
---

# Interactive questions mode: OFF

## Overview

Sets the global question mode to **OFF**: never call AskUserQuestion, never stop to wait for input,
pick the recommended option, log it, keep going. Counterpart: `interactive-questions-mode-on`.

**The state lives in one place:** a managed block in `/home/alex/.claude/CLAUDE.md`, between these
exact marker lines. Both mode skills rewrite only what is between them.

```
<!-- interactive-questions-mode:begin -->
<!-- interactive-questions-mode:end -->
```

Placement: at the end of the `## Before coding` section, directly after its bullet list (which holds
the AskUserQuestion bullet) and before `## Simplicity first`.

## Steps

### 1. Check the current state

```bash
grep -n 'interactive-questions-mode:' /home/alex/.claude/CLAUDE.md
```

- **0 lines** → block missing; insert it (step 2) after the last bullet of `## Before coding`.
- **exactly 1 begin + 1 end** → replace everything between them (step 2).
- **anything else** (duplicates, a lone marker) → collapse to one pair in the right place, then step 2.
  Never append a second block.

### 2. Write the OFF block with the Edit tool

Use Edit (not sed/echo). The block content, verbatim:

```markdown
<!-- interactive-questions-mode:begin -->
**Interactive questions mode: OFF** (toggle with `/interactive-questions-mode-on`). Overrides the
"ask" bullets above, in every session until toggled:
- Never call AskUserQuestion and never stop to wait for input. Pick the option you would label
  "(Recommended)" and keep going.
- Append each such choice to a "Decisions taken automatically" list — decision, options considered,
  choice, why — and report it in the task's final message and in any handover file.
- Hard safety gates still STOP: write gates on, prod writes, secret exposure, destructive or
  irreversible actions.
- Outward-facing or irreversible actions not already authorized (push, merge, MR, message, deploy,
  delete) are prepared but not executed, and listed as pending.
<!-- interactive-questions-mode:end -->
```

### 3. Verify — read back, don't assume

```bash
grep -c 'interactive-questions-mode:begin' /home/alex/.claude/CLAUDE.md   # must be 1
grep -c 'interactive-questions-mode:end'   /home/alex/.claude/CLAUDE.md   # must be 1
sed -n '/interactive-questions-mode:begin/,/interactive-questions-mode:end/p' /home/alex/.claude/CLAUDE.md
```

The printed block must say `OFF`. Anything else → fix and re-run.

### 4. Update the memory note (only if it exists)

File: `/home/alex/.claude/projects/-home-alex-Entwicklung-bpp/memory/autonomous-runs-no-interactive-questions.md`.
If present, Edit exactly two lines (same wording pattern as the ON skill, so either skill finds them):

- frontmatter `description:` → `Governed by the interactive-questions-mode block in ~/.claude/CLAUDE.md; currently OFF (auto-pick recommended, log, power through). The rules below apply only while the mode is OFF.`
- first body line → `Governed by the interactive-questions-mode block in ~/.claude/CLAUDE.md — currently OFF: auto-pick recommended, log, power through. Rules below apply only when the mode is OFF.`
  If the first body line does not already start with `Governed by`, insert this as a new first line
  above it — the existing first line holds the rule itself; never overwrite it.

Keep the rest of the note. If it is missing, skip and mention it — do not create memory files anywhere.

### 5. Confirm in one line

> Interactive questions mode is now **OFF** — I pick the recommended option, log it, and keep going.
> Persists across sessions until `/interactive-questions-mode-on`.

## Applies immediately

From the moment the block reads OFF, this session follows it too — including the rest of the
current task. Do not ask "are you sure?" before switching; the user asking IS the decision.

## Red flags

| Thought | Reality |
|---|---|
| "This one question is important enough to ask anyway" | Mode OFF means no AskUserQuestion. Pick the recommended option, log it. |
| "The user wants just this one group asked, but keep OFF" | Use `/interactive-questions-once` — asks one group, leaves this block and the mode untouched. |
| "Off means I can push/merge/delete without asking" | No. Unauthorized outward or irreversible actions are prepared and listed as pending. |
| "Safety gate? The user said power through" | Hard gates (prod writes, secrets, destructive ops) still STOP. |
| "I'll just append the block at the end of the file" | One block, between the markers, in `## Before coding`. Never a second copy. |
| "The Edit succeeded, done" | Grep: exactly one begin and one end, content says OFF. |
| "I'll mention my choices only if asked" | The decisions list goes in the final message, always. |
