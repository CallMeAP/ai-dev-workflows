---
name: bpp-e2e-audit
description: Use when auditing HTTP endpoint e2e/integration coverage in a BPP .NET repo or module and closing the gaps — phrases like "audit e2e coverage", "which endpoints have no integration test", "are all endpoints e2e tested", "find untested endpoints", "coverage matrix for module X", "make every endpoint 100% e2e covered". Applies to bpp-backend, bpp-auth, bpp-stella, bpp-file, connectors, etc.
---

# BPP: Audit endpoint e2e coverage and close the gaps

## Overview

For every HTTP endpoint in the scoped module(s), prove it is exercised by a `[Category("Integration")]` e2e test across the required cases, produce a per-module coverage matrix, then **write the missing tests** (audit + write, not audit-only).

**Two properties make this trustworthy:**

- **Inventory is code-derived** — enumerated from the controllers in the checkout, never from an OpenAPI/Swagger dump (a spec can be stale or hand-edited; the routing attributes are ground truth).
- **Coverage is match-by-route** — an endpoint counts as covered only when a test issues an `HttpClient` call to its route and asserts the required outcomes. Test *names* prove nothing.

## When to Use

- "audit e2e coverage" / "which endpoints aren't integration tested" / "coverage matrix for <module>"
- "make every endpoint 100% e2e covered", "close the e2e gaps in <repo>"
- Reviewing a module before a release and needing an honest covered/GAP list.

## Scope resolution

The argument is a **repo** (`bpp-backend`), a **module within a repo** (`GoUser`, `News`), or **`all`**.

1. Resolve every repo path via the **`bpp-project-index`** skill's index file (`/home/alex/Entwicklung/bpp/bpp-backend/dev/apittrich/project_index.md`). **Never guess a path.**
2. A repo that appears only in the index's **GitLab-only** section has no local checkout → **report it as not-audited** (needs a clone); never invent a path for it.
3. `all` = every locally-checked-out BPP .NET repo with controllers. Skip `bpp-document-analysis` and `bpp-agent` (standing exclusion, same as `bpp-run-integration-tests`).
4. **Fetch before auditing** — `git -C <repo> fetch -q origin development`. Auditing a stale checkout produces a false matrix (endpoints added on `development` look missing/covered wrongly).

## Steps

### 1. Endpoint inventory (per module, from code)

Enumerate controller actions from `Controllers/`. Capture route template + HTTP verb + auth posture per action:

```bash
# every action + its verb/route, per module
grep -rnE '\[Http(Get|Post|Put|Delete|Patch)' <module>/Controllers/ --include='*Controller.cs'
```

For each controller also record: the class-level `[Route(...)]`/route prefix, `[Authorize]` / `[AllowAnonymous]` / custom auth attributes (e.g. `[SelfValidatesPermissions]`, `[RequireDeveloper]`), and whether the action takes a `[FromBody]` DTO and/or an `{id:guid}` route param. These three facts decide which cases are *applicable* (next step).

### 2. Coverage bar (per endpoint — user decision)

An endpoint is **covered** only when ALL *applicable* cases below are asserted in a `[Category("Integration")]` e2e test:

| Case | Applies when | Assert |
|---|---|---|
| **2xx happy path** | always | expected success status + JSON **field-level** assertions on the body (not just status) |
| **Auth 401/403** | endpoint is protected (not `[AllowAnonymous]`) | anonymous → 401; wrong-role/foreign-resource → 403 where the endpoint enforces it |
| **404 not-found** | route carries an `{id}` (id-route) | unknown id → 404 |
| **400 validation** | action takes a `[FromBody]` DTO | invalid/missing-required body → 400 (or 422 for `BrokerException`) |

**Substring / loose assertions do NOT count** (e.g. asserting only `response.IsSuccessStatusCode`, or a `Contains("x")` on the raw body). JSON field-level assertions DO count. A happy-path-only test on a protected id-route with a body is a **partial** — the auth, 404, and 400 cases are still GAPs.

### 3. Match endpoints → tests (by route, not name)

Map each endpoint to its covering test by **route usage** in the module's `IntegrationTests/` — find the `HttpClient` calls and read what they assert:

```bash
grep -rnE '\.(GetAsync|PostAsync|PutAsync|DeleteAsync|PatchAsync|SendAsync)\(' \
  <module>.Tests/IntegrationTests/ --include='*.cs'
```

**Calls are almost always indirected** — fixtures route through per-class URL `const`s / helper methods (`ListUrl`, `ItemUrl(id) => $"/api/news/{id}"`, `ChannelSearchUrl(channel)`), not string literals. A grep for `*Async("literal")` misses most calls. So: for each `*Async(...)` call, resolve the URL argument to its route string by finding that `const`/helper definition in the fixture:

```bash
grep -rnE '(const string|=>|=)\s*\$?"/?api[^"]*"' <module>.Tests/IntegrationTests/ --include='*.cs'
```

Match the resolved URL against the inventory's route templates. Then read the surrounding assertions to decide which cases (2xx/auth/404/400) that test actually covers. Ignore test method names entirely.

### 4. Emit the coverage matrix

Per module, one row per (endpoint × applicable case), with the covering test file/method or `GAP`:

```
Module: News   (4 controllers, 11 endpoints)
Endpoint                              Case         Covered by
GET  /api/news/{id}                   2xx          NewsControllerTests.GetById_returns_news ✓
GET  /api/news/{id}                   auth(401)    GAP
GET  /api/news/{id}                   404          NewsControllerTests.GetById_unknown ✓
POST /api/news                        2xx          NewsControllerTests.Create_ok ✓
POST /api/news                        400          GAP
POST /api/news                        auth(401)    GAP
...
Summary: 11 endpoints / 27 applicable cases → 19 covered, 8 GAP
```

