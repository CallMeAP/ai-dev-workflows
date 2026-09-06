---
name: lipsum-stundenliste
description: Use when building the hour list (Stundenliste) that goes out with an invoice from Kimai time entries — phrases like "Stundenliste für August", "hour list for the invoice", "Stundenliste erstellen", "Rechnung-0000XX_Stundenliste.xlsx", "export my hours as excel for billing". Produces the Kimai-export xlsx layout grouped and colour-coded by project with a SUBTOTAL row.
---

# lipsum-stundenliste

## Overview

Builds `Stundenliste.xlsx` — the hour list attached to an invoice — straight from the Kimai
API, in the exact layout of a Kimai UI export, plus the manual post-processing the user
otherwise does by hand: rows grouped by project, each group filled with its own colour, and a
green bold `SUBTOTAL` row at the bottom.

Run the script. Do not rebuild the layout by hand.

```bash
python3 ~/.claude/skills/lipsum-stundenliste/make_stundenliste.py \
  --month 2026-08 --out /home/alex/Downloads/Rechnung-000042_Stundenliste.xlsx
```

`--begin YYYY-MM-DD --end YYYY-MM-DD` instead of `--month` for a custom range.
The script exits non-zero and writes nothing when the range has no time entries.

## Layout contract

Reproduce these exactly — they are what the user's manual files look like.

| Element | Value |
|---|---|
| Sheet name | `Sheet1` |
| Columns A–M | Date, From, To, Duration, Name, User, E-mail, Staff number, Customer, Project, Activity, Description, Billable |
| Column widths | auto-fitted from content (`fit_width`) — Kimai sizes them per month, so Project/Description differ every time; never hardcode one month's widths |
| Header row | bold, size 12, fill `EEEEEE`, thin bottom border, autofilter `A1:M1` |
| `Date` (A) | real datetime, number format `yyyy-mm-dd` |
| `From`/`To` (B, C) | strings `HH:MM` |
| `Duration` (D) | real `timedelta`, number format `[hh]:mm` |
| `Staff number` (H) | empty (Kimai `accountNumber` is null) |
| Total row | one row below the last entry, `=SUBTOTAL(9,D2:D<last>)` in D, bold, whole row filled. Fill defaults to `6AA84F` (Rechnung-000042); `Rechnung-000039`/`000041` used `93C47D` — override with `--total-color` |
| Font | Calibri 12 throughout |

## Grouping and colour rules

- **Groups:** one block per project, **alphabetical** by project name (case-insensitive).
- **Rows inside a group:** date ascending.
- **Colour:** palette assigned **in group order**, not pinned to a project name — the same
  project can get a different colour in a different month. Palette:
  `FFD966, B4A7D6, 9FC5E8, DD7E6B, B6D7A8, A2C4C9, F9CB9C, D5A6BD, C9DAF8, EA9999, D9EAD3, D9D2E9`.

## Kimai API gotchas

These are the ones that actually break the export:

- **Use `full=true` on `/api/timesheets`.** It expands user, project, customer and activity
  inline in one call.
- **Never resolve entities via `/api/projects/{id}`** — that returns **403** for this API
  token, even though the list endpoint works.
- **`/api/projects` silently omits projects whose contract period has ended.** August 2026
  used projects 2 and 21, neither of which the list returns; `ignoreDates=1` brings them back.
  `full=true` sidesteps the problem entirely.
- **Strip `tzinfo`** from Kimai datetimes — openpyxl raises
  `TypeError: Excel does not support timezones in datetimes`. Kimai already returns local time.
- Auth is `Authorization: Bearer <token>`; token file `/home/alex/kimai.token`. See the
  `kimai-instance` memory.

## Verifying a generated file

Regenerate a month the user already built by hand and compare — content must match
order-insensitively. Expected cosmetic differences: group order, group colours, the
total-row green, and column widths within ~2 (column B lands ~1.9 narrow; the real export's
metrics are not reproducible without PhpSpreadsheet's font tables).

Verified: 2026-06, 2026-07 and 2026-08 all reproduce the manual files' rows and sums exactly.

```bash
python3 - <<'PY'
from openpyxl import load_workbook
import datetime as dt
def rows(p):
    ws = load_workbook(p)['Sheet1']
    return ([tuple(ws.cell(r, c).value for c in range(1, 14))
             for r in range(2, ws.max_row) if ws.cell(r, 1).value],
            ws.cell(ws.max_row, 4).value)
a, ta = rows('reference.xlsx')
b, tb = rows('generated.xlsx')
print(len(a), len(b), sorted(map(str, a)) == sorted(map(str, b)), ta, tb)
print(sum((r[3] for r in a), dt.timedelta()), sum((r[3] for r in b), dt.timedelta()))
PY
```

## Common mistakes

- Writing `Duration` as a float of hours — it must be a `timedelta` with `[hh]:mm`, or the
  `SUBTOTAL` row shows a number instead of `76:45`.
- Putting the total in the last data row instead of one row below it.
- Colouring only column A instead of the whole row A–M.
- Uploading the finished file to Google Drive through the Drive MCP `create_file` tool — the
  base64 payload passes through the model and gets corrupted. Hand the file over locally.
