---
name: gs-inbox-cleanup
description: Use when the Gütesiegel platform mails have piled up in Alex's Gmail inbox and should be sorted — phrases like "clean up my inbox", "cleanup my gmail like yesterday", "trash the pause and speichern mails", "archive the submissions", "my inbox is full of bewegte schule mails". Classifies the automated mails from support@guetesiegel-bewegteschule.at by BODY text, saves each school's resume link before trashing the pause mails, labels + archives the submission confirmations, and never touches a mail a school actually wrote.
---

# Gütesiegel inbox cleanup

Sorts the automated mails the Gütesiegel platform Bccs to `pittrichalex@gmail.com` during a
live award cycle. In a running cycle this is a few hundred mails — 591 schools were invited
for the 2026 NÖ/Wien cycle alone — so the inbox stops being usable without this.

**Runs with full autonomy** (Alex's decision, 2026-11-05): apply the matrix below to every
matching mail without asking. Report what moved at the end.

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
- every mail you did not touch, with sender, subject, date and one line on what it wants —
  these are the ones Alex has to answer
- how many resume links the file now holds

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
