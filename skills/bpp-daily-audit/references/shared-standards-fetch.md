# Shared fleet standards — fetch contract

Beside its own three files, every run reads the **shared coding standards** from
`lipso/internal/agentic-coding-knowledge` and hands the scope-matching one to R3. They feed exactly
two rules: `be-shared-dotnet-standard-violation` and `fe-shared-angular-standard-violation`.

This is a **second, separate** knowledge source from `bpp-audit-reports`. Read-only. The audit never
writes to it — not a report, not a rule, not a dismissal. Those belong in `bpp-audit-reports`.

## Normative scope — exactly four paths

| Path | Used by | Wiring |
|---|---|---|
| `.net/CLAUDE.md` | .NET repos → R3 | here |
| `angular/CLAUDE.md` | UI repos → R3 | here |
| `bpp/repos.md` | the repo list of record | **already wired in `discovery.md` §A1 — do not duplicate it here** |
| `bpp/bpp-tag-and-release/SKILL.md` | release / tagging process | read for context only — **no rule**, see below |

### `personal-workflows/**` is excluded, and stays excluded

That tree holds individual developers' own agent setups — orchestrator prompts, private memory
files, one developer's personal `bpp-stella` conventions. **It is not fleet-normative.** One
developer's way of working is not a defect in another developer's commit, and a finding that quotes
it would be unanswerable: the person whose repo was flagged never agreed to that convention.

Nothing under that prefix may be fetched, passed to a lens, or cited by a finding. If a future run
wants a standard that currently lives there, the fix is to promote it into `.net/` or `angular/` in
the knowledge repo — not to widen this filter.

### Why `bpp-tag-and-release/SKILL.md` produces no rule

It is a **procedure**, not a check — the same reason the 2026-09-09 skill sweep retired most
candidates (`rules.md` → *Retired / rejected checks*). It describes how to cut a GitLab release
after a staging→main MR is merged: tag schema `YYYY-MM-DD.NN`, Claude-written release notes, an
interactive confirmation gate. The audit reviews **commits**, never tags or releases; it has no
release inventory, and a missing release is a step somebody has not run yet, not a defect in a
landed commit. Its one durable constraint — the repo list comes from `repos.md`, never hardcoded —
is already Phase A's rule. Read it if a work item touches release tooling; do not derive a rule from it.

## Where it comes from

Same shape as `rules-fetch.md`: local checkout first, `glab` fallback, cached once per run.

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

fetch_shared ".net/CLAUDE.md"    "$WORK/shared-dotnet-claudemd.md"   || echo "DEGRADED: .net/CLAUDE.md"
fetch_shared "angular/CLAUDE.md" "$WORK/shared-angular-claudemd.md"  || echo "DEGRADED: angular/CLAUDE.md"
```

**Read the checkout through `git show origin/main`, never off the filesystem.** Same reason
`rules.md` insists on it: a `cat` reaches the working tree, which on this machine carries an
unrelated dirty file and a developer's in-progress edits. It must also never be pulled, committed to
or branch-switched — it is a user working tree (non-negotiable #5).

**`$WORK/shared-*.md` is the only copy anything reads.** Fetched once in Phase A; Phase B never
re-fetches, so every reviewer in a run sees the identical standards.

## Failure handling — degrade loudly, do NOT abort

A shared file that cannot be fetched **skips its rule for that run** and is named in the report's
Degradations section. The run continues.

This is deliberately the *opposite* of `rules.md`, and the difference is not arbitrary:

- **`rules.md` aborts because it *is* the checklist.** Without it a run reviews against nothing,
  produces a complete-looking report, and advances watermarks as though the rules had run — the one
  degradation nobody can detect tomorrow.
- **These are *additional* standards on top of a checklist that still ran.** Every other rule still
  fires, `cross-claudemd-convention-violation` still checks the repo's own `CLAUDE.md`, and exactly
  two low-severity rules go missing. That is a worse run, not a false one — structurally the same as
  losing `common-issues.md` or `known-non-issues.md`, which degrade and are reported.
- **Different repo, different failure meaning.** `rules.md` lives in `bpp-audit-reports`, so its
  being unreachable also means the run cannot commit its report or advance its ledger — there is no
  useful partial state. The knowledge repo is a **separate GitLab project**; it being down says
  nothing about whether this run can finish. Aborting a whole fleet audit on it would trade full
  coverage for zero coverage.
- **Consistency inside this one repo.** `bpp/repos.md` comes from the *same* project and already
  degrades loudly (`discovery.md` §A1: "say so loudly in the report … and continue"). Two files from
  one repo with opposite failure policies is how someone later copies the wrong one.

The skip is a **skip, not a clean result** — `rules-fetch.md`'s standing doctrine: a rule that did
not run is never reported as "0 findings".

## Scope filter — which file reaches which reviewer

Filtering happens before dispatch, by the same repo-kind classification `rules-fetch.md` already uses.

| Repo kind | Shared standards passed to R3 |
|---|---|
| .NET repo | `.net/CLAUDE.md` only |
| Angular UI repo | `angular/CLAUDE.md` only |
| `brokernet-document-cms`, `infra`, everything else | **none** |

**`.net/CLAUDE.md` never reaches a UI repo's reviewer and `angular/CLAUDE.md` never reaches a .NET
repo's.** Passing the wrong one guarantees silence or an invented finding — the same failure the
rule scope filter exists to prevent.

`brokernet-document-cms` is excluded despite sitting in the frontend group: measured 2026-09-09 it is
**91 % Handlebars**, and standalone components, signals and `inject()` have no meaning there.

## Precedence — the repo's own `CLAUDE.md` wins

R3 receives **both** the audited repo's own `CLAUDE.md` and the scope-matching shared file, and must
be told which outranks which. The repo's own file **always** wins.

| The audited repo's own `CLAUDE.md` … | Outcome |
|---|---|
| **contradicts** the shared standard | **no finding.** The repo is right; the shared file is behind |
| **states the same** standard | the specific `be-*` / `fe-*` id owns it, else `cross-claudemd-convention-violation`. The shared rule **stays silent** |
| **is silent** on the point, or the repo has no `CLAUDE.md` | the shared rule **fires** |

Full deferral chain, strongest to weakest:

```
specific be-* / fe-* id  →  cross-claudemd-convention-violation  →  be|fe-shared-*-standard-violation
```

**One violated line, one finding, one fingerprint.** This mirrors exactly how
`cross-claudemd-convention-violation` already defers to the eight specific ids.

Both shared files are **repo-provenanced copies** and can be stale in either direction — the
`false-positive-notes` on the two rules carry the measured detail (`.net/CLAUDE.md` is
`bpp-backend`'s file verbatim; `angular/CLAUDE.md` is `brokernet-cockpit-ui`'s file, and already
**behind** it by one whole standard). Never treat the shared file's silence as permission, and never
treat a repo's divergence from it as the defect.

## Bounds — identical to the catch-all

- Only the files the **work item actually touched**. Never a repo-wide conformance sweep.
- Never an edit to **any** `CLAUDE.md` — not the repo's, not the shared one. Aligning a repo with a
  fleet standard wholesale is a conversation, not a bot MR.
- The output contract still applies: a concrete `failure_scenario`, or it is not a finding.
- Only violations the work item **introduced**; pre-existing ones are out of scope.
