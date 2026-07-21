---
name: bpp-vera-prod-read-e2e
description: Use when running the READ-ONLY VERA PROD e2e / probe suites in bpp-vera-connector against LIVE production VERA — the [Explicit] VeraProdReadOnly probes (Phase7 person-risk / reconciliation) and the Phase1 smoke connectivity tests. Phrases like "run vera prod read tests", "vera prod read-only e2e", "run the VeraProdReadOnly suite", "phase1 smoke against vera prod", "prove vera prod connectivity". VERA PRODUCTION is involved — a write-access preflight is mandatory before any call.
---

# bpp-vera-prod-read-e2e

## Overview

Runs bpp-vera-connector's **read-only** integration probes against **LIVE PROD VERA**. Because prod is involved, this skill is a discipline gate: **no prod-VERA test runs until every write toggle is verified OFF, and prod credentials must never be committed.**

**REQUIRED SUB-SKILLS:** `bpp-run-integration-tests` (discovery + run mechanics), `bpp-start-local-stack` (Postgres/Redis/bpp-auth the WebApplicationFactory needs), `bpp-connect-local-db` (only if seeding/DB reads are needed).

**Violating the letter of this preflight is violating the spirit of it.** "Write is probably off" is not "verified off".

## The Iron Rule

```
NEVER invoke a VERA-PROD suite until ALL THREE write gates are verified DISABLED.
If ANY is enabled → STOP, report the exact flag states, do NOT run. No exceptions.
```

## Step 1 — Write-access preflight (MANDATORY, before ANY prod call)

Verify all three, in the EFFECTIVE config the run uses (`BPP.VeraConnector.NET.App/appsettings.json` defaults, overridden by the git-tracked-but-locally-modified `appsettings.local.json`). All must be **false**:

| Flag | Config key | Meaning |
|---|---|---|
| Hard VERA-write gate | `FeatureTogglesVeraSync:EnableWriteAccess` | `false` blocks EVERY VERA write at the call site (`VeraWriteAccessGuard`); the `[Explicit]` probes also hard-assert this in `OneTimeSetUp`. |
| Write-test enabler | `VeraIntegrationTesting:VeraWriteTestsEnabled` | Enables Phase6 VERA-write fixtures. Must be off. |
| Sync-test enabler | `VeraIntegrationTesting:VeraSyncTestsEnabled` | Enables Phase4/5 sync fixtures (local writes + VERA push attempts). Must be off for a strictly read-only prod run. |

Extract ONLY these booleans — never dump the file (it holds prod creds):

```bash
python3 - <<'PY'
import json
def g(p):
  try: return json.load(open(p))
  except FileNotFoundError: return {}
base=g('BPP.VeraConnector.NET/BPP.VeraConnector.NET.App/appsettings.json')
loc =g('BPP.VeraConnector.NET/BPP.VeraConnector.NET.App/appsettings.local.json')
def eff(sec,key):
  v=loc.get(sec,{}).get(key); return v if v is not None else base.get(sec,{}).get(key)
flags={'EnableWriteAccess':eff('FeatureTogglesVeraSync','EnableWriteAccess'),
       'VeraWriteTestsEnabled':eff('VeraIntegrationTesting','VeraWriteTestsEnabled'),
       'VeraSyncTestsEnabled':eff('VeraIntegrationTesting','VeraSyncTestsEnabled')}
for k,v in flags.items(): print(f'{k} = {v}')
print('WRITE-SAFE' if all(not bool(v) for v in flags.values()) else 'REFUSE: a write gate is ENABLED')
PY
```

If output is `REFUSE`, STOP and report. Do not "just run Phase1 anyway" — report first and let the user decide.

## Step 2 — Credentials never get committed (non-negotiable)

The prod creds live in `VeraDebugTestConsts.cs` (seeded into the local DB) and `appsettings.local.json` (VERA URLs). **Both are git-tracked and NOT gitignored** — a `git add -A` / `git commit -a` would leak prod creds into history.

