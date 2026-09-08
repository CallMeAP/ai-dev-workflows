# Phase B — Reviewer lenses

Three agents per work item, dispatched **in parallel in one message**. Model: **Sonnet 5**, effort
**medium**.

## What each agent receives

- The work item's aggregate diff (already capped at 1500 changed lines by Phase A).
- The **named changed files** at that ref, fetched per `discovery.md` A6.
- For a ticket work item: the BRO ticket's summary, description and acceptance criteria.
- The repo's `CLAUDE.md` when one exists.

**Never a repository, never a directory tree, never "explore the codebase".** If a reviewer needs a
file the diff names, it is already supplied; if it needs one the diff does not name, that is a
finding about missing context, not a reason to widen the input.

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
- **EF Core tracking**: read paths must use `QueryAllAsNoTracking()`, write paths `QueryAll()`.
  Missing `.Include()` producing a silent null, or an `.Include()` chain that changes cardinality.
- Boundary and off-by-one, wrong comparison operator, inverted guard.
- Swallowed exceptions, empty catch, logging instead of throwing where the caller needs the failure.
- Soft-delete correctness: `SoftDeleteAsync` vs hard delete, dependent-entity checks before delete.
- Concurrency: shared mutable state, cache key collisions.
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

- **A DTO change with no endpoint migration guide** under
  `BPP.Backend.NET.App/endpoint-migration-guides/` — adding, removing, renaming a property, changing
  a type or nullability, changing an enum a DTO exposes. Additive counts.
- `DtoMapper` shape: `Projection` expression EF-translatable (no helper calls inside the expression
  tree), `Metadata` block inlined, compiled `ToInfoDto`, `ApplyUpdate` mapping every property.
- A mapper changed without its `{Entity}DtoMapperTests` updated.
- `BaseService` subclasses using primary-constructor parameters instead of the inherited
  `_repositoryWrapper` / `_logger` / `_auditContextService`.
- Re-inlined guards that belong in `ContractStateCheckerUtil` / `CustomerStateCheckerUtil`.
- Missing `[AuditReason]` on a write endpoint; missing `[ProducesResponseType]`.
- Module-boundary violations: feature logic placed in a foreign module without the documented
  cross-reference comment.
- File naming: files not prefixed with the module's singular name.

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

**Parse tolerantly.** Despite an explicit "no markdown fence" instruction, agents sometimes wrap the
array in ```json … ``` (observed 2026-09-08). Strip a leading/trailing fence before parsing rather
than treating the response as malformed — and never discard a real finding over its wrapper.
