---
name: bpp-project-index
description: Use when user mentions any BPP project (bpp-backend, bpp-auth, bpp-shared, bpp-stella, bpp-chat, bpp-file, bpp-push, bpp-mail, bpp-document-analysis, bpp-vera-connector, bpp-js-report-connector), a frontend (brokernet-cockpit-ui, bpp-stella-ui / go-stella, formerly brokernet-app), or legacy Brokernet (old-brokernet, brokernet-backend, backend-* modules like backend-claim/customer/servo/polizzierung), asks for the path/location of a BPP/Brokernet repo or module on this machine, or asks to refresh/audit the index — "refresh project index", "is the index complete", "which repos are not checked out locally", "missing local checkouts", "clone the missing repos". Also the fleet locator every other bpp-* skill routes its repo discovery through — it owns the GitLab group listing, the `bpp/repos.md` cross-check, the always-exclude list and the local-checkout map, and publishes them as `~/.claude/bpp-fleet/manifest.tsv`.
---

# BPP / Brokernet fleet index

## Overview

**Single source of truth for "which repos exist and where do I find them."** Three inputs, one output:

| Input | Question it answers | Authority |
|---|---|---|
| GitLab group `lipso/clients/brokernet/` (incl. subgroups) | what exists *right now* | live truth, but includes infra/ops repos nobody sweeps |
| `bpp/repos.md` in `lipso/internal/agentic-coding-knowledge` | what belongs to the **BPP fleet**, and in which class | human-curated; lags reality |
| local checkouts under `~/Entwicklung/bpp/` and `~/Entwicklung/brokernet/` | where it is **on this machine** | filesystem, keyed on the `origin` URL |

Output: **`~/.claude/bpp-fleet/manifest.tsv`** — one row per repo, consumed by every other `bpp-*` skill
instead of each re-deriving the fleet. Plus the human-readable
`/home/alex/Entwicklung/bpp/bpp-backend/dev/apittrich/project_index.md`, which keeps the prose
descriptions and the legacy Brokernet Java modules that exist in no GitLab listing.

Neither of the first two inputs is sufficient alone and the drift runs **both** ways — measured
2026-09-14 on a live listing: 12 repos in the group that `repos.md` does not name (incl. the active
`bpp-cypress`, `bpp-db-migrator`), and historically 5–6 in `repos.md` that a group filter misses
(`servo-hw-connector`, `docling-sidecar`, …). **Always the union.**

## Side effects — read this before invoking

| Mode | Network | Writes `manifest.tsv` | Writes `project_index.md` | Commits `repos.md` | Clones |
|---|---|---|---|---|---|
| **lookup** (default, and what other skills get) | none | no | no | no | no |
| **refresh** (default when invoked for a sweep, or "refresh the index") | read-only `glab` | yes | only if its content changed | **no** — drift is *reported* | no |
| `--write` | + one API commit | yes | if changed | yes, after preview + "go" | no |
| `--clone` | + `git clone` | yes | if changed | no | yes, after preview + "go" |

**Nothing is written to GitLab and nothing is cloned unless the user explicitly asks.** A refresh is
read-only by construction; it *reports* what a `--write` or `--clone` would do. Both flags still show a
preview and wait for confirmation — the flag says "I intend to", not "do it silently".

Rationale for that split:

- **Cloning is the expensive, irreversible-ish side effect.** Today 3 fleet repos have no checkout
  (`bpp-partner-api-guide`, `brokernet-document-cms`, `docling-sidecar`) — but on a fresh machine this
  is 35+ clones and several GB, and the user may deliberately not want the legacy/infra repos on disk.
  Silent cloning from a *path lookup* would be indefensible. Hence: never implicit, preview always,
  and `MAX_CLONE=10` per run unless the user says otherwise.
- **`repos.md` lives in a repo shared with other humans** (nangert's `personal-workflows/` is in the
  same tree) and is being restructured. A sweep skill's job is not to curate someone else's inventory,
  so a delegated refresh never commits. The user's own invocation may.

## Invocation

