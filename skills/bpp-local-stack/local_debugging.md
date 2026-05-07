# Local Debugging (personal, gitignored)

Instructions for end-to-end local verification: connect to DB → start bpp-auth → get JWT → hit bpp-backend endpoints.

**Naming conventions**
- DB tables/columns: `snake_case`
- Controller routes: `kebab-case`

---

## BPP module ports (default `launchSettings.json`)

Default profile is **HTTP** — `dotnet run` (without `--launch-profile`) binds the HTTP port only. Use `dotnet run --launch-profile https` to bind both HTTP + HTTPS.

| Module | HTTP (default) | HTTPS (opt-in) | App project path | Swagger (default) |
|--------|---------------|----------------|------------------|-------------------|
| bpp-auth | `5240` | `7016` | `bpp/bpp-auth/BPP.Auth.NET/BPP.Auth.NET.API` | `http://localhost:5240/api-doc` |
| bpp-file | `5242` | `7018` | `bpp/bpp-file/BPP.File.NET/BPP.File.NET.API` | `http://localhost:5242/api-doc` |
| bpp-backend | `5244` | `7020` | `bpp/bpp-backend/BPP.Backend.NET/BPP.Backend.NET.App` | `http://localhost:5244/api-doc` |
| bpp-vera-connector | `5246` | `7022` | `bpp/bpp-vera-connector/BPP.VeraConnector.NET/BPP.VeraConnector.NET.App` | `http://localhost:5246/api-doc` |

Always start each module with `ASPNETCORE_ENVIRONMENT=local` so `appsettings.local.json` is picked up:
```bash
cd <app-project-path>
ASPNETCORE_ENVIRONMENT=local dotnet run            # HTTP only (default)
ASPNETCORE_ENVIRONMENT=local dotnet run --launch-profile https   # HTTP + HTTPS
```

---

## 1. Postgres (local)

Connection string (from `appsettings.local.json`, key `DefaultConnection`):

```
Host=localhost;Port=5432;Database=bpp;Username=admin;Password=admin
```

Use `psql` to inspect / seed data. Always check existing data first; insert manually only when missing.

```bash
PGPASSWORD=admin psql -h localhost -p 5432 -U admin -d bpp

# inside psql
\dt                              # list tables
\d <table_name>                  # describe table
SELECT * FROM <table_name> LIMIT 10;
```

One-shot from terminal:

```bash
PGPASSWORD=admin psql -h localhost -p 5432 -U admin -d bpp -c "SELECT * FROM <table_name> LIMIT 5;"
```

Reminder: tables/columns are `snake_case` (e.g. `customer_contract`, `created_at`).

**Test-data email rule:** any customer-facing email (Customer, Person, Versicherer-Kontakt, etc.) inserted as test data MUST use `[random_name]@go-plattform.at` (e.g. `test-kunde-1@go-plattform.at`, `vollmacht-fixture@go-plattform.at`). Random valid local-part, fixed domain — keeps fake mails out of real inboxes. Existing GoUser/Makler logins on `@lipso.dev` may be reused as-is; do NOT create new `@lipso.dev` rows.

---

## 2. Start bpp-auth

Path (from `project_index.md`): `/home/alex/Entwicklung/bpp/bpp-auth/BPP.Auth.NET/BPP.Auth.NET.API`

```bash
cd /home/alex/Entwicklung/bpp/bpp-auth/BPP.Auth.NET/BPP.Auth.NET.API
ASPNETCORE_ENVIRONMENT=local dotnet run
```

- Runs on `http://localhost:5240` (https `7016`)
- Loads `appsettings.local.json` because `ASPNETCORE_ENVIRONMENT=local`
- Swagger: `http://localhost:5240/api-doc`

---

## 3. Get a local JWT

Endpoint: `POST http://localhost:5240/api/auth-go-user/login`

Credentials:
- `LoginEmail`: `a.pittrich@lipso.dev`
- `Password`: `Start123$`

