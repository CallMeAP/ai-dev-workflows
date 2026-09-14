---
name: audit-my-memories
description: Use when periodically auditing a Claude Code auto-memory directory (`~/.claude/projects/<project>/memory/`) for staleness, contradictions, redundancy and integrity — phrases like "audit my memories", "check my memory files", "are my memories stale", "clean up my memory directory", "run the memory audit". Also covers publishing an audited bpp-backend memory set to its knowledge-repo mirror per SYNC.md. Runs on a cheap/fast model — the work is bounded verification, not open-ended reasoning.
---

# Audit a Claude Code memory directory

## Overview

Memory files (`~/.claude/projects/<project>/memory/*.md` + their `MEMORY.md` index) drift the
same way code comments do: a file records "MR !259 OPEN" and is never revisited after the MR
merges three weeks later. Left alone, a memory directory accumulates stale status lines, a few
genuine contradictions, and duplicate content — and a stale memory is worse than no memory,
because it gets trusted.

This skill audits one memory directory, classifies every file into one of **four buckets**
(Obsolete / Contradicting / Redundant / Fine), applies the recommended fix for each, then runs
three mechanical integrity checks (`[[links]]`, `MEMORY.md` rows, frontmatter schema) and a
secret scan before anything is called done. For the `bpp-backend` project specifically, it also
covers syncing the audited result to its GitLab knowledge-repo mirror.

**Founding run:** 2026-09-14, `~/.claude/projects/-home-alex-Entwicklung-bpp-bpp-backend/memory/`
(226 files) plus a lighter pass over 8 smaller project memory directories (31 files). That run was
deliberately done on a stronger model given the scale and the cost of getting the four-bucket
classification wrong the first time. **Routine re-runs of this skill do not need that** — the
verification steps below are bounded lookups (a `git log`, a `glab mr view`, a grep of live
source), not creative judgement calls, so a cheap/fast model is the right default going forward.

## When to Use

- "audit my memories", "check my memory files for staleness", "clean up the memory directory"
- Periodically (monthly, or whenever a memory directory feels large / a session recently caught
  itself trusting a stale status line) — not something to run on every session.
- "sync the memory mirror" / "publish memory to the knowledge repo" (bpp-backend only, see Part 3)

## Scope resolution

The argument is a project memory directory. Resolve it, never guess:

```bash
ls -d ~/.claude/projects/*/memory | sort
```

If no argument is given, ask which one, or default to the one the user most recently worked in
(check the session's own project path). A directory with `MEMORY.md` missing is not this skill's
problem to invent — report it and stop for that directory.

## Part 1 — Classify every file into one of four buckets

### The one rule that matters more than the other four combined

**A claim is only OBSOLETE once VERIFIED against the CURRENT state of whatever it describes —
never on assumption, training data, or "this is probably merged by now."** Acceptable evidence:
a `git log` / `git show <branch>:<path>` against the actual repo, `glab mr view <iid>` /
`glab api .../merge_requests/<iid>`, a live grep of current source, or (for a non-code claim) a
direct check of whatever system the memory describes. If you cannot verify a claim this session,
**leave the memory as-is and say so explicitly** — do not downgrade it to "probably fine" or
"probably stale" without evidence either way. This mirrors the project's own no-speculation rule:
state something as fact only if verified this session; mark everything else "unverified."

### Splitting large corpora

Above roughly 30–40 files, read every file yourself first (cheap: memory files are short), then
split into topic groups (mirroring the directory's own `MEMORY.md` section structure, e.g. VERA /
Qodana / Testing-CI / Auth) and verify each group's checkable claims — either yourself in sequence
or by dispatching one subagent per group in parallel, each instructed to verify against **live
repo state, never against training-data assumptions**, and to report back exactly what it checked
and how. Two independent agents accidentally covering the same file is harmless (note the overlap,
keep the agreeing verdict); two agents each skipping a file because they assumed the other had it
is not — assign groups by an explicit file list, not a vague range.

### The four buckets

1. **OBSOLETE** — the file was true when written, but the thing it describes has since changed
   (an MR merged, a flag flipped, a bug got fixed) and the file's status line still claims the old
   state. This is the dominant failure mode — expect it to be 15–20% of a stale directory. **Fix:
   update the status/claim, keep the technical content and root-cause analysis** (that part is
   usually still correct and is the expensive part to reconstruct). A small number are more
   serious: the file asserts something about *current* behavior that has since changed, which is
   actively misleading rather than just dated — flag these as higher priority.
2. **CONTRADICTING** — two files (or two sections of the corpus) disagree about the current state
   of the same thing. Resolve which one is right by direct verification (never by recency of the
   `modified` timestamp alone — the more recently modified one is not automatically correct), fix
   the wrong one, and say so explicitly since this is the highest-confusion-risk class: a reader
   trusting the wrong half can re-do already-finished work or re-report an already-fixed bug.
3. **REDUNDANT** — two or more files say the same thing. For each group, pick a survivor (usually
   the more complete or more recently touched one) and either **merge + delete** (carry every
   unique detail from the deleted file into the survivor before removing it — never drop content
   silently) or, if both files have enough unique content to justify keeping both, **trim** the
   duplicated paragraph out of one and leave a pointer to the other.
4. **FINE** — no action. Spot-check a sample of this bucket against live state anyway (don't just
   accept it on faith) — the point of an audit is that "looks fine" and "verified fine" are not
   the same claim.

**A fifth, softer category worth flagging but not automatically acting on:** files that are
mostly a one-off session diary (dated, commit-by-commit entries) with a durable kernel buried
inside. Recommend trimming the day-by-day noise down to the final decision, but treat this as
lower priority than the four buckets above — it costs the most bytes for the least information
loss, but also carries the most risk of losing a detail nobody will think to ask about again.
Only actually trim when explicitly asked to, or when the audit's own highest-value-fixes ranking
puts it first; do not do it opportunistically while fixing something else in the same file.

### Applying fixes — rules

- **Preserve each file's frontmatter schema and voice.** Don't rewrite a terse file to be verbose
  or vice versa.
- **Keep `name:` slugs stable** unless fixing a kebab-case defect (see Part 2) — and if you do
  rename one, fix every inbound `[[link]]` in the same pass, not "later."
- **Never delete a file the audit didn't explicitly recommend deleting.** When merging, carry the
  surviving detail across before deleting — check the deleted file one more time immediately
  before removing it, for anything you might have missed.
- **Do not invent facts.** If a claim in the source material says "unverified," leave the memory
  as unverified too; don't upgrade its confidence because it would be convenient.
- Update the file's own `MEMORY.md` row (and any hub file's row) to match, in the same pass — a
  file fix that leaves the index quoting the old status just moves the staleness one level up.

