---
name: sync-my-skills
description: Use when publishing or syncing personal skills from the runtime skills directory into the canonical skills repo and its published mirror — phrases like "sync my skills", "publish this skill", "push my skills to the repo", "sync-my-skills", "did my new skill make it into the repo", "mirror my skills". Project-agnostic; works from any cwd.
---

# Sync personal skills into the canonical repo (+ mirror)

## Overview

Copies personal skills from the live runtime skills directory (`/home/alex/.claude/skills/`) into the canonical skills repo, mirrors them to the published copy, and pushes **both** remotes. It is **additive/update-only** — it never deletes and never overwrites newer repo content.

**`SYNC.md` in the canonical repo is the source of truth.** Read it at runtime and obey it — it defines the canonical→mirror rule, the tracked-file scope, and the standing push approval. Do not hardcode assumptions this file might contradict; SYNC.md wins.

Canonical repo: `/home/alex/Entwicklung/ai-dev-workflows` (remote `main`). SYNC.md names the published mirror and both remotes.

## The two remotes have different contracts

They are **not** two copies of the same thing. Sending the wrong shape to either one breaks it.

| | **Canonical — GitHub, private** | **Mirror — GitLab, team-shared** |
|---|---|---|
| Repo | `github.com/CallMeAP/ai-dev-workflows` | `gitlab.com/lipso/internal/agentic-coding-knowledge` |
| Content | **1:1 literal copy** of the live skill — absolute paths, this machine's username, ready to run | **developer-agnostic**: `{{BPP_ROOT}}`, `{{BROKERNET_ROOT}}`, `{{DEV_USER}}`, `{{WORKFLOWS_DIR}}`, `{{KNOWLEDGE_DIR}}` |
| Where bpp-* skills go | `skills/<name>/` | `skills/<name>/` (shared) |
| Where personal skills go (`gs-*`, `lipsum-stundenliste`, `sync-my-skills`) | `skills/<name>/` | `personal-workflows/apittrich/skills/<name>/` — **never** the shared `skills/` |
| Per-skill `README.md` | not used | **required** — see below |
| How it ships | direct `git push` to `main` (standing approval) | **`docs/*` branch + MR**, never a direct push to `main` |

**Machine config vs. identity — the call you will get wrong if you skim it.** A path is machine
config and becomes a placeholder: `/home/alex/Entwicklung/bpp` → `{{BPP_ROOT}}`, and a username
*inside a filesystem path* (`dev/apittrich/`) → `{{DEV_USER}}`. A username naming a **real person**
is not machine config and stays literal: MR reviewers (`apittrich` for .NET/backend repos,
`nangertLipso` for Angular/frontend), "maintained by nangert" attributions, Jira/GitLab handles in
prose. Blanket-replacing those breaks the reviewer logic. Ambiguous → leave it and say so.

**Every skill carries its own `README.md` — personal ones too.** For a skill under
`personal-workflows/<user>/skills/` the README sits *beside* the skill and does **not** template it:
the skill keeps its literal paths and real usernames. Same headings as a shared one — placeholders
(usually "none"), prerequisites, repo layout it assumes, shell/OS assumptions, how to install it by
hand, and a verification step. **Write it for your own skills only.** Writing one for someone else's
means guessing their intent; ask the owner instead.

Why this is a rule: a personal skill authored on macOS, using BSD `sed -i ''` six times and paths
from before a repo became a monorepo, was installed onto a Linux machine with nothing warning anyone.
It did not error — it edited nothing, or the wrong file.

**Every shared skill carries its own `README.md`** naming the placeholders it uses, the prerequisites
it assumes (authenticated `glab`, `jq`, `psql`, a running local stack, a sibling checkout, VPN, a
`QODANA_TOKEN`, …), anything still developer-specific after install, and the `install.sh` line.
`install.sh` skips `README.md` when rendering, so this text costs no tokens at invocation time —
which is exactly why it must **not** be folded into `SKILL.md`. **A new skill is not ready for the
shared remote until its README is written.**

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
- Mirror to the published copy per **SYNC.md's scope** — top-level `*.md` plus the **whole** of
  `skills/**`, including the `.sh` / `.py` a skill actually invokes. **Mirror a skill complete or not
  at all**: a `SKILL.md` whose sibling script is missing fails at the first command with "No such file
  or directory". SYNC.md governs the exclusions (`memory/`, `runAgents.sh`, large binary fixtures).
