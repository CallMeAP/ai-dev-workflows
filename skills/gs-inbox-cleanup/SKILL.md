---
name: gs-inbox-cleanup
description: Use when the Gütesiegel platform mails have piled up in Alex's Gmail inbox and should be sorted — phrases like "clean up my inbox", "cleanup my gmail like yesterday", "trash the pause and speichern mails", "archive the submissions", "my inbox is full of bewegte schule mails". Classifies the automated mails from support@guetesiegel-bewegteschule.at by BODY text, saves each school's resume link before trashing the pause mails, labels + archives the submission confirmations, and never touches a mail a school actually wrote. Every run also scans the same inbox for new support tickets — the mails a human wrote — and reports each one with a triage line, so a cleanup run can never silently bury a school's question.
---

# Gütesiegel inbox cleanup

Sorts the automated mails the Gütesiegel platform Bccs to `pittrichalex@gmail.com` during a
live award cycle. In a running cycle this is a few hundred mails — 591 schools were invited
for the 2026 NÖ/Wien cycle alone — so the inbox stops being usable without this.

**Runs with full autonomy** (Alex's decision, 2026-11-05): apply the matrix below to every
matching mail without asking. Report what moved at the end.

**This skill has two jobs, and the second one is not optional.** Sorting the automated mails is
one; **scanning for new support tickets** (step 1b) is the other. They belong together because
the same cleanup that empties the inbox is what makes a school's question stop being visible —
so the run that files the automated mails away is exactly the run that has to surface the human
ones. Never finish a run without the support-ticket section in the report, even when it is empty.

## The one rule that matters

**Classify by BODY text, never by subject.** The pause mail and the submission confirmation
carry the **identical** subject `Gütesiegel Bewegte Schule Österreich` — seeded at
`BewegteSchule.Guetesiegel.DataAccess/DB/DbInitializer.cs:3110` and `:3119`. Only the body
tells them apart. A subject-based rule trashes submissions, which are the only mail copy of
the Ergebnis-PDF and the Plakettenrechnung.

| Body contains | What it is | Action |
|---|---|---|
| `jederzeit weitermachen` | Pause & Speichern resume-link mail (`MailBodyPausedAndSaved`, `DbInitializer.cs:3070`) | **save the link** (step 3), then `trash_message` |
| `Vielen Dank für Ihre Teilnahme` | Submission confirmation (`MailBodySubmitted`, `DbInitializer.cs:3080`), carries Ergebnis-PDF + Rechnung | add label `Guetesiegel`, remove `INBOX` |
| neither, and sender is **not** `support@guetesiegel-bewegteschule.at` | a human wrote this — a school's question, Sigi, a bounce report | **NEVER TOUCH.** List it for Alex. |

Anything you cannot classify stays in the inbox and gets listed. Never guess.

## Steps

### 1. Find the candidates

```
search_threads  query: "from:support@guetesiegel-bewegteschule.at in:inbox"  view: THREAD_VIEW_IDS_ONLY
```

All of these mails share one subject, so Gmail collapses them into **one thread** (in the 2026
cycle: `1a1a3f4825ccfab5`, 57+ messages). A thread listing is therefore useless for counting.
Pull the thread itself and work per message:

```
get_thread  threadId: <id>  messageFormat: PLAIN_TEXT
```

Keep only messages whose `labelIds` contain `INBOX`. Ignore the rest — already handled.

If the thread is too large for one read, fall back to `get_message` per id with
`messageFormat: PLAIN_TEXT`.

### 1b. Scan for new support tickets — always, every run

A second, independent search. The step-1 query only finds mails **from** the platform; a school's
question comes from the school, so it would never appear there. Run both.

```
search_threads  query: "in:inbox -from:support@guetesiegel-bewegteschule.at newer_than:14d"
                view: THREAD_VIEW_SUMMARY  pageSize: 50
```

Widen `newer_than` if the last run was longer ago; the point is to cover everything since then.
A reply from a school often lands **inside** a platform thread (same subject, `AW:` prefix), so
it also shows up in the step-1 threads — read every message of those threads, not only the ones
`labelIds` marks `INBOX`.

For each hit, decide from the body:

| What it is | What to do |
|---|---|
| A school, a Landeskoordination, or Sigi writing about a submission, an invoice, a plaque, a resume link, a defect | **a support ticket** — handle it (below) |
| A bounce / delivery report for a platform mail | report it with the affected address; do not touch the mail |
| Unrelated mail (newsletters, other projects, Claude/AWS/vendor mail) | ignore it entirely, and do not list it — it is not inbox cleanup's business |

For every support ticket, in the same run:

1. **Draft the reply immediately** — do not offer and wait for a go. Reply on the school's own
   message (`replyToMessageId`), To only the person who wrote, Cc `skai@ms-taiskirchen.at` and
   `peter.klein@bewegteschule.at`. Sending stays with Alex; the skill only drafts.
2. **File a GitHub issue** via `gs-support-ticket` (English body, original quoted verbatim in a
   `<details>` block, label `support-ticket`, plus a triage comment). Check
   `gh issue list --state open --search "<key terms>"` for a duplicate first.
3. **Flag the time-critical shape**: a school that has *not yet submitted* and needs a flag
   changed is cheap — the fix costs nothing before submission and becomes a manual production
   write afterwards (#109, #112, #113). If a mail looks like that, say so first in the report, in
   its own line, so Alex can mail the school to hold before it submits.
4. Never trash, archive or label a mail a person wrote, not even after filing the issue.

### 2. Classify every message by its `plaintextBody`

Apply the matrix above. Count each class before acting, and print the counts.

Mails addressed to `pittrichalex@gmail.com` itself are e2e self-tests; classify them by body
exactly like the rest.

### 3. Save the resume links BEFORE trashing anything

A pause mail is the **only** copy of that school's personal resume URL
(`https://www.guetesiegel-bewegteschule.at/antrag/<guid>`). Schools do ask for it — `912051`
did on 2026-11-05. Once the mail is in Trash the link is gone in 30 days.

Append one tab-separated line per pause mail to `~/.claude/gs-inbox-cleanup/antrag-links.tsv`:

```
<ISO-Datum>	<Empfängeradresse>	<Antrag-URL>	<Gmail-Message-Id>
```

```bash
mkdir -p ~/.claude/gs-inbox-cleanup
touch ~/.claude/gs-inbox-cleanup/antrag-links.tsv
chmod 700 ~/.claude/gs-inbox-cleanup
chmod 600 ~/.claude/gs-inbox-cleanup/antrag-links.tsv
```

**This file is a credential store.** The resume URL is a capability URL: whoever holds it can
read and change that school's entire submission, with no login. Mode 600, never inside the
repo, never in a commit, never pasted into an issue, a PR or a chat message. Hand a single
link to a single school only in a direct reply to that school's own address.

Skip a line that is already in the file (match on the message id) so repeated runs don't
duplicate.

**Also record the pause mails the Gmail filter already trashed.** The step-1 thread read returns
them too (their `labelIds` say `TRASH`, not `INBOX`), and their link is still intact there — so
harvest it even though there is nothing left to trash. Those are the links nobody ever wrote down,
and in 30 days they are gone for good. Record them, then leave the mails in Trash.

### 4. Act

Pause mails — one call each:
```
trash_message  messageId: <id>
```

Submission confirmations — label and archive atomically, one call each:
```
update_message_labels  messageId: <id>
  addLabelIds:    ["<id of the user label 'Guetesiegel'>"]
  removeLabelIds: ["INBOX"]
```

Resolve the label id with `list_labels` first — the API takes ids, not display names. In this
account `Guetesiegel` is `Label_2210398649724927123`, but **verify it, don't trust this file**;
if the label is missing, create it with `create_label`.

Archiving keeps the mail and its attachments fully searchable. Nothing is deleted.

### 5. Report

- counts per class, and the Kennzahlen/addresses of the trashed pause mails
- how many resume links the file now holds
- **Support tickets (step 1b), always its own section, even when empty:** per ticket the sender,
  the Schulkennzahl, the date, one line on what it wants, the GitHub issue number, and whether a
  reply draft exists. Anything time-critical goes first.
- every other mail you did not touch, with sender, subject, date and one line on what it wants

## The filter

Alex has a Gmail filter that already auto-trashes incoming pause mails
(`From: support@guetesiegel-bewegteschule.at` + `Has the words: jederzeit weitermachen` →
Delete it). Verified by behaviour on 2026-11-05: seven pause mails arrived and were in Trash
without anyone acting.

**This MCP connector cannot read or create Gmail filters** — the Gmail server here exposes only
message/thread/label/draft tools, nothing behind `gmail.settings.basic`. So never claim the
filter exists or does not; if a new auto-rule is wanted, hand Alex the click-path:
Settings → Filters and Blocked Addresses → Create a new filter.

Because the filter catches pause mails on arrival, step 3 may find nothing to save. That is the
healthy state, not a failure — but it also means **the links of auto-trashed mails were never
recorded**. To recover one, search with `includeTrash: true`.

## Never

- Never trash or archive a mail a school or a person wrote. Replies arrive with subject
  `AW: Gütesiegel „Bewegte Schule Österreich" – Einladung zur Teilnahme bis 11.12.2026` from
  `direktion.*@schule.wien.gv.at` and the like. They are support cases; route them through
  `gs-support-ticket` if they describe a defect.
- Never use `mark_message_spam`. It teaches Gmail that the platform's own sender is spam, and
  `support@guetesiegel-bewegteschule.at` is the From on every school mail.
- Never permanently delete. `trash_message` only.
- Never commit `antrag-links.tsv` or quote a resume URL anywhere but a reply to that school.
