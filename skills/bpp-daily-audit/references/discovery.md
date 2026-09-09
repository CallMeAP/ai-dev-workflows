# Phase A — Discovery

**Zero model calls in this phase.** Everything here is bash, `glab`, `acli` and `jq`.

Working dir for the run: `WORK=$(mktemp -d)`. Run id: `RUN_ID=$(date +%Y-%m-%d-%H%M)`.

## A1. Repo map

Identical discovery to `bpp-promote-dev-to-staging` — that logic is proven; do not invent a new one.

```bash
declare -A ENC

# filtered repos in the brokernet group
while read -r repo; do
  ENC[$repo]="lipso%2Fclients%2Fbrokernet%2F${repo}"
done < <(glab api "/groups/lipso%2Fclients%2Fbrokernet/projects?per_page=100&simple=true" \
  | jq -r '.[] | select(.path | test("^(bpp-|brokernet-.*-ui$)")) | .path')

# always-include extras (filter misses them / live in subgroups)
ENC[brokernet-document-cms]="lipso%2Fclients%2Fbrokernet%2Fbrokernet-document-cms"
ENC[callidus-bvs-ui]="lipso%2Fclients%2Fbrokernet%2Fcallidus%2Fcallidus-bvs-ui"
ENC[servo-ui]="lipso%2Fclients%2Fbrokernet%2Fservo%2Fservo-ui"
```

### `bpp/repos.md` — the authoritative repo list, cross-checked against the group filter

`bpp/repos.md` in the knowledge repo is **the fleet's repo list of record** — the only human-curated
inventory of what belongs to BPP / Brokernet. It is fetched on every run and everything it names is
audited.

It is **not** used as the *sole* source, and that is deliberate: the drift runs in **both**
directions, measured 2026-09-09 on a live fleet listing.

| Direction | Count | Repos |
|---|---|---|
| in `repos.md`, missed by filter + extras | 5 | `brokernet-fiab-connector`, `brokernet-file-scanner`, `brokernet-varias-sign`, `docling-sidecar`, `servo-hw-connector` |
| in the group, **missing from `repos.md`** | 3 | `bpp-arag-connector`, `bpp-external-mail-connector`, `bpp-partner-api-guide` |

The three `repos.md` does not list are not dormant: **`bpp-arag-connector` and
`bpp-external-mail-connector` both had commits on 2026-09-09**, making them among the most active
repos in the fleet. Dropping the group filter would silently un-audit them — the exact failure this
pipeline cannot detect afterwards. Keep the union.

(The filter also surfaces `bpp-audit-reports` and `bpp-shared-template`; both are on the
always-exclude list below and are correctly absent from `repos.md`.)

```bash
glab api "projects/lipso%2Finternal%2Fagentic-coding-knowledge/repository/files/bpp%2Frepos.md/raw?ref=main" > "$WORK/repos.md"
rows=0
: > "$WORK/reposmd-names.txt"
while IFS='|' read -r _ name link _; do
  name=$(echo "$name" | xargs); link=$(echo "$link" | xargs)
  [[ "$link" == https://gitlab.com/* ]] || continue
  rows=$((rows+1)); echo "$name" >> "$WORK/reposmd-names.txt"
  path=${link#https://gitlab.com/}
  [ -z "${ENC[$name]:-}" ] && ENC[$name]=$(printf %s "$path" | sed 's#/#%2F#g')
done < <(grep -E '^\|[^|]+\| *https://gitlab.com/' "$WORK/repos.md")

# report the reverse delta so repos.md's staleness is visible and someone fixes it upstream
for r in "${!ENC[@]}"; do
  grep -qx "$r" "$WORK/reposmd-names.txt" || echo "NOT IN repos.md: $r"
done
```

**Its links are old paths, and that is fine.** Every row reads
`https://gitlab.com/brokernet/<repo>` (subgroup rows `.../brokernet/servo/servo-ui`,
`.../brokernet/callidus/callidus-bvs-ui`), while the group moved to `lipso/clients/brokernet/`.
**GitLab redirects the old path**, so the derived encoded path resolves through the API unchanged —
verified 2026-09-09 for `bpp-backend`, `brokernet-fiab-connector`, `docling-sidecar` and both
subgroup entries, each returning its current `lipso/clients/brokernet/…` namespace. Do not "fix" the
derivation, and do not rewrite `repos.md`'s links to make it look right.