- **Reverse-render on the way to the mirror** — a `bpp-*` skill goes to the shared `skills/` with every
  machine path turned back into a placeholder. Then **verify by rendering back** and diffing against the
  live skill:
  ```bash
  NAME=bpp-create-mr                                    # the skill being synced
  K=/home/alex/Entwicklung/lipso/agentic-coding-knowledge
  set -a; . "$K/personal-workflows/apittrich/paths.env"; set +a
  sed -e "s|{{BPP_ROOT}}|$BPP_ROOT|g" -e "s|{{BROKERNET_ROOT}}|$BROKERNET_ROOT|g" \
      -e "s|{{DEV_USER}}|$BPP_DEV_USER|g" -e "s|{{WORKFLOWS_DIR}}|$WORKFLOWS_DIR|g" \
      -e "s|{{KNOWLEDGE_DIR}}|$KNOWLEDGE_DIR|g" "$K/skills/$NAME/SKILL.md" \
    | diff - "$HOME/.claude/skills/$NAME/SKILL.md"
  ```
  Only `~`/`$HOME` vs the literal `/home/alex/...` may differ. A placeholder that renders to the wrong
  path is worse than the hardcoded value it replaced. Then confirm nothing leaked:
  `grep -rn '/home/' "$K/skills/"` must be empty.
- **New shared skill** → write its `skills/<name>/README.md` in the same change. A skill reaching the
  shared remote without one is incomplete.
- **Personal skill** (`gs-*`, `lipsum-stundenliste`, `sync-my-skills`) → mirror copy goes to
  `personal-workflows/apittrich/skills/<name>/`, literal paths, no placeholders — but **with a
  `README.md` beside it** (see above). Never de-personalise it and never move it into the shared
  `skills/`.
- **Support files carry the same contract as the `.md`.** Under the shared `skills/` a `.sh`/`.py`
  gets the same reverse-render (`start_local_stack.sh` ships `ROOT="{{BPP_ROOT}}"`); `install.sh`
  renders it and preserves the executable bit. Under `personal-workflows/` it stays literal.
  **Secret-scan every support file before staging** — executables are where a stray token lands, and
  a widened scope puts them in a shared repo for the first time.
- **Secret scan** every copied file before staging — grep for obvious credentials:
  ```bash
  grep -rInE '(BEGIN [A-Z ]*PRIVATE KEY|glpat-|ghp_|xox[baprs]-|AKIA[0-9A-Z]{16}|password\s*[:=]|secret\s*[:=]|api[_-]?key\s*[:=]|Bearer [A-Za-z0-9._-]{20,})' <copied-skill-dir>
  ```
  **Manually read every flagged line — the scan flags candidates, not verdicts.** STOP and sync nothing only when a match is an **actual credential value**. A *documented* pattern is not a secret: a skill that teaches credential handling (this one included — its own scan regex self-matches), a placeholder like `password: <yours>`, or example code showing `api_key=` will trip the grep. Those are expected; note them and proceed.

### 6. Commit both repos (explicit adds only)

Stage only the synced skill paths — never `git add -A` (unrelated dirty files must stay out):

```bash
CANONICAL=/home/alex/Entwicklung/ai-dev-workflows
git -C "$CANONICAL" add "skills/$NAME/"
git -C "$CANONICAL" commit -m "chore(skills): sync $NAME from personal skills"
```

The mirror ships through review, so branch off `origin/main` **first** — never commit the mirror on `main`:

```bash
TOPIC=sync-my-skills-contract           # short kebab topic for the branch
MIRROR=/home/alex/Entwicklung/lipso/agentic-coding-knowledge

git -C "$MIRROR" fetch -q origin
git -C "$MIRROR" switch -c "docs/$TOPIC" origin/main
git -C "$MIRROR" add "personal-workflows/apittrich/skills/$NAME/"   # or skills/$NAME/ for a shared one
git -C "$MIRROR" commit -m "docs(skills): sync $NAME from personal skills"
```

`switch -c <b> origin/main` sets the upstream to `origin/main`, so a bare `git push` would target
`main`. Always push explicitly by refspec (step 7).

Commit trailer on both:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

### 7. Push both remotes (standing approval)

SYNC.md grants standing approval to push the canonical remote and to push the mirror's `docs/*`
branch — **not** to merge the MR. **Plain pushes only, never `--force`:**

