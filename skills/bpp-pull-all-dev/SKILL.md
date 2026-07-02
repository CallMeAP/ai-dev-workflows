---
name: bpp-pull-all-dev
description: Use when pulling latest development across all local BPP repos — phrases like "pull latest on all bpp repos", "update all bpp repos", "sync all repos to dev", "are we up to date", "fast-forward all bpp checkouts". Iterates every git repo under ~/Entwicklung/bpp/, fast-forward-pulls development, skips dirty/off-branch repos (reporting whether they are actually behind), and prints a per-repo summary of pulled commits with authors.
---

# bpp-pull-all-dev

## Overview

Fast-forward `development` in all local BPP repos under `~/Entwicklung/bpp/`. Never loses local work: dirty repos and repos on another branch are skipped, then checked read-only whether they are behind. Ends with a short summary — commits pulled per repo, authors, subjects.

## When to Use

- "pull latest on all bpp repos", "update all bpp repos", "sync everything to dev", "make sure we're up to date"

## When NOT to Use

- Single-repo pull → just `git pull` there
- Bumping the shared package version → `bpp-bump-shared-version`

## Steps

### 1. Discover repos

All directories in `~/Entwicklung/bpp/` that contain `.git`. Known non-repos / excluded: `bpp-to-dos` (not git), `infra`, `*.worktrees` (worktree containers — never pull these).

### 2. Pull loop (safe by construction)

Per repo, in order — skip (with reason) on first failed check:

1. `.git` exists? else `SKIP not a git repo`
2. branch == `development`? else `SKIP on branch '<x>'`
3. `git status --porcelain` empty? else `SKIP dirty working tree`
4. Record old head, then `git pull --ff-only` (never merge/rebase implicitly)

```bash
set -uo pipefail
BASE=/home/alex/Entwicklung/bpp
for repo in "$BASE"/*/; do
  name=$(basename "$repo")
  case "$name" in *worktrees*|infra) continue;; esac
  [ -d "$repo/.git" ] || { echo "SKIP $name: not a git repo"; continue; }
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "development" ] || { echo "SKIP $name: on branch '$branch'"; continue; }
  [ -z "$(git -C "$repo" status --porcelain)" ] || { echo "SKIP $name: dirty"; continue; }
  old=$(git -C "$repo" rev-parse HEAD)
  if git -C "$repo" pull --ff-only -q; then
    new=$(git -C "$repo" rev-parse HEAD)
    if [ "$old" = "$new" ]; then
      echo "OK $name: already up to date"
    else
      count=$(git -C "$repo" rev-list --count "$old..$new")
      echo "PULLED $name: $count commits"
      git -C "$repo" log --pretty=format:'    %h %an — %s' "$old..$new"
      echo
    fi
  else
    echo "ERR $name: pull failed"
  fi
done
exit 0
```

### 3. Check skipped repos (read-only)

For every repo skipped as dirty or off-branch: `git fetch -q origin development` then `git rev-list --count HEAD..origin/development`. Behind-count 0 → it's current anyway, no action. Behind > 0 → report it.

### 4. Handle behind + dirty repos — ASK FIRST

If a dirty repo is behind and its changes are only local config (e.g. `appsettings.local.json`), offer stash-pull-pop — do NOT do it unprompted:

```bash
git stash push -m "auto-stash before dev pull" && git pull --ff-only && git stash pop
```

Verify the pop succeeded (no conflicts) and the local change is back via `git status --porcelain`.

### 5. Summary (required)

Always end with a short per-repo summary:
- **Pulled:** repo → N commits, authors, one-line subjects (from step 2 output)
- **Skipped:** repo → reason + behind-count (0 behind = harmless)
- **Errors:** any `ERR` lines

Example:

```
Pulled:
  bpp-file       2 commits (M. Huber) — RV-Dokument-Download fix for view-only go-User
Skipped (current anyway):
  bpp-mail       dirty, 0 behind
Skipped (action needed):
  bpp-vera-connector  dirty, 3 behind → offer stash-pull-pop
```

## Common Mistakes

- **Pulling a dirty repo without asking** → stash-pull-pop only after user confirms.
- **Plain `git pull` (merge)** → always `--ff-only`; a non-ff dev branch is a red flag to surface, not auto-resolve.
- **Treating dirty-but-0-behind as a problem** → it's current; just note it.
- **Pulling inside `*.worktrees` containers** → exclude them.
- **Loop aborting early** — `&&`-chains under `set -e`/`pipefail` can exit the loop on the last skip; end script with `exit 0` and don't let a failed test be the last statement.
- **Omitting the commit summary** → user wants to see what changed and who committed; always print it.