Local config returns the JWT in a `Set-Cookie: brokernet-auth-token=…; httponly` response header — the response body is empty (status `200`, `Content-Length: 0`). Extract from the header:

```bash
JWT=$(curl -s -i -X POST http://localhost:5240/api/auth-go-user/login \
  -H "Content-Type: application/json" \
  -d '{"loginEmail":"a.pittrich@lipso.dev","password":"Start123$"}' \
  | grep -i "Set-Cookie:" | sed -n 's/.*brokernet-auth-token=\([^;]*\).*/\1/p')
echo "$JWT" > /tmp/jwt.txt
echo "JWT_LEN=${#JWT}"
```

The token's `sub` claim is the GoUser-Id (decode with `echo "$JWT" | cut -d. -f2 | base64 -d`).

---

## 4. Start bpp-backend

Path: `/home/alex/Entwicklung/bpp/bpp-backend/BPP.Backend.NET/BPP.Backend.NET.App`

```bash
cd /home/alex/Entwicklung/bpp/bpp-backend/BPP.Backend.NET/BPP.Backend.NET.App
ASPNETCORE_ENVIRONMENT=local dotnet run
```

- Runs on `http://localhost:5244` (https `7020`)
- Loads `appsettings.local.json`
- Swagger: `http://localhost:5244/api-doc`

**Always start every module with `ASPNETCORE_ENVIRONMENT=local`** so `appsettings.local.json` is picked up.

---

## 4b. Companion services for HVA / Callidus / Servo pipelines

Run any of these in a separate shell when the pipeline you are exercising needs them. Stop them when you are done — none are required just to call read-only endpoints like `/pipeline-pending-requirements` against an existing contract.

> **Quick-start for all 4 services**: [`start_local_stack.sh`](./start_local_stack.sh) — one command to bring up the full integration-test prereq stack (`bpp-auth`, `bpp-file`, `bpp-mail`, `bpp-js-report-connector`). Counterpart [`stop_local_stack.sh`](./stop_local_stack.sh) is a thin wrapper around the `stop` subcommand.
> ```bash
> dev/apittrich/start_local_stack.sh start    # ~10s warm, ~5min cold
> dev/apittrich/start_local_stack.sh status   # health probe of all 4
> dev/apittrich/start_local_stack.sh stop     # port-based kill
> dev/apittrich/stop_local_stack.sh           # same as `start_local_stack.sh stop`
> ```
> Logs land in `/tmp/bpp-local-stack/{name}.log`. Used by `BPP.Backend.NET.Products.Tests` integration tests (category `LocalIntegration`) — see `IntegrationTests/Infrastructure/LocalServiceGuard.cs` which fails fast if the probes don't reach the same 4 services.

| Service | Path | Port | Start | When needed |
|---|---|---|---|---|
| `bpp-file` | `bpp/bpp-file/BPP.File.NET/BPP.File.NET.API` | 5242 | `ASPNETCORE_ENVIRONMENT=local dotnet run` | Any pipeline step that uploads/persists a `BrokernetFile` (Vollmacht, Maklervertrag, Ausschreibungs-PDF, Polizze, etc.) and `dev-customer/ensure-signed-documents`. |
| `bpp-mail` | `bpp/bpp-mail` | 8082 | `./mvnw spring-boot:run` (default profile is already `local`; no `application-local.yml` exists, base `application.yml` covers it) | Any step that sends mail (HVA `request-offerts`, `create-offert-vergleich`, `start-polizzierung`; Callidus customer-data link; Servo customer-sign link). |
| `bpp-js-report-connector` | `bpp/bpp-js-report-connector` | 8081 | `./mvnw spring-boot:run` | Any step that renders a PDF (HVA Ausschreibungs-PDF in `run-product-pipeline`, Vergleich PDF in `create-offert-vergleich`, Vollmacht/Maklervertrag/Antrag PDFs in VariasSign flows). Connects to the **dev** JsReport at `jsreport.dev.go-plattform.at` — no local JsReport instance required, just the connector. |
| `brokernet-varias-sign` | `brokernet/brokernet-varias-sign` | 8400 | `varias_sign_healthcheck_user=test varias_sign_healthcheck_password=test ./mvnw spring-boot:run -Dspring-boot.run.profiles=development` | **Not needed in DEBUG builds** — `ConnectorVariasSignService.CallVariasSignApiAsync` short-circuits to a dummy `SignApiResponse` and `LoadVariasSignCredentialsAsync` returns dummy creds. Pair with `dev-varias-sign/*/trigger-callback` (see Products `CLAUDE.md`) to fake the customer signature. The Redis Auftrag is still written before the stub, so the dev callback works unchanged. |
| `servo-hw-connector` | `brokernet/servo-hw-connector` | 8900 | `npm run start:dev` | **Not needed in DEBUG builds** — `ProductServoPolizzeService.CreateAndDownloadPolizzeAsync` short-circuits HW-Connector + PDF-Download to a synthetic `PolizzeNumber` (`DEBUG-STUB-{contractId8}`) and reads the Polizze-PDF bytes from `dev/apittrich/testing.pdf`. Pipeline runs full Step 7a–7e without any outbound HW call. |