```
/bpp-project-index                  # refresh + report (read-only)
/bpp-project-index bpp-file         # lookup only — no network at all
/bpp-project-index --write          # + commit the missing rows to bpp/repos.md (preview first)
/bpp-project-index --clone          # + clone fleet repos with no local checkout (preview first)
/bpp-project-index --cached         # skip the refresh, use the manifest as-is (offline)
```

## Lookup (the common case)

1. Read `~/.claude/bpp-fleet/manifest.tsv` → `local_path` column is the answer. It is authoritative for
   the *path*, because it is keyed on the `origin` URL, not the folder name.
2. For purpose / architecture / legacy Java modules (`backend-claim`, `backend-servo`, …), read
   `/home/alex/Entwicklung/bpp/bpp-backend/dev/apittrich/project_index.md`.
3. `local_path` is `-` → the repo exists but is not checked out. Say so; offer `--clone`. **Never guess
   a path.**
4. Name in neither → say so, offer a refresh; it may simply be newer than the last one.

**Lookup makes no network calls.** If the manifest is missing, run a refresh once, then look up.

## The manifest — contract for other skills

`~/.claude/bpp-fleet/manifest.tsv`. Comment lines start with `#`; consumers use `grep -v '^#'` or
`awk -F'\t' '!/^#/'`. Tab-separated, 8 columns:

| # | Column | Values |
|---|---|---|
| 1 | `name` | bare repo name — the key every skill already uses |
| 2 | `path_with_namespace` | `lipso/clients/brokernet/servo/servo-ui` |
| 3 | `enc` | URL-encoded path for `glab api /projects/<enc>/…` — **subgroup-safe** |
| 4 | `class` | `backend` \| `frontend` \| `docs` \| `infra` \| `unlisted` (in GitLab, not yet in `repos.md`) |
| 5 | `tags` | `-`, or comma-separated fleet policy tags (below) |
| 6 | `state` | `active` \| `archived` \| `gone` |
| 7 | `local_path` | absolute checkout path, or `-` |
| 8 | `default_branch` | e.g. `development`, `main`, `-` |

Header lines carry provenance: `#generated <iso8601>`, `#source gitlab=ok|unreachable reposmd=ok|unreachable`,
and `#extra <name> <path>` for *additional* checkouts of a repo that already has a canonical one.

### Policy tags (fleet decisions, owned by this skill)

| Tag | Repo | Why |
|---|---|---|
| `internal-temp` | `bpp-cca-connector-internal` | temporary internal repo, slated for removal/merge — excluded from every automated sweep. **Exact-name**: `bpp-cca-connector` is a separate, real repo and stays in. |
| `generated-output` | `bpp-audit-reports` | generated output of `bpp-daily-audit` (reports, escalations, ledger). Single `main` branch, no product code — never promoted, and auditing it is a self-audit loop. |
| `scaffold` | `bpp-shared-template` | template projects, no product code. Excluded by the audit; the promotion sweep keeps it and reports "no staging branch". |
| `shared-source` | `bpp-shared` | the source of `BPP.Shared.NET`, not a consumer of it. |
| `excluded-manual` | `servo-backend` | excluded from every automated sweep by user decision 2026-09-18. Its `development`→`staging` diff is 2024 legacy (dev idle since 2024-12-11, staging since 2024-05-24) and its build job fails on a pre-existing CI defect — `invalid tag "…/servo-backend/:4.0.0": invalid reference format`, an unset image-name variable. A promotion sweep re-opened MR !2 from it; that MR was closed. Re-including it means fixing the repo's CI first. `servo-ui` and `servo-hw-connector` are NOT excluded. |

A tag is a *label*, not a filter. Each consumer excludes the tags that matter to it — the sets differ,
and flattening them into one boolean would silently change three skills' behaviour.

### Consumer filters (verified 2026-09-14 to reproduce each skill's current repo set exactly)

| Skill | Filter | Set size |
|---|---|---|
| `bpp-promote-dev-to-staging` | `state=active`, tags ∌ `internal-temp,generated-output,excluded-manual`, and `class ∈ {backend,frontend,docs}` **or** (`class=unlisted` and name matches `^bpp-|^brokernet-.*-ui$`) | 37 (re-measured 2026-09-18; was 38 before `servo-backend` was excluded — the old "35" dates from 2026-09-14 and the fleet has grown since) |
| `bpp-daily-audit` | same, plus tags ∌ `scaffold` | 37 — same as promote, not a typo: the only `scaffold` repo (`bpp-shared-template`) is `class=infra` and is already dropped by the class filter |
| `bpp-bump-shared-version` | `state=active`, name matches `^bpp-`, tags ∌ `shared-source,internal-temp` | 24 |

