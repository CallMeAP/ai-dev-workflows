---
name: bpp-run-integration-tests
description: Use when user wants to run end-to-end / integration tests in a BPP .NET repo and auto-heal failures — phrases like "run integration tests", "run e2e tests", "are integration tests green", "fix failing integration tests", "check integration tests". Discovers test projects, starts the local stack via bpp-start-local-stack, runs `dotnet test --filter Category=Integration`, and on failure investigates recent commits in cwd + bpp-shared before stopping for user input. Always skips bpp-document-analysis (aka bpp-doci) and bpp-agent entirely (no unit, no e2e).
---

# bpp-run-integration-tests

## Overview

Auto-discovers integration tests in a BPP .NET repo (NUnit + WebApplicationFactory pattern), ensures the local stack is up, runs them, and on failure surfaces likely culprit commits before stopping. **Never auto-commits.** **Stops at hard limits to prevent runaway loops.**

## When to Use

- "run integration tests", "run e2e tests", "run integration suite"
- "are integration tests green", "check integration tests"
- "integration tests are failing — fix them"

## Excluded repos (standing user directive, non-negotiable)

**ALWAYS skip `bpp-document-analysis` (aka "bpp-doci") and `bpp-agent` — no unit tests, no integration/e2e tests**, whether cwd is that repo or a fleet-wide sweep includes it. Resolve repo names/paths via the `bpp-project-index` skill. If cwd IS one of these repos, report the standing exclusion and stop instead of running anything. In fleet summaries, list them as `SKIPPED (excluded by user directive)` — never as green or missing.

## Conventions Discovered

Both `bpp-backend` and `bpp-vera-connector` follow the same pattern:
- NUnit 4.x + `Microsoft.AspNetCore.Mvc.Testing`
- Base class marked `[Category("Integration")]` → all subclasses inherit
- `[SetUpFixture] GlobalTestSetup` performs health-probe + JWT login + DB guard
- `bpp-backend` e2e suites are stage-aware — same `[Category("Integration")]`, env-driven via `ASPNETCORE_ENVIRONMENT` (`local-integration` locally, `{branch}-integration` in CI)
- `[Explicit]` tests (e.g. JsReport) are intentionally opt-in — leave alone

Other BPP .NET repos likely follow the same pattern. Run discovery to confirm.

## Steps

### 1. Discover integration test projects

```bash
# Find candidate test csproj files under cwd
find . -name "*.csproj" \( -path "*Tests*" -o -path "*IntegrationTests*" \) -not -path "*/bin/*" -not -path "*/obj/*"

# Confirm which contain integration tests
grep -rlnE 'Category\("(Local)?Integration"|Category\(IntegrationTestCategories\.' --include="*.cs" <test-project-dir>
```

Build the working set: csproj files whose source contains an integration category. CAUTION: bpp-backend module suites tag via the CONSTANT `[Category(IntegrationTestCategories.Integration)]` — a grep for the literal `Category("Integration")` misses all 8 of them (Backoffice/Contract/Customer/GoUser/News/Products/Rahmenvereinbarung/Tenant; proven blind spot 2026-07-13). The `--filter "Category=Integration"` at run time works either way (it matches the resolved value).

### 2. Repo-specific prereq checks

- **bpp-vera-connector**: read `BPP.VeraConnector.NET.App/appsettings.local.json` → `VeraIntegrationTesting.{VeraReadTestsEnabled,VeraSyncTestsEnabled,VeraWriteTestsEnabled}`. If all `false`, warn user — most tests will skip.
- **bpp-backend**: confirm `appsettings.local.json` exists for the App project.

### 3. Start local stack

Invoke `bpp-start-local-stack` skill (it verifies via status afterward). If any service is DOWN, **stop** — report and ask user.

### 4. Run tests

For each discovered project:

```bash
dotnet test <project>.csproj --filter "Category=Integration" --logger "console;verbosity=normal" --nologo
```

Capture: pass/fail counts, names of failed tests, full stack traces.

`[Explicit]` tests stay skipped — that's intentional. Don't add `--filter Explicit` or similar.

