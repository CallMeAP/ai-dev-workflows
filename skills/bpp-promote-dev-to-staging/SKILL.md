---
name: bpp-promote-dev-to-staging
description: Use when promoting a stage branch across BPP GitLab repositories — "promote dev to staging", "create staging MRs", "staging deployment MRs", and equally "promote staging to main", "main deployment MRs". Bulk-creates one merge request per repo that has content diffs, with the direction's fixed title/label and a short generated change summary as description.
---

# BPP: Promote stage branches (development → staging, staging → main)

## Overview

Bulk-create promotion MRs across all BPP repos in the `lipso/clients/brokernet/` GitLab group via `glab`. Two supported directions with fixed conventions (table below). Skips repos with no content diffs and repos that already have an open promotion MR for the direction. Always shows a preview and waits for explicit user confirmation before creating any MR.

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

## Repo discovery — delegated to `bpp-project-index`

**This skill no longer derives the repo set.** `bpp-project-index` owns the group listing, the
`bpp/repos.md` cross-check, the subgroup-encoded paths and the always-exclude list, and publishes them
as `~/.claude/bpp-fleet/manifest.tsv`. Invoke it first (read-only refresh, ~7 s), then filter.

The promotion candidate set is:

> `state=active`, tags ∌ `internal-temp,generated-output,excluded-manual`, and
> `class ∈ {backend, frontend, docs}` **or** (`class=unlisted` and name matches `^bpp-|^brokernet-.*-ui$`)

Verified 2026-09-14: this reproduces the old filter + extras + cross-check set **exactly** — 35 repos,
zero drift in either direction.

Everything below is still true; it just lives in the index now, once, instead of here and in three other
skills:

- **`bpp-cca-connector-internal`** (tag `internal-temp`) — temporary internal repo, slated for
  removal/merge, excluded from automated sweeps. Exact-name exclusion: `bpp-cca-connector` is a separate,
  real repo and stays in.
- **`servo-backend`** (tag `excluded-manual`) — excluded by user decision 2026-09-18. Its
  `development`→`staging` diff is 2024 legacy (`development` idle since 2024-12-11, `staging` since
  2024-05-24) and its `build` job fails on a pre-existing CI defect unrelated to the promotion content:
  `invalid tag "…/servo-backend/:4.0.0": invalid reference format` — an unset image-name variable. The
  sweep opened MR !2 from it, which was then closed. **Do not re-open it**; re-including the repo means
  fixing that CI first. `servo-ui` and `servo-hw-connector` stay in scope.
- **`bpp-audit-reports`** (tag `generated-output`) — generated output of the `bpp-daily-audit` skill
  (reports, escalations, finding ledger). Single `main` branch, no product code, never promoted.
- **`brokernet-document-cms`, `callidus-bvs-ui`, `servo-ui`** — the former "always-include extras". The
  first has no `-ui$` suffix so the name filter misses it; the other two live in **subgroups**
  (`callidus/`, `servo/`) and a group listing without `include_subgroups=true` returns neither
  (verified 2026-09-14: 57 projects, zero of them). They are ordinary manifest rows now.
- **The `bpp/repos.md` cross-check is still mandatory** — the index does it on every refresh. It is what
  keeps `brokernet-fiab-connector`, `brokernet-file-scanner`, `brokernet-varias-sign`,
  `servo-hw-connector` and `docling-sidecar` in the set (2026-08-14 precedent: six repos silently
  missed without it).
- **The `class=unlisted` clause is load-bearing** — it is what keeps `bpp-cypress` and `bpp-db-migrator`
  in the sweep while `repos.md` still omits them.
- **Encoded paths come from the manifest's `enc` column.** Never rebuild them as
  `lipso%2Fclients%2Fbrokernet%2F${repo}` — wrong for every subgroup repo.

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

Invoke `bpp-project-index` first, then build the `name → encoded-project-path` map from its manifest.
Every later step keys off `${ENC[$repo]}`.

