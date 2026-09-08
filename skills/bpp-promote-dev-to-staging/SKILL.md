---
name: bpp-promote-dev-to-staging
description: Use when promoting a stage branch across BPP GitLab repositories — "promote dev to staging", "create staging MRs", "staging deployment MRs", and equally "promote staging to main", "main deployment MRs". Bulk-creates one merge request per repo that has content diffs, with the direction's fixed title/label and a short generated change summary as description.
---

# BPP: Promote stage branches (development → staging, staging → main)

## Overview

Bulk-create promotion MRs across all BPP repos in the `brokernet/` GitLab group via `glab`. Two supported directions with fixed conventions (table below). Skips repos with no content diffs and repos that already have an open promotion MR for the direction. Always shows a preview and waits for explicit user confirmation before creating any MR.

## Direction conventions (non-negotiable)

| | dev→staging (default) | staging→main |
|---|---|---|
| Source branch | `development` | `staging` |
| Target branch | `staging` | `main` |
| Title | `Development -> Staging` | `Staging -> Main` |
| Label | `staging-deployment` | `main-deployment` |
| Bump commit msg | `raise version for staging` | `raise version for main` |

Single arrow `->` with spaces, exact casing. The staging→main label is `main-deployment` — NOT `prod-deployment` (retired fleet-wide 2026-07-02) and never the other direction's label. Set `SRC`/`TGT`/`TITLE`/`LABEL` once from this table; every snippet below uses them.

## Prerequisites

- `glab` authenticated against gitlab.com — verify with `glab auth status`
- `jq` available

## Repo filter

Filtered repos in `brokernet/` group:
- `^bpp-.*` (e.g. `bpp-backend`, `bpp-auth`, `bpp-stella`)
- `^brokernet-.*-ui$` (e.g. `brokernet-cockpit-ui`, `brokernet-onboarding-ui`)

Exclude everything else (ops scripts, infra, archived).

### Always-exclude (matches the filter, but must NOT be promoted)

- `bpp-cca-connector-internal` — temporary internal repo, slated for removal/merge — excluded from automated sweeps. Exact-name exclusion; `bpp-cca-connector` is a separate, real repo and stays in. It matches `^bpp-` **and** may appear in `repos.md`, so it is dropped in two places: the group-listing filter (step 1) and an `unset` after the cross-check below — otherwise the cross-check re-adds it.
- `bpp-audit-reports` — generated output of the `bpp-daily-audit` skill (reports, escalations, finding ledger). It has a single `main` branch and no product code, so it is never promoted. Dropped in the same two places as above.

### Always-include extras (do NOT match the filter / live in a subgroup)

These are explicitly added on every run regardless of the filter:
- `brokernet-document-cms` — in `brokernet/` group but has no `-ui$` suffix → filter misses it.
- `callidus-bvs-ui` — in the `lipso/clients/brokernet/callidus/` **subgroup**, so the group listing never returns it; needs the encoded path `lipso%2Fclients%2Fbrokernet%2Fcallidus%2Fcallidus-bvs-ui`.
- `servo-ui` — in the `lipso/clients/brokernet/servo/` **subgroup**; encoded path `lipso%2Fclients%2Fbrokernet%2Fservo%2Fservo-ui`.

Because one extra lives in a subgroup, the encoded project path can't be derived as `lipso%2Fclients%2Fbrokernet%2F${repo}` for every repo. The workflow therefore builds a per-repo `ENC[repo]` → encoded-path map and uses `${ENC[$repo]}` everywhere instead of hardcoding `lipso%2Fclients%2Fbrokernet%2F${repo}`.

### Authoritative cross-check: bpp/repos.md (MANDATORY)

The central BPP repo list lives in the internal knowledge repo:
`https://gitlab.com/lipso/internal/agentic-coding-knowledge/-/blob/main/bpp/repos.md`

After building `ENC`, fetch it and cross-check so no repo gets missed (real precedent 2026-08-14: the filter+extras missed `brokernet-app`, `brokernet-fiab-connector`, `brokernet-file-scanner`, `brokernet-varias-sign`, `servo-hw-connector`, `docling-sidecar`):

