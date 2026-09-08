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

### Mandatory cross-check against `bpp/repos.md`

The filter + extras provably drift (2026-08-14: six repos missed). Fetch the central list and add
everything it names:

```bash
glab api "projects/lipso%2Finternal%2Fagentic-coding-knowledge/repository/files/bpp%2Frepos.md/raw?ref=main" > "$WORK/repos.md"
rows=0
while IFS='|' read -r _ name link _; do
  name=$(echo "$name" | xargs); link=$(echo "$link" | xargs)
  [[ "$link" == https://gitlab.com/* ]] || continue
  rows=$((rows+1))
  path=${link#https://gitlab.com/}
  [ -z "${ENC[$name]:-}" ] && ENC[$name]=$(printf %s "$path" | sed 's#/#%2F#g')
done < <(grep -E '^\|[^|]+\| *https://gitlab.com/' "$WORK/repos.md")
```

If the fetch fails or `rows` is 0, **say so loudly in the report** ("repo cross-check skipped — list
unreachable") and continue with filter + extras. Never silently pretend the check ran.

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
