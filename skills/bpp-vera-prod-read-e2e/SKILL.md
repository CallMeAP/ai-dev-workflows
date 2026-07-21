---
name: bpp-vera-prod-read-e2e
description: Use when running the READ-ONLY VERA PROD e2e / probe suites in bpp-vera-connector against LIVE production VERA — the [Explicit] VeraProdReadOnly probes (Phase7 person-risk / reconciliation) and the Phase1 smoke connectivity tests. Phrases like "run vera prod read tests", "vera prod read-only e2e", "run the VeraProdReadOnly suite", "phase1 smoke against vera prod", "prove vera prod connectivity". VERA PRODUCTION is involved — a write-access preflight is mandatory before any call.
---

# bpp-vera-prod-read-e2e

## Overview

Runs bpp-vera-connector's **read-only** integration probes against **LIVE PROD VERA**. Because prod is involved, this skill is a discipline gate: **no prod-VERA test runs until the VERA-write gates are verified OFF, and prod credentials must never be committed.**

**REQUIRED SUB-SKILLS:** `bpp-run-integration-tests` (discovery + run mechanics), `bpp-start-local-stack` (Postgres/Redis/bpp-auth the WebApplicationFactory needs), `bpp-connect-local-db` (only if seeding/DB reads are needed).

**Violating the letter of this preflight is violating the spirit of it.** "Write is probably off" is not "verified off".

## The Iron Rule

```
NEVER invoke a VERA-PROD suite until BOTH VERA-write gates are verified DISABLED:
  FeatureTogglesVeraSync:EnableWriteAccess = false
  VeraIntegrationTesting:VeraWriteTestsEnabled = false
If either is enabled → STOP, report the exact flag states, do NOT run. No exceptions.
```

`VeraReadTestsEnabled` / `VeraSyncTestsEnabled` are test-SCOPE toggles (which fixtures run), **not** VERA-write gates — they MAY be `true` for a read run (see below).

## Step 1 — Write-access preflight (MANDATORY, before ANY prod call)

Verify in the EFFECTIVE config the run uses (`BPP.VeraConnector.NET.App/appsettings.json` defaults, overridden by the git-tracked-but-locally-modified `appsettings.local.json`):

| Flag | Config key | Rule |
|---|---|---|
| **Hard VERA-write gate** | `FeatureTogglesVeraSync:EnableWriteAccess` | **MUST be false.** Blocks EVERY VERA write at the call site — `VeraWriteAccessGuard.IsWriteAccessEnabledOrLog` (`Vera/Services/VeraWriteAccessGuard.cs`) returns false and no-ops; every write op (claim/contract/customer/document/advisor/task API services + all sync-push paths) calls it first and returns early. The `[Explicit]` probes also hard-assert this in `OneTimeSetUp`. |
| **Write-test enabler** | `VeraIntegrationTesting:VeraWriteTestsEnabled` | **MUST be false.** Enables the Phase6 VERA-write fixtures. |
| Sync-test scope | `VeraIntegrationTesting:VeraSyncTestsEnabled` | **MAY be true for a read run.** Enables Phase4/5 sync fixtures, which READ from VERA and write only the LOCAL DB; their VERA-push attempts still short-circuit at the `EnableWriteAccess` guard, so no VERA write occurs. |
| Read-test scope | `VeraIntegrationTesting:VeraReadTestsEnabled` | May be true (required for the read fixtures to run). |

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
hard={'EnableWriteAccess':eff('FeatureTogglesVeraSync','EnableWriteAccess'),
      'VeraWriteTestsEnabled':eff('VeraIntegrationTesting','VeraWriteTestsEnabled')}
scope={'VeraSyncTestsEnabled':eff('VeraIntegrationTesting','VeraSyncTestsEnabled'),
       'VeraReadTestsEnabled':eff('VeraIntegrationTesting','VeraReadTestsEnabled')}
for k,v in {**hard,**scope}.items(): print(f'{k} = {v}')
print('WRITE-SAFE' if all(not bool(v) for v in hard.values()) else 'REFUSE: a VERA-write gate is ENABLED')
PY
```

If output is `REFUSE`, STOP and report. Do not "just run Phase1 anyway".

## Step 2 — Fresh-worktree setup: the mTLS client cert (top failure cause)

The PROD VERA **token endpoint requires an mTLS client certificate** `gobrokernet.p12`, loaded by `ConnectorVeraCertificateHelper` from `App/Certificates/` (copied to build output via `<Content Include="Certificates\**">`). Password comes from `Vera:ClientCertificatePassword` (in `appsettings.local.json`); filename from `Vera:ClientCertificateFileName` (default `gobrokernet.p12`).

`.gitignore` ignores `*.p12` / `*.pfx` ("VERA client certificates — never commit"), so **the cert is a LOCAL-only file absent from a fresh git worktree.** If it's missing, `TryAddClientCertificate` silently skips mTLS (debug-logs "kein mTLS") → the PROD token endpoint rejects → **health 503 / reads 500 even though the host is reachable.**

Before running in a worktree, ensure the cert is present; if not, copy it (and the dev `gobrokernet_test.pfx`) from the main checkout — they stay untracked (gitignored); never stage/commit:

```bash
CERT="BPP.VeraConnector.NET/BPP.VeraConnector.NET.App/Certificates"
for f in gobrokernet.p12 gobrokernet_test.pfx; do
  [ -f "$CERT/$f" ] || cp "/home/alex/Entwicklung/bpp/bpp-vera-connector/$CERT/$f" "$CERT/$f"