```bash
glab api "projects/lipso%2Finternal%2Fagentic-coding-knowledge/repository/files/bpp%2Frepos.md/raw?ref=main" > "$WORK/repos.md"
# rows: "| repo-name | https://gitlab.com/<path> | description |" (Backend + Frontend tables)
while IFS='|' read -r _ name link _; do
  name=$(echo "$name" | xargs); link=$(echo "$link" | xargs)
  [[ "$link" == https://gitlab.com/* ]] || continue
  path=${link#https://gitlab.com/}
  if [ -z "${ENC[$name]:-}" ]; then
    ENC[$name]=$(printf %s "$path" | sed 's#/#%2F#g')
    echo "ADDED-FROM-LIST $name ($path)"
  fi
done < <(grep -E '^\|[^|]+\| *https://gitlab.com/' "$WORK/repos.md")

# always-exclude (the cross-check would re-add them):
#   bpp-cca-connector-internal — temporary internal repo, slated for removal/merge
#   bpp-audit-reports          — generated audit output, single main branch, never promoted
unset 'ENC[bpp-cca-connector-internal]' 'ENC[bpp-audit-reports]'
```

- Every list repo missing from `ENC` is **added** (encoded path derived from the link — this also handles subgroups like `brokernet/servo/...`). The branch probe then decides naturally whether it participates ("no staging branch" stays an expected outcome).
- If the fetch fails or parses to zero rows, **say so loudly in the preview** ("cross-check skipped — list unreachable") and continue with filter+extras; never silently pretend the check ran.
- Repos discovered by the filter but absent from the list are fine (list may lag) — report them informationally.

## MR defaults (non-negotiable)

| Field | Value |
|-------|-------|
| Source branch | `$SRC` (per direction) |
| Target branch | `$TGT` (per direction) |
| Title | per direction table |
| Label | per direction table |
| Draft | no |
| Description | short generated change summary (see "MR change summary" below) |
| Assignee / Reviewer | none |

## UI version bump (extra step for UI repos)

**UI repos need a version bump on the source branch BEFORE the promotion MR is created.** Rule (user directive 2026-08-06): **raise the PATCH version when promoting** — applies to BOTH directions. Reference commit: brokernet-hotel-ui `83b8bc87` ("raise version for staging", `package.json` version line change; that instance happened to be a major bump — the standing rule is patch).

Affected UI repos (exactly these six):

| Repo | package.json |
|------|--------------|
| `callidus-bvs-ui` | root `package.json` |
| `servo-ui` | root `package.json` |
| `brokernet-cockpit-ui` | root `package.json` |
| `brokernet-hotel-ui` | root `package.json` |
| `brokernet-onboarding-ui` | root `package.json` |
| `bpp-document-analysis-dashboard` | root `package.json` |

`brokernet-document-cms` and the `bpp-*` backends do NOT get a bump — MR only.

### `brokernet-app` (go-stella) — do NOT bump it from this skill

`brokernet-app` looks like a UI repo but its version does **not** live in one `package.json`. It sits in **16 files across 4 ecosystems** (Gradle `versionName`, Xcode `MARKETING_VERSION`, npm, and 12 Angular `src/environments/*` files). A naive root-`package.json` bump leaves the app reporting inconsistent versions across platforms, and a global search-replace on the pbxproj corrupts the 2 `MARKETING_VERSION` lines that belong to a separate Xcode extension target with its own release cadence.

It has its own dedicated skill, maintained by nangert, which handles all 16 files with a hard verification gate:
<https://gitlab.com/lipso/internal/agentic-coding-knowledge/-/blob/main/personal-workflows/nangert/skills/stella-bump-version-staging-mr/SKILL.md>

Rules when a promotion wave includes `brokernet-app`:
- **Never** bump its version from this skill — not `package.json`, not any environment file.
- If the wave needs a go-stella release bump, hand that off to `stella-bump-version-staging-mr` (or the user) **first**, then create the promotion MR here so the bump commit rides in it.
- If no bump is wanted, promote `brokernet-app` MR-only like the backends. That is the default.
- Note that skill targets **`development` -> `staging`** and the `staging-deployment` **label** (not a git tag). For `staging` -> `main` it does not apply — bump handling there is out of its scope; ask the user.
- Also note it is written for BSD `sed -i ''`; on this Linux box that invocation fails. Read it as the source of truth for *which files and which anchors*, not for verbatim commands.