## Part 2 — Integrity checks (mechanical, run these every time)

### 2a. Broken `[[link]]` + `MEMORY.md` row check

Every `[[wikilink]]` must resolve to some file's `name:` frontmatter value (not the filename —
they can differ). Every `MEMORY.md` row must point at a file that exists, and (for a directory
with hub files) every file must be reachable from `MEMORY.md` directly or via a hub. Run this
after every batch of edits, not just once at the end:

```bash
cd ~/.claude/projects/<project>/memory/ && python3 << 'EOF'
import re, os, glob
files = [f for f in glob.glob("*.md") if f != "MEMORY.md"]
names = {}
for f in files:
    c = open(f, encoding='utf-8').read()
    m = re.search(r'^name:\s*(.+)$', c, re.MULTILINE)
    if m: names[m.group(1).strip()] = f
    else: print(f"NO name: frontmatter in {f}")
broken = [(f, link.strip()) for f in files
          for link in re.findall(r'\[\[([^\]|#]+)\]\]', open(f, encoding='utf-8').read())
          if link.strip() not in names]
print("BROKEN LINKS:", broken)
mem = open("MEMORY.md", encoding='utf-8').read()
rows = re.findall(r'\[([^\]]+)\]\(([^)]+)\)', mem)
print("Missing MEMORY.md targets:", [p for _, p in rows if not os.path.exists(p)])
referenced = set(p for _, p in rows)
hub_referenced = set()
for hf in [f for f in files if f.startswith("memory-hub-")]:
    for _, p in re.findall(r'\[([^\]]+)\]\(([^)]+)\)', open(hf, encoding='utf-8').read()):
        hub_referenced.add(p)
unreferenced = [f for f in files if f not in referenced | hub_referenced and not f.startswith("memory-hub-")]
print("Files reachable from nowhere:", unreferenced)
EOF
```

**Known false positive:** a `MEMORY.md` row whose *title* contains its own `[...]` (e.g.
`[Paging DTO: clamp not [Range]](file.md)`) breaks the row-matching regex above — the file is
still fine, just spot-check it by eye before reporting it missing.

### 2b. Frontmatter schema check

Every file should use nested `metadata: { type: ... }`, not a flat top-level `type:` field, and
`name:` should be a kebab-case slug — no spaces, no capitals, no underscores, matching what other
files' `[[links]]` actually use to reference it (grep for existing inbound links to a file *before*
renaming it, so you know what to fix):

