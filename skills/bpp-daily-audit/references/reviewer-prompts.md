# Phase B — Reviewer lenses

Three agents per work item, dispatched **in parallel in one message**. Model: **Sonnet 5**, effort
**medium**.

## What each agent receives

- The work item's aggregate diff (already capped at 1500 changed lines by Phase A).
- The **named changed files** at that ref, fetched per `discovery.md` A6.
- For a ticket work item: the BRO ticket's summary, description and acceptance criteria.
- **The repo's own `CLAUDE.md`, read through git** — never off the filesystem, which reaches sibling
  worktrees whose paths look native. **Root first, then `.claude/CLAUDE.md`:**

  ```bash
  git -C "$LOCAL" show "origin/$br:CLAUDE.md" > "$WORK/claudemd-${repo}.md" 2>/dev/null \
    || git -C "$LOCAL" show "origin/$br:.claude/CLAUDE.md" > "$WORK/claudemd-${repo}.md" 2>/dev/null \
    || echo "no CLAUDE.md on origin/$br"     # rule skipped for this repo, not reported clean
  ```

  It goes to **R3**, which owns `cross-claudemd-convention-violation`. **Only this repo's file** —
  `CLAUDE.md` content differs per repo, and enforcing one repo's convention against another is that
  rule's defining misfire.

  Measured 2026-09-09 over the 59 projects of the group (default branch): **20 repos keep one at the
  root, 4 keep one only at `.claude/CLAUDE.md`, 35 have none.** All four dot-directory repos are UI
  (`brokernet-cockpit-ui`, `bpp-stella-ui`, `brokernet-onboarding-ui`,
  `bpp-document-analysis-dashboard`) — **no UI repo in the fleet has a root `CLAUDE.md`**, so a
  root-only fetch reported every Angular repo as having no conventions at all. Hence the fallback.
  A repo with neither has the rule skipped, never reported clean.
- **The scope-matching shared fleet standard**, from `lipso/internal/agentic-coding-knowledge`,
  fetched in Phase A §A4c and read only from `$WORK`:

  | Repo kind | File passed to R3 | Rule it drives |
  |---|---|---|
  | .NET repo | `$WORK/shared-dotnet-claudemd.md` (`.net/CLAUDE.md`) | `be-shared-dotnet-standard-violation` |
  | Angular UI repo | `$WORK/shared-angular-claudemd.md` (`angular/CLAUDE.md`) | `fe-shared-angular-standard-violation` |
  | `brokernet-document-cms`, infra, everything else | none | — |

  **Tell R3 the precedence explicitly, in the prompt.** The audited repo's own `CLAUDE.md` **wins**:
  where the repo's file contradicts the shared one there is **no finding**; where it states the same
  convention the finding is `cross-claudemd-convention-violation`'s (or a specific `be-*`/`fe-*`
  id's) and the shared rule **stays silent**; only where the repo's file is **silent** — or absent —
  does the shared standard fire. Both shared files are repo-provenanced copies that can be stale in
  either direction, so silence in them is never permission. Full contract, scope filter, the
  `personal-workflows/**` exclusion and the degrade-don't-abort argument:
  **`references/shared-standards-fetch.md`**.
- **The rules from `$WORK/rules.md` that apply to this repo** — filtered by `scope` and by each
  rule's `applies-to`, per `references/rules-fetch.md`. That filtered set is the lens's checklist.

**Never a repository, never a directory tree, never "explore the codebase".** If a reviewer needs a
file the diff names, it is already supplied; if it needs one the diff does not name, that is a
finding about missing context, not a reason to widen the input.

## The rules drive the lenses

`rules.md` in `bpp-audit-reports` is the checklist; the lenses below say who applies which part of it.