Mechanics, per UI repo that will get an MR:

1. **Idempotency guard** — read `.version` from `package.json` on BOTH branches (`/repository/files/package.json/raw?ref=<branch>`). If source-branch version ≠ target-branch version, the bump already happened (e.g. re-run, or a manual bump) → skip the bump, create the MR only.
2. Bump the patch component: `X.Y.Z[-SUFFIX]` → `X.Y.(Z+1)[-SUFFIX]` (keep any `-SNAPSHOT`-style suffix verbatim).
3. Commit it on the **source branch** with the direction's bump message, via the GitLab commits API (update action on `package.json`) — or via a local clean checkout already on the source branch if one exists (then push plain; report so other checkouts get pulled). Never force-push.
4. Then create the promotion MR as usual — the bump commit rides in it.

The preview (step 4) must mark which repos will receive a bump so the user confirms both actions with one "go".

## Workflow

### 1. Discover repos

Build a `name → encoded-project-path` map. Filtered repos get `lipso%2Fclients%2Fbrokernet%2F${repo}`; the always-include extras are added explicitly (two with subgroup-encoded paths). Every later step keys off `${ENC[$repo]}`.

```bash
declare -A ENC

# Filtered repos from the brokernet/ group
while read -r repo; do
  ENC[$repo]="lipso%2Fclients%2Fbrokernet%2F${repo}"
done < <(glab api "/groups/lipso%2Fclients%2Fbrokernet/projects?per_page=100&simple=true" \
  | jq -r '.[] | select((.path | test("^(bpp-|brokernet-.*-ui$)")) and (.path | IN("bpp-cca-connector-internal", "bpp-audit-reports") | not)) | .path')

# Always-include extras (filter misses them / subgroup)
ENC[brokernet-document-cms]="lipso%2Fclients%2Fbrokernet%2Fbrokernet-document-cms"
ENC[callidus-bvs-ui]="lipso%2Fclients%2Fbrokernet%2Fcallidus%2Fcallidus-bvs-ui"
ENC[servo-ui]="lipso%2Fclients%2Fbrokernet%2Fservo%2Fservo-ui"

REPOS=("${!ENC[@]}")
```

### 2. Probe branches explicitly, then compare (FAIL LOUDLY, but separate "no branch" from "no diffs")

**TRAP — `jq '.commits | length'` cannot detect a missing branch:** on an error body `.commits` is `null`, and in jq `null | length` evaluates to `0`, not null — so a repo whose stage branch doesn't exist silently reads as "no diffs". Probe both branches explicitly FIRST; only then compare.

Repos legitimately have no stage branches (e.g. `bpp-shared` ships via NuGet; `bpp-agent`, `bpp-agent-ui`, `bpp-shared-template` have no `staging`; `bpp-partner-api-guide` has neither `development` nor `staging`). "No `$TGT`/`$SRC` branch" is an expected reported outcome, NOT an abort — but an API error on a repo whose branches BOTH exist IS an abort.

```bash
declare -A AHEAD NDIFFS
declare -a NOBRANCH ERRORS
for repo in "${REPOS[@]}"; do
  enc="${ENC[$repo]}"
  skip=""
  for br in "$SRC" "$TGT"; do
    name=$(glab api "/projects/${enc}/repository/branches/${br}" 2>/dev/null | jq -r '.name // "MISSING"')
    [ "$name" = "MISSING" ] && { NOBRANCH+=("${repo}: no ${br} branch"); skip=1; break; }
  done
  [ -n "$skip" ] && continue
  resp=$(glab api "/projects/${enc}/repository/compare?from=${TGT}&to=${SRC}" 2>/dev/null)
  commits=$(echo "$resp" | jq -r '.commits | length' 2>/dev/null)
  diffs=$(echo "$resp" | jq -r '.diffs | length' 2>/dev/null)
  if [ -z "$commits" ] || [ "$commits" = "null" ]; then
    ERRORS+=("${repo}: compare failed despite both branches existing"); continue
  fi
  AHEAD[$repo]=$commits
  NDIFFS[$repo]=$diffs
done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "FAIL — compare errors:" >&2; printf "  %s\n" "${ERRORS[@]}" >&2; exit 1
fi
```

