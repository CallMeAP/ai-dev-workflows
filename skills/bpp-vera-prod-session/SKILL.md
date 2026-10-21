---
name: bpp-vera-prod-session
description: Use when one tenant's or broker's VERA PROD credentials must go into the bpp-vera-connector main checkout to read live VERA data — phrases like "switch vera creds to tenant", "use vera creds of broker", "vera prod poll for customer", "read-only vera prod check", "pull this customer from VERA prod", "which creds are swapped in", "restore vera creds". Applies whenever a prod SQL result gives a tenant_id or go_user_id and live VERA data for it is needed.
---

# bpp-vera-prod-session

## Overview

One script swaps a single `creds.csv` row into `VeraDebugTestConsts.cs` of the **main checkout**, builds, runs
the Phase1 smoke, optionally starts the App and fires **GET-only** polls at its debug read routes, then **always**
restores the original consts and rebuilds. The agent never sees a credential value: every cred touch happens
inside the script's python, which prints ids, tenant name and booleans only.

**REQUIRED SUB-SKILL:** `bpp-vera-prod-read-e2e` (write gates, main checkout only, user's go per run, never commit
creds). Also `bpp-start-local-stack` (Postgres, Redis). Fleet-wide catalog runs: `bpp-vera-keyword-audit`, whose
`vera-audit.sh` sources the shared functions from this script.

**Violating the letter of these gates is violating the spirit of them.**

## Inputs

- `~/Downloads/.vera-audit/creds.csv` (mode 600): exported by the user with
  `~/.claude/skills/bpp-vera-keyword-audit/vera-tenant-creds.sql`. The user deletes it. Never open it.
- Selector `<sel>`, taken from a prod SQL result:

| You have | Pass | Picks |
|---|---|---|
| `go_users.id` (a broker) | the UUID | that broker's row |
| `tenants.id` | the UUID | the tenant's oldest broker (`user_idx=1`) |
| a report's `T<n>` | `T<n>` | same as tenant_id |
| a `creds.csv` row number | `<idx>` | that row |

  No match or ambiguous -> abort. A broker missing from the export -> the user re-exports.
- Paths file (optional): one request per line, `GET /api/debug/vera/<route>[?query]`; `#` comments allowed.
  `bash vera-session.sh routes` lists the allowed GET routes and the derived write-route denylist.

## Steps

`S=~/.claude/skills/bpp-vera-prod-session/vera-session.sh`

1. `bash $S resolve <sel>`: confirm the row (idx, tenant name, go_user_id) with what the task needs.
2. `bash $S poll --dry-run <paths>`: every line must say `ALLOW` (no network).
3. `bash $S preflight`: every flag must be `True`. Start the local stack. Show the user the preflight line, the
   resolved row and the exact `use` command, then **wait for an explicit go and VPN up**. A go covers one run.
4. `bash $S use <sel> [<paths>]` with `run_in_background`. Smoke red -> abort + restore (VPN, cert, or creds).
   Output: `~/Downloads/.vera-audit/session/out/<ts>-row<idx>/NN-<route>.json`; logs in `.../session/logs/`.
5. After it exits, it must print `consts: restored`, `rebuilt with original consts` and `leak-check: ... 0 hit(s)`
   (out dir, session logs and `bin/` scanned for the row's cred values). A `HIT` names column + file only: do not
   open that file, tell the user. Then `bash $S status`: `consts == backup`, and every `bin:` line says
   `the current consts`. Report from the JSON with ids only; customer data stays out of commits and MR text.

`swap <sel>` + `restore` exist for manual use: `swap` does NOT restore itself, so follow it with `restore`.

## Red Flags - STOP

| About to... | Why it is wrong |
|---|---|
| cat / grep / `head` / Read `creds.csv`, the consts, the backup, `appsettings.local.json` | prod secrets; use `resolve` / `status` / `preflight` |
| run `use`, smoke or `dotnet test` from a worktree | GlobalTestSetup seeds the consts into the shared DB; the script always targets the main checkout |
| `curl -X POST`, or curl the App by hand while creds are swapped | the GET guard only covers `use`; write routes reach VERA PROD |
| add a route to the guard's allowlist, or call `health-manual` | it takes creds in the query string |
| leave creds swapped ("I'll restore after the next poll") | `bin/` and later test runs would carry another broker's creds; `use` restores on exit |
| `git add -A` / `commit -a`, or stage `VeraDebugTestConsts.cs`, `appsettings.local.json`, the WAF config | tracked files holding prod creds; preflight refuses while one is staged |
| delete the backup when preflight says `backup_consistent=False` | the backup may be the only copy of the user's own creds; `status`, then ask |
| run again because "the user said go earlier" | a go covers one run |
| edit `vera-session.sh` while a run uses it | bash reads lazily: write a new file, then `mv` |

## Common mistakes

- **Rebuild after restore matters:** the consts are inlined into every assembly that uses them; restoring the `.cs`
  alone leaves the swapped creds in `bin/`. `use` rebuilds; after a manual `swap`/`restore`, build once. Restore
  copies WITHOUT `cp -p`: an old mtime makes MSBuild skip CoreCompile and the "rebuild" keeps the swapped creds.
- **A `bin:` line naming a creds.csv row** that is not the current consts = stale build output; an orphan project
  dir (untracked, not in the sln) is never rebuilt, so only deleting its `bin/`/`obj/` clears it (user's call).
- **The local DB still holds the session's creds** after a smoke (GlobalTestSetup upserts them) until the next
  integration run with the original consts. Tell the user; do not run a VERA test just to reseed.
- **`status` can list several rows:** brokers of one tenant can share one VERA user token.
- Poll output contains PROD customer data: keep it under `~/Downloads/.vera-audit/session/`.