If the fetch fails or `rows` is 0, **say so loudly in the report** ("repo cross-check skipped — list
unreachable") and continue with filter + extras. Never silently pretend the check ran. The reverse
delta goes in the report too, as "in the group but not in `repos.md`: …" — a run that discovers a
repo the list of record does not name has found a gap in the list, and saying nothing lets it rot.

### Always-exclude

```bash
for x in bpp-cca-connector-internal bpp-shared-template bpp-audit-reports; do unset "ENC[$x]"; done
```

- `bpp-cca-connector-internal` — temporary internal repo, excluded from all automated sweeps.
- `bpp-shared-template` — scaffolding, no product code.
- `bpp-audit-reports` — the run's own output repo; auditing it is a self-audit loop.

The exclusions run **after** the cross-check, or the cross-check re-adds them.

## A2. Branch probe, then compare

**Trap:** `jq '.commits | length'` cannot detect a missing branch — on an error body `.commits` is
`null`, and `null | length` is `0` in jq, so a missing branch silently reads as "no new commits".
Probe explicitly first.

```bash
for repo in "${!ENC[@]}"; do
  enc="${ENC[$repo]}"
  for br in development staging main; do
    head=$(glab api "/projects/${enc}/repository/branches/${br}" 2>/dev/null | jq -r '.commit.id // "MISSING"')
    if [ "$head" = "MISSING" ]; then
      echo -e "${repo}\t${br}\tno-branch" >> "$WORK/skipped.tsv"   # expected outcome, not an error
      continue
    fi
    from=$(ledger_sha "$repo" "$br")        # see references/ledger.md
    if [ -z "$from" ]; then
      bootstrap_window "$repo" "$br" "$head"   # first run: last 24h, max 20 commits
      continue
    fi
    resp=$(glab api "/projects/${enc}/repository/compare?from=${from}&to=${br}" 2>/dev/null)
    if [ -z "$(echo "$resp" | jq -r '.commits // empty')" ]; then
      echo -e "${repo}\t${br}\tcompare-failed" >> "$WORK/failed.tsv"  # ledger NOT advanced
      continue
    fi
    echo "$resp" > "$WORK/compare-${repo}-${br}.json"
  done
done
```

- A missing branch is an **expected reported outcome** (`bpp-shared` has no `staging`), never an abort.
- A compare error on a repo whose branch demonstrably exists is a **per-repo failure**: recorded in
  the report, and the ledger SHA for that repo/branch is left untouched so the next run retries it.
- The compare payload is **truncated on large ranges**. Treat file counts as a lower bound (`N+`) and
  never conclude "X was not changed" from it.

## A3. Work items

Three kinds. Merge commits and pure version-bump commits are dropped before grouping.

| Kind | Built from | Reviewed with |
|---|---|---|
| **ticket** | all commits in one repo/branch sharing one `BRO-\d+` key, as one aggregate diff | R1 + R2 + R3 |
| **unkeyed** | one bundle per repo/branch of commits with no BRO key | R1 + R3 only (no spec exists) |
| **status-change** | a board ticket whose Jira status changed since the last run, even with no new commit | R2 primarily, then R1 + R3 on the code it points at |

```bash
jq -r '.commits[] | select(.title | test("^Merge |raise version for ") | not)
       | [.id, .title] | @tsv' "$WORK/compare-${repo}-${br}.json" \
  | grep -oE 'BRO-[0-9]+' | sort -u > "$WORK/keys-${repo}-${br}.txt"
```

### Unresolvable BRO keys

A commit can cite a key that does not resolve — `acli` answers
`Issue does not exist or you do not have permission to see it`, and a `key = BRO-xxxx` search returns
nothing (observed 2026-09-08 on `BRO-1234`, cited by a live commit on `bpp-backend/development`).

Handle it, do not abort:

1. The work item is **downgraded to R1 + R3 only** — there is no spec, so R2 would invent one.
2. The unresolvable key is itself recorded as a finding, `rule_id` `r3.unresolvable-ticket-key`,
   severity `low`, outcome `escalated` — a commit citing a ticket nobody can open is a traceability
   gap worth one line in the report, not an MR.
3. Never silently treat it as unkeyed; the key stays in the report so the miss is visible.

Distinguish this from a **permission** problem: if *every* ticket fetch fails, that is an auth
failure — abort with a partial report, do not label the whole board unresolvable.

### A3b. Cross-branch commit dedup — MANDATORY

**A commit that appears on more than one branch is reviewed once.** Promotion means the same SHAs
land on `development`, then `staging`, then `main`. Verified 2026-09-08 on `bpp-stella`: **8 of 8**
staging commits and **6 of 6** main commits were byte-identical SHAs already present on
`development`.

Reviewing per-branch without this step:

- triples reviewer, debate and adjudication cost for every promoted commit;
- emits the same finding three times — and the ledger will **not** catch it, because `branch` is part
  of the fingerprint, so the three copies fingerprint differently;
- produces three escalation files, or three MRs, for one defect.

The rule:

1. Collect the commit SHAs per repo across all three branches.
2. Assign each SHA to the **most upstream branch it appears on**, in the order
   `development` → `staging` → `main`.
3. Build work items only from that assignment. Record the other branches the commit is present on as
   a `also_on` field on the work item — the report shows it, and an MR targets the most upstream
   branch that carries the bug.
4. Only **branch-exclusive** commits — a hotfix landed straight on `staging` or `main` and not yet
   back-merged — become their own work item. Those are exactly the ones that need the back-merge
   checklist, so they matter disproportionately despite being rare.

```bash
cut -f1 t-${repo}-development.tsv | sort > "$WORK/dev.txt"
comm -23 <(cut -f1 "t-${repo}-staging.tsv" | sort) "$WORK/dev.txt"   # staging-exclusive == real hotfixes
```

A repo whose `staging` commits are entirely a subset of `development` is reported as
"staging: N commits, all already reviewed on development" — not as "no commits", which would be false.

### A3c. Exclude machine-generated files before measuring or reviewing

**The 1500-line cap is measured on human-authored lines only.** Generated files are excluded from the
diff before the cap is applied and before anything reaches a reviewer.

Verified 2026-09-08 on `bpp-shared`: a two-enum-value change measured **25,523 changed lines**, of
which **25,354 (99.3%)** were two EF `*.Designer.cs` migration snapshots. Unfiltered, the cap defers
the work item for "manual review" while the actual reviewable change is ~170 lines. Every
migration-bearing change set in the fleet would hit this.

Exclude at minimum:

```
*/Migrations/*.Designer.cs        EF migration snapshots
*/Migrations/*ModelSnapshot.cs    EF model snapshot
*.g.cs                            NSwag-generated connector clients (backend)
api-docs-*.json                   committed OpenAPI specs the clients regenerate from
*/.openapi-generator/*            openapi-generator metadata (FILES, VERSION) — frontends
package-lock.json  yarn.lock  *.lock
*.min.js  *.min.css
```

**Frontend generated clients are excluded from a manifest, not from a guessed glob.** The Angular
repos generate one client per backend into `src/app/api/<service>/` via `openapi-generator-cli`
(`npm run generate:models:*`), and each output directory carries
`<dir>/.openapi-generator/FILES` listing **exactly** what was generated — 817 entries for
`brokernet-cockpit-ui`'s `src/app/api/backend` alone, 1757 tracked files under `src/app/api` across
its ten services. Derive the exclusion from that manifest so it stays correct when a client is added
or the generator's layout changes:

```bash
# every path listed in a .openapi-generator/FILES manifest, repo-relative
gen_manifest_paths() {           # $1 = local repo checkout, $2 = branch
  git -C "$1" ls-tree -r --name-only "origin/$2" \
    | grep -E '\.openapi-generator/FILES$' \
    | while read -r manifest; do
        dir=${manifest%/.openapi-generator/FILES}
        git -C "$1" show "origin/$2:$manifest" | sed "s#^#${dir}/#"
      done
}
```

Drop any changed path that appears in that list, in addition to the pathspec excludes above. A repo
with no manifest (no generated client) simply yields nothing.

```bash
git -C "$L" show "$sha" -- . \
  ':(exclude)*/Migrations/*.Designer.cs' \
  ':(exclude)*/Migrations/*ModelSnapshot.cs' \
  ':(exclude)*.g.cs' ':(exclude)*-lock.json' ':(exclude)*.lock' \
  ':(exclude)*api-docs-*.json' ':(exclude)*/.openapi-generator/*'
```

The **migration `.cs` file itself is NOT excluded** — the `Up`/`Down` body is exactly what a reviewer
should read, and a schema change is on the escalate-regardless list. Only the generated snapshot
beside it is dropped.

**`api-docs-*.json` stays readable to the rules that need it.** `be-stale-connector-client` compares
that file's **commit date** against the source repo's controller commits — it reads git metadata, not
the diff — so excluding the spec's 4,875 lines from the reviewed diff does not blind it.

**Excluded does not mean invisible.** The report still names generated files that changed, so a
reviewer can see when generated output moved without a regeneration commit beside it. Only the
line-by-line content is withheld.

The report must state the exclusion: "N changed lines (M generated lines excluded)". Silently
shrinking a diff would make the cap column meaningless.

## A4. Jira

Board filter (verified 2026-09-08 — 268 tickets, mostly `Staging-Deployed`):

```bash
JQL='project = BRO AND assignee IN (EMPTY, "712020:69d5f7a5-44b0-4aa7-9c76-e369ea0994d8")'
acli jira workitem search --jql "$JQL" --limit 300 --json > "$WORK/board.json"
acli jira workitem view "$KEY" --json > "$WORK/ticket-$KEY.json"
```

- **Always `--json`** — plain output carries ANSI codes.
- The board is **never iterated wholesale**. It is a spec source for keys named by commits, and the
  input to the status-change sweep only.
- Status-change sweep: compare each ticket's `fields.status.name` against `ledger.jira[KEY].status`.
  Changed → one status-change work item. Unchanged → nothing.

## A4b. Load the rule set and the two memory files

```bash
REPORTS=~/Entwicklung/bpp/bpp-audit-reports
git -C "$REPORTS" pull --ff-only -q      # another machine may have run since
[ -f "$REPORTS/common-issues.md" ]    || echo "WARNING: common-issues.md missing"
[ -f "$REPORTS/known-non-issues.md" ] || echo "WARNING: known-non-issues.md missing"

# the rule set — Phase B's checklist
cp "$REPORTS/rules.md" "$WORK/rules.md" 2>/dev/null \
  || glab api "/projects/86222771/repository/files/rules.md/raw?ref=main" > "$WORK/rules.md"
rules=$(grep -cE '^### `[a-z0-9.-]+`$' "$WORK/rules.md" 2>/dev/null || echo 0)
[ "$rules" -gt 0 ] || { echo "FATAL: no rules loaded"; exit 1; }   # abort, write a partial report
```

The two memory files missing is a **degradation**, reported, not a silent skip — see
`references/known-non-issues.md` for what each does and which lens receives it.

`rules.md` is stricter: it *is* the checklist, so an empty or unreachable rule set **aborts** the run
with a partial report rather than degrading it into a review against nothing. A partial parse
continues on the rules that loaded and names the rest as a degradation. Full contract — sources,
parse, scope filter, why abort — in `references/rules-fetch.md`.

## A4c. Load the shared fleet standards

A **second** knowledge source, from a different repo: `.net/CLAUDE.md` and `angular/CLAUDE.md` in
`lipso/internal/agentic-coding-knowledge`. They drive `be-shared-dotnet-standard-violation` and
`fe-shared-angular-standard-violation`, and are handed to R3 beside the repo's own `CLAUDE.md`.

```bash
KNOW=~/Entwicklung/lipso/agentic-coding-knowledge
KNOW_ENC=lipso%2Finternal%2Fagentic-coding-knowledge

fetch_shared() {   # $1 = path in the knowledge repo, $2 = destination in $WORK
  if [ -d "$KNOW/.git" ]; then
    git -C "$KNOW" fetch --quiet origin main 2>/dev/null
    git -C "$KNOW" show "origin/main:$1" > "$2" 2>/dev/null && return 0
  fi
  glab api "/projects/${KNOW_ENC}/repository/files/$(printf %s "$1" | jq -sRr @uri)/raw?ref=main" \
    > "$2" 2>/dev/null && [ -s "$2" ]
}

fetch_shared ".net/CLAUDE.md"    "$WORK/shared-dotnet-claudemd.md" \
  || echo "DEGRADED: .net/CLAUDE.md unreachable — be-shared-dotnet-standard-violation skipped" >> "$WORK/degradations.txt"
fetch_shared "angular/CLAUDE.md" "$WORK/shared-angular-claudemd.md" \
  || echo "DEGRADED: angular/CLAUDE.md unreachable — fe-shared-angular-standard-violation skipped" >> "$WORK/degradations.txt"
```

- **Read-only, and never written to.** The audit's own outputs go to `bpp-audit-reports`. That
  checkout is a user working tree with unrelated dirty files — read it through
  `git show origin/main:`, never `cat`, never `pull`, never a branch switch (non-negotiable #5).
- **`bpp/repos.md` is already fetched in §A1.** Do not fetch it twice.
- **`personal-workflows/**` is out of scope** — individual developers' own setups, never fleet
  standards. Never fetched, never passed to a lens, never cited by a finding.
- **Unreachable degrades, it does not abort** — unlike `rules.md`. The rule is *skipped* for the run
  (never reported clean) and named in the report. The argument for why the two policies differ is in
  `references/shared-standards-fetch.md`; do not "harmonise" them.

## A5. Ledger dedup — before any dispatch

Compute each candidate finding slot's fingerprint and drop what is already known. This is the single
largest cost control in the whole pipeline; skipping it re-reviews and re-reports the same code daily.
See `references/ledger.md` for the fingerprint definition and the dedup rule.

Deferred items from the previous run are queued **first**, ahead of new work, before caps are applied.

## A6. Reading file content without disturbing a working tree

Never `checkout`, `switch` or `stash` in a user working tree.

```bash
git -C "$LOCAL" fetch --quiet origin
git -C "$LOCAL" show "origin/${br}:${path}"
```

For a repo with no local checkout (resolve paths via `project_index.md`, lookup only — never trigger
its refresh):

```bash
glab api "/projects/${enc}/repository/files/$(printf %s "$path" | jq -sRr @uri)/raw?ref=${sha}"
```