```bash
MANIFEST=~/.claude/bpp-fleet/manifest.tsv
# promote / audit candidate set → name TAB enc
awk -F'\t' '!/^#/ && $6=="active" && $5!~/internal-temp|generated-output|excluded-manual/ \
  && ($4=="backend" || $4=="frontend" || $4=="docs" || ($4=="unlisted" && $1 ~ /^bpp-|^brokernet-.*-ui$/)) \
  {print $1 "\t" $3}' "$MANIFEST"
```

The `class=unlisted and name matches …` clause is not decoration: it is what keeps `bpp-cypress` and
`bpp-db-migrator` in the sweeps while `repos.md` still omits them. Dropping it un-sweeps active repos.

## Workflow — refresh

Requires `glab` (authenticated: `glab auth status`) + `jq`. One pass, ~7 s.

### 1–4. Build the manifest

```bash
MANIFEST_DIR=~/.claude/bpp-fleet; MANIFEST="$MANIFEST_DIR/manifest.tsv"; mkdir -p "$MANIFEST_DIR"
WORK=$(mktemp -d)
GROUP=lipso%2Fclients%2Fbrokernet
KNOW=lipso%2Finternal%2Fagentic-coding-knowledge

# 1. GitLab listing — include_subgroups is mandatory, archived=false is mandatory
GITLAB_STATE=ok
glab api "/groups/${GROUP}/projects?include_subgroups=true&archived=false&per_page=100&simple=true" --paginate 2>/dev/null \
  | jq -r '.[] | [.path, .path_with_namespace, (.default_branch // "-")] | @tsv' \
  | LC_ALL=C sort -u > "$WORK/gitlab.tsv"
[ -s "$WORK/gitlab.tsv" ] || GITLAB_STATE=unreachable

# 2. repos.md — class comes from the section heading it sits under
REPOSMD_STATE=ok
glab api "projects/${KNOW}/repository/files/bpp%2Frepos.md/raw?ref=main" > "$WORK/repos.md" 2>/dev/null
awk '
  /^##[ ]/ { sect = substr($0, 4); next }
  /^\|[^|]+\| *https:\/\/gitlab\.com\// {
    split($0, f, "|"); name = f[2]; link = f[3]
    gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", link)
    sub(/^https:\/\/gitlab\.com\//, "", link)
    cls = "other"
    if (sect ~ /^Backend/)       cls = "backend"
    else if (sect ~ /^Frontend/) cls = "frontend"
    else if (sect ~ /^Dokument/) cls = "docs"
    else if (sect ~ /^Infra/)    cls = "infra"
    print name "\t" link "\t" cls
  }' "$WORK/repos.md" | LC_ALL=C sort -u > "$WORK/reposmd.tsv"
[ -s "$WORK/reposmd.tsv" ] || REPOSMD_STATE=unreachable

# 3. Local checkouts — keyed on the ORIGIN URL, never on the folder name
: > "$WORK/local.tsv"
for d in "$HOME"/Entwicklung/bpp/*/ "$HOME"/Entwicklung/brokernet/*/; do
  n=$(basename "$d"); case "$n" in *.worktrees) continue;; esac
  [ -e "$d/.git" ] || continue
  u=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
  [ -n "$u" ] || continue
  p=$(printf '%s' "$u" | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^ssh://[^@]*@?[^/]+/##; s#^https?://([^@/]+@)?[^/]+/##')
  printf '%s\t%s\t%s\n' "$p" "${d%/}" "$n" >> "$WORK/local.tsv"
done
LC_ALL=C sort -o "$WORK/local.tsv" "$WORK/local.tsv"

# 4. Union, keyed on path_with_namespace
{ cut -f2 "$WORK/gitlab.tsv"; cut -f2 "$WORK/reposmd.tsv"; cut -f1 "$WORK/local.tsv"; } \
  | LC_ALL=C sort -u > "$WORK/union.txt"

policy_tags() {
  case "$1" in
    bpp-cca-connector-internal) echo internal-temp ;;
    servo-backend)              echo excluded-manual ;;
    bpp-audit-reports)          echo generated-output ;;
    bpp-shared-template)        echo scaffold ;;
    bpp-shared)                 echo shared-source ;;
    *)                          echo - ;;
  esac
}

: > "$WORK/manifest.body"; : > "$WORK/extra.txt"
while read -r pathns; do
  name=${pathns##*/}
  enc=$(printf %s "$pathns" | sed 's#/#%2F#g')

  gl=$(awk -F'\t' -v p="$pathns" '$2==p {print $3; exit}' "$WORK/gitlab.tsv")
  if [ -n "$gl" ]; then
    state=active; defbr="$gl"
  else                      # not in the live listing → archived, or gone. Probe, never assume.
    meta=$(glab api "/projects/${enc}" 2>/dev/null \
      | jq -r 'if .id then ((if .archived then "archived" else "active" end) + "\t" + (.default_branch // "-")) else empty end')
    if [ -n "$meta" ]; then state=${meta%%$'\t'*}; defbr=${meta##*$'\t'}
    else state=gone; defbr="-"; fi
  fi

  cls=$(awk -F'\t' -v p="$pathns" '$2==p {print $3; exit}' "$WORK/reposmd.tsv"); [ -n "$cls" ] || cls=unlisted

  # canonical checkout: prefer the folder whose basename == repo name; others become #extra
  lp=$(awk -F'\t' -v p="$pathns" -v n="$name" '$1==p && $3==n {print $2; exit}' "$WORK/local.tsv")
  [ -n "$lp" ] || lp=$(awk -F'\t' -v p="$pathns" '$1==p {print $2; exit}' "$WORK/local.tsv")
  [ -n "$lp" ] || lp="-"
  awk -F'\t' -v p="$pathns" -v c="$lp" -v n="$name" '$1==p && $2!=c {print "#extra\t" n "\t" $2}' \
    "$WORK/local.tsv" >> "$WORK/extra.txt"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$pathns" "$enc" "$cls" "$(policy_tags "$name")" "$state" "$lp" "$defbr" >> "$WORK/manifest.body"
done < "$WORK/union.txt"

dupes=$(cut -f1 "$WORK/manifest.body" | LC_ALL=C sort | uniq -d)
[ -n "$dupes" ] && echo "WARN — name collision across subgroups, consumers key on name: $dupes" >&2

# Never overwrite a good manifest with a degraded one.
if [ "$GITLAB_STATE" = unreachable ] && [ -s "$MANIFEST" ]; then
  echo "DEGRADED — GitLab unreachable; keeping the existing manifest ($(grep -m1 '^#generated' "$MANIFEST"))" >&2
else
  { echo "#generated $(date -Iseconds)"
    echo "#source gitlab=$GITLAB_STATE reposmd=$REPOSMD_STATE"
    cat "$WORK/extra.txt"
    printf '#name\tpath_with_namespace\tenc\tclass\ttags\tstate\tlocal_path\tdefault_branch\n'
    LC_ALL=C sort "$WORK/manifest.body"
  } > "$MANIFEST"
fi
```