```bash
for f in *.md; do [ "$f" = MEMORY.md ] && continue
  grep -qE '^type:' "$f" && echo "FLAT type: $f"
  name=$(grep -m1 '^name:' "$f" | sed 's/^name: *//')
  echo "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || echo "NON-KEBAB name: $f -> $name"
done
```

When fixing a non-kebab name, prefer the kebab form other files *already* link to (grep first) —
that fixes the maximum number of broken links for free instead of creating new ones.

## Part 3 — Secret scan (do this before calling anything done, including a plain local edit)

**Never pipe a credential-bearing file through a naive redactor and never `cat`/dump a config
file that might hold a secret**, even "just to check." This is not a hypothetical: in the
founding run, a verification step grepped a live `appsettings.local.json` through a redaction
pipe that failed silently, and the real value it was supposed to mask landed unredacted in that
step's own tool output. The memory *file itself* was fine (it only pointed at the config file's
location, never embedded a value) — the leak was in the verification method, not the content
being audited.

**The safe pattern: grep for the KEY NAME, or check the file merely exists — never print the
value.**

```bash
# Confirm a credential-bearing file exists / has the key present, without ever showing its value:
grep -q '^ClientCertificatePassword' path/to/appsettings.local.json && echo "key present"
test -f path/to/creds-file && echo "file exists"
# NEVER: cat path/to/appsettings.local.json | some-redactor   (a failed pipe leaks the raw value)
```

Within the memory files themselves, grep for actual secret-shaped values before calling the
directory clean:

```bash
grep -rniE "(client.?secret|api.?key|private.?key|signing.?key|password|pwd)\s*[:=]\s*['\"]?[A-Za-z0-9+/=_-]{12,}" .
```

Read every hit by eye. A memory file that only *points at* where a credential lives (a file path,
a "see local_debugging.md §1") is fine and common — that's the correct pattern. A memory file that
contains a reproducible value is not, and gets fixed the same way regardless of directory: replace
the value with a pointer to its location, never leave it embedded.

## Part 4 — Mirror sync (bpp-backend memory only, optional)

`~/.claude/projects/-home-alex-Entwicklung-bpp-bpp-backend/memory/` has a published, redacted
mirror at `personal-workflows/apittrich/memory/` in
`/home/alex/Entwicklung/lipso/agentic-coding-knowledge`. **`memory/SYNC.md` in that repo is the
source of truth for this — read it at runtime, don't rely on this summary if they disagree:**

```bash
cat /home/alex/Entwicklung/lipso/agentic-coding-knowledge/personal-workflows/apittrich/memory/SYNC.md
```

- **Direction is source → mirror.** The local memory directory is authoritative; the mirror is a
  published copy with secrets redacted. Before assuming the reverse, check evidence: a file that
  exists only in the mirror, or whose mirror content is *not* a prefix/subset of the local
  version, is real signal the mirror moved ahead — verify, don't assume staleness runs one way.
- **Isolate your work in a worktree**, especially if another branch might be active in the main
  clone (`git worktree add ../agentic-coding-knowledge.worktrees/<slug> -b docs/<slug>
  origin/main`) — never touch another branch's uncommitted state.
- **Rsync source → mirror:** `rsync -a --delete --exclude SYNC.md <source>/ <mirror>/`
- **The grep-gate is not optional — zero hits on all of these before committing:**
  ```bash
  cd <mirror-memory-dir>
  grep -rniE "PGPASSWORD=[^ \`<]|password=[a-zA-Z0-9]" .        # passwords / connection strings
  grep -rEo "\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b" . \
    | grep -vE "^127\.0\.0\.1$"                                  # real IPv4 literals (review each hit — version numbers like 21.0.12.1 false-positive on this shape)
  grep -rE "\b000[0-9A-Za-z]{17}\b" .                             # VERA customer/contract/claim OIDs
  grep -rniE "\b(<known real first/last names or surnames from the source>)\b" .   # customer/person names — build this list from what you actually saw while reading, don't skip it
  ```
  Redact each real hit with the established placeholder shape from SYNC.md's table
  (`<vera-oid>`, `<vera-dev-host>:<port>`, `<contact>@<insurer>`, initials for a person name,
  etc.) — apply the SAME placeholder convention already used elsewhere in the mirror, don't invent
  a new one. Re-run the whole gate after redacting, not just the one pattern you fixed.
- **Also spot-check any newly-mirrored security-labelled memory** (a file whose description says
  SECURITY, or that documents a real committed-credential / exposed-key finding) for an actual
  reproducible secret value, even if it wasn't caught by the generic gate above — these are exactly
  the files most likely to have one, and most costly to leak.
