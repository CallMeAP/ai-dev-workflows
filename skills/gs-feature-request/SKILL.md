---
name: gs-feature-request
description: Use when the user provides a feature request or enhancement idea — pasted text, a described idea, or a code reference such as a TODO comment — and wants it turned into a GitHub issue ONLY, with no implementation and no pull request. Triggers on "create a feature ticket", "make an issue for this feature", "file this enhancement", "turn these TODOs into an issue". For bugs use gs-bug-report; for support tickets use gs-support-ticket; for an autonomously-implemented PR use gs-issue-to-pr.
---

# Feature Request → GitHub Issue

Turn a feature request into a GitHub issue. **Stop at the issue** — never create a
branch, never implement code, never open a pull request.

This is the feature-request counterpart of `gs-support-ticket` (which handles
bugs / support tickets). If the user wants implementation, point them to
`gs-issue-to-pr`.

## Steps

### 1. Parse the request

Input is pasted text, a described idea, or a code reference (e.g. a TODO comment,
a file/line). For a code reference, read the cited code so the issue captures
real context.

Requests are often in German. Write the issue in English. Quote the original
request text verbatim — never discard it.

### 2. Check for duplicates

Run: `gh issue list --state open --search "<key terms from the request>"`
If an existing open issue clearly covers the same feature, stop and ask the user
whether to proceed anyway or link the existing issue instead.

### 3. Refine if underspecified

Judge whether the request is clear enough to write a scoped issue:
- **Clear** — concrete behavior, obvious scope → go straight to step 4.
- **Underspecified** — vague goal, multiple interpretations, or missing
  acceptance criteria → use the superpowers:brainstorming skill to explore
  intent and requirements with the user *before* writing the issue.

If that brainstorming run produced a design doc (`docs/superpowers/specs/`) or a
plan (`docs/superpowers/plans/`), link them by repo-relative path in the issue
body created in the next step. Skip the link if no such artifact was produced.

### 4. Create the GitHub issue

Run `gh issue create` with:
- `--title` — English rendering of the feature name.
- `--label enhancement`
- `--body` — an English summary, then **Motivation** (why this is wanted) and
  **Proposed behavior** (what it should do, with acceptance criteria if known),
  then the original request quoted verbatim inside a collapsed `<details>` block.

Capture the issue number from the command output.

### 5. Report to the user

Report the issue URL. Do not create a branch, implement code, or open a PR.
Point the user to `gs-issue-to-pr` if they later want it implemented.
