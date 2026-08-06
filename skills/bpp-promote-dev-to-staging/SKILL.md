---
name: bpp-promote-dev-to-staging
description: Use when promoting development to staging across BPP GitLab repositories — phrases like "promote dev to staging", "create staging MRs", "dev→staging release", "staging deployment MRs". Bulk-creates one merge request per repo that has diffs, titled "Development -> Staging" with label "staging-deployment".
---

# BPP: Promote development → staging

## Overview

Bulk-create dev→staging MRs across all BPP repos in the `brokernet/` GitLab group via `glab`. Skips repos with no diffs and repos that already have an open dev→staging MR. Always shows a preview and waits for explicit user confirmation before creating any MR.

## Prerequisites

- `glab` authenticated against gitlab.com — verify with `glab auth status`
- `jq` available

## Repo filter

Filtered repos in `brokernet/` group:
- `^bpp-.*` (e.g. `bpp-backend`, `bpp-auth`, `bpp-stella`)
- `^brokernet-.*-ui$` (e.g. `brokernet-cockpit-ui`, `brokernet-onboarding-ui`)

Exclude everything else (ops scripts, infra, archived).

### Always-include extras (do NOT match the filter / live in a subgroup)

These are explicitly added on every run regardless of the filter:
- `brokernet-document-cms` — in `brokernet/` group but has no `-ui$` suffix → filter misses it.
- `callidus-bvs-ui` — in the `brokernet/callidus/` **subgroup**, so the group listing never returns it; needs the encoded path `brokernet%2Fcallidus%2Fcallidus-bvs-ui`.
- `servo-ui` — in the `brokernet/servo/` **subgroup**; encoded path `brokernet%2Fservo%2Fservo-ui`.

Because one extra lives in a subgroup, the encoded project path can't be derived as `brokernet%2F${repo}` for every repo. The workflow therefore builds a per-repo `ENC[repo]` → encoded-path map and uses `${ENC[$repo]}` everywhere instead of hardcoding `brokernet%2F${repo}`.

## MR defaults (non-negotiable)

| Field | Value |
|-------|-------|
| Source branch | `development` |
| Target branch | `staging` |
| Title | `Development -> Staging` |
| Label | `staging-deployment` |
| Draft | no |
| Description | empty |
| Assignee / Reviewer | none |

## UI version bump (extra step for UI repos)

**UI repos need a version bump on the source branch BEFORE the promotion MR is created.** Rule (user directive 2026-08-06): **raise the PATCH version when promoting dev→staging** — and the same extra step applies to staging→main promotions. Reference commit: brokernet-hotel-ui `83b8bc87` ("raise version for staging", `package.json` version line change; that instance happened to be a major bump — the standing rule is patch).

Affected UI repos (exactly these five):

| Repo | package.json |
|------|--------------|
| `callidus-bvs-ui` | root `package.json` |
| `servo-ui` | root `package.json` |
| `brokernet-cockpit-ui` | root `package.json` |
| `brokernet-hotel-ui` | root `package.json` |
| `brokernet-onboarding-ui` | root `package.json` |

`brokernet-document-cms` and the `bpp-*` backends do NOT get a bump — MR only.

Mechanics, per UI repo that will get an MR:

1. **Idempotency guard** — read `.version` from `package.json` on BOTH branches (`/repository/files/package.json/raw?ref=<branch>`). If source-branch version ≠ target-branch version, the bump already happened (e.g. re-run, or a manual bump) → skip the bump, create the MR only.
2. Bump the patch component: `X.Y.Z[-SUFFIX]` → `X.Y.(Z+1)[-SUFFIX]` (keep any `-SNAPSHOT`-style suffix verbatim).
3. Commit it on the **source branch** with message `raise version for staging` (or `raise version for main` for staging→main), via the GitLab commits API (update action on `package.json`) — or via a local clean checkout already on the source branch if one exists (then push plain; report so other checkouts get pulled). Never force-push.
4. Then create the promotion MR as usual — the bump commit rides in it.

The preview (step 4) must mark which repos will receive a bump so the user confirms both actions with one "go".

## Workflow

### 1. Discover repos

Build a `name → encoded-project-path` map. Filtered repos get `brokernet%2F${repo}`; the always-include extras are added explicitly (one of them with a subgroup-encoded path). Every later step keys off `${ENC[$repo]}`.

```bash
declare -A ENC

# Filtered repos from the brokernet/ group
while read -r repo; do
  ENC[$repo]="brokernet%2F${repo}"
done < <(glab api "/groups/brokernet/projects?per_page=100&simple=true" \
  | jq -r '.[] | select(.path | test("^(bpp-|brokernet-.*-ui$)")) | .path')

# Always-include extras (filter misses them / subgroup)
ENC[brokernet-document-cms]="brokernet%2Fbrokernet-document-cms"
ENC[callidus-bvs-ui]="brokernet%2Fcallidus%2Fcallidus-bvs-ui"
ENC[servo-ui]="brokernet%2Fservo%2Fservo-ui"

REPOS=("${!ENC[@]}")
```

