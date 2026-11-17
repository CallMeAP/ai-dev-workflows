---
name: gs-prod-db-maintenance
description: Use when a correction has to be made to the live Gütesiegel database during a running award cycle — phrases like "maintenance window", "fix the plaque flag for school X", "void that invoice", "add the plaque after the fact", "run the prod SQL", "we need to change something in the prod db". Covers the whole loop: stop the API, download the SQLite file from Kudu, apply the writes to the copy, mint any invoice PDF by running the API locally against that copy, audit the running numbers, upload, restart, verify. Never writes to production directly.
---

# Gütesiegel production DB maintenance

Every correction a school asks for — plaque added, plaque removed, invoice voided,
billing address changed — is a hand-written statement against the live SQLite
database. There is no admin UI for any of it and no EF migrations; the schema comes
from `EnsureCreated()` alone.

**The agent never writes to production.** It prepares, verifies and audits. Uploading
to Azure and sending mail are the user's actions.

## The shape of the loop

Production is a single SQLite file in Azure App Service at
`C:\home\site\wwwroot\Guetesiegel.db`, reachable only through the Kudu debug console
(`https://<api-host>.scm.<region>.azurewebsites.net/DebugConsole`). So the procedure is
**download → change the copy → verify → upload**, never in-place SQL.

```
stop API → download → backup copy → apply writes → mint invoice via LOCAL API
         → audit numbers → diff vs pre-write copy → upload → restart → re-download → diff
```

The site is **down for the whole middle**. In a live cycle that is real lost
submissions, so prepare everything before stopping anything.

## Before you stop the API

Read the state first — these queries need no downtime.

```bash
gsq() { python3 -I -c '
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
[print(r) for r in c.execute(sys.argv[2])]' "$1" "$2"; }
```

Classify every affected school, because the action differs completely:

| State | What happens | Action |
|---|---|---|
| **paused**, flag wrong | invoice is minted at submission | flip the flag only — **free**, no number consumed |
| **submitted**, plaque missing | nothing re-triggers | flip the flag **and** mint the invoice by hand |
| **submitted**, plaque wrongly ordered | invoice already issued and mailed | clear all three columns — the number becomes a **permanent gap** |

A paused school is the cheap case and it **expires the moment they submit**. Mail them
"please do not submit yet" *first*, before any other work. That mail is more urgent
than the window itself.

## Stop the API

```bash
# az webapp stop --name <app> --resource-group <rg>
```

Then download `Guetesiegel.db` through Kudu.

**WAL:** the DB runs in `journal_mode=wal`. A clean shutdown checkpoints the WAL into
the main file, and Kudu then shows **no** `-wal`/`-shm` sidecars — confirm that in the
file listing (the `.db` filter matches `Guetesiegel.db-wal` too, so their absence is
real). If sidecars *are* present, the main file alone is an incomplete snapshot: take
them as well, or checkpoint first. On the way back, a stale `-wal` left beside a
replaced `.db` gets replayed over it — lost writes or an unopenable file.

Keep the untouched download as the rollback point, under a dated name, and never write
to it:

```bash
cp -a "$DL" "$DL.pre-writes-$(date +%F-%H%M)"
```

## Apply the writes to a working copy

One statement per school, each in its own transaction, committed only on
`rowcount == 1`:

```python
c = sqlite3.connect(DB, isolation_level=None)
c.execute("BEGIN")
n = c.execute(sql, args).rowcount
c.execute("COMMIT" if n == 1 else "ROLLBACK")
```

`WHERE SchuldatenId = '<guid>'` — **always the SchuldatenId from the state check, never
a Kennzahl.**

```sql
-- add the plaque
UPDATE Schuldaten SET IsPlaketteAusgewaehlt = 1 WHERE SchuldatenId = '…';

-- remove it before submission (no invoice exists yet)
UPDATE Schuldaten SET IsPlaketteAusgewaehlt = 0 WHERE SchuldatenId = '…';

-- void an issued invoice
UPDATE Schuldaten
SET IsPlaketteAusgewaehlt = 0, PlaketteRechnung = NULL, PlaketteRechnungLaufendeNummer = NULL
WHERE SchuldatenId = '…';
```

**Never write `PlaketteRechnung` or `PlaketteRechnungLaufendeNummer` by hand.** Set the
flag and let the application assign both.

### Before voiding: the reuse guard

The next number is `MAX + 1`, not a counter (`SubmissionService.GetNextPlaketteLaufendeRechnungsnummer:216-234`),
so a freed number is only dangerous when it is the **highest remaining** one:

```sql
SELECT MAX(s.PlaketteRechnungLaufendeNummer)
FROM Schuldaten s JOIN Submissions sub ON sub.SchuldatenId = s.SchuldatenId
WHERE s.PlaketteRechnungLaufendeNummer IS NOT NULL
  AND s.PlaketteRechnungLaufendeNummer NOT IN (<the numbers being freed>)
  AND CAST(strftime('%Y', sub.SubmissionDate) AS INTEGER) = <year>;
```

Must come back **greater than the highest number being freed**. If it does, voiding
mid-cycle is safe and does not have to wait for the cycle to close.

## Mint an invoice — run the API locally, never call production

Only for a school that **already submitted**. Run the real application against the
downloaded copy: same code, same numbering, production untouched.

```bash
cd <repo>/BewegteSchule.Guetesiegel.API          # CWD matters — see below
ASPNETCORE_ENVIRONMENT=Development \
ASPNETCORE_URLS=http://localhost:5199 \
SeedDatabaseOnStartup=false \
ConnectionStrings__Sqlite="Data Source=/abs/path/to/copy.db" \
dotnet run --no-launch-profile
```