done
git check-ignore "$CERT/gobrokernet.p12"   # confirm it's ignored (won't be staged)
```

## Step 3 — Credentials never get committed (non-negotiable)

Prod creds live in `VeraDebugTestConsts.cs` (seeded into the local DB) and `appsettings.local.json` (VERA URLs + cert password). **Both are git-tracked and NOT gitignored** — a `git add -A` / `git commit -a` would leak prod creds into history.

- **Never** `git add -A`, `git add .`, or `git commit -a` in this worktree. Only explicit `git add <specific-file>`.
- Before every commit: `git status` + `git diff --cached --name-only`; confirm `appsettings.local.json`, `VeraDebugTestConsts.cs`, and the WAF config file are NOT staged.
- Never print, log, or echo cred VALUES. Print only booleans / redacted classifications. Hostnames (public prod URL) are OK; username/password/apikey/clientId/clientSecret/userToken/cert-password are NOT.
- Local config edits made for a run (e.g. flipping a scope toggle, pointing `Vera` at PROD) stay **unstaged** — never revert or commit them either; leave them as-is unless told otherwise.

## Step 4 — Phase1 smoke FIRST (prove connectivity, cheap, read-only)

Always run Phase1 smoke before the full VeraProdReadOnly suite. Phase1 is 16 unauthenticated GET reads (health, search, customer/contract/claim/doc) — it proves the App boots and PROD VERA is reachable **and authenticating (mTLS + token)**, in ~6s when healthy. Only proceed to the full suite once Phase1 is green (or the user green-lights despite failures). Green Phase1 also confirms the cert is in place.

## Step 5 — Run (net9 build recipe)

`main` targets **net9**, but the local `apittrich` bpp-shared ProjectReference resolves to a net10 checkout and breaks the build. Temporarily neuter ONLY that condition in the worktree's `BPP.VeraConnector.NET/Directory.Build.props`, run, then `git checkout -- Directory.Build.props` (never commit it):

```bash
# ensure Postgres+Redis (+bpp-auth for authed suites) are up first (bpp-start-local-stack)
cd BPP.VeraConnector.NET
python3 -c "p='Directory.Build.props';s=open(p).read();open(p,'w').write(s.replace('/home/alex/Entwicklung/bpp/bpp-shared/BPP.Shared.NET/BPP.Shared.NET/BPP.Shared.NET.csproj','/NEUTERED/x.csproj',1))"

# Phase1 smoke (read-only connectivity) — run FIRST
dotnet test BPP.VeraConnector.NET.IntegrationTests/BPP.VeraConnector.NET.IntegrationTests.csproj -c Debug --filter "FullyQualifiedName~Phase1_Smoke"

# Full read-only prod probes ([Explicit] => must be named explicitly). Space suites ≥60s (bpp-auth 429 trap); ≤3 runs.
dotnet test BPP.VeraConnector.NET.IntegrationTests/BPP.VeraConnector.NET.IntegrationTests.csproj -c Debug --filter "Category=VeraProdReadOnly"

git checkout -- Directory.Build.props   # ALWAYS revert; never commit
```

`VeraProdReadOnly` probes are `[Explicit]` + inert unless `appsettings.local.json` points VERA at PROD and `ReadTestAnchor:CustomerVeraId` (for anchor-based tests) is set; the discovery probe needs no anchor. Never force `[Explicit]` WRITE tests.

## Diagnosing failures (read-only, so never a write risk)

- **Health 503 / reads 500, host TCP-reachable** → **FIRST suspect: missing mTLS cert** `gobrokernet.p12` in the worktree `App/Certificates/` (Step 2). Otherwise a VERA token/credential problem. The generic 500 handler masks the inner exception; check the `health` 503 body (`Error` field) or the App server log. If a fresh worktree is red but the main checkout is green, it is almost always the missing local cert.
- **Health 503 / reads fail, host NOT reachable (DNS/TCP)** → VPN/network. Connect to the VERA-prod VPN.
- **`Assert.Ignore` "Vera section points to Dev-Tenant"** → `appsettings.local.json` still on dmz211/uniquare; set the `Vera` section to PROD.
- **bpp-auth down** → only blocks authenticated suites; Phase1 + the debug-endpoint probes are unauthenticated and still run.

## Red flags — STOP

- About to run a prod-VERA test without having printed the two hard-gate flag values → STOP, run the preflight.
- `EnableWriteAccess` or `VeraWriteTestsEnabled` is `true` → STOP, report, do not run.
- Fresh worktree red (health 503 / reads 500) but main checkout green → STOP, copy the missing mTLS cert (Step 2), don't chase creds.
- `git add -A` / `git commit -a` anywhere in this worktree → STOP, use explicit per-file `git add`.
- Pasting or echoing a cred value → STOP, redact.

## Rationalization table

| Excuse | Reality |
|---|---|
| "Write is surely off, just run it" | Surely ≠ verified. Print the two hard-gate flags first. |
| "VeraSyncTestsEnabled=true means it can write to VERA" | No — sync fixtures write only the LOCAL DB; every VERA-push is gated by `EnableWriteAccess`. Only `EnableWriteAccess` + `VeraWriteTestsEnabled` must be false. |
| "Phase1 is read-only, skip the preflight" | The preflight is the gate for ANY prod call, Phase1 included. |
| "Worktree is red, the creds must be wrong" | If main checkout is green, it's the gitignored mTLS cert missing in the worktree — copy it before touching creds. |
| "I'll `git add -A`, the creds/certs are only local" | The cred files are tracked; `-A` commits them. Explicit add only. |
| "Reverting Directory.Build.props later is fine, commit now" | Never commit the neuter. Revert before any commit. |