### 5. Report the four deltas (always, even on a plain refresh)

```bash
# a) in GitLab, missing from repos.md  → candidates for --write
awk -F'\t' '!/^#/ && $4=="unlisted" && $6=="active" {print "  " $1 "\t" $2 "\t(" $8 ")"}' "$MANIFEST"
# b) fleet repo with no local checkout → candidates for --clone
awk -F'\t' '!/^#/ && $7=="-" && $6=="active" && $4!~/^(infra|unlisted)$/ {print "  " $1}' "$MANIFEST"
# c) checked out locally but archived/gone in GitLab
awk -F'\t' '!/^#/ && $7!="-" && $6!="active" {print "  " $1 "\t" $6 "\t" $7}' "$MANIFEST"
# d) extra checkouts of the same repo
grep '^#extra' "$MANIFEST"
```

(c) is **informational only.** An archived repo is intact and still readable — never delete a checkout,
never remove a `repos.md` row on the strength of it. `gone` (a 404) is the one that deserves a loud line:
renamed, moved namespace, or deleted. Check before acting.

### 6. `project_index.md` — rewrite only when the content changed

The index file is tracked in `bpp-backend`, so an unconditional rewrite leaves that repo dirty on every
invocation. Generate the section, compare, write only on a difference, and report the dirty file.

