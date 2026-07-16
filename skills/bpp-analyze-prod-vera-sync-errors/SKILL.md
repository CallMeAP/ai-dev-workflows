---
name: bpp-analyze-prod-vera-sync-errors
description: Use when the user provides a prod-DB CSV export of bpp-vera-connector `third_party_sync_histories` (nightly sync ran with errors) and asks to triage — "are these errors on our side or on external VERA API side?", night-sync error analysis, error buckets, "could not resize shared memory segment", D0005 documentType, "konnte nicht hochgeladen werden".
---

# bpp-analyze-prod-vera-sync-errors

## Overview

Triages a prod export of `third_party_sync_histories` (`sync_status = 'synced_with_errors'`) from bpp-vera-connector into per-bucket verdicts (our-side / VERA-side / boundary), diffs against the known baseline, and hands back ready-made prod SQL for deeper digging. **Prod DB is never directly reachable — craft SQL, the user runs it and returns CSVs.** For schema guidance use the local vera-connector DB via `bpp-connect-local-db`.

## When to Use

- User drops a CSV like `~/Downloads/data-*.csv` from prod `third_party_sync_histories` and asks who's at fault / what broke last night.
- Nightly-sync regression checks after a fix deploy ("did D0005 go to 0?").

Not for: fixing the bugs found (normal dev flow / `bpp-create-mr`), local single-sync debugging (read service logs instead).

## Input Format

Export should be `SELECT *` rows; the payload column is `error_details_json_data` — a **JSON array** per row, fields: `syncStep`, `errorType`, `errorMessage`, scope IDs (`customerId`/`documentId`/`contractId`/`claimId`/`riskId`/`personId`), `userId`. One row = one sync run with possibly many error entries → **always report both counts: error entries AND distinct sync runs.**

## Step 1 — Parse + bucket

```python
import csv, json, re, collections
csv.field_size_limit(10**8)  # error_details_json_data rows can be huge
buckets = collections.Counter(); runs = collections.defaultdict(set)
SIGS = [  # first match wins — order matters: bpp-file BEFORE vera-500 (its messages also contain "Status: 500")
    ("shm-53100",       r"could not resize shared memory segment"),
    ("d0005-doctype",   r"D0005|documentType.*not valide"),
    ("bpp-file-500",    r"ConnectorBppFileApiException|unerwarteter Fehler|bpp-file"),
    ("vera-500",        r"Status: 500(?![0-9])"),
    ("stale-404",       r'"errorCode":"(C0001|P0001|CLAIM0001)"'),
    ("vera-401",        r"Status: 401"),
    ("vera-cd0002",     r"CD0002"),
    ("vera-conn-reset", r"Broken pipe|Error while copying content to a stream"),
    ("upload-wrapper",  r"konnte nicht hochgeladen werden"),
    ("multipart-quote", r"ArgumentException.*format of value|Content-Disposition"),
    ("dto-validation",  r"ValidationException|muss zwischen"),
]
for row in csv.DictReader(open(CSV_PATH)):  # CSV_PATH = the user-provided export
    for e in json.loads(row["error_details_json_data"] or "[]"):
        msg = e.get("errorMessage") or ""
        key = next((k for k, p in SIGS if re.search(p, msg)), "UNMATCHED")
        buckets[key] += 1; runs[key].add(row["id"])
```

Manually read a sample of every `UNMATCHED` entry — new buckets are the whole point. Also compute: (a) **per-night split** — an export window is 24h wall-clock and can contain stragglers of the previous night's run; group by night (`sync_started_at` shifted −12h) before any baseline comparison; (b) **shm-only runs** — runs whose entries are ALL shm-53100; that's the count that vanishes once the shm fix lands (forecast: total runs − shm-only runs).

## Signature Table — verdicts

| Bucket | Verdict | Meaning / action |
|---|---|---|
| `shm-53100` | **OUR infra** | Postgres `/dev/shm` (64MB default) exhausted by parallel-query DSM segments. The EF wrapper `InvalidOperationException … transient failure` is **misleading** — not transient, not app-side. Fix: Portainer `shm_size: 1gb` or `ALTER DATABASE … SET max_parallel_workers_per_gather = 0` (BRO-1033). |
| `d0005-doctype` | **Boundary (our labels)** | Our hardcoded German documentType vs mandant-configurable VERA catalog (`GET 2.0/document/documentType`, labels truncated at 40 chars). **Fixed 2026-07-16** (vera !69: catalog gate + remaps) → expect 0. If it reappears: new mandant catalog mismatch; the gate's skip error names the rejected label + full catalog. |
| `vera-500` | **VERA-side** | Empty-body 500s on GETs (customer/contracts, document). Collect endpoint + external ID + timestamp lists for the VERA support report. |
| `stale-404` | **VERA-side (stale objects)** | C0001/P0001/CLAIM0001 "Object not found" — our stored VERA IDs no longer exist there. Reconciliation topic, not a code bug. |
| `vera-401` | **VERA-side (permissions)** | Mandant permission config; historically a single customer/claim. |
| `vera-cd0002` | **VERA-side** | VERA's own "unexpected error" on document POST. |
| `vera-conn-reset` | **Boundary/transient** | Socket drop mid multipart upload (broken pipe). One-offs — monitor, don't chase. |
| `bpp-file-500` | **OUR (bpp-file)** | Grab the `requestId` from the message → pull bpp-file prod logs. |
| `upload-wrapper` | **OUR (diagnostic gap)** | `VeraDocumentBaseSyncService` skip-wrapper **swallows the root cause** (Debug-only logs, prod = Info) — unclassifiable from the CSV; note count, don't guess. |
| `multipart-quote` | **OUR bug (open)** | `"` in filename breaks `MultipartFormDataContent` Content-Disposition. |
| `dto-validation` | **OUR data quality** | Source values out of range (Baujahr, Geburtsdatum, …). |

