# audit-my-memories

## Placeholders

**None — this is a personal skill.** Per the sync convention other personal skills in this
runtime directory follow, it keeps literal absolute paths (`/home/alex/...`,
`~/.claude/projects/...`) rather than `{{PLACEHOLDER}}`-style templates. On another machine or for
another developer, those paths need adjusting by hand — templating that is the job of a move into
a shared skills location, not of this file.

## Prerequisites

- **`python3`** — Part 2a's integrity checker (broken `[[links]]` + `MEMORY.md` row check) is a
  small inline script, no extra packages.
- **`glab` authenticated** (`glab auth status`) — only needed for Part 1's live-repo verification
  step when the memory directory describes work in a BPP/GitLab repo (`glab mr view`,
  `glab api .../merge_requests/<iid>`), and for Part 4's mirror MR.
- **`git`** — for the live-repo verification checks in Part 1 and, for the bpp-backend mirror sync
  in Part 4, for the worktree + branch + push.
- **The relevant source repos checked out locally** — Part 1's "verify against current state" step
  is only as good as the checkout it greps. A stale or missing checkout produces a false verdict;
  `git fetch` before trusting a "still true" or "now false" conclusion.
- **For Part 4 only:** the `agentic-coding-knowledge` repo cloned at
  `/home/alex/Entwicklung/lipso/agentic-coding-knowledge`, and read access to
  `personal-workflows/apittrich/memory/SYNC.md` there (it's the actual source of truth for the
  mirror contract — this skill summarizes it, but SYNC.md wins on any disagreement).

## Repo layout it assumes

- Memory directories live at `~/.claude/projects/<project-slug>/memory/`, one `.md` file per
  memory plus an index `MEMORY.md`, optionally with `memory-hub-*.md` files grouping related
  pointers by topic (the pattern the bpp-backend directory uses once it grows past ~150 files).
- A memory file's `[[wikilink]]`s reference other files by their frontmatter `name:` value, **not**
  their filename — the two can and do differ (deliberately, in some files). The integrity checker
  in Part 2a accounts for this; don't grep filenames directly.
- The bpp-backend mirror lives in a *different* repo entirely
  (`lipso/internal/agentic-coding-knowledge` on GitLab) under
  `personal-workflows/apittrich/memory/`, governed by its own `SYNC.md` — separate from the
  top-level `personal-workflows/apittrich/SYNC.md` that governs skills/workflow docs.

## Shell / OS assumptions

Linux + bash, nothing exotic. The Part 2a script is plain `python3` (standard library only —
`re`, `os`, `glob`). The Part 3/4 secret scans are plain `grep -E`/`grep -P`. `sed -i` (GNU form,
no `-i ''`) is used for the small in-place redaction edits in Part 4.

Verified on this machine 2026-09-14: Python 3.12, GNU sed, glab 1.x.

## After install

Read **Part 1's "one rule that matters more than the other four combined"** before running this
against a real memory directory for the first time — it's the difference between a useful audit
and one that quietly downgrades good memories to "probably stale" on a guess. Everything else in
the skill is mechanical by comparison.

If you're running this on a memory directory for the first time (no prior audit to compare
against), expect the initial pass to take real wall-clock time proportional to file count — the
founding run read all 226 bpp-backend files plus 31 across eight smaller directories. A *repeat*
run only needs to re-check what changed since the last audit, which is much cheaper and is exactly
the case this skill's "use a cheap model" guidance is written for.

## Install

Personal skills are not templated and not rendered by any install script. This one already lives
at `~/.claude/skills/audit-my-memories/` — nothing further to copy. If restoring it on another
machine, copy the directory by hand and adjust the literal paths in `SKILL.md`/this file to match
that machine's layout.

Invoke it bare (`/audit-my-memories`, or ask "audit my memories") — it will ask which project's
memory directory if more than one exists and none was named.

## Verify it works

Read-only — this doesn't edit anything:

```bash
# 1. the integrity checker actually runs against a real directory
cd ~/.claude/projects/-home-alex-Entwicklung-bpp-bpp-backend/memory/ 2>/dev/null && python3 -c "
import re, os, glob
files = [f for f in glob.glob('*.md') if f != 'MEMORY.md']
print(f'{len(files)} memory files found')
" || echo "adjust the path to a memory directory that exists on this machine"

# 2. glab is authenticated, for the live-verification step
glab auth status

# 3. the mirror repo + its SYNC.md are where Part 4 expects (only relevant for bpp-backend)
test -f /home/alex/Entwicklung/lipso/agentic-coding-knowledge/personal-workflows/apittrich/memory/SYNC.md \
  && echo "mirror SYNC.md found" || echo "mirror repo not cloned here — Part 4 not usable on this machine"
```

Step 1 should print a file count close to what `ls ~/.claude/projects/<project>/memory | wc -l`
reports (minus one, for `MEMORY.md` itself). Step 3 failing just means Part 4 (the bpp-backend
mirror sync) isn't usable on this machine — Parts 1–3 work on any memory directory regardless.

---

*Written by an agent from the founding 2026-09-14 audit run (226 bpp-backend memory files + 31
across eight other project directories) and the two audit reports it produced, not dictated by
the skill's owner — @apittrich should confirm it captures what that audit actually learned.*