```bash
INDEX=/home/alex/Entwicklung/bpp/bpp-backend/dev/apittrich/project_index.md
{
  echo '<!-- BEGIN AUTO:GITLAB-ONLY — generated by bpp-project-index refresh; do not edit by hand -->'
  echo "## GitLab-only (not checked out locally) — auto-generated, refreshed $(date +%Y-%m-%d)"
  echo
  echo 'Repos in GitLab with no local checkout. Clone target: `bpp-*` → `~/Entwicklung/bpp/{name}`, else `~/Entwicklung/brokernet/{name}`.'
  echo
  echo '| Repo | GitLab path | Class | Default branch |'
  echo '|---|---|---|---|'
  awk -F'\t' '!/^#/ && $7=="-" && $6=="active" {printf "| %s | `%s` | %s | %s |\n", $1, $2, $4, $8}' "$MANIFEST"
  echo '<!-- END AUTO:GITLAB-ONLY -->'
} > "$WORK/section.md"

awk '/BEGIN AUTO:GITLAB-ONLY/{s=1} s{print} /END AUTO:GITLAB-ONLY/{s=0}' "$INDEX" > "$WORK/section.old"
if ! diff -q <(grep -v 'refreshed 20' "$WORK/section.old") <(grep -v 'refreshed 20' "$WORK/section.md") >/dev/null; then
  awk -v section="$WORK/section.md" '
    /BEGIN AUTO:GITLAB-ONLY/ { while ((getline line < section) > 0) print line; skip=1; next }
    /END AUTO:GITLAB-ONLY/   { skip=0; next }
    !skip
  ' "$INDEX" > "$WORK/index.new" && mv "$WORK/index.new" "$INDEX"
  echo "project_index.md updated — bpp-backend now has an uncommitted change; the user decides when to commit."
fi
```

The `refreshed <date>` line is stripped from the comparison on purpose — otherwise the date alone would
dirty the file daily. The **hand-written tables are user-maintained: source of truth, never edited by
this skill.** It owns only the `AUTO:GITLAB-ONLY` block.

## `--write`: adding missing repos to `bpp/repos.md`

**Direct commit on `main` via the GitLab commits API. Never through the local checkout.**

Why this shape:

- **Why not the local checkout** — `~/Entwicklung/lipso/agentic-coding-knowledge` is a user working tree
  that carries unrelated dirty files (`bpp-daily-audit` documents exactly this), and other agents work in
  it. A commit there would sweep up someone else's changes. This is the same reasoning
  `bpp-bump-shared-version` uses for its API-commit path.
- **Why not a branch + MR** — the established pattern for a mechanical single-file change in this fleet
  is a direct commit (`bpp-bump-shared-version` commits `Directory.Build.props` straight onto
  `development` across 20+ repos; `bpp-promote-dev-to-staging` commits the `package.json` bump straight
  onto the source branch). MRs are reserved for product-code promotion. An MR per discovered repo would
  be a review queue for a list nobody reviews.
- **Access is real**: verified 2026-09-14 — the user holds group access level 40 on
  `lipso/internal/agentic-coding-knowledge` and `main` allows push at level 40.

Rules:

1. **Append only.** Add rows to the table matching the repo's proposed class. **Never rewrite, reorder or
   delete an existing row** — that table is human curation. A repo that vanished from GitLab is
   *reported*, never removed.
2. **Propose the class, let the user confirm it.** Heuristic for the preview: name ends `-ui` → Frontend;
   default branch `development` → Backend; `main`-only with no product code → Infrastruktur. It is a
   proposal, and the preview says so.
3. **Optimistic lock.** Read `last_commit_id` for the file and pass it on the update action; if the commit
   is rejected, re-fetch and retry **once**, then report. Verified against the GitLab Commits API docs:
   `last_commit_id` is honoured on `update` actions.