```bash
MANIFEST=~/.claude/bpp-fleet/manifest.tsv

declare -A ENC
while IFS=$'\t' read -r repo enc; do
  ENC[$repo]="$enc"
done < <(awk -F'\t' '!/^#/ && $6=="active" && $5!~/internal-temp|generated-output|excluded-manual/ \
  && ($4=="backend" || $4=="frontend" || $4=="docs" || ($4=="unlisted" && $1 ~ /^bpp-|^brokernet-.*-ui$/)) \
  {print $1 "\t" $3}' "$MANIFEST")

REPOS=("${!ENC[@]}")
echo "${#REPOS[@]} repos — $(grep -m1 '^#generated' "$MANIFEST") $(grep -m1 '^#source' "$MANIFEST")"
[ ${#REPOS[@]} -gt 20 ] || { echo "FAIL — only ${#REPOS[@]} repos; the manifest is truncated or stale" >&2; exit 1; }
```

- **Sanity gate, not decoration:** the set has been 34–35 repos all year. A sudden small set means a
  truncated manifest, not a shrinking fleet — abort rather than promote a subset.
- **Check the manifest header.** Older than 24 h, or `#source` says `gitlab=unreachable`? Refresh the
  index before creating MRs, or state it in the preview. A promotion wave built on a stale fleet list
  silently skips a repo that was added since.
- **If the manifest is missing and the index cannot run** (glab down), use the legacy inline discovery
  below and **say so loudly in the preview** — never promote from a silently-truncated set.

<details>
<summary>Fallback — legacy inline discovery (only when the manifest is unavailable)</summary>

Filtered repos in the `lipso/clients/brokernet/` group: `^bpp-.*` and `^brokernet-.*-ui$`; plus the
three always-include extras; then the `bpp/repos.md` cross-check; then the two always-excludes (the
cross-check re-adds them otherwise).

```bash
declare -A ENC

# Filtered repos from the lipso/clients/brokernet/ group
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

```bash
glab api "projects/lipso%2Finternal%2Fagentic-coding-knowledge/repository/files/bpp%2Frepos.md/raw?ref=main" > "$WORK/repos.md"
while IFS='|' read -r _ name link _; do
  name=$(echo "$name" | xargs); link=$(echo "$link" | xargs)
  [[ "$link" == https://gitlab.com/* ]] || continue
  path=${link#https://gitlab.com/}
  [ -z "${ENC[$name]:-}" ] && ENC[$name]=$(printf %s "$path" | sed 's#/#%2F#g')
done < <(grep -E '^\|[^|]+\| *https://gitlab.com/' "$WORK/repos.md")
unset 'ENC[bpp-cca-connector-internal]' 'ENC[bpp-audit-reports]'
```

</details>

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
- **Missing servo-ui / callidus-bvs-ui** → both live in subgroups; a group listing without `include_subgroups=true` never returns them (verified 2026-09-14: 57 projects, zero of them). They reach this skill as ordinary `bpp-project-index` manifest rows with subgroup-encoded `enc` values — never rebuild an encoded path from the repo name.
- **Rebuilding the repo set here instead of reading the manifest** → the filter+extras provably drift from `bpp/repos.md` in both directions (2026-08-14: six repos missed, e.g. `brokernet-app`, `servo-hw-connector`; 2026-09-14: `bpp-cypress` and `bpp-db-migrator` in the group but not in the list). `bpp-project-index` does the union on every refresh — read it. If the manifest is stale or `#source` says `gitlab=unreachable`, flag it in the preview instead of silently proceeding.

## Red flags — STOP

- About to call POST `/merge_requests` before showing preview → STOP, show preview first.
- Compare API errored on a repo whose branches both exist → do NOT silently skip; abort with error.
- About to label a staging→main MR `staging-deployment` (or vice versa) → STOP, check the direction table.
- Considering creating an MR for a repo the manifest filter did not return → STOP, exclude it. Fix the classification in `bpp/repos.md` via `bpp-project-index`, never by special-casing a repo here.
