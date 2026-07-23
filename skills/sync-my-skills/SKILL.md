---
name: sync-my-skills
description: Use when publishing or syncing personal skills from the runtime skills directory into the canonical skills repo and its published mirror — phrases like "sync my skills", "publish this skill", "push my skills to the repo", "sync-my-skills", "did my new skill make it into the repo", "mirror my skills". Project-agnostic; works from any cwd.
---

# Sync personal skills into the canonical repo (+ mirror)

## Overview

Copies personal skills from the live runtime skills directory (`/home/alex/.claude/skills/`) into the canonical skills repo, mirrors them to the published copy, and pushes **both** remotes. It is **additive/update-only** — it never deletes and never overwrites newer repo content.

**`SYNC.md` in the canonical repo is the source of truth.** Read it at runtime and obey it — it defines the canonical→mirror rule, the tracked-file scope, and the standing push approval. Do not hardcode assumptions this file might contradict; SYNC.md wins.

Canonical repo: `/home/alex/Entwicklung/ai-dev-workflows` (remote `main`). SYNC.md names the published mirror and both remotes.

## When to Use

- "sync my skills", "publish this skill", "push my skills to the repo", "mirror my skills"
- After creating or editing a skill under `/home/alex/.claude/skills/` and wanting it in the repo.
- Verifying whether a local skill is already synced ("did X make it into the repo").

## Argument (optional)

- **`sync-my-skills <skill-name>`** → sync just that one skill directory.
- **No argument** → diff every skill under `/home/alex/.claude/skills/` against its repo copy and sync everything **new or changed**. Report per skill: **new / updated / unchanged**.

## Steps

### 1. Read SYNC.md first — obey it

```bash
cat /home/alex/Entwicklung/ai-dev-workflows/SYNC.md
```

If **SYNC.md is missing** → STOP and report; do not sync (you cannot know the mirror rule or push approval). Everything below follows the current SYNC.md; if it and this skill disagree, **SYNC.md wins**.

### 2. Discover where skills live in the repo (don't hardcode)

Find the canonical skills subpath by looking at an already-synced skill, rather than assuming:

```bash
find /home/alex/Entwicklung/ai-dev-workflows -type d -name skills
```

Derive the mirror's skills path the same way from the mirror root SYNC.md names. (At time of writing: canonical `ai-dev-workflows/skills/`, mirror `.../personal-workflows/apittrich/skills/` — but confirm from the repo, don't trust this line.)

### 3. Pre-flight both repos

For the canonical repo and the mirror's repo:
- Confirm branch is the one SYNC.md says to push (`main`) and note any **unrelated** dirty files — they must NOT be swept into the sync commit (stage explicitly, step 6).
- `git -C <repo> fetch -q` so the newer-than check (step 4) sees remote state.

### 4. Per-skill diff + drift guard

For each in-scope skill, compare the live copy to the repo copy:

- **No repo copy** → **new**.
- **Differs** → decide direction by mtime/content. If the **repo copy is newer** than the live one (repo→local drift — someone edited the repo copy since), **STOP and report that skill**; do not overwrite. Sync is local→repo only.
- **Identical** → **unchanged**, skip.

### 5. Copy verbatim (live → canonical → mirror)

For each new/updated skill:
- Copy the skill directory into canonical **verbatim**.
- Mirror to the published copy per **SYNC.md's scope** (tracked `.md` only — `skills/**/*.md`). If a skill carries non-`.md` supporting files, SYNC.md's scope governs what reaches the mirror; do not widen it here.
- **Secret scan** every copied file before staging — grep for obvious credentials:
  ```bash
  grep -rInE '(BEGIN [A-Z ]*PRIVATE KEY|glpat-|ghp_|xox[baprs]-|AKIA[0-9A-Z]{16}|password\s*[:=]|secret\s*[:=]|api[_-]?key\s*[:=]|Bearer [A-Za-z0-9._-]{20,})' <copied-skill-dir>
  ```
  **Manually read every flagged line — the scan flags candidates, not verdicts.** STOP and sync nothing only when a match is an **actual credential value**. A *documented* pattern is not a secret: a skill that teaches credential handling (this one included — its own scan regex self-matches), a placeholder like `password: <yours>`, or example code showing `api_key=` will trip the grep. Those are expected; note them and proceed.

### 6. Commit both repos (explicit adds only)

Stage only the synced skill paths — never `git add -A` (unrelated dirty files must stay out):

```bash
git -C <canonical> add skills/<name>/ ...
git -C <canonical> commit -m "chore(skills): sync <names> from personal skills"

git -C <mirror-repo> add <mirror-skills-path>/<name>/ ...
git -C <mirror-repo> commit -m "chore(skills): sync <names> from personal skills"
```

Commit trailer on both:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

### 7. Push both remotes (standing approval)

SYNC.md grants standing approval to auto-push both remotes — no need to ask. **Plain pushes only, never `--force`:**

```bash
git -C <canonical> push
git -C <mirror-repo> push
```

### 8. Verify + report

Confirm each remote received the commit and report per-skill status:

```bash
git -C <canonical> log origin/main -1 --oneline
git -C <mirror-repo> log origin/main -1 --oneline
```

Report: `new: […]`, `updated: […]`, `unchanged: […]`, `skipped (repo newer): […]`, plus both pushed SHAs.

## Quick Reference

| Step | Action |
|---|---|
| Rule | `cat .../ai-dev-workflows/SYNC.md` — obey it; missing → STOP |
| Skills path | discover via `find … -type d -name skills`, don't hardcode |
| Diff | live `/home/alex/.claude/skills/<name>` vs repo copy → new/updated/unchanged |
| Drift | repo copy newer → STOP, don't overwrite |
| Copy | verbatim to canonical; mirror per SYNC.md scope (tracked `.md`) |
| Secrets | grep copied files; read each hit; real credential → STOP (documented patterns are fine) |
| Commit | explicit `git add <paths>`, Co-Authored-By trailer |
| Push | plain `git push` both remotes (standing approval); never `--force` |

## Common Mistakes

- **Skipping SYNC.md** → it owns the mirror rule, scope, and push approval; read it every run. Missing → STOP.
- **Hardcoding the repo skills subpath** → discover it from an existing synced skill; layouts move.
- **`git add -A`** → sweeps unrelated dirty files into the sync commit. Stage only the synced skill paths.
- **Deleting repo skills that aren't local** → never. Sync is additive/update-only; deletions are a manual user action.
- **Overwriting a newer repo copy** → repo→local drift means someone changed the repo; STOP and report, don't clobber.
- **Committing secrets** → scan copied files first; a skill may have accreted a token/key.
- **Syncing only the canonical side** → SYNC.md requires the mirror too; both must move together.
- **`--force`** → never, on either remote.

## Red Flags — STOP

- **SYNC.md missing** → STOP; you can't know the mirror rule or push approval.
- About to `git push --force` on either remote → STOP.
- About to `git add -A` / commit with unrelated dirty files staged → STOP; explicit paths only.
- Repo copy is **newer** than the local skill → STOP; report drift, do not overwrite.
- A secret-scan hit that, on reading the line, is a **real credential value** (not a documented pattern/placeholder/regex) → STOP; sync nothing until it's cleared.
- About to **delete** a repo skill because it's not local → STOP; sync never deletes.