---

## Upload fixture

For any endpoint that requires a file upload (Vollmacht, Maklervertrag, Polizze, Antrags-PDF, generic `BrokernetFile`, etc.), use [`testing.pdf`](./testing.pdf) located next to this file. Use it as the default fixture for all multipart/form-data upload calls — do not pull random PDFs from elsewhere.

```bash
curl -s -X POST http://localhost:5244/api/<kebab-case-route> \
  -H "Authorization: Bearer $JWT" \
  -F "file=@/home/alex/Entwicklung/bpp/bpp-backend/dev/apittrich/testing.pdf"
```

---

## 5. Hit the updated endpoints

Routes are `kebab-case`. Pass JWT in `Authorization: Bearer` header.

```bash
# GET
curl -s http://localhost:5244/api/<kebab-case-route>/<id> \
  -H "Authorization: Bearer $JWT" | jq

# POST
curl -s -X POST http://localhost:5244/api/<kebab-case-route> \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{ ... }' | jq

# PUT
curl -s -X PUT http://localhost:5244/api/<kebab-case-route>/<id> \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{ ... }' -w "\nHTTP %{http_code}\n"

# DELETE
curl -s -X DELETE http://localhost:5244/api/<kebab-case-route>/<id> \
  -H "Authorization: Bearer $JWT" -w "\nHTTP %{http_code}\n"
```

---

## Verification flow (per task)

1. `psql` → check existing rows touching the changed code path; insert fixtures only when missing.
2. Start `bpp-auth` (port 5240) with `ASPNETCORE_ENVIRONMENT=local`.
3. Login → capture `$JWT`.
4. Start `bpp-backend` (port 5244) with `ASPNETCORE_ENVIRONMENT=local`.
5. Start any companion services from §4b that the exercised flow needs.
6. Curl the updated kebab-case endpoint(s) with `Authorization: Bearer $JWT`.
7. Re-query DB to confirm side effects (snake_case columns).

---

## Gotchas

