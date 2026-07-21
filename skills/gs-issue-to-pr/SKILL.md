---
name: gs-issue-to-pr
description: Use when the user has an existing GitHub issue — a number, a URL, or "the issue we just created" — and wants it autonomously implemented into a pull request. Triggers on "implement issue #7", "turn this issue into a PR", "build a PR for issue #n", "implement that issue". The issue itself is created by gs-support-ticket, gs-feature-request, or gs-bug-report; this skill takes it from there.
---

# GitHub Issue → Pull Request

Take an existing GitHub issue and, when it is a clear code change, produce an
autonomously-implemented PR for the user to review.

This is the implementation half of the `gs-*` family. The issue is created by an
intake skill — `gs-support-ticket`, `gs-feature-request`, or `gs-bug-report` —
which all stop at the issue. This skill picks up any such issue and runs it to a
PR.

## Steps

### 1. Identify the issue

Input is a GitHub issue number, a URL, or a reference to one just created in the
session. Read it with `gh issue view <n>` to get the title, body, and labels.

Write the PR, branch name, and commits in English.

### 2. Triage gate

Decide whether the issue is autonomously implementable:
- **Implement** — a clear, scoped code change with a determinable fix. Skip to
  step 4.
- **Clarify** — a code change in principle, but underspecified: details that
  change *what gets built* are missing or ambiguous (e.g. which of several
  behaviors is wanted, unstated edge cases, no acceptance criteria). Go to
  step 3.
- **Stop** — a question, a user/config error, not a code change, or needs a
  product decision. Post a comment on the issue (`gh issue comment`) explaining
  why it was not auto-implemented, report the reasoning to the user, and stop.
  Do not create a branch or PR.

### 3. Clarify underspecified issues

Only for the **Clarify** outcome. Resolve the ambiguity with the user in this
session *before* dispatching — the background agent runs unattended and must not
guess on decisions that change what gets built.

Use the superpowers:brainstorming skill to explore intent and requirements with
the user. When the open questions are settled:
- Edit the GitHub issue body (`gh issue edit`) to fold in the clarified
  requirements, so the dispatched agent works from a complete spec.
- Proceed to step 4.

If the user is unavailable to answer, do not dispatch — leave a comment on the
issue listing the open questions and stop.

### 4. Dispatch a background implementation agent

Dispatch a background subagent (`Agent` tool, `run_in_background: true`,
`subagent_type: general-purpose`) with this brief:

> Implement GitHub issue #<n> in the BewegteSchule.Guetesiegel repo.
> 1. Create an isolated git worktree off the latest `master` (use the superpowers
>    using-git-worktrees skill) so the user's main checkout is untouched. Branch
>    name: `issue/<n>-<short-slug>`.
> 2. Implement the change using the superpowers flow: writing-plans →
>    test-driven-development → verification-before-completion. Scale down to a
>    direct implement-then-verify for trivial one-line changes where a plan and
>    test-first cycle add no value.
> 3. Verify: run `dotnet build` and `dotnet test` on the solution. Both must pass.
> 4. If you hit a design decision the issue does not answer, make a reasonable
>    best-effort choice, implement it, and record the assumption for the PR
>    description — do not abort.
> 5. Open a PR with `gh pr create --base master`. The body must include
>    `Closes #<n>`, a change summary, and any flagged assumptions / open
>    questions. If build or tests do not pass, open it as a draft (`--draft`) and
>    state the failure plainly at the top of the body.
> 6. Report the PR URL.

### 5. Label the issue and report to the user

When the background agent finishes and a PR was created (ready or draft), mark the
issue so its status is visible at a glance:

- Apply the `in review` label: `gh issue edit <n> --add-label "in review"`. If the
  label does not exist yet, create it first:
  `gh label create "in review" --description "Implemented; has an open PR awaiting review" --color fbca04`.
- No separate PR-linking step is needed: the `Closes #<n>` keyword in the PR body
  already links the PR to the issue — it shows in the issue's Development panel and
  auto-closes the issue when the PR merges to the default branch.

Then tell the user the outcome: the PR URL (ready or draft), or — for a triage stop —
the issue URL and why no PR was created. On a triage **stop** no PR exists, so do not
apply the `in review` label.
