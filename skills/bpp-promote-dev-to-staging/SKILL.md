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

> `state=active`, tags ∌ `generated-output,excluded-manual`, and
> `class ∈ {backend, frontend, docs}` **or** (`class=unlisted` and name matches `^bpp-|^brokernet-.*-ui$`)

Verified 2026-09-14: this reproduces the old filter + extras + cross-check set **exactly** — 35 repos,
zero drift in either direction.

Everything below is still true; it just lives in the index now, once, instead of here and in three other
skills:

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

## Version bump (extra step for the repos in the bump table)

**The repos in the table below need a version bump on the source branch BEFORE the promotion MR is created.** Rule (user directive 2026-08-06): **raise the PATCH version when promoting** — applies to BOTH directions. Reference commit: brokernet-hotel-ui `83b8bc87` ("raise version for staging", `package.json` version line change; that instance happened to be a major bump — the standing rule is patch).

Affected repos (exactly these nine):

| Repo | Version file | Version anchor |
|------|--------------|----------------|
| `bpp-stella-ui` | `projects/bpp-stella-web/package.json` **+** its workspace entry in the root `package-lock.json` | `.version` — see the `bpp-stella-ui` subsection; never the app or common |
| `callidus-bvs-ui` | root `package.json` | `.version` |
| `servo-ui` | root `package.json` | `.version` |
| `brokernet-cockpit-ui` | root `package.json` | `.version` |
| `brokernet-hotel-ui` | root `package.json` | `.version` |
| `brokernet-onboarding-ui` | root `package.json` | `.version` |
| `bpp-document-analysis-dashboard` | root `package.json` | `.version` |
| `brokernet-document-cms` | root `package.json` | `.version` |
| `brokernet-varias-sign` | root `pom.xml` | the project `<version>` — the first one **after** `</parent>`. The first `<version>` in the file is the spring-boot parent (`2.7.2`); never touch it. |

Why `brokernet-document-cms` and `brokernet-varias-sign` are in: their image build refuses to overwrite an existing tag — `main with tag 4.2.2-SNAPSHOT already exists!` / `main with tag 11.0.0 already exists!` — so an un-bumped promotion merges but **skips deploy**. Happened on both `main` pipelines in the 2026-08-14 and 2026-09-25 waves.

The `bpp-*` backends do NOT get a bump — MR only.

### `bpp-stella-ui` (formerly `brokernet-app`, go-stella) — bump the web project only

An npm-workspaces monorepo (`projects/*`): `bpp-stella-app` (the mobile app), `bpp-stella-web` (the Kundenportal), `bpp-stella-common`. The repo root `package.json` is `0.0.0` and never changes.

