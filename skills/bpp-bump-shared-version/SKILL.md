---
name: bpp-bump-shared-version
description: Use when bumping the BPP.Shared.NET package version across all BPP .NET repos — phrases like "bump bpp-shared", "update shared version", "sync bpp-shared across repos", "release shared package", "pull latest bpp-shared everywhere". Fetches the latest `*-development+*` package from the GitLab registry via `glab`, then for every BPP .NET repo with a `Directory.Build.props` containing `<BppSharedVersion>`: pulls `development`, rewrites the version, commits, and pushes. Skips dirty repos, repos not on `development`, and already-current repos.
---

# BPP: Bump bpp-shared version across all .NET repos

## Overview

Single-command bulk update of the `<BppSharedVersion>` property in every BPP .NET repo's `Directory.Build.props`, sourced from the latest `-development+*` package in the GitLab registry of `brokernet/bpp-shared`. Pulls before bumping (no push-on-stale), commits per repo with a uniform message, pushes to `origin development`. Conservative on edge cases: skip + report rather than auto-fix.

## Prerequisites

- `glab` authenticated against gitlab.com — verify with `glab auth status`
- `jq` available
- Local BPP repos cloned under `~/Entwicklung/bpp/` (sibling layout)

## Defaults (non-negotiable)

| Field | Value |
|-------|-------|
| Branch | `development` |
| Commit message | `chore: bump bpp-shared to {version}` |
| Push remote | `origin` |
| Channel | latest version with `-development+*` suffix |
| Repo glob | `~/Entwicklung/bpp/bpp-*` (excluding `bpp-shared`, worktrees) |
| Props path | first `BPP.*/Directory.Build.props` under each repo containing `<BppSharedVersion>` (matches non-`.NET` project folders too, e.g. `BPP.DocumentAnalysis`) |

## Skip rules

A repo is **skipped + reported** (never auto-fixed) when:

1. Working tree is dirty (`git status --porcelain` non-empty).
2. Current branch is not `development`.
3. `git pull --ff-only origin development` fails (e.g. diverged history).
4. Local `<BppSharedVersion>` already equals fetched `LATEST` → reported as `up-to-date`.
5. **Downgrade guard**: local version is *newer* than `LATEST` (semver-style compare on the `YYYY.M.D` portion before `-development`). Reported as `skipped (newer-local)`.

Skipped repos do NOT abort the run. Continue to the next repo.

## Workflow

### 1. Fetch latest -development version

```bash
LATEST=$(glab api "projects/brokernet%2Fbpp-shared/packages?per_page=20&order_by=created_at&sort=desc" \
  | jq -r '[.[] | select(.version | test("-development\\+"))][0].version')

[ -z "$LATEST" ] || [ "$LATEST" = "null" ] && { echo "FAIL — no -development package found" >&2; exit 1; }
echo "Latest bpp-shared (development): $LATEST"
```

### 2. Discover candidate repos

```bash
mapfile -t PROPS < <(find ~/Entwicklung/bpp -maxdepth 3 -type f -name 'Directory.Build.props' \
  -path '*BPP.*/*' \
  -not -path '*bpp-shared/*' \
  -not -path '*.worktrees/*' \
  2>/dev/null \
  | xargs grep -l '<BppSharedVersion>' 2>/dev/null)

echo "Found ${#PROPS[@]} candidate repos:"
printf '  %s\n' "${PROPS[@]}"
```

Each entry is the absolute path to a `Directory.Build.props`. The repo root is two levels up (`dirname $(dirname $props)`).

### 3. Per-repo loop

For each `props` in `PROPS`, in sequence:

```bash
declare -a UPDATED UPTODATE SKIPPED
for props in "${PROPS[@]}"; do
  repo=$(dirname "$(dirname "$props")")
  name=$(basename "$repo")

  # (1) cleanliness + branch
  cd "$repo" || { SKIPPED+=("$name: cd-failed"); continue; }
  if [ -n "$(git status --porcelain)" ]; then
    SKIPPED+=("$name: dirty"); continue
  fi
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" != "development" ]; then
    SKIPPED+=("$name: on-branch-$branch"); continue
  fi

  # (2) pull
  if ! git pull --ff-only origin development >/dev/null 2>&1; then
    SKIPPED+=("$name: pull-failed"); continue
  fi

  # (3) read current version
  current=$(grep -oP '(?<=<BppSharedVersion>)[^<]+' "$props" | head -1)
  if [ "$current" = "$LATEST" ]; then
    UPTODATE+=("$name"); continue
  fi

  # (4) downgrade guard — compare YYYY.M.D portion before -development
  local_date=${current%-development*}
  latest_date=${LATEST%-development*}
  newer=$(printf '%s\n%s\n' "$local_date" "$latest_date" \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  if [ "$newer" = "$local_date" ] && [ "$local_date" != "$latest_date" ]; then
    SKIPPED+=("$name: newer-local ($current)"); continue
  fi

  # (5) rewrite + commit + push
  sed -i "s|<BppSharedVersion>[^<]*</BppSharedVersion>|<BppSharedVersion>${LATEST}</BppSharedVersion>|" "$props"
  git add "$props"
  git commit -m "chore: bump bpp-shared to ${LATEST}" >/dev/null
  if git push origin development >/dev/null 2>&1; then
    UPDATED+=("$name: $current → $LATEST")
  else
    SKIPPED+=("$name: push-failed (committed locally)")
  fi
done
```

### 4. Final summary

Print three groups:

```
Updated (N):
  bpp-backend       2026.5.4-development+5cc45b16 → 2026.5.8-development+5870cea0
  bpp-auth          ...

Up-to-date (N):
  bpp-stella
  ...

Skipped (N):
  bpp-chat          dirty
  bpp-file          on-branch-feature/foo
  bpp-push          pull-failed
  bpp-vera-connector  newer-local (2026.5.9-development+abc12345)
```

If `Skipped` is non-empty, end the message with one line per skipped repo so the user can act on each.

## Common mistakes

- **Pushing on top of stale state** → always `git pull --ff-only` first; if it fails, skip the repo.
- **Auto-stashing dirty changes** → never. Skip + notify; the user owns their working tree.
- **Auto-checkout to `development`** → never. Skip + notify if on another branch.
- **Mass-rewriting other props files** → only touch files that already contain `<BppSharedVersion>`. The `xargs grep -l` filter is non-negotiable.
- **Narrowing the discovery glob to `*BPP.*.NET/*`** → don't. Some repos use a non-`.NET` project folder (e.g. bpp-document-analysis → `BPP.DocumentAnalysis/`) and were silently skipped. The glob is `*BPP.*/*`; the `xargs grep -l '<BppSharedVersion>'` filter + `-maxdepth 3` keep the broader match safe.
- **Using `--force` on push** → never. Plain `git push origin development` only.
- **Including `bpp-shared` itself** → it's the source, not a consumer. Path filter excludes it.
- **Running multiple repos in parallel** → keep sequential. Per-repo output must be readable; any conflict needs a clear single-repo error.
- **Skipping the downgrade guard** → if a teammate published a newer version locally and CI has not yet caught up, blindly rewriting would be a regression. Skip with `newer-local` instead.

## Red flags — STOP

- About to `git stash` / `git checkout development` / `git reset` on a user's repo → STOP. Skip + notify only.
- About to push without a successful `pull --ff-only` → STOP. Skip the repo.
- `LATEST` is empty or `null` → STOP. Abort the whole run; do not continue with a blank version.
- About to commit a change to a file that does not contain `<BppSharedVersion>` → STOP. The discovery filter failed; do not write.
- About to use `git push --force` → STOP. Never force-push from this skill.