**Gate MR creation on `NDIFFS > 0`, not commit count.** Degenerate promotions exist: commits ahead but ZERO file diffs (merge-commit-only ancestry, content identical — real precedent: callidus-bvs-ui 2 merge commits, empty `.diffs`). Those are reported as "no content diffs", no MR.

### 3. Skip repos with an existing open promotion MR

For repos with diffs, query open MRs (`source_branch=$SRC`, `target_branch=$TGT` — match on branches, NOT on title; older MRs may carry legacy titles like `Development --> Staging`). If one already exists, skip creation — do not create a duplicate. A push to the source branch updates the open MR automatically.

```bash
declare -A EXISTING_MR
for repo in "${REPOS[@]}"; do
  c=${NDIFFS[$repo]:-0}
  [ "$c" -eq 0 ] && continue
  enc="${ENC[$repo]}"
  iid=$(glab api "/projects/${enc}/merge_requests?state=opened&source_branch=${SRC}&target_branch=${TGT}" 2>/dev/null \
    | jq -r '.[0].iid // empty')
  [ -n "$iid" ] && EXISTING_MR[$repo]=$iid
done
```

### 4. Preview — STOP and wait for "go"

Print four groups: repos that WILL get an MR (diffs, no existing MR), repos SKIPPED for no content diffs (show commit count if > 0 — degenerate), repos SKIPPED because an open promotion MR already exists (show the existing `!iid`), and repos with NO stage branch (expected topology). Then stop and ask the user to confirm. Do NOT create any MR before the user replies "go" (or equivalent).

```
Will create MR for:
  bpp-backend             (3 commits, 12 files)
  bpp-auth                (1 commit, 2 files)
  brokernet-hotel-ui      (2 commits, 5 files)  + patch-version bump 4.0.1 → 4.0.2
  ...

Skipping (no content diffs):
  bpp-mail
  callidus-bvs-ui         (2 commits but 0 file diffs — merge-commit-only)
  ...

Skipping (open MR already exists):
  bpp-stella              !35
  ...

No stage branch (expected):
  bpp-shared              (no staging — ships via NuGet)
  ...

Reply "go" to create MRs.
```

### 5. MR change summary (description) — generate per repo

Every promotion MR gets a SHORT generated description summarizing what the promotion ships. Build it from the compare response already fetched in step 2:

1. **Commits** → group by conventional prefix / ticket key (`BRO-xxxx`) → one bullet per feature/fix theme, not one per commit. Drop pure merge commits and version-bump noise from the bullets.
2. **Files** (`diffs[]`) → categorize: added (`new_file`), removed (`deleted_file`), renamed (`renamed_file`), modified (the rest). Report counts + call out high-signal paths explicitly: **DB migrations** (`Migrations/`), **CI** (`.gitlab-ci.yml`), **config** (`appsettings.*`), **version bumps** (`package.json` / `Directory.Build.props`).
3. **TRAP — the compare payload is TRUNCATED on big promotions**: per-file diff content can be missing hunks and the file list itself can be capped. Treat counts from a truncated payload as a lower bound ("N+ files") and NEVER claim "X was not changed/removed" from compare output — verify via `/repository/files/<path>/raw?ref=` on both branches when it matters.
4. Keep it short — Markdown, ≤ ~15 lines:

```markdown
### Changes
- Added: <feature theme(s)> (BRO-xxxx)
- Updated: <theme(s)>
- Fixed: <theme(s)>
- Removed: <theme(s), if any>

### Files
N added / M modified / K removed — incl. 1 DB migration, CI change, package.json bump
```

Omit empty categories. Pass it via `-f description="$DESC"` on the POST. If the summary was drafted in a file, inline it with `DESC="$(cat file)"` — glab cannot read description-file args from sandboxed /tmp.

### 6. Create MRs

Only for repos with `NDIFFS[$repo] > 0` AND no existing open MR.

**UI repos first get the patch-version bump** (see "UI version bump" section above — guard, bump, commit on `$SRC`), then the MR:

```bash
for repo in "${REPOS[@]}"; do
  [ "${NDIFFS[$repo]:-0}" -eq 0 ] && continue
  [ -n "${EXISTING_MR[$repo]:-}" ] && continue
  enc="${ENC[$repo]}"
  result=$(glab api --method POST "/projects/${enc}/merge_requests" \
    -f source_branch="$SRC" \
    -f target_branch="$TGT" \
    -f title="$TITLE" \
    -f labels="$LABEL" \
    -f description="${DESC[$repo]}" 2>&1)
  iid=$(echo "$result" | jq -r '.iid // empty')
  url=$(echo "$result" | jq -r '.web_url // empty')
  if [ -n "$iid" ]; then
    echo "✓ ${repo}!${iid}  ${url}"
  else
    echo "✗ ${repo}  ERROR: ${result}" >&2
  fi
done
```

### 7. Report

Final summary: created MRs (with URLs), reused open MRs, skipped repos (no diffs / degenerate / no branch). Note: `detailed_merge_status` stays `checking` for a while after bulk creation and `has_conflicts:false` is NOT authoritative while checking — report mergeability as un-computed rather than clean.

## Common mistakes

- **Creating MRs without diff check** → GitLab returns "no commits between branches"; always compare first.
- **Gating on commit count instead of `.diffs | length`** → degenerate merge-commit-only promotions create empty MRs.
- **Trusting `jq '.commits | length'` for missing-branch detection** → `null | length` is `0` in jq; a missing branch silently reads as "no diffs". Probe branches explicitly.
- **Writing `select(.path | test(...) and .path != "x")`** → inside `select(.path | ...)` the pipe rebinds `.` to the string, so the second `.path` fails with `Cannot index string with string "path"` and the whole listing aborts (verified 2026-09-08; this was a live bug in this skill). Each field access needs its own parenthesised pipe: `select((.path | test(...)) and (.path | IN("a","b") | not))`.
- **Wrong label for the direction** → `staging-deployment` vs `main-deployment`; ops dashboards filter on these. staging→main is NOT `prod-deployment` (retired).
- **Wrong title casing or arrow** → exactly `Development -> Staging` / `Staging -> Main` (space, single `->`, space).
- **Matching existing MRs by title** → legacy MRs use `-->`; match on source/target branch only.
- **Concluding "X isn't in this promotion" from compare output** → the compare diff is truncated; read the raw file on both branches.
- **Silent skip on an API error** → "no stage branch" is an expected reported outcome; a compare error with both branches present is an abort.
- **Skipping preview** → never bulk-write across 13+ repos without explicit user confirmation.
- **Omitting the change-summary description** → every created MR carries the short added/updated/fixed/removed summary; empty descriptions are no longer allowed.
- **Adding assignee / reviewer** → defaults only; only override if user explicitly asks.
- **Forgetting the UI patch-version bump** → the six UI repos (callidus-bvs / servo / cockpit / hotel / onboarding / doci-dashboard) need the `package.json` patch bump committed on the source branch BEFORE the MR; document-cms and backends don't.
- **Bumping `brokernet-app` like a UI repo** → its version lives in 16 files across Gradle / Xcode / npm / Angular envs, not one `package.json`. Never bump it here; it has its own skill ([stella-bump-version-staging-mr](https://gitlab.com/lipso/internal/agentic-coding-knowledge/-/blob/main/personal-workflows/nangert/skills/stella-bump-version-staging-mr/SKILL.md)). Default in a promotion wave is MR-only.
- **Double-bumping on re-run** → always apply the idempotency guard (source vs target version differ = already bumped).
- **Missing servo-ui / callidus-bvs-ui** → both live in subgroups; the group listing without `include_subgroups` never returns them — they come from the always-include extras.
- **Skipping the bpp/repos.md cross-check** → the filter+extras provably drift (2026-08-14: six repos missed, e.g. `brokernet-app`, `servo-hw-connector`). Always fetch the list and add its missing repos before probing; if unreachable, flag it in the preview instead of silently proceeding.

## Red flags — STOP

- About to call POST `/merge_requests` before showing preview → STOP, show preview first.
- Compare API errored on a repo whose branches both exist → do NOT silently skip; abort with error.
- About to label a staging→main MR `staging-deployment` (or vice versa) → STOP, check the direction table.
- Considering creating an MR for a repo not matching the filter AND not in the always-include extras list → STOP, exclude it.