**`bpp-stella-web` IS bumped** (user decision 2026-10-02) — same patch rule and idempotency guard as the other rows, read from `projects/bpp-stella-web/package.json` on both branches. Its staging/main web image is tagged with that version. Exactly two lines change, one per file: the `version` in `projects/bpp-stella-web/package.json`, and the `"projects/bpp-stella-web"` workspace entry in the root `package-lock.json` (present on development/staging/main, verified 2026-10-02). Patch the lock with an anchored `sed`, never `npm version -w` (it runs a full install and rewrites unrelated lock entries). The lock is ~1.4 MB, which is too big for a `-f content=` argument (`Argument list too long`), so commit both files in ONE commit as JSON on stdin (`$OLD`/`$NEW` from the guard and patch rule under "Mechanics", `$BUMP_MSG` = the direction table's bump commit msg):

```bash
P=${ENC[bpp-stella-ui]}
glab api "/projects/$P/repository/files/projects%2Fbpp-stella-web%2Fpackage.json/raw?ref=$SRC" > web.json
glab api "/projects/$P/repository/files/package-lock.json/raw?ref=$SRC" > lock.json
cp web.json web.orig; cp lock.json lock.orig
sed -i "s/^  \"version\": \"$OLD\",$/  \"version\": \"$NEW\",/" web.json
sed -i "/^    \"projects\/bpp-stella-web\": {$/,+2 s/^      \"version\": \"$OLD\",$/      \"version\": \"$NEW\",/" lock.json
diff web.orig web.json; diff lock.orig lock.json      # exactly one changed line each, else STOP
jq -n --arg b "$SRC" --arg m "$BUMP_MSG" --rawfile w web.json --rawfile l lock.json \
  '{branch:$b, commit_message:$m, actions:[
     {action:"update", file_path:"projects/bpp-stella-web/package.json", content:$w},
     {action:"update", file_path:"package-lock.json", content:$l}]}' \
  | glab api --method POST "/projects/$P/repository/commits" -H 'Content-Type: application/json' --input -
```

**`bpp-stella-app` and `bpp-stella-common` are NEVER bumped here.** That rules out their `package.json`, their lock entries and every `environment*` file. The app version does **not** live in one `package.json`. It sits in **16 files across 4 ecosystems** (Gradle `versionName`, Xcode `MARKETING_VERSION`, npm, and 12 Angular `src/environments/*` files). A naive bump leaves the app reporting inconsistent versions across platforms, and a global search-replace on the pbxproj corrupts the 2 `MARKETING_VERSION` lines that belong to a separate Xcode extension target with its own release cadence.

The app has its own dedicated skill, maintained by nangert, which handles all 16 files with a hard verification gate:
<https://gitlab.com/lipso/internal/agentic-coding-knowledge/-/blob/main/personal-workflows/nangert/skills/stella-bump-version-staging-mr/SKILL.md>

Rules when a promotion wave includes `bpp-stella-ui`:
- **Never** bump the app's version from this skill. The `bpp-stella-web` bump above is the only version change this skill makes in the repo.
- If the wave needs a go-stella release bump, hand that off to `stella-bump-version-staging-mr` (or the user) **first**, then create the promotion MR here so the bump commit rides in it.
- If no app bump is wanted, the app goes MR-only, riding along with the web bump. That is the default.
- Note that skill targets **`development` -> `staging`** and the `staging-deployment` **label** (not a git tag). For `staging` -> `main` it does not apply — bump handling there is out of its scope; ask the user.
- Also note it is written for BSD `sed -i ''`; on this Linux box that invocation fails. Read it as the source of truth for *which files and which anchors*, not for verbatim commands.

Mechanics, per affected repo that will get an MR:

1. **Idempotency guard** — read the version (per the table's anchor) on BOTH branches (`/repository/files/<file>/raw?ref=<branch>`). If source-branch version ≠ target-branch version, the bump already happened (e.g. re-run, or a manual bump) → skip the bump, create the MR only.
   - `package.json`: `jq -r .version`
   - `pom.xml`: `sed -n '/<\/parent>/,$p' | grep -m1 -oP '(?<=<version>)[^<]+'`
2. Bump the patch component: `X.Y.Z[-SUFFIX]` → `X.Y.(Z+1)[-SUFFIX]` (keep any `-SNAPSHOT`-style suffix verbatim). Change **only that one line**; diff old vs new before committing — exactly one line may differ, and the trailing newline must survive.
3. Commit it on the **source branch** with the direction's bump message, via the GitLab commits API (update action on the version file) — or via a local clean checkout already on the source branch if one exists (then push plain; report so other checkouts get pulled). Never force-push.
4. Then create the promotion MR as usual — the bump commit rides in it.

The preview (step 4) must mark which repos will receive a bump so the user confirms both actions with one "go".

### `ui_configs` SQL per stage DB — cockpit, kundenportal, stella (user directives 2026-09-28, 2026-10-02)

`ui_configs` holds one active row per `ui_type` in **each stage's DB**. `ui_type` is the native PG enum `bpp_ui_type`, so the labels are lowercase: `'cockpit'`, `'kundenportal'`, `'stella'`. Each row's `version_number` drives that UI's forced reset or update. Agents have no stage-DB access, so this skill never runs the SQL. It only hands the user the statements.

**Every run prints all three stage DBs** — `development`, `staging` and `main`, whatever the direction — with a statement for each of the three `ui_type`s in each group. The value is the **post-promotion** state of that stage's branch: read `origin/development`, `origin/staging` and `origin/main` **after** step 6 (so this run's bump commits on `$SRC` are included), then give `$TGT` the `$SRC` value the promotion brings. Mark every line:

- **`changed by this promotion`**:
  - on `$TGT`, when its pre-promotion value differs from `$SRC`'s;
  - on `$SRC`, only when this run committed the bump there.
- **`unchanged (no-op if already set)`**: everything else, including the stage that this direction does not touch.

| `ui_type` | Version source (per stage branch) | Value in the SQL | Qualifier |
|---|---|---|---|
| `cockpit` | `brokernet-cockpit-ui` root `package.json` | literal, `-SNAPSHOT` included | run once that stage runs the new build |
| `kundenportal` | `bpp-stella-ui` `projects/bpp-stella-web/package.json` | literal, `-SNAPSHOT` included | run **after** the new web image is live on that stage. **development DB: optional**, "only if a reset is wanted on dev" (dev images are sha-tagged) |
| `stella` | `bpp-stella-ui` `environment.appVersion` (see below), cross-checked against `projects/bpp-stella-app/package.json` | plain `major.minor.patch`, any `-SNAPSHOT` stripped | the store warning below; never bumped by this skill |

Statement shape, one per `ui_type` and stage DB. The audit columns follow bpp-backend's `01-seed-ui-configs-*.sql` convention:

```sql
UPDATE ui_configs SET version_number = '<v>', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = '<type>' AND is_soft_deleted = false;
```

**`stella` needs a prominent warning.** Print it verbatim above the statement: "run only AFTER the build is live in App Store + Play Store; a higher major/minor locks users onto the /update page; a patch-only raise does nothing".

**The `stella` value comes from `environment.appVersion`, not package.json, because the app compares `environment.appVersion`.**
- Read it from every file in `projects/bpp-stella-app/src/environments/` except `environment.local-network.ts`.
- That file is stale at `1.5.0` on purpose: it is an emulator config against `localhost:8080`, left unmaintained per `stella-bump-version-staging-mr`.
- If, on a stage branch, the env files disagree among themselves or with package.json, that stage gets BOTH values and the mismatch warning instead of a statement. Never guess.
- On 2026-10-02, development and staging had package.json `1.33.1` against appVersion `1.33.0`.

```bash
P=${ENC[bpp-stella-ui]}
for br in development staging main; do
  pkg=$(glab api "/projects/$P/repository/files/projects%2Fbpp-stella-app%2Fpackage.json/raw?ref=$br" | jq -r .version)
  env=$(glab api "/projects/$P/repository/tree?path=projects/bpp-stella-app/src/environments&ref=$br&per_page=100" \
    | jq -r '.[].name | select(startswith("environment") and . != "environment.local-network.ts")' \
    | while read -r f; do glab api "/projects/$P/repository/files/projects%2Fbpp-stella-app%2Fsrc%2Fenvironments%2F$f/raw?ref=$br" \
        | grep -oP "appVersion:\s*'\K[^']+"; done | sort -u | paste -sd,)
  echo "$br pkg=$pkg appVersion=$env"   # one appVersion value AND == ${pkg%%-*}, else mismatch warning
done
```

- If an UPDATE reports `UPDATE 0`, the row is missing on that stage. The fix is bpp-backend's `BPP.Backend.NET.Sql/InsertSql/01-seed-ui-configs-<stage>.sql`, which creates only missing rows. Say so in the report.
- Before that stage's DbMigrator has applied the `ui_configs` migration, the table doesn't exist yet. Say so instead of printing SQL that will fail.

## Workflow

### 1. Discover repos

Invoke `bpp-project-index` first, then build the `name → encoded-project-path` map from its manifest.
Every later step keys off `${ENC[$repo]}`.

```bash
MANIFEST=~/.claude/bpp-fleet/manifest.tsv

declare -A ENC
while IFS=$'\t' read -r repo enc; do
  ENC[$repo]="$enc"
done < <(awk -F'\t' '!/^#/ && $6=="active" && $5!~/generated-output|excluded-manual/ \
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
  | jq -r '.[] | select((.path | test("^(bpp-|brokernet-.*-ui$)")) and (.path | IN("bpp-audit-reports") | not)) | .path')

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
unset 'ENC[bpp-audit-reports]'
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

**Repos in the bump table first get the patch-version bump** (see "Version bump" section above — guard, bump, commit on `$SRC`), then the MR:

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

Final summary: created MRs (with URLs), reused open MRs, skipped repos (no diffs / degenerate / no branch). Then a **"ui_configs SQL"** block, built per the `ui_configs` section. It always has three groups, `development`, `staging` and `main` in that order, and each group has a line for all three `ui_type`s. Every line carries its marker and qualifier. The statements are handed to the user only, never run. Example: development → staging on 2026-10-02 (cockpit and stella-web bumped by this run):

```
ui_configs SQL (hand to the user, never run):
-- development DB
-- cockpit: changed by this promotion
UPDATE ui_configs SET version_number = '16.0.75-SNAPSHOT', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'cockpit' AND is_soft_deleted = false;
-- kundenportal: changed by this promotion; after the new web image is live; optional, only if a reset is wanted on dev
UPDATE ui_configs SET version_number = '0.1.2-SNAPSHOT', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'kundenportal' AND is_soft_deleted = false;
-- stella: MISMATCH, no statement. package.json 1.33.1 vs environment.appVersion 1.33.0. run only AFTER the build is live in App Store + Play Store; a higher major/minor locks users onto the /update page; a patch-only raise does nothing
-- staging DB
-- cockpit: changed by this promotion
UPDATE ui_configs SET version_number = '16.0.75-SNAPSHOT', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'cockpit' AND is_soft_deleted = false;
-- kundenportal: changed by this promotion; after the new web image is live
UPDATE ui_configs SET version_number = '0.1.2-SNAPSHOT', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'kundenportal' AND is_soft_deleted = false;
-- stella: MISMATCH, no statement. package.json 1.33.1 vs environment.appVersion 1.33.0. run only AFTER the build is live in App Store + Play Store; a higher major/minor locks users onto the /update page; a patch-only raise does nothing
-- main DB
-- cockpit: unchanged (no-op if already set)
UPDATE ui_configs SET version_number = '16.0.73-SNAPSHOT', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'cockpit' AND is_soft_deleted = false;
-- kundenportal: unchanged (no-op if already set); after the new web image is live
UPDATE ui_configs SET version_number = '0.1.0', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'kundenportal' AND is_soft_deleted = false;
-- stella: unchanged (no-op if already set). run only AFTER the build is live in App Store + Play Store; a higher major/minor locks users onto the /update page; a patch-only raise does nothing
UPDATE ui_configs SET version_number = '1.33.0', updated_at = now(), updated_by_name = 'release', updated_by_type = 'system' WHERE ui_type = 'stella' AND is_soft_deleted = false;
```

Note: `detailed_merge_status` stays `checking` for a while after bulk creation and `has_conflicts:false` is NOT authoritative while checking — report mergeability as un-computed rather than clean.

The report's last line is always the group-wide list of open MRs for this direction:

```bash
echo "Open $TITLE MRs: https://gitlab.com/groups/lipso/clients/brokernet/-/merge_requests/?sort=created_date&state=opened&label_name%5B%5D=${LABEL}&first_page_size=100"
```

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
- **Forgetting the patch-version bump** → the nine repos in the bump table (six UIs + stella-web + document-cms + varias-sign) need the patch bump committed on the source branch BEFORE the MR; backends don't. Missing it on document-cms / varias-sign does not fail the MR — it fails the **target** pipeline with `<stage> with tag <version> already exists!` and silently skips deploy.
- **Bumping the spring-boot parent in `brokernet-varias-sign/pom.xml`** → the first `<version>` in the file is the parent; the project version is the first one after `</parent>`.
- **Bumping the go-stella app in `bpp-stella-ui`** → the app version lives in 16 files across Gradle / Xcode / npm / Angular envs, not one `package.json`. Never bump `bpp-stella-app` or `bpp-stella-common` here; the app has its own skill ([stella-bump-version-staging-mr](https://gitlab.com/lipso/internal/agentic-coding-knowledge/-/blob/main/personal-workflows/nangert/skills/stella-bump-version-staging-mr/SKILL.md)). Only `projects/bpp-stella-web/package.json` and its lock entry are bumped.
- **Forgetting the `bpp-stella-web` lock entry, or bumping it with `npm version -w`** → either the lock and package.json disagree, or ~90 unrelated lock lines change. Use the anchored `sed`; exactly two lines may differ.
- **Promoting a version change without handing over the `ui_configs` SQL** → the stage DB keeps the old version and the forced reset never fires for that release (cockpit, kundenportal). Always print all three stage DBs × all three `ui_type`s with their markers, also when this run bumped nothing.
- **Taking the `stella` value from package.json, or printing it without the store warning** → the app compares `environment.appVersion`, and a premature major/minor raise locks every user onto `/update` with nothing to install. On a package.json/appVersion mismatch, print both values and no statement.
- **Double-bumping on re-run** → always apply the idempotency guard (source vs target version differ = already bumped).
- **Missing servo-ui / callidus-bvs-ui** → both live in subgroups; a group listing without `include_subgroups=true` never returns them (verified 2026-09-14: 57 projects, zero of them). They reach this skill as ordinary `bpp-project-index` manifest rows with subgroup-encoded `enc` values — never rebuild an encoded path from the repo name.
- **Rebuilding the repo set here instead of reading the manifest** → the filter+extras provably drift from `bpp/repos.md` in both directions (2026-08-14: six repos missed, e.g. `brokernet-app`, `servo-hw-connector`; 2026-09-14: `bpp-cypress` and `bpp-db-migrator` in the group but not in the list). `bpp-project-index` does the union on every refresh — read it. If the manifest is stale or `#source` says `gitlab=unreachable`, flag it in the preview instead of silently proceeding.

## Red flags — STOP

- About to call POST `/merge_requests` before showing preview → STOP, show preview first.
- Compare API errored on a repo whose branches both exist → do NOT silently skip; abort with error.
- About to label a staging→main MR `staging-deployment` (or vice versa) → STOP, check the direction table.
- Considering creating an MR for a repo the manifest filter did not return → STOP, exclude it. Fix the classification in `bpp/repos.md` via `bpp-project-index`, never by special-casing a repo here.