- **Enum payload values are the full C# member name** (PascalCase as declared, *not* the German display string). `Rechtsform` accepts `GesellschaftMitBeschraenkterHaftung` (not `GmbH`); `Gender` accepts `Male`/`Female`/`Divers` (not `Maennlich`); `CustomerPersonRelationType` accepts `Manager` (not `IsManager`). When in doubt, grep the enum source under `bpp-shared/.../Enums/`.
- **Validation 400 with `"createDto"` field error** = enum value couldn't be parsed; the `errors` block lists the offending property + line number, the `createDto` entry is generic noise.
- **`dev-customer/ensure-signed-documents`** needs both `bpp-backend` and `bpp-file` running — it uploads stub PDFs through bpp-file's auto-sign path, no VariasSign round-trip.
- **HVA full-pipeline run** requires at least 2 broker insurance contacts (`/api/go-user-insurance-contact/broker/{goUserId}`) on the managing GoUser before `/request-offerts`; `/create-offert-vergleich` requires 2–3 selections, so `/request-offerts` must broadcast to ≥2 Versicherer.
- **Field `insuranceBrokerContactId` (not `insuranceContactId`)** in `ProductInsuranceContactSelectionDto` for `/request-offerts`. Mismatched names silently bind as `Guid.Empty` and yield a `"… mit der ID '00000000-0000-0000-0000-000000000000' wurde nicht gefunden"` 400.
- **HVA `/run-product-pipeline` is idempotent prep, not a state advance.** At `BearbeitungsStatus.AktionErforderlich` it renders + persists the Ausschreibungs-PDF as a side-effect but does NOT advance `BearbeitungsStatus`. The pipeline status only progresses when the broker calls `/request-offerts`. Don't expect `pipelineStatus` to change after `run-pipeline` alone.
- **`dev-customer/ensure-signed-documents` is customer-scoped, not contract-scoped.** Once called for a customer, every HVA contract on that customer inherits the active signed Vollmacht + Maklervertrag — no need to re-call per contract. Saves a step on follow-up test contracts using the same fixture.
- **`bpp-file` build break = bpp-shared drift.** If `bpp-file` won't compile with missing types like `BPP.Shared.NET.Attributes.SelfValidatesPermissionsAttribute` or `BPP.Shared.NET.Services.Permission.IGoUserPermissionValidator`, the local `bpp-file` checkout is on a branch that pre-dates a `bpp-shared` refactor (e.g. the GoUserPermission middleware migration). Switch `bpp-file` to its `development` branch (or whichever matches the currently-checked-out `bpp-shared`) and rebuild.
- **Callidus pipeline Step 2 hard-checks `VariasSignUsername` + `VariasSignPassword` directly on `GoUserExternalServicesLink` row** (NOT routed through the `ConnectorVariasSignService` DEBUG stub). Servo Step 2 hard-checks `HelveticWarrantyApiKey` + `HelveticWarrantyAdvertiserId` (latter is on `GoUserAdvertisementNumber` with `InsuranceCompany.HelveticWarranty`, not `GoUserExternalServicesLink`). Insert dummy values for the managing GoUser before running these pipelines locally — the in-DEBUG Connector stub only short-circuits the outbound HTTP call, not the boot-time precondition guards.
- **Callidus BVS-Haftpflicht is private-customer-only** (Step 3 enforces `CustomerStateCheckerUtil.ValidateIsPrivateCustomerOrThrow`). Linking a CompanyCustomer via `PublicLinkCustomerDto` lets the contract get created (Step 1 has no customer-type guard), then aborts at Step 3 with *"Kunde … ist kein Privatkunde."*. Skipper variants follow the same rule; Charter is private-only too.
- **bpp-mail Java DTOs sometimes mark optional fields `@NotBlank`.** Example: `SendPoliciertServoBikeEmailCommand.iban` is `@NotBlank` even though the bpp-backend correctly sends `""` when `PaymentType=Zahlschein`. Result: Servo Step 7d broker-mail returns 400, pipeline halts at `AntragVonKundenUnterschrieben` despite Polizze being uploaded successfully. Workaround for local testing: use `PaymentType=Sepa` + a real-looking IBAN on the test customer (`UPDATE customer_payment_settings SET payment_type='sepa' …` + `INSERT INTO bank_account_infos …`). Real fix lives in bpp-mail (`@NotBlank` → `@NotNull`).
- **`PublicLinkCustomerDto` audit-actor lookup needed `.Include(cp => cp.Person)`** — without it, `SetCustomerPersonActorForAudit(cp)` throws `InvalidOperationException: CustomerPersonActor's associated Person entity or FullName is null` from `AuditService.EnsureMetadataIsSet` on the very first save inside the create flow. Hit while creating a Callidus / Servo contract via the public endpoint linked to an existing customer. Fixed in `PublicCallidusContractService` + `PublicServoContractService` `ResolveAndSetAuditActorAsync`. Pre-existing — likely never hit in prod because only Stella-integrated GUIs use the link path.