```bash
FILE=bpp/repos.md
meta=$(glab api "projects/${KNOW}/repository/files/bpp%2Frepos.md?ref=main")
last=$(echo "$meta" | jq -r '.last_commit_id')
echo "$meta" | jq -r '.content' | base64 -d > "$WORK/repos.current.md"

#   … build "$WORK/repos.new.md" by inserting the confirmed rows into the right tables …
new_names=$(printf '%s, ' "${CONFIRMED[@]}"); new_names=${new_names%, }
#   Sanity gate: the new file must be LONGER and must still contain every existing row.
old_rows=$(grep -cE '^\|[^|]+\| *https://gitlab\.com/' "$WORK/repos.current.md")
new_rows=$(grep -cE '^\|[^|]+\| *https://gitlab\.com/' "$WORK/repos.new.md")
[ "$new_rows" -gt "$old_rows" ] || { echo "FAIL — new repos.md does not add rows; refusing to commit" >&2; exit 1; }
comm -23 <(grep -E '^\|' "$WORK/repos.current.md" | LC_ALL=C sort) \
         <(grep -E '^\|' "$WORK/repos.new.md"     | LC_ALL=C sort) | grep . \
  && { echo "FAIL — a pre-existing row would be lost; refusing to commit" >&2; exit 1; }

jq -n --arg msg "docs(repos): add $new_names discovered by bpp-project-index" \
      --arg path "$FILE" --arg content "$(cat "$WORK/repos.new.md")" --arg last "$last" \
  '{branch:"main", commit_message:$msg,
    actions:[{action:"update", file_path:$path, content:$content, last_commit_id:$last}]}' \
  | glab api --method POST "/projects/${KNOW}/repository/commits" -H 'Content-Type: application/json' --input -
```

## `--clone`: checking out what is missing

Target root: `bpp-*` → `~/Entwicklung/bpp/{name}`, everything else → `~/Entwicklung/brokernet/{name}`.
That is a *default*, not an assertion — `bpp-document-analysis-dashboard` legitimately lives under
`brokernet/`, and because the local scan is keyed on the `origin` URL it is found there and never
re-cloned.

```bash
MAX_CLONE=${MAX_CLONE:-10}
awk -F'\t' '!/^#/ && $7=="-" && $6=="active" && $4!~/^(infra|unlisted)$/ {print $1 "\t" $2}' "$MANIFEST" \
  | head -n "$MAX_CLONE" \
  | while IFS=$'\t' read -r name pathns; do
      case "$name" in bpp-*) root=~/Entwicklung/bpp ;; *) root=~/Entwicklung/brokernet ;; esac
      [ -e "$root/$name/.git" ] && { echo "SKIP $name — already there"; continue; }
      git clone "https://gitlab.com/${pathns}.git" "$root/$name" && echo "CLONED $name → $root/$name"
    done
```

- **Preview the list and the count first.** Wait for "go".
- `class=unlisted` and `class=infra` are **not** cloned: an unclassified repo may be CI infra, a
  WordPress site or a discontinued backend. Get it into `repos.md` first (`--write`), then clone.
- A failed clone is reported and the loop continues; it never aborts the run.

## Degraded operation

| Failure | Behaviour |
|---|---|
| `glab` unauthenticated / GitLab unreachable | Keep the existing manifest, stamp the report `DEGRADED`, state the manifest's age. **Never** overwrite a good manifest with an empty one, never write `repos.md`, never clone. |
| `repos.md` unreachable or parses to 0 rows | Continue with `gitlab` + local; every row lands as `class=unlisted`. Say **loudly** "class data unavailable — repos.md unreachable" so a consumer's class filter is not silently trusted. Never write `repos.md`. |
| No manifest at all and GitLab down | Fall back to `project_index.md` for lookups and say the fleet data is stale. |

A consumer that finds a manifest older than 24 h must refresh it or say its age in the run report. A
stale manifest is usable for a *lookup*; for a **write** sweep (promotion MRs, a version bump) it must be
refreshed first or the run reports that it was not.

## Common mistakes

