---
name: bpp-add-integration-tests
description: Use when adding end-to-end / self-seeding integration tests to a BPP .NET module (bpp-auth, bpp-backend, bpp-stella, bpp-file, connectors, etc.) — phrases like "add integration tests", "add e2e tests to this module", "WebApplicationFactory tests", "self-seeding integration tests". Documents the WAF + GlobalTestSetup + raw-SQL self-seeding pattern and the gotchas so the suite always runs without seeding the DB first.
---

# Adding E2E integration tests to a BPP .NET module

## Overview

In-process `WebApplicationFactory<Program>` boots the module's API; a `[SetUpFixture] GlobalTestSetup`
seeds its own data idempotently (raw Npgsql) and logs in, then exposes shared `HttpClient`s. Tests
drive live HTTP calls against the real endpoints. Everything is tagged `[Category("Integration")]`.

**Self-seeding is the point:** the suite never depends on the bpp-shared `DbSeeder` having been run.
Every run "ensures its data exists, else inserts it" and force-resets any field a test mutates.

## Reference implementations

- **bpp-auth** — `BPP.Auth.NET/BPP.Auth.NET.API.Tests/IntegrationTests/` (deps: Postgres + Redis + bpp-mail).
- **bpp-backend** — `BPP.Backend.NET.Products.Tests/IntegrationTests/` (also bpp-auth/bpp-file/bpp-mail).

Read one of these first; copy its structure.

## Steps

1. **Bring up the dependencies** with the `bpp-start-local-stack` skill (Postgres, Redis, bpp-mail,
   bpp-file, …). Integration tests need the real companions running.
2. **Verify the live schema first** with the `bpp-connect-local-db` skill before writing any seed SQL:
   exact NOT-NULL columns (`information_schema.columns`), enum labels (`SELECT enum_range(NULL::<enum>)`),
   and unique indexes (`pg_index`). Hand-written INSERTs must match the DB exactly.
3. **Test csproj**: SDK `Microsoft.NET.Sdk.Web`; add `Microsoft.AspNetCore.Mvc.Testing`, `Npgsql`,
   (`StackExchange.Redis` if the module uses Redis — match the version the shared lib resolves, or
   `dotnet build` fails with NU1605 downgrade-as-error), `FluentAssertions`, project ref to the API.
4. **Expose the entry point**: append `public partial class Program { }` to the API `Program.cs`
   (top-level statements make `Program` internal/implicit; the factory needs it).
5. **`Infrastructure/`**:
   - `<Module>WebApplicationFactory : WebApplicationFactory<Program>` — env=local + config overrides
     (+ mock only truly external third-party connectors).
   - `BearerTokenHandler` — attaches the Bearer header.
   - `LocalServiceGuard` — fail-fast probe of each companion the module needs.
6. **`GlobalTestSetup`** (`[SetUpFixture]` in the `IntegrationTests` **parent** namespace so it wraps
   all fixtures, but NOT the unit-test namespace — so unit-only runs don't touch the DB): pre-flight
   probe → localhost DB guard → self-seed (raw Npgsql, `PasswordHasherUtil.Create` for any login
   user) → login → build authenticated client. Expose `internal static` clients/ids.
7. **Fixtures per controller**, each `[Category("Integration")]`.
8. **Run**: `dotnet test <proj> --filter "Category=Integration"`. CI excludes via
   `--filter "Category!=Integration"`. Run twice to prove idempotency.

## Self-seeding rules

- Idempotent = "select by natural key; if present, force-reset the mutated fields and return its id;
  else insert the full graph". This makes runs order-independent and re-runnable.
- A GoUser needs `tenant_id` + `person_id` (NOT-NULL FKs) and (for realism) a `contact_info`.
  Compute `password_hash`/`password_salt` with `BPP.Shared.NET.Utils.PasswordHasherUtil.Create`
  (PBKDF2-HMAC-SHA256, Base64) at seed time — never hard-code a hash.
- Use a **dedicated** test user/email (e.g. `*-e2e-*@go-plattform.at`), not a DbSeeder user. Use a
  **separate disposable** user for any test that mutates auth state (e.g. password reset).

## Gotchas (hard-won)

- **`Program` exposure** — without `public partial class Program { }`, `WebApplicationFactory<Program>`
  won't compile.
- **Env var, not just `UseEnvironment`** — `CurrentEnvironmentUtil` reads `ASPNETCORE_ENVIRONMENT`
  from the process. In the factory do BOTH
  `Environment.SetEnvironmentVariable("ASPNETCORE_ENVIRONMENT","local")` and `builder.UseEnvironment("local")`.
  `IsGuiTestMode()`/`IsLocal()` gate dev-only responses (e.g. the password-reset URL in the body).
  Note: this leaks process-wide for the run — a unit test that needs a different env must set+restore it.
- **Config override** — use `builder.ConfigureAppConfiguration(c => c.AddInMemoryCollection(...))`
  (runs last, wins over appsettings). E.g. bpp-auth `FeaturesToggles:UseCookie=false` makes login
  return the JWT in the body instead of a cookie.
- **Mock only external third parties** in `ConfigureTestServices` (`services.RemoveAll<T>()` then add
  a Moq mock). Prefer running the real companion via `bpp-start-local-stack`; only stub services with
  real-world side effects you want to avoid.
- **Redis required** wherever login/token flows store to it.
- **Postgres specifics**: `citext` columns (username/login_email) are case-insensitive; enum casts are
  `'value'::enum_type` with snake_case labels; audit NOT-NULLs need
  `'system'::created_updated_deleted_by_type` + `created_at` + `is_soft_deleted=false`;
  partial unique indexes (`WHERE is_soft_deleted=false`) on login_email/username/broker_shortcode.
- **Password-reset throttle**: clear `last_password_reset_request_at` for the reset user each run
  (15-min window via `PasswordResetTokenExpiryInMinutes`), else the request returns 204 not 200.
- **Rate limiting**: `Base*Controller`s may carry `[RequestLimit(MaxRequests=N, TimeWindowInSeconds=T)]`
  — per-path, keyed by JWT/IP; anonymous calls in the WAF usually resolve to "unknown" and skip it.
  Keep per-path authed calls modest.
- **Exception → status** (`BrokernetExceptionHandlerMiddleware`): `BrokernetUnauthorizedException`→401,
  `BrokernetServiceException`→400, `BrokernetServiceNotFoundException`→404, `BrokerException`→422,
  `BrokernetForbiddenException`→403. In local/GuiTestMode the body contains the full exception string
  — handy for asserting *why* a call failed.
- **`[SetUpFixture]` scope** — it wraps its namespace and sub-namespaces only. Put `GlobalTestSetup`
  under `...IntegrationTests` so unit tests (a sibling namespace) don't trigger the DB/Redis setup.

## When a test reveals a production bug

Self-seeding e2e tests exercise real code paths and will catch real bugs (e.g. an inverted password
validator). **Do not** weaken the test to make it green. Investigate, classify, and surface it to the
user with options (fix in this MR / document / skip) — never mask a production regression.

## Stop conditions

- Never run against a non-local DB (enforce a localhost connection-string guard).
- If a failing test maps to a production bug, STOP and report — don't edit the test to pass.
