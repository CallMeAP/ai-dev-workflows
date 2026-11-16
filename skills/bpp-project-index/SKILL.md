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
| local checkouts under `~/Entwicklung/bpp/` (single dev root since 2026-11-15; the former `~/Entwicklung/brokernet/` was merged into it) | where it is **on this machine** | filesystem, keyed on the `origin` URL |

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
`#extra <name> <path>` for *additional* checkouts of a repo that already has a canonical one, and
`#renamed <old> <new> <repos.md | checkout path>` for an old path that is still referenced after a rename.

### Policy tags (fleet decisions, owned by this skill)

| Tag | Repo | Why |
|---|---|---|
| `generated-output` | `bpp-audit-reports` | generated output of `bpp-daily-audit` (reports, escalations, ledger). Single `main` branch, no product code — never promoted, and auditing it is a self-audit loop. |
| `guides-store` | `bpp-endpoint-migration-guides` | endpoint migration guides of all backend repos, one folder per repo. Single `main` branch, no product code — never promoted, never audited; `bpp-migration-guide-audit` reads it directly. |
| `scaffold` | `bpp-shared-template` | template projects, no product code. Excluded by the audit; the promotion sweep keeps it and reports "no staging branch". |
| `shared-source` | `bpp-shared` | the source of `BPP.Shared.NET`, not a consumer of it. |
| `excluded-manual` | `servo-backend` | excluded from every automated sweep by user decision 2026-09-18. Its `development`→`staging` diff is 2024 legacy (dev idle since 2024-12-11, staging since 2024-05-24) and its build job fails on a pre-existing CI defect — `invalid tag "…/servo-backend/:4.0.0": invalid reference format`, an unset image-name variable. Re-including it means fixing the repo's CI first. `servo-ui` and `servo-hw-connector` are NOT excluded. |

A tag is a *label*, not a filter. Each consumer excludes the tags that matter to it — the sets differ,
and flattening them into one boolean would silently change three skills' behaviour.

### Consumer filters

| Skill | Filter | Set size |
|---|---|---|
| `bpp-promote-dev-to-staging` | `state=active`, tags ∌ `generated-output,excluded-manual,guides-store`, and `class ∈ {backend,frontend,docs}` **or** (`class=unlisted` and name matches `^bpp-|^brokernet-.*-ui$`) | 37 (measured 2026-09-18) |
| `bpp-daily-audit` | same, plus tags ∌ `scaffold` | 37 — same as promote, not a typo: the only `scaffold` repo (`bpp-shared-template`) is `class=infra` and is already dropped by the class filter |
| `bpp-bump-shared-version` | `state=active`, name matches `^bpp-`, tags ∌ `shared-source` | 24 |

Each set is implemented in `refresh.sh` (offline, prints `name TAB enc`):

```bash
bash ~/.claude/skills/bpp-project-index/refresh.sh candidates promote   # or: audit | bump
```

Columns by number for consumers that filter themselves: name=1, path_with_namespace=2, enc=3, class=4,
tags=5, state=6, local_path=7, default_branch=8. Copy the awk from `do_candidates` in `refresh.sh`, not
from memory.

The `class=unlisted and name matches …` clause is not decoration: it is what keeps `bpp-cypress` and
`bpp-db-migrator` in the sweeps while `repos.md` still omits them. Dropping it un-sweeps active repos.

## Workflow — refresh

Requires `glab` (authenticated: `glab auth status`) + `jq`. One pass, ~7 s.

The code ships as `refresh.sh` beside this file. It is not inlined: Claude Code substitutes positional
placeholders (dollar sign + digit) in skill text when the skill is invoked with arguments; on 2026-11-16
that turned every awk field reference into the word `refresh` and broke the run. Keep dollar-digit
sequences out of this file. Run it by path:

| Command | Does |
|---|---|
| `bash ~/.claude/skills/bpp-project-index/refresh.sh` | refresh, then index (the default) |
| `… refresh.sh refresh` | steps 1–5: rebuild the manifest, print the deltas |
| `… refresh.sh report` | step 5 only, from the existing manifest — offline |
| `… refresh.sh index` | step 6 only |
| `… refresh.sh candidates promote\|audit\|bump` | consumer filter sets |
| `… refresh.sh reposmd-diff` | `--write` preview |
| `… refresh.sh clone-preview` / `clone <name>…` | `--clone` preview / clone after "go" |
| `source …/refresh.sh` | helpers only (`do_refresh`, `do_report`, `policy_tags`, …); stops before reading a mode |

### 1–4. Build the manifest (`refresh`)

1. **GitLab listing** of `lipso/clients/brokernet` — `include_subgroups=true` and `archived=false` are
   both mandatory. An empty listing marks the run `gitlab=unreachable`.
2. **`repos.md`** via `glab api …/repository/files/bpp%2Frepos.md/raw?ref=main`; a row's class comes from
   the section heading it sits under (`Backend…` / `Frontend…` / `Dokument…` / `Infra…`).