## Step 2 — Diff vs baseline (as of 2026-07-16, per night; units = entries / runs)

Steady noise floor — don't panic-report: vera-500 ~150/~140, stale-404 ~65/~45, upload-wrapper ~105/~60, bpp-file-500 ~15/~13 ⇒ ≈ **265 non-shm failed runs/night** total. Deviations to flag: `shm-53100` (was ~305/~290 per night 2026-07-13→16; should VANISH once the BRO-1033 shm fix lands — nonzero after = escalate), `d0005-doctype` (fixed by vera !69, deployed to prod 2026-07-16 → must be 0; **compare the export's night against the deploy date before calling it a regression**), any `UNMATCHED`, or a step-change in a steady bucket. `MaxConcurrentSyncs` on main is 10 since 2026-07-16 (was 20) — a run-count drop after that date can be pacing, not healing.

## Step 3 — Prod SQL helpers (hand to user, never run yourself)

Night timeline per bucket:

```sql
SELECT sync_started_at::date AS night, COUNT(*) AS failed_runs,
       COUNT(*) FILTER (WHERE error_details_json_data::text LIKE '%could not resize shared memory segment%') AS shm_runs,
       COUNT(*) FILTER (WHERE error_details_json_data::text LIKE '%D0005%') AS d0005_runs
FROM third_party_sync_histories
WHERE sync_status = 'synced_with_errors' AND error_details_json_data IS NOT NULL
  AND sync_started_at >= now() - interval '30 days'
GROUP BY 1 ORDER BY 1;
```

Hour histogram (swap the date filter): `GROUP BY date_trunc('hour', sync_started_at)`. Raw dump: `SELECT * FROM third_party_sync_histories WHERE sync_status='synced_with_errors' AND error_details_json_data IS NOT NULL ORDER BY created_at DESC LIMIT 600;`

Affected tenant/GoUser (+ VERA creds for read-only e2e repro — **redact every credential value in your output**):

```sql
SELECT gu.id, gu.login_email, t.id AS tenant_id, t.tenant_name,
       tesl.vera_username, tesl.vera_api_key, gesl.vera_user_token
FROM go_users gu
LEFT JOIN tenants t ON t.id = gu.tenant_id
LEFT JOIN tenant_external_services_links tesl ON tesl.tenant_id = t.id AND tesl.is_soft_deleted = false
LEFT JOIN go_user_external_services_links gesl ON gesl.go_user_id = gu.id AND gesl.is_soft_deleted = false
WHERE gu.id = '<userId from error entry>';
```

## Step 4 — Report

User's style: 1-sentence summary → bucket table (bucket, entries, runs, verdict, 1-line reasoning) → delta vs baseline (NEW/changed buckets first) → one clear next action. Include ID lists (external VERA IDs, endpoints, timestamps) for VERA-side buckets so a support report can be assembled without re-parsing. **ID extraction:** the external VERA ID is NOT always in `errorText` — P0001 carries it (`Object not found: {id}`), but C0001 is a generic sentence; parse the endpoint tag instead: `\[VERA API: GET 2\.0/(customer|contract|document|claim)/([^/\]]+)`. Note that per-bucket run sets overlap (one run holds many buckets) — never sum bucket runs to a total.

## Common Mistakes

- **Trusting "transient failure"** — the EF wrapper text lies; grep the inner message for `shared memory segment` first.
- **Counting rows instead of entries** (or vice versa) — report both, they diverge wildly (e.g. 4 runs = 115 D0005 entries).
- **Skipping `csv.field_size_limit`** → `_csv.Error: field larger than field limit`.
- **Reporting the steady VERA noise floor as a regression** — diff against the baseline table first.
- **Guessing root causes for `upload-wrapper` entries** — the cause is swallowed; say so.
- **Printing credential values** from the creds query → always redact.

## Red Flags — STOP

- About to connect to / query the prod DB yourself → STOP, hand SQL to the user.
- CSV has no `error_details_json_data` column → wrong export; ask for `SELECT *`.
- About to echo `vera_password` / `vera_api_key` / `vera_user_token` values → STOP, redact.
- `UNMATCHED` bucket non-empty and you're about to ignore it → STOP, read samples, name the new bucket.