If the scope is audit-only (user asked "which endpoints aren't covered"), stop here and report. Otherwise continue to close the gaps.

### 5. Close the gaps (write the missing e2e tests)

Follow the **`bpp-add-integration-tests`** skill for the WAF + `GlobalTestSetup` + self-seeding pattern. Mirror the module's existing fixtures and personas — do not invent a new harness.

- **Isolated worktree, never the main checkout:**
  ```bash
  slug=<module-or-scope>
  git -C <repo> fetch -q origin development
  git -C <repo> worktree add <repo>.worktrees/e2e-audit-$slug -b test/e2e-audit-$slug origin/development
  ```
  Copy any gitignored local test-config into the worktree first (see `bpp-run-integration-tests` → *Worktree runs*), else the suite dies in `OneTimeSetUp` looking like a regression.
- **e2e mail recipients: `@go-plattform.at` only** — any flow that dispatches mail through local-stack bpp-mail must seed recipients on that domain, never real/external addresses.
- Write only the missing cases from the matrix; assert JSON at field level; reuse existing seed helpers.

### 6. Run the affected suites

Per `bpp-run-integration-tests` conventions: bring the stack up first (**`bpp-start-local-stack`**), run **one suite at a time, ≥60s apart** (bpp-auth login 429 has no retry), **max 3 runs per suite**.

- **bpp-backend trap:** `BPP.Backend.NET.Public.Tests` is **not in the `.sln`** — build that csproj explicitly; a `dotnet test --no-build` on it silently exits 0 with no output (looks green, ran nothing).
- Module e2e suites tag via the constant `[Category(IntegrationTestCategories.Integration)]` — a grep for the literal `Category("Integration")` misses them; `--filter "Category=Integration"` matches either form.

### 7. One MR per repo

Follow **`bpp-create-mr`**. Target `development`, reviewer `apittrich`, and pin the base remote to dodge the glab-base trap:

```bash
git -C <worktree> add <new-test-file> ...          # explicit adds only — never git add -A
git -C <worktree> commit -m "test(<module>): close e2e coverage gaps"
git -C <worktree> push -u origin test/e2e-audit-$slug     # never --force
glab mr create -R brokernet/<repo> --source-branch test/e2e-audit-$slug \
  --target-branch development --reviewer apittrich --fill
```

Commit trailer:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

### 8. Deliberate-skip policy

A case that needs infrastructure not available locally (real Minio blobs, an external provider, a signing backend) is **documented as skipped in the MR description** — endpoint, case, and reason — never silently dropped from the matrix. The MR description carries the full covered / GAP-closed / skipped breakdown.

## Quick Reference

| Step | Action |
|---|---|
| Resolve paths | `bpp-project-index` index file — never guess |
| Fetch | `git -C <repo> fetch -q origin development` before auditing |
| Inventory | `grep -rnE '\[Http(Get\|Post\|Put\|Delete\|Patch)' <module>/Controllers/` |
| Cases | 2xx (+JSON fields), auth 401/403, 404 (id-routes), 400 (body routes) |
| Match | `HttpClient` route calls in `IntegrationTests/`, not test names |
| Write | `bpp-add-integration-tests` pattern, worktree off `origin/development` |
| Run | `bpp-run-integration-tests` conventions (stack up, 1 suite, ≥60s, ≤3 runs) |
| MR | `bpp-create-mr`, `-R brokernet/<repo>`, reviewer apittrich, no `--force` |

## Common Mistakes

- **Inventory from OpenAPI/Swagger** → stale or hand-edited; enumerate from `Controllers/` in the fetched checkout.
- **Matching by test name** → a `GetById_returns_404` name proves nothing; read the actual `HttpClient` route + assertions.
- **Grepping only `*Async("literal")` route calls** → fixtures indirect through URL `const`s/helpers (`ItemUrl(id)`, `ListUrl`); resolve the helper to its route string or you undercount coverage massively.
- **Counting a status-only / substring assertion as covered** → only field-level JSON assertions (and the specific status per case) count.
- **Marking a happy-path-only test "covered"** → it's a partial; auth/404/400 remain GAPs for protected id/body routes.
- **Auditing a stale checkout** → fetch `origin/development` first; endpoints drift.
- **Switching a main checkout's branch** → never. Always a worktree off `origin/development`.
- **Grepping only literal `Category("Integration")`** → misses the constant-tagged module suites.
- **`--no-build` test on `BPP.Backend.NET.Public.Tests`** → not in the `.sln`; exits 0 having run nothing. Build the csproj.
- **Running suites back-to-back** → bpp-auth login 429 (no retry) → whole suite dies in `OneTimeSetUp`, looks like a regression. Space ≥60s.
- **Silently dropping infra-blocked cases** → document them as skipped in the MR description.

## Red Flags — STOP

- About to edit **production code** to make a test pass → out of scope. This skill audits + writes tests only; a real production bug is surfaced to the user, never patched here.
- About to **loosen an assertion** (status-only, `Contains`, remove a field check) to go green → STOP. That fakes coverage. Fix the seed/test or report the bug.
- About to audit or write against a checkout you did **not fetch** → STOP. Fetch `origin/development` first.
- About to `git checkout` / switch a **main checkout's** branch → STOP. Use a worktree.
- About to `git add -A` / `--force` / omit the reviewer or `-R` pin → STOP. Explicit adds, plain push, `-R brokernet/<repo>`, reviewer apittrich.
- About to seed a **non-`@go-plattform.at`** mail recipient in an e2e test → STOP. Real mail would dispatch.