- Every rule whose `detect` is a **command runs in bash, in Phase A** — never inside an agent
  (non-negotiable #1). A reviewer receives the command's *result*, already computed.
- A rule whose `detect` says *dispatch reviewer lens* goes to that lens with its `false-positive-notes`
  attached. Those notes exist to stop a known misfire; a finding that walks straight into one costs a
  debate round.
- A finding raised against a rule **must carry that rule's `id` as its `rule_id`**, verbatim. The id
  is part of the fingerprint — inventing a variant spelling creates a duplicate finding the ledger
  cannot recognise.
- A lens may still raise something no rule covers. It uses the `r{1,2,3}.<slug>` form, and if the same
  shape recurs, Phase E proposes it as a new rule for a human to add to `rules.md`.
- **Only in-scope rules are passed.** A backend rule never reaches a reviewer looking at an Angular
  repo. A rule that does not apply is skipped, never reported as clean.

## Hunt list — `common-issues.md`

Before the lens instructions, every **R1** prompt carries the entries from `common-issues.md` in
`bpp-audit-reports` as an explicit hunt list: patterns already confirmed to recur in this codebase,
each with its detection heuristic and its counter-risk.

Tell R1 plainly: *these are known to recur here — check for each one, and also check whether a fix
for one has been applied in the wrong way (each entry names how).* A hunt list is additive; it never
replaces the lens's own judgement, and finding none of them is a normal outcome.

The current entries include the **cartesian `Include` explosion** (two or more collection includes in
one query without `.AsSplitQuery()`, timing out rather than returning a wrong answer) — including its
inverse, an `.AsSplitQuery()` added to an order-dependent query with no `OrderBy`.

## Lenses

### R1 — Correctness

Logic errors and defects in the changed code itself.

- Null / nullable-reference handling, `async` misuse (unawaited tasks, `async void`, sync-over-async).
- Boundary and off-by-one, wrong comparison operator, inverted guard.
- Swallowed exceptions, empty catch, logging instead of throwing where the caller needs the failure.
- Missing `.Include()` producing a silent null, or an `.Include()` chain that changes cardinality.
- Concurrency: shared mutable state, cache key collisions.
- The in-scope `rules.md` entries routed to R1 — EF tracking (`be-ef-tracking-misuse`) and
  soft-delete correctness (`be-soft-delete-or-dependent-check-missing`) among them. Everything above
  this line is R1's own judgement and deliberately has no rule id.
- Every pattern in the `common-issues.md` hunt list, in both directions — the defect, and a fix for it
  applied wrongly.

### R2 — Spec-fit  *(ticket and status-change work items only)*

The diff judged against the BRO ticket. Skipped for unkeyed work items **and for work items whose
key does not resolve in Jira** — there is no spec to judge against, and inventing one produces noise.

**Be fair to multi-repo tickets.** A BRO ticket often names work that belongs to other repos
(`bpp-external-mail-connector`, `bpp-agentic`, a UI). Code landing in this repo is not required to
implement those parts. Flag a gap only when this change set claims something it does not deliver, or
contradicts the ticket — not merely because the ticket mentions work done elsewhere.

- Does the implementation do what the acceptance criteria say, or something adjacent?
- Is a stated sub-requirement missing entirely?
- Is there behaviour in the diff that the ticket never asked for (silent scope creep)?
- Does the ticket's status claim more than the code delivers (a `Staging-Deployed` ticket whose code
  only half-implements it)?
- Are the ticket's German business terms implemented with the right domain semantics?

### R3 — Convention and regression

Project rules from `CLAUDE.md`. These are the findings most likely to be real and cheapest to fix.

R3 receives **the audited repo's `CLAUDE.md`** (fetched above) and owns the catch-all
`cross-claudemd-convention-violation`: a violation of a convention that file states **explicitly**,
quoting the offending line. Two bounds make it a rule rather than a style-guide dumping ground:

- **The specific rule wins.** Eight ids already carve out the high-value conventions
  (`be-mapper-shape-violation`, `be-baseservice-ctor-param-use`, `be-ef-tracking-misuse`,
  `be-file-naming-module-prefix`, `be-module-boundary-violation`, `be-reinlined-state-checker-guard`,
  `be-dto-change-without-migration-guide`, `be-missing-assplitquery-on-multi-collection-include`).
  When both would fire, raise **one** finding under the specific id — two ids for one line means two
  fingerprints for one defect.
- **Nothing the file does not say.** A convention R3 infers from surrounding code, recalls from
  another repo, or simply considers good practice is out of scope. `CLAUDE.md` is an actively
  maintained surface — the `AsSplitQuery` convention was pushed into 17 repos' files on 2026-09-09,
  and the other 15 repos with a `CLAUDE.md` did not get it.

R3 also owns the two **shared-standard** rules, `be-shared-dotnet-standard-violation` and
`fe-shared-angular-standard-violation` — the same shape as the catch-all, but sourced from the
knowledge repo instead of the repo itself, and **one step further down the same deferral chain**:

```
specific be-* / fe-* id  →  cross-claudemd-convention-violation  →  be|fe-shared-*-standard-violation
```

They fire **only on a point the audited repo's own `CLAUDE.md` is silent about**. That is where the
coverage actually is: no UI repo has a root `CLAUDE.md`, and this file's three `fe-` rules are all
build/codegen hygiene — without `angular/CLAUDE.md` the fleet's Angular code is reviewed against no
written convention at all. Same bounds as the catch-all: only files the work item touched, never a
repo-wide sweep, never an edit to any `CLAUDE.md`, and a concrete `failure_scenario` or it is not a
finding.

