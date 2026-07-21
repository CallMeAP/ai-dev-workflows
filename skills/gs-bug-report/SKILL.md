---
name: gs-bug-report
description: Use when the user provides a bug report — pasted text, a described defect, or a code reference such as a TODO/FIXME comment — and wants it turned into a GitHub issue ONLY, with no fix and no pull request. Triggers on "create a bug ticket", "make an issue for this bug", "file this bug", "report this defect". For feature requests use gs-feature-request; for support tickets use gs-support-ticket; for an autonomously-implemented PR use gs-issue-to-pr.
---

# Bug Report → GitHub Issue

Turn a bug report into a GitHub issue. **Stop at the issue** — never create a
branch, never fix code, never open a pull request.

This is the bug counterpart of `gs-feature-request` (enhancements) and
`gs-support-ticket` (customer support tickets). If the user wants the fix
implemented, point them to `gs-issue-to-pr`.

## Steps

### 1. Parse the report

Input is pasted text, a described defect, or a code reference (e.g. a TODO/FIXME
comment, a file/line). For a code reference, read the cited code so the issue
captures real context.

Reports are often in German. Write the issue in English. Quote the original
report text verbatim — never discard it.

### 2. Check for duplicates

Run: `gh issue list --state open --search "<key terms from the report>"`
If an existing open issue clearly covers the same bug, stop and ask the user
whether to proceed anyway or link the existing issue instead.

### 3. Refine if underspecified

Judge whether the report is clear enough to write a scoped issue:
- **Clear** — concrete defect, known trigger, observable wrong behavior → go
  straight to step 4.
- **Underspecified** — vague symptom, no reproduction path, or ambiguous
  expected behavior → use the superpowers:brainstorming skill to explore the
  symptom and expected behavior with the user *before* writing the issue.

If that brainstorming run produced a design doc (`docs/superpowers/specs/`) or a
plan (`docs/superpowers/plans/`), link them by repo-relative path in the issue
body created in the next step. Skip the link if no such artifact was produced.

### 4. Investigate automated reproduction

Investigate whether the bug can be reproduced with an automated test:
explore the relevant code and existing test projects to judge feasibility and
which test level fits (unit / integration). **Do not write the test** — only
assess. Record the finding for the issue body:
- Reproducible by an automated test → name the test project/level that fits.
- Not practically reproducible by a test → state why (e.g. needs external
  service, manual UI step, environment-specific).

### 5. Create the GitHub issue

Run `gh issue create` with:
- `--title` — English rendering of the bug.
- `--label bug`
- `--body` — an English summary, then **Expected** vs **Actual** behavior, then
  **Steps to reproduce** (if known), then an **Automated reproduction** section
  with the step 4 finding, then the original report quoted verbatim inside a
  collapsed `<details>` block.

Capture the issue number from the command output.

### 6. Report to the user

Report the issue URL and the automated-reproduction finding. Do not create a
branch, fix code, or open a PR. Point the user to `gs-issue-to-pr` if
they later want the bug fixed.