```bash
git -C "$CANONICAL" push                                  # canonical: straight to main

# Mirror: explicit refspec. `switch -c` set the upstream to origin/main, so a bare
# `git push` here would target main.
git -C "$MIRROR" push -u origin "HEAD:refs/heads/docs/$TOPIC"
```

Then open the MR against `main` and stop. `glab mr create` is unreliable here; use the API:

```bash
P=lipso%2Finternal%2Fagentic-coding-knowledge
IID=$(glab api --method POST "/projects/$P/merge_requests" \
  -f source_branch="docs/$TOPIC" -f target_branch=main -f title="$TITLE" \
  --raw-field "description=$DESC" | jq -r .iid)   # -f description=@file posts the literal path
glab mr update "$IID" --reviewer apittrich -R lipso/internal/agentic-coding-knowledge
```

**Never merge the MR.**

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
| Copy | **canonical = verbatim literal**; **mirror = reverse-rendered to `{{…}}`** + per-skill `README.md` |
| Placeholder check | render mirror copy back with `paths.env`, diff vs live; `grep -rn '/home/' skills/` empty |
| Personal skills | canonical `skills/`, mirror `personal-workflows/apittrich/skills/` — never shared `skills/` |
| Scope | top-level `*.md` + all of `skills/**` incl. support scripts; mirror a skill complete or not at all |
| Secrets | grep copied files, **support scripts included**; read each hit; real credential → STOP (documented patterns are fine) |
| Commit | explicit `git add <paths>`, Co-Authored-By trailer |
| Push | canonical: plain `git push` to `main`. Mirror: `docs/*` branch → `push -u origin HEAD:refs/heads/docs/<topic>` → MR. Never `--force`, never merge |

## Common Mistakes

- **Skipping SYNC.md** → it owns the mirror rule, scope, and push approval; read it every run. Missing → STOP.
- **Hardcoding the repo skills subpath** → discover it from an existing synced skill; layouts move.
- **`git add -A`** → sweeps unrelated dirty files into the sync commit. Stage only the synced skill paths.
- **Deleting repo skills that aren't local** → never. Sync is additive/update-only; deletions are a manual user action.
- **Overwriting a newer repo copy** → repo→local drift means someone changed the repo; STOP and report, don't clobber.
- **Committing secrets** → scan copied files first; a skill may have accreted a token/key.
- **Syncing only the canonical side** → SYNC.md requires the mirror too; both must move together.
- **Pushing literal `/home/<you>/...` paths into the mirror's shared `skills/`** → `install.sh` renders placeholders, so a hardcoded path silently installs your machine's layout on someone else's. Reverse-render, then render back and diff.
- **Blanket-replacing every username with `{{DEV_USER}}`** → reviewer names and "maintained by" attributions are real people, not machine config; replacing them breaks the reviewer logic.
- **Committing the mirror on `main` / bare `git push` on a `docs/*` branch** → the branch's upstream is `origin/main`, so a bare push lands on `main`. Branch off `origin/main` and push by explicit refspec.
- **A personal skill published without a README** → the installing developer gets no shell-dialect, layout or verification information at all, and personal skills are exactly the ones authored against one machine. Write it for your own; ask the owner for theirs.
- **A new shared skill without its `README.md`** → the installing developer has no way to know its placeholders or prerequisites. Write it in the same change.
- **Putting setup text inside `SKILL.md`** → `install.sh` renders `SKILL.md` into the runtime, so it costs tokens on every invocation. It belongs in the sibling `README.md`, which `install.sh` skips.
- **`--force`** → never, on either remote.

## Red Flags — STOP

- **SYNC.md missing** → STOP; you can't know the mirror rule or push approval.
- About to `git push --force` on either remote → STOP.
- About to push, commit, or merge directly on the mirror's `main` → STOP; mirror changes ship as a `docs/*` branch + MR, and you never merge it.
- A `{{PLACEHOLDER}}` about to reach the **canonical** repo, or a literal `/home/...` path about to reach the mirror's shared `skills/` → STOP; you have the two contracts swapped.
- About to `git add -A` / commit with unrelated dirty files staged → STOP; explicit paths only.
- Repo copy is **newer** than the local skill → STOP; report drift, do not overwrite.
- A secret-scan hit that, on reading the line, is a **real credential value** (not a documented pattern/placeholder/regex) → STOP; sync nothing until it's cleared.
- About to **delete** a repo skill because it's not local → STOP; sync never deletes.
