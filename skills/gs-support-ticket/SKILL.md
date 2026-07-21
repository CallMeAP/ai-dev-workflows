---
name: gs-support-ticket
description: Use when the user provides a support ticket — pasted email text or a path to a .eml file — and wants it turned into a triaged GitHub issue ONLY, with no autonomous implementation and no pull request. Triggers on "file this ticket", "create an issue from this email", "ticket to issue", or a .eml file path when no PR is wanted. For the issue-plus-autonomous-PR flow use gs-issue-to-pr instead.
---

# Support Ticket → GitHub Issue

Turn a support ticket into a triaged GitHub issue. **Stop at the issue** — never
create a branch, never implement code, never open a pull request.

This is the issue-only counterpart of `gs-issue-to-pr`. If the user
wants an autonomously-implemented PR, use that skill instead.

## Steps

### 1. Parse the ticket

Input is either pasted email text or a path to a `.eml` file.
- For a `.eml` path: read the file, extract `Subject`, `From`, and the body. If
  the message is multipart MIME, prefer the `text/plain` part.
- For pasted text: take the subject and body as given.

Tickets are typically in German. Write the issue in English. Quote the original
ticket text verbatim — never discard it.

### 2. Check for duplicates

Run: `gh issue list --state open --search "<key terms from subject>"`
If an existing open issue clearly covers the same ticket, stop and ask the user
whether to proceed anyway or link the existing issue instead.

### 3. Refine if underspecified

Judge whether the ticket is clear enough to write a scoped issue:
- **Clear** — concrete problem, understandable request → go straight to step 4.
- **Underspecified** — vague complaint, ambiguous expected behavior, or missing
  context → use the superpowers:brainstorming skill to explore the problem and
  expected behavior with the user *before* writing the issue.

If that brainstorming run produced a design doc (`docs/superpowers/specs/`) or a
plan (`docs/superpowers/plans/`), link them by repo-relative path in the issue
body created in the next step. Skip the link if no such artifact was produced.

### 4. Create the GitHub issue

Run `gh issue create` with:
- `--title` — English rendering of the ticket subject.
- `--label support-ticket`
- `--body` — an English summary, then **Expected** vs **Actual** behavior, then
  the original ticket quoted verbatim inside a collapsed `<details>` block.

Capture the issue number from the command output.

### 5. Triage note

Decide whether the issue looks autonomously implementable and record it as a
comment on the issue (`gh issue comment`) so a human can decide next steps:
- Clear, scoped code change → comment: looks autonomously implementable — run
  `gs-issue-to-pr` on the created issue to generate a PR.
- Question, user/config error, not a code change, or needs a product decision →
  comment why, and that no implementation is planned.

Never create a branch or PR regardless of the triage outcome.

### 6. Report to the user

Report the issue URL and the triage note. Do not create or offer to create a PR
in this skill — point the user to `gs-issue-to-pr` if they want one.