**R3's checklist is the filtered rule set, not a list kept here.** It receives every in-scope rule
from `rules.md` whose `detect` needs judgement — the migration-guide rules, `DtoMapper` shape,
mapper tests, `BaseService` field usage, re-inlined state-checker guards, `[AuditReason]` on writes,
module boundaries, file naming — each with its own `false-positive-notes`. Enumerating them here too
would guarantee the two copies drift.

R3 also owns the mechanical rules' *results*: Phase A ran those commands, and R3 judges each hit
against the rule's notes rather than re-running anything.

## Batching lenses per repo — allowed, with one hard limit

When a repo's work items are small, one agent per lens **per repo** (covering all that repo's work
items) is cheaper than one agent per lens per work item, and gives the reviewer cross-item context.
That is permitted.

**But never collapse to a single agent for a repo.** Observed 2026-09-08: batching R1+R3 into one
agent for `bpp-shared`, and R1+R2+R3 into one for `bpp-stella-ui`, left those repos' findings with
**no peer to debate them** — Phase C silently degraded to nothing for two of four repos, and the
findings went to adjudication undebated.

The rule: **at least two independent agents per repo that produced any finding.** If a repo's work
genuinely only warrants one lens, either run a second lens anyway, or record in the report that this
repo's findings were **not debated** and treat their confidence accordingly. Never let a repo's
findings reach adjudication undebated without saying so.

## Output contract

Each agent returns **JSON only** — an array of findings, no prose, no preamble.

```json
[
  {
    "rule_id": "r1.ef-tracking",
    "severity": "high",
    "file": "BPP.Backend.NET.Contract/Services/ContractService.cs",
    "line": 214,
    "claim": "one sentence stating the defect",
    "failure_scenario": "concrete inputs or state -> the wrong output or crash that results",
    "confidence": 0.75,
    "fix_sketch": "one or two sentences on the smallest change that fixes it",
    "files_touched_by_fix": ["path/one.cs"]
  }
]
```

- `severity` ∈ `high` | `medium` | `low`. `rule_id` is `r{1,2,3}.<kebab-slug>` and must be stable
  across runs — it is part of the fingerprint.
- **`failure_scenario` is required.** A finding that cannot name concrete inputs and a concrete wrong
  result is a style opinion, not a defect; return it as `low` or not at all.
- `files_touched_by_fix` feeds the 5-file fixability bound in Phase D. An honest estimate matters
  more than a small one.
- An empty array is a valid and common answer. Do not manufacture findings to fill the response.

### There is no tool for returning findings — say so in the prompt

**Every reviewer prompt must state this verbatim:**

> There is no `ReportFindings` tool. No `submit_findings`, no reporting tool, no structured-output
> tool of any kind exists in this pipeline. Your final assistant message **is** the output channel:
> it must be the JSON array and nothing else — no preamble, no prose summary, no markdown fence.

Observed 2026-09-09: two reviewers (bpp-backend R1, bpp-file R3) **invented a `ReportFindings` tool**,
"called" it, and returned prose. Both sets of findings were recovered by hand-parsing the prose —
one of them the medium-severity bpp-file escalation — but a stricter parser would have dropped them
and reported both repos as clean. An agent that believes a tool exists does not need the contract
repeated harder; it needs to be told the tool does not exist.

### Response validation — a reviewer's output is never silently dropped

Three steps, in order. **A silent drop is not an available outcome at any of them.**

1. **Parse tolerantly.** Despite the "no markdown fence" instruction, agents wrap the array in
   ```json … ``` (observed 2026-09-08). Strip a leading/trailing fence, and strip a prose preamble
   before the first `[`, rather than treating the response as malformed. Never discard a real finding
   over its wrapper.
2. **Re-ask once, do not drop.** If step 1 does not yield a JSON array, `SendMessage` that agent
   once: *"Your reply did not parse as JSON. There is no ReportFindings tool. Re-send only the JSON
   array of your findings — `[]` if you found none."* Same 6-minute bounded wait as the debate
   channel (`references/debate-protocol.md`).
3. **Hand-extract, and mark it.** If the re-ask fails or times out, extract the findings from the
   prose by hand into the contract shape and set `"recovered_from_prose": true` on each. Recovered
   findings are debated and adjudicated normally.

**The accounting is mechanical.** Before Phase C, the number of lenses dispatched must equal
parsed + recovered + explicitly-empty:

```bash
# lenses dispatched for this run vs. responses accounted for
test "$LENSES_DISPATCHED" -eq $(( PARSED + RECOVERED + EMPTY )) \
  || echo "UNACCOUNTED reviewer responses — name each one in the report"
```

A lens whose output could be neither parsed nor recovered is **not** "no findings". Its work item is
reported as **unreviewed by that lens**, in Degradations, naming the repo and the lens. A repo whose
only responding lens failed this way is reported as unreviewed, never as clean.