Wait for `/health` → 200, then **confirm the boot changed nothing** (`md5sum` before and
after) before calling anything.

```bash
curl -sS -D headers.txt -o invoice.pdf \
  "http://localhost:5199/submission-pdf/submissions/<SubmissionId>/plaketten-rechnung"
grep -i content-disposition headers.txt     # the assigned filename
```

Four things that cost time if you get them wrong:

- **The route is `/submission-pdf/...`, not `/api/pdf/...`.** No controller carries an
  `/api` prefix (`Shared/Consts.cs:90`). A wrong path gives a 404 and no invoice.
- **`SeedDatabaseOnStartup` defaults to `true`** (`Program.cs:164`). On a populated DB
  `DbInitializer.Initialize` self-disables — it returns at
  `if (context.Schulkennzahlen.Any())` (`DbInitializer.cs:26-31`) and contains no
  `UPDATE` or `DELETE` — but set it to `false` rather than trust a single guard.
  `DbInitializerSchulennzahlen.Initialize` behind it has **no** existence check at all.
- **The CWD must be the API project directory.** The invoice template resolves through
  `Environment.CurrentDirectory` (`PlaketteRechnungPdfService.cs:79`).
- **Call strictly sequentially, one school at a time.** `MAX + 1` runs in no transaction
  and the column has no unique index, so concurrent calls silently mint duplicate
  numbers. `BaseController` also rate-limits to 10 requests / 5 s.

A **204 No Content** means the guard rejected it (`SubmissionPdfController.cs:88-93`):
sponsored cycle, or `IsPlaketteAusgewaehlt = 0` — i.e. your write did not land. Stop.

A second call for the same school writes nothing and returns the stored name
(`PlaketteRechnungPdfService.cs:60-64`), so retrying is safe. The flip side: a wrong
number can only be corrected by nulling both columns first.

**That guard does not check the Gütesiegel level.** A school at `KeinGuetesiegel` will
happily be given a number it must never be billed for. Mint only for the schools on
your list.

### No mail can escape

Nothing sends at startup and there is no background service; the only send is
`POST mail/submission/{id}`, which this procedure never calls. With
`ASPNETCORE_ENVIRONMENT=Development`, `MailService.cs:88-92` rewrites every recipient to
the dev mailbox anyway. Do not start the WASM frontend — `Uebersicht.razor.cs:115` posts
that route by itself.

## Audit before uploading

**Diff the written copy against the pre-write backup, every table.** The expected result
is exactly the rows you meant to touch and nothing else:

```python
a = {r[0]: r for r in before.execute(Q)}        # Q selects the columns you care about
b = {r[0]: r for r in after.execute(Q)}
diff = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
```

Then the running numbers — **always year-scoped**, because the series resets per
calendar year (#44):

```sql
SELECT strftime('%Y', sub.SubmissionDate) y, s.PlaketteRechnungLaufendeNummer n, COUNT(*) c
FROM Schuldaten s JOIN Submissions sub ON sub.SchuldatenId = s.SchuldatenId
WHERE s.PlaketteRechnungLaufendeNummer IS NOT NULL
GROUP BY y, n HAVING c > 1;          -- must return nothing
```

An unscoped check for a number or a gap **will produce false alarms** — `25_ERG_023_…`
and `26_ERG_023_…` are different invoices in different series. Verify per year:

- no duplicate within a year
- every filename's `yy`, `nnn` and Kennzahl match the row's columns and submission year
- no half-set row (one column set, the other `NULL`)
- every row carrying an invoice has `IsPlaketteAusgewaehlt = 1`
- the gaps are exactly the ones you intended

Finally `PRAGMA wal_checkpoint(TRUNCATE)`, `PRAGMA integrity_check`,
`PRAGMA foreign_key_check`, and delete the `-wal`/`-shm` so a single consistent file
goes up.

## Upload, restart, verify

Upload the file, restart the API, confirm `/health` → 200 and the frontend loads.

**Then download once more and diff against what you uploaded.** Identical checksums
prove the upload landed. Nothing else does — no endpoint exposes these columns, and the
one call that would (the invoice endpoint) is only read-only *if* the upload succeeded;
if it did not, that same call mints a number against stale data.

Keep both backups until that diff passes.

## Afterwards

- Mail each school. A manually minted invoice is **not** sent by anything — the school
  learns nothing until you send it. Drafts only; see `gs-support-ticket` conventions:
  reply on the original thread, Sigi (`skai@ms-taiskirchen.at`) and Peter Klein
  (`peter.klein@bewegteschule.at`) on Cc, the user sends.
- Do not promise a number to a school that has not submitted — theirs is minted at
  submission and other paused schools are in the queue.
- Record on the issue what each step actually returned: the state check, the counter
  before and after, the diff result, the number audit. Close it.

## Never

- Never run the `UPDATE`s against production directly, and never upload a file whose
  diff you have not read.
- Never write a running number or an invoice filename by hand.
- Never call the **production** invoice endpoint to "check" something — it is a write.
- Never invent address data to satisfy a `NOT NULL` column. `PlaketteRechnungAnschriften`
  requires `Name`, `City`, `Zip` (1000–9999), `Street`, `HouseNumber`; if the ticket
  names only a recipient, ask the school (see #105).
- Never bundle an unconfirmed correction into a window. A school's own written statement
  of its Schulkennzahl is the bar; an inference from a send timestamp is not.
