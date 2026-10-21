---
name: bpp-vera-keyword-audit
description: Use when re-running the VERA keyword / mapper audit of bpp-vera-connector across all BPP tenants with VERA access — phrases like "re-run vera keyword audit", "new tenant has vera", "audit vera mappers", "check vera catalogs for all tenants", "do the vera mappers still cover every catalog". Involves LIVE PROD VERA reads with per-tenant prod credentials.
---

# bpp-vera-keyword-audit

## Overview

Collects every tenant's VERA product catalog plus a contract/doctype/enum inventory **read-only from PROD VERA**
(one GoUser credential set at a time, swapped into the main checkout), then lets a workflow measure the real
mapper code against all of it and implement fixes in worktrees. Prod is involved and every row of `creds.csv`
is a prod secret: **the gates of `bpp-vera-prod-read-e2e` apply to every step that touches VERA.**

**REQUIRED SUB-SKILL:** `bpp-vera-prod-read-e2e` (write-gate preflight, main-checkout-only, user's go, never commit creds).
Also: `bpp-start-local-stack` (Postgres, Redis), `workflow-authoring` (how to launch the workflow script).

Support files (this directory; invoke through the interpreter):

| File | What |
|---|---|
| `vera-tenant-creds.sql` | PROD query: one row per GoUser with a VERA token, per tenant (`idx`, `tenant_idx`, `user_idx`, creds) |
| `vera-audit.sh` | driver: `preflight`, `run-all`, `run <idx> [1]` (updates `results.tsv`), `refetch <idx>`, `check-fingerprints`, `manifest`, `swap`, `restore` |
| `../bpp-vera-prod-session/vera-session.sh` | sourced by `vera-audit.sh`: preflight, swap, restore, build, smoke, App start/stop, rate-limited `get` (single-tenant runs: skill `bpp-vera-prod-session`) |
| `vera-keyword-audit.workflow.js` | analyze -> verify -> implement (TDD) -> review; args below |
| `leak-scan.py` | scans a git range for tenant names / cred values from `creds.csv`, prints only column + file:line |

Fixed paths: main checkout `/home/alex/Entwicklung/bpp/bpp-vera-connector`, audit dir `~/Downloads/.vera-audit`
(`creds.csv`, `out/results.tsv`, `out/row-<idx>/`, `out/manifest.json`, `logs/`, consts backup).

## Steps

**1. Credentials (user).** The user runs `vera-tenant-creds.sql` against PROD and exports CSV **with header** to
`~/Downloads/.vera-audit/creds.csv`, then `chmod 600`. The agent never opens, cats or greps it; it checks
only shape:

```bash
python3 -I -c 'import csv,sys;r=list(csv.DictReader(open(sys.argv[1])));print(list(r[0].keys()) if r else "EMPTY",len(r),"rows",len({x["tenant_idx"] for x in r}),"tenants")' ~/Downloads/.vera-audit/creds.csv
```

**2. Preflight + stack + go.** `bash ~/.claude/skills/bpp-vera-keyword-audit/vera-audit.sh preflight` must print
`EnableWriteAccess=False VeraWriteTestsEnabled=False (appsettings.local.json: False/False)`: both gates **explicitly
false in `appsettings.local.json`** (a default from `appsettings.json` is refused), env forced to `local`, no env
override. `appsettings.local.json` points `Vera` at PROD, the mTLS cert is in place (VERA PROD needs no VPN).
Start Postgres + Redis (`bpp-start-local-stack`). Show the user preflight output + row/tenant counts + the command of
step 3 and wait for an explicit go for this prod run.

**3. run-all (background).** `run-all` refuses while `out/` holds row dirs of an earlier audit (row idx shift when GoUsers
are added): first `mv out out.<date>; mv logs logs.<date>` in the audit dir. Then
`mkdir -p ~/Downloads/.vera-audit/logs && bash ~/.claude/skills/bpp-vera-keyword-audit/vera-audit.sh run-all > ~/Downloads/.vera-audit/logs/run-all.log 2>&1`
with `run_in_background`; do not poll, wait for the exit notice. Per row: swap creds -> build -> Phase1 smoke
(retried once after `RETRY_WAIT`, then the row is marked `smoke-failed` and skipped) -> catalog fingerprint; the first
green user of each tenant also gets the inventory. Observed pace ~1 min/row. Consts are restored on exit and abort.
Rate limits are env vars on the same command line:

| Var | Default | Effect |
|---|---|---|
| `MIN_INTERVAL_MS` | 1500 | min gap between two VERA GETs (across rows) |
| `MAX_RETRIES` / `BACKOFF_BASE` / `BACKOFF_MAX` | 3 / 5 / 120 | backoff on 429/5xx/timeout, honours `Retry-After` |
| `ROW_COOLDOWN` / `SMOKE_COOLDOWN` | 15 / 10 | pause between rows / after smoke |
| `MAX_CALLS_PER_ROW` / `MAX_CALLS_TOTAL` | 200 / 6000 | hard budgets on probe GETs; total aborts the run before the next row |
| `RETRY_WAIT` | 30 | wait before the smoke retry |

Many 429s in `logs/http-backoff.log` -> raise `MIN_INTERVAL_MS` and `ROW_COOLDOWN`, re-run; never lower them mid-audit.

**4. check-fingerprints.** `bash .../vera-audit.sh check-fingerprints`. Exit 1 (users of one tenant see different
catalogs) -> **STOP, report the T<idx>/row groups to the user, do not build a manifest**: the "audit one user per
tenant" premise is broken. Exit 2 (unverified rows) -> `run <idx>` those rows (updates `results.tsv`, restores consts), re-check.

**5. Refetch short samples.** `bash .../vera-audit.sh manifest` flags `SHORT` (returned + skipped is >= 10 below
min(total, 2000)) and `MISSING`. For each: `bash .../vera-audit.sh refetch <row>` (swaps, builds, inventory only,
restores). For a MISSING tenant use `run <idx> 1` on a green row. Same gates and go as step 2.

**6. manifest.** Re-run `manifest` until no `SHORT`/`MISSING`; exit 0 writes `out/manifest.json` (one row per
tenant, `same_catalog_as_tenant` = earlier tenant with the identical fingerprint).

**7. Workflow.** Target worktrees = the open MR(s) the user names (keyword mappers -> `w153`, catalog lookup ->
`w154`; one MR -> pass only `w153`). If none: `git worktree add` off `origin/development` with new branches. Run
`vera-keyword-audit.workflow.js` with args
`{manifest, w153, branch153, w154?, branch154?, out, handover?, ticket?}` (`out` = a reports dir outside the repos;
`handover` = the track dir whose `RESUME.md` holds earlier business decisions). The workflow runs with interactive
questions OFF and returns `decisions` and `signoff` lists per area.

**8. Verify.** Per worktree `dotnet test BPP.VeraConnector.NET/BPP.VeraConnector.NET.Vera.Tests` (exact counts).
Combined: temp worktree off `origin/development`, merge both branches, same test run, remove the worktree. Then
`python3 -I ~/.claude/skills/bpp-vera-keyword-audit/leak-scan.py <worktree> origin/development..HEAD` on each
(must say `0 hit(s)`; a hit names column + file:line only). Push / MR description / MR notes only as far as the
user authorized, via `bpp-create-mr` conventions.

**9. Cleanup + report.** `cmp -s ~/Downloads/.vera-audit/VeraDebugTestConsts.cs.orig /home/alex/Entwicklung/bpp/bpp-vera-connector/BPP.VeraConnector.NET/BPP.VeraConnector.NET.Vera/Consts/VeraDebugTestConsts.cs && echo restored`
(`swap` alone does not restore: always follow it with `restore`)
(the script restores it; never print either file). Delete `creds.csv` only when the user says the audit is done. Report:
tenants/catalogs/rows (counts, T<idx> only), per-area verdicts, **Decisions taken automatically**, and the
**needs business sign-off** list.

## Red Flags - STOP

| About to... | Why it is wrong |
|---|---|
| run the smoke / `dotnet test` / a swap by hand in a worktree | the script always works on the main checkout; a worktree run seeds swapped prod creds into the shared DB (GlobalTestSetup) |
| run with a write gate only defaulted to false | preflight demands explicit `false` in `appsettings.local.json`; a default can flip with a merge |
| cat / grep / print `creds.csv`, the consts file or the backup | prod secrets; shape checks via python only, `leak-scan.py` prints no values |
| put a tenant name in code, tests, commits, reports, MR text | tenants are `T<idx>` in reports and absent from code |
| add salutation-like free-text fields (Anrede, Briefanrede, names) to the inventory `ENUM_KEYS` | they carry customer names; enum_values must stay value counts of real enums |
| build the manifest after a fingerprint mismatch | one representative user per tenant is then unproven; stop and report |
| edit `vera-audit.sh` or `vera-session.sh` while it runs | bash reads scripts lazily; write a new file, then `mv` it over the old one |
| re-run without the user's go because "the last audit was approved" | a go covers one prod run |

## Lessons learned

- **VERA contract search returns a deterministic 500 for a whole page when a single record in it is broken.** Retries
  do not help; the inventory re-reads that page in tens and logs skipped tens to `logs/skipped-<idx>.log`.
- **`local a=$1 b=$a` is a bash trap:** `$a` expands before `a` is assigned (it sees the outer/empty value). Split
  into two `local` statements.
- **The consts backup captures whatever creds were in the file at backup time** (taken once). A swap left in place by
  a killed run becomes the "original". `run-all` now refuses when backup and consts differ; resolve by hand
  (`git diff` of the consts, ask the user) before deleting the stale backup.
- Earlier business decisions (which product line maps to which ContractProductType) live in the handover `RESUME.md`
  of the track, not in this skill; pass it as `handover`.