### 2. Check diffs and validate branches (FAIL LOUDLY)

For each repo, compare `staging` ← `development`. Detect missing branches by checking whether `.commits` is present in the JSON response — do NOT grep the body for "404"/"not found" (commit messages can contain those strings and produce false positives). If `.commits` is missing/null, the API returned an error (usually missing branch); record it and fail loudly at the end.

```bash
declare -A AHEAD
declare -a MISSING
for repo in "${REPOS[@]}"; do
  enc="${ENC[$repo]}"
  resp=$(glab api "/projects/${enc}/repository/compare?from=staging&to=development" 2>/dev/null)
  count=$(echo "$resp" | jq -r '.commits | length' 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "null" ]; then
    err=$(echo "$resp" | jq -r '.message // .error // "unknown"' 2>/dev/null)
    MISSING+=("${repo} (${err})")
    continue
  fi
  AHEAD[$repo]=$count
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "FAIL — missing branches or API errors:" >&2
  printf "  %s\n" "${MISSING[@]}" >&2
  exit 1
fi
```

### 3. Skip repos with an existing open dev→staging MR

For repos with diffs, query open MRs (`source=development`, `target=staging`). If one already exists, skip — do not create a duplicate.

```bash
declare -A EXISTING_MR
for repo in "${REPOS[@]}"; do
  c=${AHEAD[$repo]:-0}
  [ "$c" -eq 0 ] && continue
  enc="${ENC[$repo]}"
  iid=$(glab api "/projects/${enc}/merge_requests?state=opened&source_branch=development&target_branch=staging" 2>/dev/null \
    | jq -r '.[0].iid // empty')
  [ -n "$iid" ] && EXISTING_MR[$repo]=$iid
done
```

### 4. Preview — STOP and wait for "go"

Print three groups: repos that WILL get an MR (diffs, no existing MR), repos SKIPPED for no diffs, and repos SKIPPED because an open dev→staging MR already exists (show the existing `!iid`). Then stop and ask the user to confirm. Do NOT create any MR before the user replies "go" (or equivalent).

```
Will create MR for:
  bpp-backend             (3 commits)
  bpp-auth                (1 commit)
  brokernet-hotel-ui      (2 commits)  + patch-version bump 4.0.0 → 4.0.1
  ...

Skipping (no diffs):
  bpp-mail
  ...

Skipping (open MR already exists):
  bpp-stella              !35
  ...

Reply "go" to create MRs.
```

### 5. Create MRs

Only for repos with `AHEAD[$repo] > 0` AND no existing open MR.

**UI repos first get the patch-version bump** (see "UI version bump" section above — guard, bump, commit on `development`), then the MR:

```bash
for repo in "${REPOS[@]}"; do
  [ "${AHEAD[$repo]}" -eq 0 ] && continue
  [ -n "${EXISTING_MR[$repo]}" ] && continue
  enc="${ENC[$repo]}"
  result=$(glab api --method POST "/projects/${enc}/merge_requests" \
    -f source_branch=development \
    -f target_branch=staging \
    -f title="Development -> Staging" \
    -f labels="staging-deployment" 2>&1)
  iid=$(echo "$result" | jq -r '.iid // empty')
  url=$(echo "$result" | jq -r '.web_url // empty')
  if [ -n "$iid" ]; then
    echo "✓ ${repo}!${iid}  ${url}"
  else
    echo "✗ ${repo}  ERROR: ${result}" >&2
  fi
done
```

### 6. Report

Final summary: created MRs (with URLs) and skipped repos.

## Common mistakes

- **Creating MRs without diff check** → GitLab returns "no commits between branches"; always compare first.
- **Forgetting the `staging-deployment` label** → ops dashboards filter on this; non-negotiable.
- **Silent skip on missing branch** → fail loudly, do NOT assume conventions.
- **Skipping preview** → never bulk-write across 13+ repos without explicit user confirmation.
- **Adding description / assignee / reviewer** → defaults only; only override if user explicitly asks.
- **Wrong title casing or arrow** → must be exactly `Development -> Staging` (space, `->`, space).
- **Forgetting the UI patch-version bump** → the five UI repos (callidus-bvs / servo / cockpit / hotel / onboarding) need the `package.json` patch bump committed on the source branch BEFORE the MR; document-cms and backends don't.
- **Double-bumping on re-run** → always apply the idempotency guard (source vs target version differ = already bumped).
- **Missing servo-ui / callidus-bvs-ui** → both live in subgroups; the group listing without `include_subgroups` never returns them — they come from the always-include extras.

## Red flags — STOP

- About to call POST `/merge_requests` before showing preview → STOP, show preview first.
- Got a 404 on `/repository/compare` → do NOT silently skip; abort with error.
- Considering creating an MR for a repo not matching the filter AND not in the always-include extras list → STOP, exclude it.
