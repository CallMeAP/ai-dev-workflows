---
name: bpp-pull-all-dev
description: Use when pulling latest development across all local BPP repos — phrases like "pull latest on all bpp repos", "update all bpp repos", "sync all repos to dev", "are we up to date", "fast-forward all bpp checkouts". Iterates every git repo under ~/Entwicklung/bpp/; on development it pulls even with local/unpushed changes when provably conflict-free (dirty tree → overlap pre-check, unpushed commits → rebase with abort-on-conflict); skips off-branch repos and conflict cases (reporting whether they are actually behind), and prints a per-repo summary of pulled commits with authors.
---

# bpp-pull-all-dev

## Overview

Update `development` in all local BPP repos under `~/Entwicklung/bpp/`. Never loses local work — but does NOT skip on the first sign of local state either: a dirty tree pulls anyway when the incoming diff is provably disjoint from the local modifications, and unpushed local commits are rebased onto origin/development with automatic abort on conflict. Only actual (would-be) conflicts and off-branch repos are skipped + reported. Ends with a short summary — commits pulled per repo, authors, subjects.

## When to Use

- "pull latest on all bpp repos", "update all bpp repos", "sync everything to dev", "make sure we're up to date"

## When NOT to Use

- Single-repo pull → just `git pull` there
- Bumping the shared package version → `bpp-bump-shared-version`

## Steps

### 1. Discover repos

All directories in `~/Entwicklung/bpp/` that contain `.git`. Known non-repos / excluded: `bpp-to-dos` (not git), `infra`, `*.worktrees` (worktree containers — never pull these).

### 2. Pull loop (safe by construction)

Per repo, in order:

1. `.git` exists? else `SKIP not a git repo`
2. branch == `development`? else `SKIP on branch '<x>'` (never auto-checkout)
3. `git fetch origin development`, compute `behind`/`ahead` vs `origin/development`
4. `behind == 0` → `OK already up to date` (note ahead/dirty state, no action)
5. Dirty tree? → **overlap pre-check**: local modified/untracked paths vs incoming diff `HEAD...origin/development` (three-dot = merge-base→origin, incoming changes ONLY). Overlap → `SKIP would-conflict` listing the files. Disjoint → proceed (no stash needed; git's checkout cannot clobber untouched files).
6. `ahead == 0` → `git merge --ff-only origin/development` (cannot conflict after the pre-check)
7. `ahead > 0` → `git rebase --autostash origin/development`; non-zero exit → `git rebase --abort` (repo fully restored, incl. autostash) → `SKIP rebase-conflict`

```bash
set -uo pipefail
BASE=/home/alex/Entwicklung/bpp
for repo in "$BASE"/*/; do
  name=$(basename "$repo")
  case "$name" in *worktrees*|infra) continue;; esac
  [ -d "$repo/.git" ] || { echo "SKIP $name: not a git repo"; continue; }
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "development" ] || { echo "SKIP $name: on branch '$branch'"; continue; }

  git -C "$repo" fetch -q origin development || { echo "ERR $name: fetch failed"; continue; }
  behind=$(git -C "$repo" rev-list --count HEAD..origin/development)
  ahead=$(git -C "$repo" rev-list --count origin/development..HEAD)
  # cut -c4-, then strip rename arrows — porcelain-v1-safe incl. spaces in names
  dirty_files=$(git -C "$repo" status --porcelain | cut -c4- | sed 's/.* -> //')

  if [ "$behind" -eq 0 ]; then
    extra=""
    [ "$ahead" -gt 0 ] && extra="$extra (ahead $ahead unpushed)"
    [ -n "$dirty_files" ] && extra="$extra (dirty)"
    echo "OK $name: already up to date$extra"
    continue
  fi

  # overlap pre-check: dirty/untracked paths vs INCOMING-only diff (three-dot!)
  if [ -n "$dirty_files" ]; then
    incoming=$(git -C "$repo" diff --name-only HEAD...origin/development)
    overlap=$(comm -12 <(sort -u <<<"$dirty_files") <(sort -u <<<"$incoming"))
    if [ -n "$overlap" ]; then
      echo "SKIP $name: dirty + behind $behind — incoming touches locally modified file(s):"
      sed 's/^/    /' <<<"$overlap"
      continue
    fi
  fi

  old=$(git -C "$repo" rev-parse HEAD)
  if [ "$ahead" -eq 0 ]; then
    git -C "$repo" merge --ff-only -q origin/development \
      || { echo "ERR $name: ff merge failed unexpectedly"; continue; }
  else
    if ! git -C "$repo" rebase --autostash -q origin/development >/dev/null 2>&1; then
      git -C "$repo" rebase --abort >/dev/null 2>&1
      echo "SKIP $name: behind $behind + ahead $ahead — rebase conflict, aborted (repo restored)"
      continue
    fi
    echo "REBASED $name: $ahead unpushed commit(s) replayed on top"
  fi
  echo "PULLED $name: $behind commits"
  git -C "$repo" log --pretty=format:'    %h %an — %s' "$old..origin/development"
  echo
done
exit 0
```

### 3. Check skipped repos (read-only)

For every repo skipped as off-branch: `git fetch -q origin development` then `git rev-list --count HEAD..origin/development`. Behind-count 0 → its development is current anyway, no action. Behind > 0 → report it (user must switch + pull manually).

### 4. Would-conflict repos — ASK FIRST

Repos skipped by the overlap pre-check or a rebase conflict need a human decision. If the local change is only local config (e.g. `appsettings.local.json`), you MAY offer stash-pull-pop — do NOT do it unprompted:

```bash
git stash push -m "auto-stash before dev pull" && git pull --ff-only && git stash pop
```

Verify the pop succeeded (no conflicts) and the local change is back via `git status --porcelain`. For rebase conflicts, just report — resolving them is the user's call.

### 5. Summary (required)

Always end with a short per-repo summary:
- **Pulled:** repo → N commits, authors, one-line subjects (mark `(rebased, N local ahead)` where applicable)
- **Skipped:** repo → reason + behind-count (0 behind = harmless; would-conflict → list the overlapping files / conflict)
- **Errors:** any `ERR` lines

Example:

```
Pulled:
  bpp-file       2 commits (M. Huber) — RV-Dokument-Download fix for view-only go-User
  bpp-push       1 commit  (A. Pittrich) — (rebased, 2 local ahead)
Skipped (current anyway):
  bpp-mail       dirty, 0 behind
Skipped (action needed):
  bpp-vera-connector  dirty, 3 behind — incoming touches appsettings.local.json → offer stash-pull-pop
```

## Common Mistakes

- **Two-dot diff for the overlap pre-check** → `HEAD..origin/development` diffs the two trees, so your OWN local commits pollute the "incoming" set and cause false overlaps. Always three-dot (`HEAD...origin/development` = merge-base→origin).
- **Plain `git pull` (merge) on a diverged dev** → never create merge commits on development; unpushed local commits are rebased (they're unpublished, rewriting is safe), everything else is ff-only.
- **Leaving a repo mid-rebase** → any non-zero rebase exit MUST be followed by `git rebase --abort` before reporting.
- **Stashing when the pre-check passed** → unnecessary; disjoint incoming diff cannot clobber dirty files. Stash-pull-pop is only a (user-confirmed) offer for would-conflict repos.
- **Treating dirty-but-0-behind as a problem** → it's current; just note it.
- **Pulling inside `*.worktrees` containers** → exclude them.
- **Auto-checkout to `development`** → never; off-branch repos are skip+report only.
- **Loop aborting early** — `&&`-chains under `set -e`/`pipefail` can exit the loop on the last skip; end script with `exit 0` and don't let a failed test be the last statement.
- **Omitting the commit summary** → user wants to see what changed and who committed; always print it.