- **Commit, push a `docs/*` branch, open an MR — do not push the mirror's `main` directly** unless
  `memory/SYNC.md`, read fresh, explicitly says otherwise for this exact change. Reviewer
  `apittrich`. See the `sync-my-skills` skill's Steps 6–7 for the exact `glab api` MR-creation
  recipe (`glab mr create` is unreliable in this environment).
- **State your scope decision.** If other project memory directories exist with no mirror rule at
  all, that's a real gap worth surfacing to the user each time (recommend extending `SYNC.md`'s
  scope, or documenting them as deliberately local-only) — don't silently mirror them without a
  scope rule, and don't silently ignore the gap either.

## Quick Reference

| Step | Action |
|---|---|
| Scope | `ls -d ~/.claude/projects/*/memory` — never guess which directory |
| Classify | 4 buckets: Obsolete (fix status, keep content) / Contradicting (verify + fix the wrong one) / Redundant (merge+delete or trim) / Fine (spot-check anyway) |
| The rule | OBSOLETE only with a fresh, cited verification (git log / glab / live grep) — never from assumption |
| Large corpus | split into topic groups, verify each against live state, one subagent per group if parallelizing |
| Fix | preserve schema/voice, keep `name:` stable unless kebab-fixing, never delete without the audit saying so, no invented facts |
| Integrity | the python link/MEMORY.md script (2a) after every batch of edits |
| Schema | flat `type:` → nested `metadata: {type:}`; non-kebab `name:` → kebab matching existing inbound links |
| Secrets | grep KEY NAMES, never pipe/cat a credential file; read every hit by eye |
| Mirror (bpp-backend) | read `SYNC.md` fresh, worktree, rsync source→mirror, grep-gate = 0 hits, `docs/*` branch + MR, never mirror `main` directly |
| Model | cheap/fast by default; this founding run used a stronger model deliberately |

## Common Mistakes

- **Piping a credential-bearing config file through a redaction script "just to check."** A failed
  pipe leaks the raw value into your own tool output — the exact incident this skill exists partly
  to prevent. Grep for the key name, or confirm the file exists; never print its content.
- **Marking something OBSOLETE from training-data intuition** ("this MR is probably merged by
  now") instead of an actual `git log`/`glab` check this session. If you can't verify it, say
  "unverified," don't guess in either direction.
- **Deleting a file the audit didn't explicitly recommend deleting.** Trimming and merging are not
  the same license as deleting.
- **Merging two files and dropping the deleted one's unique content.** Read the file one more time
  immediately before removing it.
- **Renaming a `name:` slug without fixing every inbound `[[link]]` in the same pass** — this
  trades one broken-link defect for a different one.
- **Running the integrity check once, at the start, and trusting it for the rest of the session.**
  Re-run it after every batch of edits — a rename or delete three files later can silently reopen
  a link you already "fixed."
- **Treating the mirror as bidirectional.** It's source → mirror per `SYNC.md`. A file that exists
  only in the mirror is a real finding to investigate, not something to blindly pull into local.
- **Trimming a "diary" file's day-by-day history opportunistically** while fixing something else in
  it. That's real, reconstructable history — only trim it when it's the explicit task, not a
  side-effect of an unrelated status-line fix.
- **Re-using a stale local branch/worktree from a previous audit run** for the mirror MR instead of
  branching fresh off `origin/main` — a weeks-old branch mixes old and new redaction work in one
  diff and makes the grep-gate harder to trust.

## Red Flags — STOP

- About to mark a memory **OBSOLETE** or **FINE** without a verification you can cite (a specific
  command, its output, a specific commit/MR) from **this session** → STOP, verify first or leave it
  as-is and say so.
- About to **delete** a memory file the classification step didn't explicitly call out → STOP.
- Any grep-gate check in Part 3/4 returns a hit → STOP, do not commit; redact and re-run the whole
  gate.
- About to **pipe or `cat` a file that might hold a credential** (`appsettings.local.json`,
  `*.env`, anything a memory file itself flags as creds-bearing) → STOP; grep for the key name or
  confirm existence only.
- About to **overwrite local memory content from the mirror** → STOP; the documented direction is
  source → mirror. Verify which side is actually ahead before touching either.
- About to **push directly to the mirror repo's `main`** → STOP; re-read `SYNC.md` fresh — this
  audit's own run used a `docs/*` branch + MR, and the parent `SYNC.md`'s standing push-approval is
  scoped to skills/workflow docs, not (necessarily) memory. Don't assume it carries over.
