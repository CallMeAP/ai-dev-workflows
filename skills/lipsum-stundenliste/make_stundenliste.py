#!/usr/bin/env python3
"""Build a Stundenliste .xlsx from Kimai timesheets (Kimai UI export layout).

Usage: make_stundenliste.py --month 2026-06 --out /home/alex/Downloads/Rechnung-000043_Stundenliste.xlsx
       make_stundenliste.py --begin 2026-06-01 --end 2026-07-31 --out ...
"""
import argparse, datetime as dt, json, urllib.parse, urllib.request
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

BASE = "https://times.lipsum.services/api"
TOKEN_FILE = "/home/alex/kimai.token"

HEADERS = ["Date", "From", "To", "Duration", "Name", "User", "E-mail",
           "Staff number", "Customer", "Project", "Activity", "Description", "Billable"]
# Column widths are auto-fitted from content (see fit_width) - the Kimai export
# sizes them per month, so the Project/Description columns differ every time.
# Google-Sheets palette, assigned to project groups in order of appearance.
PALETTE = ["FFD966", "B4A7D6", "9FC5E8", "DD7E6B", "B6D7A8", "A2C4C9",
           "F9CB9C", "D5A6BD", "C9DAF8", "EA9999", "D9EAD3", "D9D2E9"]
HEADER_FILL = "EEEEEE"
TOTAL_FILL = "6AA84F"      # Rechnung-000042 used this; 000039/000041 used 93C47D
MIN_WIDTH, MAX_WIDTH = 5.0, 65.0


def fit_width(header, values):
    """Approximate the Kimai export's auto-fit width for one column.

    Calibrated against Rechnung-000039/000041 (untouched auto-fit files); within
    ~1 character. Exact replication would need PhpSpreadsheet's font metrics.
    """
    longest = 0
    for v in values:
        if isinstance(v, dt.datetime):
            n = len("2026-08-07")
        elif isinstance(v, dt.timedelta):
            n = len("03:30")
        elif isinstance(v, bool):
            n = len("TRUE")
        elif v is None:
            n = 0
        else:
            n = max((len(line) for line in str(v).split("\n")), default=0)
        longest = max(longest, n)
    w = max(len(header) * 1.02, longest * 0.79) + 0.5
    return round(min(max(w, MIN_WIDTH), MAX_WIDTH), 2)


def api(path):
    req = urllib.request.Request(BASE + path, headers={
        "Authorization": "Bearer " + open(TOKEN_FILE).read().strip()})
    with urllib.request.urlopen(req, timeout=60) as f:
        return json.load(f)


def fetch(begin, end):
    """All timesheets of the authenticated user in [begin, end], oldest first.

    full=true expands user/project/customer/activity inline. Do NOT fetch
    /projects/{id} instead - that endpoint returns 403 for this API token, and
    the /projects list silently omits projects whose contract period has ended.
    """
    rows, page = [], 1
    q = urllib.parse.urlencode({"begin": f"{begin}T00:00:00", "end": f"{end}T23:59:59"})
    while True:
        chunk = api(f"/timesheets?size=100&page={page}&full=true&{q}")
        rows += chunk
        if len(chunk) < 100:
            break
        page += 1
    rows.sort(key=lambda t: t["begin"])
    return [{
        # Excel cannot store tz-aware datetimes; Kimai already returns local time.
        "begin": dt.datetime.fromisoformat(t["begin"]).replace(tzinfo=None),
        "end": dt.datetime.fromisoformat(t["end"]).replace(tzinfo=None) if t.get("end") else None,
        "duration": t.get("duration") or 0,
        "customer": (t["project"]["customer"] or {}).get("name", ""),
        "project": t["project"]["name"],
        "activity": (t.get("activity") or {}).get("name", ""),
        "description": t.get("description") or "",
        "billable": bool(t.get("billable")),
        "user": t["user"],
    } for t in rows]


def build(entries, out_path, user, total_fill=TOTAL_FILL):
    # Groups alphabetical by project; rows inside a group by date ascending.
    groups = sorted({e["project"] for e in entries}, key=str.casefold)
    colors = {p: PALETTE[i % len(PALETTE)] for i, p in enumerate(groups)}

    wb = Workbook()
    ws = wb.active
    ws.title = "Sheet1"
    thin = Side(style="thin")

    ws.append(HEADERS)
    for c in ws[1]:
        c.font = Font(bold=True, size=12)
        c.fill = PatternFill("solid", fgColor=HEADER_FILL)
        c.border = Border(bottom=thin)

    row = 2
    for proj in groups:
        fill = PatternFill("solid", fgColor=colors[proj])
        for e in sorted((e for e in entries if e["project"] == proj), key=lambda e: e["begin"]):
            ws.append([
                e["begin"], e["begin"].strftime("%H:%M"),
                e["end"].strftime("%H:%M") if e["end"] else "",
                dt.timedelta(seconds=e["duration"]),
                user["alias"], user["username"], user["email"], user.get("accountNumber"),
                e["customer"], proj, e["activity"], e["description"], e["billable"],
            ])
            for c in ws[row]:
                c.fill = fill
                c.font = Font(size=12)
            ws.cell(row, 1).number_format = "yyyy-mm-dd"
            ws.cell(row, 4).number_format = "[hh]:mm"
            row += 1

    total = ws.cell(row, 4, f"=SUBTOTAL(9,D2:D{row - 1})")
    total.number_format = "[hh]:mm"
    for col in range(1, len(HEADERS) + 1):
        c = ws.cell(row, col)
        c.fill = PatternFill("solid", fgColor=total_fill)
        c.font = Font(bold=True, size=12)
    ws.cell(row, 1).number_format = "yyyy-mm-dd"

    for i, head in enumerate(HEADERS, 1):
        col = get_column_letter(i)
        ws.column_dimensions[col].width = fit_width(
            head, [ws.cell(r, i).value for r in range(2, row)])
    ws.auto_filter.ref = f"A1:{get_column_letter(len(HEADERS))}1"
    wb.save(out_path)
    return row - 2, sum(e["duration"] for e in entries)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--month", help="YYYY-MM")
    ap.add_argument("--begin")
    ap.add_argument("--end")
    ap.add_argument("--out", required=True)
    ap.add_argument("--total-color", default=TOTAL_FILL,
                    help="fill of the SUBTOTAL row (default %(default)s; 93C47D also seen)")
    a = ap.parse_args()
    if a.month:
        y, m = map(int, a.month.split("-"))
        begin = dt.date(y, m, 1)
        end = dt.date(y + (m == 12), m % 12 + 1, 1) - dt.timedelta(days=1)
    else:
        begin, end = dt.date.fromisoformat(a.begin), dt.date.fromisoformat(a.end)

    entries = fetch(begin.isoformat(), end.isoformat())
    if not entries:
        raise SystemExit(f"no timesheets between {begin} and {end} - nothing written")
    user = entries[0]["user"]
    n, secs = build(entries, a.out, user, a.total_color)
    print(f"{a.out}: {n} rows, {secs / 3600:.2f} h, {begin}..{end}")


if __name__ == "__main__":
    main()
