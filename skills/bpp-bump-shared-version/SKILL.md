---
name: bpp-bump-shared-version
description: Use when bumping the BPP.Shared.NET package version across all BPP .NET repos — phrases like "bump bpp-shared", "update shared version", "sync bpp-shared across repos", "release shared package", "pull latest bpp-shared everywhere". Fetches the latest `*-development+*` package from the GitLab registry via `glab`, discovers ALL consumer repos GitLab-side (`bpp-*` repos whose `BPP.*/Directory.Build.props` contains `<BppSharedVersion>`), bumps locally cloned repos via pull→rewrite→commit→push and uncloned repos via a direct GitLab API commit. Unrelated local changes don't block a bump (detached-worktree fallback); skips repos whose props file itself is dirty, off-branch repos (bulk mode), and already-current repos.
---

# BPP: Bump bpp-shared version across all .NET repos

## Overview

Single-command bulk update of the `<BppSharedVersion>` property in every BPP .NET consumer repo's `Directory.Build.props`, sourced from the latest `-development+*` package in the GitLab registry of `brokernet/bpp-shared`.

**The GitLab group is the source of truth for the consumer list** — a machine-local `find` over `~/Entwicklung/bpp/` misses consumers that aren't cloned on this machine (real precedent: `bpp-agent` existed only in GitLab and was silently missed by local-only discovery). Discovery therefore queries the `brokernet/` group via `glab` (same pattern as bpp-promote-dev-to-staging), then:

- **Cloned repos** → local flow: pull, rewrite, commit, push (keeps local checkouts current).
- **Not-cloned repos** → GitLab API commit directly on `development` (no repo is ever missed).

Conservative on edge cases: skip + report rather than auto-fix.

## Prerequisites

- `glab` authenticated against gitlab.com — verify with `glab auth status`
- `jq` available
- Local BPP repos (if any) cloned under `~/Entwicklung/bpp/` (sibling layout, folder = repo name). Repos without a local clone are handled via API — no clone required.

## Defaults (non-negotiable)

| Field | Value |
|-------|-------|
| Branch | `development` |
| Commit message | `chore: bump bpp-shared to {version}` (identical for local and API commits) |
| Push remote | `origin` |
| Channel | latest version with `-development+*` suffix |
| Repo list | GitLab group `brokernet/`, projects matching `^bpp-`, excluding `bpp-shared` |
| Consumer test | repo has a root-level `BPP.*/Directory.Build.props` on `development` containing `<BppSharedVersion>` (folder name varies — e.g. `BPP.DocumentAnalysis`, `BPP.Agent.NET`) |
| Local clone path | `~/Entwicklung/bpp/{repo}` |

## Skip rules

A repo is **skipped + reported** (never auto-fixed) when:

1. Local clone working tree is dirty **on the props file itself** (`git status --porcelain` lists the repo's `Directory.Build.props`). Dirt on UNRELATED files (e.g. `appsettings.local.json` cred edits) does NOT block — use the detached-worktree fallback below.
2. Local clone branch is not `development` (bulk flow; a targeted bump may use the worktree fallback instead — see below).
3. `git pull --ff-only origin development` fails (e.g. diverged history).
4. Local (or remote, for API-path repos) `<BppSharedVersion>` already equals fetched `LATEST` → reported as `up-to-date`.
5. **Downgrade guard**: current version is *newer* than `LATEST` (semver-style compare on the `YYYY.M.D` portion before `-development`). Reported as `skipped (newer-local)` / `skipped (newer-remote)`.
6. **A repo with a local clone is NEVER bumped via API** — if its local flow skips, it stays skipped (API commit behind the user's back would make their checkout diverge). The detached-worktree fallback is the sanctioned alternative: it commits via git on origin/development without touching the checkout.
7. Discovery could not inspect a repo (tree/props fetch failed, e.g. missing `development` branch) → reported under **Unverified** — these are potential missed consumers; the run continues but the summary must call them out.

Skipped repos do NOT abort the run. Continue to the next repo.

## Detached-worktree fallback (unrelated-dirty / targeted bump)

The bump commit only ever touches `Directory.Build.props` — an unrelated local change must not block it. When a local clone is dirty on unrelated files, or a **targeted bump** ("bump bpp-file") hits a checkout that is dirty and/or on another branch: never stash, never switch, never touch the working tree. Instead commit via a throwaway detached worktree based on origin/development:

```bash
repo_dir=~/Entwicklung/bpp/<repo>
W=$(mktemp -d)/wt-bump
git -C "$repo_dir" fetch -q origin development
git -C "$repo_dir" worktree add "$W" --detach origin/development
sed -i "s|<BppSharedVersion>[^<]*</BppSharedVersion>|<BppSharedVersion>${LATEST}</BppSharedVersion>|" "$W/<props-path>"
git -C "$W" add <props-path>
git -C "$W" commit -m "chore: bump bpp-shared to ${LATEST}"
git -C "$W" push origin HEAD:development
git -C "$repo_dir" worktree remove "$W"
```

Apply the same up-to-date + downgrade guards on the worktree's props content first. In the BULK flow, use this automatically for dirty-but-unrelated repos on `development`; off-branch repos stay skip+report in bulk (branch state may signal in-progress work) but MAY be bumped this way when the user asks for that repo explicitly. Note the checkout does not receive the commit — report `(checkout not updated — worktree push)` so the user knows their local clone is now 1 behind.

## Workflow

### 1. Fetch latest -development version

```bash
LATEST=$(glab api "projects/brokernet%2Fbpp-shared/packages?per_page=20&order_by=created_at&sort=desc" \
  | jq -r '[.[] | select(.version | test("-development\\+"))][0].version')

[ -z "$LATEST" ] || [ "$LATEST" = "null" ] && { echo "FAIL — no -development package found" >&2; exit 1; }
echo "Latest bpp-shared (development): $LATEST"
```

### 2. Discover consumer repos in GitLab (authoritative)

List `bpp-*` projects in the `brokernet/` group, then probe each repo's root tree on `development` for a `BPP.*/Directory.Build.props` containing `<BppSharedVersion>`. Record the props path and current remote version per consumer.

```bash
declare -A PROPSPATH REMOTEVER
declare -a CONSUMERS NONCONSUMERS UNVERIFIED

mapfile -t ALLREPOS < <(glab api "/groups/brokernet/projects?per_page=100&simple=true" \
  | jq -r '.[] | select(.path | test("^bpp-")) | .path' | grep -vx 'bpp-shared' | sort)

for repo in "${ALLREPOS[@]}"; do
  enc="brokernet%2F${repo}"
  tree=$(glab api "/projects/${enc}/repository/tree?ref=development&per_page=100" 2>/dev/null)
  if ! echo "$tree" | jq -e 'type=="array"' >/dev/null 2>&1; then
    UNVERIFIED+=("$repo"); continue
  fi
  found=""
  for dir in $(echo "$tree" | jq -r '.[] | select(.type=="tree" and (.name|test("^BPP\\."))) | .name'); do
    version=$(glab api "/projects/${enc}/repository/files/${dir}%2FDirectory.Build.props/raw?ref=development" 2>/dev/null \
      | grep -oP '(?<=<BppSharedVersion>)[^<]+' | head -1)
    if [ -n "$version" ]; then
      PROPSPATH[$repo]="${dir}/Directory.Build.props"
      REMOTEVER[$repo]="$version"
      found=1; break
    fi
  done
  if [ -n "$found" ]; then CONSUMERS+=("$repo"); else NONCONSUMERS+=("$repo"); fi
done

echo "Consumers (${#CONSUMERS[@]}): ${CONSUMERS[*]}"
echo "Non-consumers (${#NONCONSUMERS[@]}): ${NONCONSUMERS[*]}"
[ ${#UNVERIFIED[@]} -gt 0 ] && echo "UNVERIFIED — could not inspect: ${UNVERIFIED[*]}" >&2
```

Non-consumers (no props / no `<BppSharedVersion>`) are expected: Java services (`bpp-mail`, `bpp-js-report-connector`) and UIs/dashboards (`bpp-agent-ui`, `bpp-document-analysis-dashboard`). They are reported informationally, never touched.

### 3. Split consumers: local clone vs remote-only

```bash
declare -a LOCAL_REPOS REMOTE_ONLY
for repo in "${CONSUMERS[@]}"; do
  if [ -e ~/Entwicklung/bpp/"$repo"/.git ]; then
    LOCAL_REPOS+=("$repo")
  else
    REMOTE_ONLY+=("$repo")
  fi
done
```

### 4. Local per-repo loop (cloned consumers)

For each repo in `LOCAL_REPOS`, in sequence:

```bash
declare -a UPDATED UPDATED_API UPTODATE SKIPPED
for repo in "${LOCAL_REPOS[@]}"; do
  repo_dir=~/Entwicklung/bpp/"$repo"
  props="${repo_dir}/${PROPSPATH[$repo]}"

  # (1) cleanliness + branch
  cd "$repo_dir" || { SKIPPED+=("$repo: cd-failed"); continue; }
  if [ -n "$(git status --porcelain)" ]; then
    SKIPPED+=("$repo: dirty"); continue
  fi
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" != "development" ]; then
    SKIPPED+=("$repo: on-branch-$branch"); continue
  fi

  # (2) pull
  if ! git pull --ff-only origin development >/dev/null 2>&1; then
    SKIPPED+=("$repo: pull-failed"); continue
  fi

  # (3) read current version (from local file, post-pull)
  current=$(grep -oP '(?<=<BppSharedVersion>)[^<]+' "$props" | head -1)
  if [ -z "$current" ]; then
    SKIPPED+=("$repo: no-BppSharedVersion-in-props"); continue
  fi
  if [ "$current" = "$LATEST" ]; then
    UPTODATE+=("$repo"); continue
  fi

  # (4) downgrade guard — compare YYYY.M.D portion before -development
  local_date=${current%-development*}
  latest_date=${LATEST%-development*}
  newer=$(printf '%s\n%s\n' "$local_date" "$latest_date" \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  if [ "$newer" = "$local_date" ] && [ "$local_date" != "$latest_date" ]; then
    SKIPPED+=("$repo: newer-local ($current)"); continue
  fi

  # (5) rewrite + commit + push
  sed -i "s|<BppSharedVersion>[^<]*</BppSharedVersion>|<BppSharedVersion>${LATEST}</BppSharedVersion>|" "$props"
  git add "$props"
  git commit -m "chore: bump bpp-shared to ${LATEST}" >/dev/null
  if git push origin development >/dev/null 2>&1; then
    UPDATED+=("$repo: $current → $LATEST")
  else
    SKIPPED+=("$repo: push-failed (committed locally)")
  fi
done
```

### 5. Remote-only per-repo loop (API commit)

For consumers with no local clone, commit the rewritten props file directly on `development` via the GitLab commits API. Re-fetch the raw file at bump time (the discovery snapshot may be stale), apply the same up-to-date + downgrade guards, and sanity-check the rewritten content before POSTing.

```bash
for repo in "${REMOTE_ONLY[@]}"; do
  enc="brokernet%2F${repo}"
  props_rel="${PROPSPATH[$repo]}"
  props_enc="${props_rel//\//%2F}"

  # (1) re-fetch raw props + current version
  raw=$(glab api "/projects/${enc}/repository/files/${props_enc}/raw?ref=development" 2>/dev/null)
  current=$(echo "$raw" | grep -oP '(?<=<BppSharedVersion>)[^<]+' | head -1)
  if [ -z "$current" ]; then
    SKIPPED+=("$repo: raw-fetch-failed"); continue
  fi
  if [ "$current" = "$LATEST" ]; then
    UPTODATE+=("$repo (remote)"); continue
  fi

  # (2) downgrade guard
  remote_date=${current%-development*}
  latest_date=${LATEST%-development*}
  newer=$(printf '%s\n%s\n' "$remote_date" "$latest_date" \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  if [ "$newer" = "$remote_date" ] && [ "$remote_date" != "$latest_date" ]; then
    SKIPPED+=("$repo: newer-remote ($current)"); continue
  fi

  # (3) rewrite + sanity check (must change, must contain LATEST)
  new_content=$(echo "$raw" | sed "s|<BppSharedVersion>[^<]*</BppSharedVersion>|<BppSharedVersion>${LATEST}</BppSharedVersion>|")
  if [ "$new_content" = "$raw" ] || ! echo "$new_content" | grep -qF "$LATEST"; then
    SKIPPED+=("$repo: rewrite-sanity-failed"); continue
  fi

  # (4) commit via API
  payload=$(jq -n \
    --arg msg "chore: bump bpp-shared to ${LATEST}" \
    --arg path "$props_rel" \
    --arg content "$new_content" \
    '{branch:"development", commit_message:$msg, actions:[{action:"update", file_path:$path, content:$content}]}')
  if echo "$payload" | glab api --method POST "/projects/${enc}/repository/commits" \
       -H 'Content-Type: application/json' --input - >/dev/null 2>&1; then
    UPDATED_API+=("$repo: $current → $LATEST (API commit, no local clone)")
  else
    SKIPPED+=("$repo: api-commit-failed")
  fi
done
```

### 6. Final summary

Print all groups; `Unverified` and `Skipped` entries get one line each so the user can act on them:

```
Updated via local push (N):
  bpp-backend       2026.5.4-development+5cc45b16 → 2026.7.3-development+6af1b772
  bpp-auth          ...

Updated via API commit — no local clone (N):
  bpp-agent         2026.5.4-development+5cc45b16 → 2026.7.3-development+6af1b772

Up-to-date (N):
  bpp-stella
  ...

Skipped (N):
  bpp-chat          dirty
  bpp-file          on-branch-feature/foo

Non-consumers (N): bpp-mail, bpp-js-report-connector, bpp-agent-ui, ...

UNVERIFIED — could not inspect, possible missed consumers (N):
  bpp-foo           (tree fetch failed — check branch/permissions)
```

## Common mistakes

- **Local-only `find` discovery** → misses consumers that aren't cloned on this machine (`bpp-agent` precedent). The GitLab group listing is the authoritative repo set; local `find` is not a substitute.
- **API-bumping a repo that has a local clone** → never. Local clone present = local flow (or detached-worktree fallback) only; an API commit would silently diverge the user's checkout.
- **Letting an unrelated dirty file block a bump** → the bump touches only `Directory.Build.props`; use the detached-worktree fallback instead of skipping (skip only when the props file itself is dirty).
- **Silently dropping repos whose tree/props fetch failed** → report them under `UNVERIFIED` in the summary; they are exactly the "incomplete bump" risk this design exists to prevent.
- **Pushing on top of stale state** → always `git pull --ff-only` first; if it fails, skip the repo.
- **Auto-stashing dirty changes** → never. Skip + notify; the user owns their working tree.
- **Auto-checkout to `development`** → never. Skip + notify if on another branch.
- **Assuming the props folder is `BPP.*.NET`** → some repos use a different folder (e.g. `bpp-document-analysis` → `BPP.DocumentAnalysis/`). The probe is `^BPP\.` on root tree dirs; the `<BppSharedVersion>` grep decides consumership.
- **Rewriting without a sanity check on the API path** → the rewritten content must differ from the original AND contain `LATEST`, otherwise skip. Never POST a no-op or corrupted file.
- **Using `--force` on push** → never. Plain `git push origin development` only.
- **Including `bpp-shared` itself** → it's the source, not a consumer. Excluded from the repo list.
- **Running repos in parallel** → keep sequential. Per-repo output must be readable; any conflict needs a clear single-repo error.
- **Skipping the downgrade guard** → applies to BOTH paths (local and API). If the current version is newer than `LATEST`, blindly rewriting would be a regression. Skip with `newer-local` / `newer-remote`.
- **Trusting the discovery snapshot on the API path** → re-fetch the raw props at bump time; the version read during discovery may be stale by the time the commit is made.

## Red flags — STOP

- About to `git stash` / `git checkout development` / `git reset` on a user's repo → STOP. Skip + notify only.
- About to push without a successful `pull --ff-only` → STOP. Skip the repo.
- `LATEST` is empty or `null` → STOP. Abort the whole run; do not continue with a blank version.
- About to POST an API commit for a repo that exists under `~/Entwicklung/bpp/` → STOP. Local clones use the local flow only.
- About to POST an API commit whose content is empty, unchanged, or missing `LATEST` → STOP. The rewrite failed; skip the repo.
- About to commit a change to a file that does not contain `<BppSharedVersion>` → STOP. The discovery filter failed; do not write.
- About to use `git push --force` → STOP. Never force-push from this skill.