3. **Local checkouts** under `~/Entwicklung/bpp/*/` (skipping `*.worktrees`), keyed on the `origin` URL
   reduced to `path_with_namespace` — never on the folder name.
4. **Union** of the three, keyed on `path_with_namespace`, minus the `EOL` list at the top of
   `refresh.sh` (archived for good; add a repo there only on the user's word). Every path *not* in the live
   listing is probed with `/projects/<enc>`: `archived`, `active`, or `gone` (404) — never assumed.
   **Renames:** when the probe answers with a *different* `path_with_namespace`, the old path is folded
   onto the new one — in the union, in the `repos.md` class table (the new row inherits the old row's
   class) and in the checkout map. The new row gets the new project's `state` and default branch; the old
   row is dropped, so no duplicate names and no stale row. Each old path that is still referenced is
   recorded as a comment line `#renamed <old> <new> <repos.md | checkout path>` (comment lines are
   ignored by consumers; the 8-column contract is unchanged).
   Canonical checkout = the folder whose basename equals the repo name; any other becomes `#extra`.
   A name collision across subgroups prints a `WARN`.
   **Never overwrites a good manifest** when the listing was unreachable, nor with a 0-row body.

### 5. Report the deltas (always, even on a plain refresh; `report` reprints them offline)

- **a)** in GitLab, missing from `repos.md` (`class=unlisted`, active) → candidates for `--write`
- **b)** fleet repo with no local checkout (active, class not `infra`/`unlisted`) → candidates for `--clone`
- **c)** checked out locally but archived/gone in GitLab
- **d)** extra checkouts of the same repo (`#extra`)
- **e)** renames: `renamed <old> -> <new>`, with the fix — a `repos.md` row on the old path needs a
  hand edit (`--write` is append-only), a checkout whose origin uses the old path gets the hint
  `git remote set-url origin <new url>`. Report these **loudly**; a rename is the most likely reason a
  repo shows up `unlisted`.

(c) is **informational only.** An archived repo is intact and still readable — never delete a checkout,
never remove a `repos.md` row on the strength of it. `gone` (a 404) is the one that deserves a loud line:
moved out of reach or deleted (a rename shows up in (e) instead). Check before acting.

### 6. `project_index.md` — rewrite only when the content changed (`index`)

The index file is tracked in `bpp-backend`, so an unconditional rewrite leaves that repo dirty on every
invocation. `index` generates the `AUTO:GITLAB-ONLY` section (active repos with no checkout), compares it
with the current block, writes only on a difference, and says when it left `bpp-backend` dirty.

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

Preview first with `bash ~/.claude/skills/bpp-project-index/refresh.sh reposmd-diff`. After "go":

```bash
KNOW=lipso%2Finternal%2Fagentic-coding-knowledge; WORK=$(mktemp -d)
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

Target root: `~/Entwicklung/bpp/{name}` for every repo (single dev root since 2026-11-15).
That is a *default*, not an assertion — a checkout whose folder name differs from the repo name (e.g.
`brokernet-app` = `bpp-stella-ui`) is still found, because the local scan is keyed on the `origin` URL, and
is never re-cloned.

```bash
bash ~/.claude/skills/bpp-project-index/refresh.sh clone-preview              # MAX_CLONE=10 by default
bash ~/.claude/skills/bpp-project-index/refresh.sh clone <name> [<name>…]     # only after "go"
```

`clone` takes only names from the preview set, skips a folder that already has `.git`, and clones to
`~/Entwicklung/bpp/{name}` over HTTPS.


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
  `~/Entwicklung/bpp/brokernet-app` is the checkout of **`bpp-stella-ui`** (renamed 2026-09-01),
  and (until 2026-11-15) `scan-backend` was a second clone of **`brokernet-file-scanner`**. Name-matching reports both
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
- **Treating `default_branch` as proof a stage branch exists** → it is not a promise that `staging`
  exists; consumers that need a stage branch probe it explicitly.
- **Letting a lookup trigger network calls** → lookups must stay instant and offline-safe.
- **Keeping a renamed repo's old path as its own row** → 2026-11-16: `repos.md` still named
  `brokernet-fiab-connector` (now `bpp-fiab-connector`) and the old non-`templates/` path of
  `bpp-shared-template`; the new paths showed as `unlisted` and the old rows were stale. Fold the old path
  onto the new one (refresh does this), report `renamed old -> new`, and get `repos.md` fixed. Same for a
  checkout whose `origin` still uses the old path: GitLab's redirect hides it until it breaks — report
  `git remote set-url origin <new url>`.
- **Inlining awk or bash positional variables in this file** → skill args replace dollar-digit
  placeholders; code lives in `refresh.sh`.

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
- About to delete a local checkout because the repo is archived or `gone` → STOP. Report only. Only the
  user's explicit word removes one — then also add it to the `EOL` list in step 4.
- About to edit the hand-written tables in `project_index.md` → STOP. Only the `AUTO:GITLAB-ONLY` block
  belongs to this skill.