- **Never** `git add -A`, `git add .`, or `git commit -a` in this worktree. Only explicit `git add <specific-file>`.
- Before every commit: `git status` + `git diff --cached --name-only`, and confirm `appsettings.local.json`, `VeraDebugTestConsts.cs`, and the WAF config file are NOT staged.
- Never print, log, or echo cred VALUES. When inspecting config, print only booleans / redacted classifications. Hostnames (public prod URL) are OK; username/password/apikey/clientId/clientSecret/userToken are NOT.

## Step 3 — Phase1 smoke FIRST (prove connectivity, cheap, read-only)

Always run Phase1 smoke before the full VeraProdReadOnly suite. Phase1 is 16 unauthenticated GET reads (health, search, customer/contract/claim/doc) — it proves the App boots and PROD VERA is reachable and authenticating, without touching the heavier probes. Only proceed to the full suite once Phase1 is green (or the user green-lights despite failures).

## Step 4 — Run (net9 build recipe)

`main` targets **net9**, but the local `apittrich` bpp-shared ProjectReference resolves to a net10 checkout and breaks the build. Temporarily neuter ONLY that condition in the worktree's `BPP.VeraConnector.NET/Directory.Build.props`, run, then `git checkout -- Directory.Build.props` (never commit it):

```bash
# ensure Postgres+Redis (+bpp-auth for authed suites) are up first (bpp-start-local-stack)
cd BPP.VeraConnector.NET
python3 -c "p='Directory.Build.props';s=open(p).read();open(p,'w').write(s.replace('/home/alex/Entwicklung/bpp/bpp-shared/BPP.Shared.NET/BPP.Shared.NET/BPP.Shared.NET.csproj','/NEUTERED/x.csproj',1))"

# Phase1 smoke (read-only connectivity)
dotnet test BPP.VeraConnector.NET.IntegrationTests/BPP.VeraConnector.NET.IntegrationTests.csproj -c Debug --filter "FullyQualifiedName~Phase1_Smoke"

# Full read-only prod probes ([Explicit] => must be named explicitly)
dotnet test BPP.VeraConnector.NET.IntegrationTests/BPP.VeraConnector.NET.IntegrationTests.csproj -c Debug --filter "Category=VeraProdReadOnly"

git checkout -- Directory.Build.props   # ALWAYS revert; never commit
```

`VeraProdReadOnly` probes are `[Explicit]` + inert unless `appsettings.local.json` points VERA at PROD and `ReadTestAnchor:CustomerVeraId` (for anchor-based tests) is set; the discovery probe needs no anchor.

## Diagnosing failures (read-only, so never a write risk)

- **Health 503 / reads 500, host TCP-reachable** → VERA auth/token/credential problem, NOT network. The generic 500 handler masks the inner exception; check the `health` 503 body (`Error` field) or the App server log. Verify a VERA OAuth token can be obtained with the seeded creds.
- **Health 503 / reads fail, host NOT reachable (DNS/TCP)** → VPN/network. Connect to the VERA-prod VPN.
- **`Assert.Ignore` "Vera section points to Dev-Tenant"** → `appsettings.local.json` still on dmz211/uniquare; set the `Vera` section to PROD.
- **bpp-auth down** → only blocks authenticated suites; Phase1 + the debug-endpoint probes are unauthenticated and still run.

## Red flags — STOP

- About to run a prod-VERA test without having printed the three flag values → STOP, run the preflight.
- "EnableWriteAccess is false so the other two don't matter" → all three must be false; report and let the user decide.
- `git add -A` / `git commit -a` anywhere in this worktree → STOP, use explicit per-file `git add`.
- Pasting or echoing a cred value → STOP, redact.

## Rationalization table

| Excuse | Reality |
|---|---|
| "Write is surely off, just run it" | Surely ≠ verified. Print all three flags first. |
| "Only EnableWriteAccess matters" | The directive requires all three false for a read-only prod run. Refuse + report if any is on. |
| "Phase1 is read-only, skip the preflight" | The preflight is the gate for ANY prod call, Phase1 included. |
| "I'll `git add -A`, the creds are only local" | The cred files are tracked, not ignored — `-A` commits them. Explicit add only. |
| "Reverting Directory.Build.props later is fine, commit now" | Never commit the neuter. Revert before any commit. |