- **Matching local checkouts on the folder name** → two live counter-examples on this machine:
  `~/Entwicklung/brokernet/brokernet-app` is the checkout of **`bpp-stella-ui`** (renamed 2026-09-01),
  and `~/Entwicklung/brokernet/scan-backend` is **`brokernet-file-scanner`**. Name-matching reports both
  repos as "not cloned" and `--clone` then creates a **duplicate second checkout**. Key on
  `git remote get-url origin`, always.
- **Dropping `include_subgroups=true`** → verified 2026-09-14: the group listing returns 57 projects and
  **zero** of `servo-ui`, `servo-hw-connector`, `servo-backend`, `callidus-bvs-ui`, `wordpress-website`.
  They are invisible, not absent.
- **Deriving the encoded path as `lipso%2Fclients%2Fbrokernet%2F${repo}`** → wrong for every subgroup
  repo. Always use the manifest's `enc` column (derived from `path_with_namespace`).
- **Dropping `archived=false`** → 17 archived projects reappear, including three whose checkouts are
  still on this machine (`brokernet-backend`, `brokernet-vera-connector`, `brokernet-epz-connector`).
  They would be swept, promoted and audited.
- **Treating "not in the group listing" as "deleted"** → it almost always means *archived*. Probe
  `/projects/<enc>` and record `archived` vs `gone`; never delete a checkout or a `repos.md` row on a
  listing miss.
- **Using `repos.md` alone as the repo set** → it omitted `bpp-arag-connector` and
  `bpp-external-mail-connector` on 2026-09-09 while both were among the most active repos in the fleet,
  and today omits `bpp-cypress` and `bpp-db-migrator`. Union, always.
- **Using the group listing alone** → it misses nothing today, but historically missed 5–6 `repos.md`
  entries via the old name filter. The union is what makes both drifts visible instead of silent.
- **Flattening the policy tags into one "exclude" boolean** → the three consumers genuinely exclude
  different sets (`scaffold` is excluded by the audit and *not* by the promotion sweep). One boolean
  silently changes behaviour in at least one skill.
- **Rewriting `project_index.md` unconditionally** → leaves `bpp-backend` permanently dirty, which then
  trips `bpp-pull-all-dev`'s overlap pre-check. Diff first, write only on a real change.
- **Committing `repos.md` through the local knowledge-repo checkout** → it carries unrelated dirty files
  and other agents work in it. API commit on `main` only.
- **Deleting a `repos.md` row because a repo is archived or missing** → append-only. Report it; removal
  is a human decision.
- **`jq 'select(.path | test(...) and .path != "x")'`** → inside `select(.path | …)` the pipe rebinds `.`
  to the string, so the second `.path` fails with `Cannot index string with string "path"` and the whole
  listing aborts (a real bug in `bpp-promote-dev-to-staging`, 2026-09-08). Each field access needs its
  own parenthesised pipe. This skill sidesteps it by filtering in `awk` over the manifest, not in `jq`.
- **`jq '.commits | length'` to detect a missing branch** → `null | length` is `0` in jq, so a missing
  branch reads as "no diffs". Not this skill's job — but every consumer that probes branches must probe
  explicitly first. The manifest's `default_branch` is not a promise that `staging` exists.
- **Letting a lookup trigger network calls** → lookups must stay instant and offline-safe.

## Red flags — STOP

- About to `git clone` without having shown the list and received "go" → STOP. Preview first.
- About to clone a `class=unlisted` or `class=infra` repo → STOP. Classify it in `repos.md` first.
- About to POST a commit to `repos.md` that removes or rewrites an existing row → STOP. Append only.
- About to write `repos.md` from a delegated refresh (a sweep skill invoked this) → STOP. Only the
  user's own `--write` commits.
- About to overwrite `manifest.tsv` when the GitLab listing came back empty → STOP. That is a degraded
  run; keep the last good manifest.
- About to touch `~/Entwicklung/lipso/agentic-coding-knowledge` with a git command → STOP. Read via
  `glab api`, write via the commits API.
- About to delete a local checkout because the repo is archived or `gone` → STOP. Report only.
- About to edit the hand-written tables in `project_index.md` → STOP. Only the `AUTO:GITLAB-ONLY` block
  belongs to this skill.