**When a repo has many e2e suites, run one project at a time and space them ≥60s apart — never run them all at once.** Each module's `[SetUpFixture] GlobalTestSetup` logs in several personas at boot; running suites concurrently (`dotnet test <sln> --filter Category=Integration`) or back-to-back bursts those logins past **bpp-auth's** rate limit. bpp-auth login has **no retry**, so a whole suite dies in `OneTimeSetUp` with `bpp-auth login fehlgeschlagen (429)` and reports e.g. `Failed: 345, Passed: 0` in ~4s — looks like a mass regression but is pure throttling. Drive it with a spaced loop, e.g.:

```bash
for proj in <projects-with-integration-tests>; do
  dotnet test "$proj" --filter "Category=Integration" --nologo
  sleep 60   # let bpp-auth's login rate-limit window reset before the next suite
done
```

### 5. On failure — investigate, do NOT auto-fix blindly

For each failed test:

1. Identify the source file containing the test + the production code under test (resolve via test class name → namespace → likely file path).
2. Recent-commits hunt:
   ```bash
   git -C <cwd-repo> log --since="48 hours ago" --oneline --name-only
   git -C ~/Entwicklung/bpp/bpp-shared log --since="48 hours ago" --oneline --name-only
   ```
3. Cross-reference touched files vs. failing tests.
4. Classify failure:
   - **Likely production regression** (recent commit in cwd or bpp-shared touches relevant files) → **STOP**, report commit SHAs + message + which test(s) they likely broke. Ask user how to proceed. Do NOT modify test logic to "make it green".
   - **Likely test drift** (no relevant recent commits; assertion mismatch looks like contract update) → propose a minimal test-side fix and ask user before applying.
   - **Environment / flake** (timeout, connection refused, port-in-use; or a whole suite failing in `OneTimeSetUp` with `bpp-auth login fehlgeschlagen (429)` — that's the login-throttle from running suites un-spaced, see Step 4) → re-run that suite in isolation, ≥60s after the previous one. If still failing, STOP and report.
   - **Unknown** → STOP, report full output, ask user.

### 6. Re-run loop — hard cap

- Maximum **3** total runs per session (initial + 2 retries).
- Only re-run if a fix was applied or it was a flake.
- If still red after cap → STOP, summarize all attempts, ask user.

### 7. Never auto-commit

Leave any test edits unstaged for the user to review.

## Quick Reference

| Step | Command |
|---|---|
| Discover | `grep -rlnE 'Category\("(Local)?Integration"|Category\(IntegrationTestCategories\.' --include="*.cs"` |
| Start stack | invoke `bpp-start-local-stack` skill |
| Run | `dotnet test X.csproj --filter "Category=Integration"` |
| Recent commits (cwd) | `git log --since="48 hours ago" --oneline --name-only` |
| Recent commits (shared) | `git -C ~/Entwicklung/bpp/bpp-shared log --since="48 hours ago" --oneline --name-only` |

## Stop Conditions (non-negotiable)

- Local stack failed to come up.
- A failed test maps to a recent commit in cwd or bpp-shared → STOP, do not edit tests.
- 3 runs exhausted.
- Failure reason unclear.

## Common Mistakes

- **Running anything in bpp-document-analysis (bpp-doci) or bpp-agent** → standing user exclusion, unit AND e2e. Skip + report, never run.
- **Auto-fixing tests to make them green** when production regressed → masks the real bug. Always classify the failure first.
- **Forcing `[Explicit]` tests to run** — they are opt-in for a reason.
- **Looping indefinitely** — respect the 3-run cap.
- **Committing fixes silently** — never. Leave changes for user review.
- **Grepping only the literal `Category("Integration")`** → misses suites tagged via the `IntegrationTestCategories` constant (all 8 bpp-backend module e2e suites) — they silently get classified unit-only and never run.
- **Running every e2e suite at once / back-to-back** (`dotnet test <sln>`) → bursts bpp-auth logins → mass `OneTimeSetUp` 429s that look like a regression but aren't. Space suites ≥60s (see Step 4).
