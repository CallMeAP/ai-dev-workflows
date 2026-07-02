---
name: bpp-regen-connector-clients
description: Use when regenerating the NSwag auto-generated *.g.cs connector clients in any BPP .NET repo with a *.Connectors project (bpp-backend, bpp-cheggnet-connector, bpp-vera-connector, bpp-document-analysis) — phrases like "regen connectors", "update connector clients", "regenerate nswag clients", "refresh api-docs / swagger json", "connector client out of date", "bpp-mail/bpp-file/bpp-push/js-report API changed".
---

# BPP: Regenerate NSwag connector clients

## Overview

Refreshes the committed OpenAPI specs (`api-docs-*.json`) from the **running local dev services** and regenerates the `Connector*Client.g.cs` clients via the commented-out NSwag targets in the `*.Connectors` csproj. Works in any BPP repo that follows the connectors pattern. Reports (does NOT fix, does NOT commit) call sites broken by the regen.

**Run from the consuming repo's root** (e.g. `~/Entwicklung/bpp/bpp-backend`). All commands below use `$REPO` for that path.

## Connector → source service map

| Connector folder | Source repo | Kind | Local port | Spec URL |
|---|---|---|---|---|
| `ConnectorBppFile` | `bpp-file` | dotnet | 5242 | `http://localhost:5242/api-doc/v1/swagger.json` |
| `ConnectorBppPush` | `bpp-push` | dotnet | 5245 | `http://localhost:5245/api-doc/v1/swagger.json` |
| `ConnectorBppMail` | `bpp-mail` | java | 8082 | `http://localhost:8082/v3/api-docs` |
| `ConnectorJsReport` | `bpp-js-report-connector` | java | 8081 | `http://localhost:8081/v3/api-docs` |
| `ConnectorHw`, `ConnectorEpz`, `ConnectorFiab`, `ConnectorVariasSign`, `ConnectorVeraApi` | — external, no local repo | — | — | **SKIP** — regen only if the user supplies an updated spec |

Ports are pinned by the local stack; cross-check against `*Connector.BaseUrl` in the consuming repo's `appsettings.local.json` if in doubt.

**Endpoint gotchas (do NOT guess paths):**
- .NET services serve Swashbuckle at `/api-doc/v1/swagger.json` — NOT `/swagger/v1/swagger.json`. Gated to `CurrentEnvironmentUtil.IsLocal()`; the stack script sets `ASPNETCORE_ENVIRONMENT=local`, so it works locally only.
- Java services (springdoc) have api-docs **disabled by default even locally** (`springdoc.api-docs.enabled: false`). They 404 unless started with `SPRINGDOC_APIDOCS_ENABLED=true SPRINGDOC_SWAGGERUI_ENABLED=true` in the environment.

## Preconditions

- Consuming repo working tree **clean** (`git status --porcelain` empty) — the flow relies on `git restore`/`git diff` to manage the csproj and review churn. Abort and report if dirty.
- Local BPP repos cloned as siblings under `~/Entwicklung/bpp/`.

## Workflow

### 1. Pull latest development everywhere

Invoke the `bpp-pull-all-dev` skill. Source repos must be on fresh `development` — otherwise you regen against a stale API.

**Source-repo state rule:** if a source repo is dirty or not on `development` (pull-all-dev skips it), its running service reflects WIP/off-branch code — **skip that connector**, report `skipped (dirty/off-branch source)`. Never stash or touch the source repo's working tree.

### 2. Discover in-scope connectors

In the consuming repo, find the connectors project and its NSwag targets:

```bash
CSPROJ=$(ls $REPO/*/*.Connectors/*.csproj)
grep -o 'nswag run [^ ]*' "$CSPROJ"          # one commented <Target> per connector
```

Each `Connector*/nswag-*.json` config names its input spec (`documentGenerator.fromDocument.url` → the `api-docs-*.json` sitting next to it) and output (`codeGenerators.openApiToCSharpClient.output` → the `.g.cs`, `className`). Scope = connectors from the map above whose source repo exists locally; list skipped external connectors in the final summary.

### 3. (Re)start the local stack with springdoc enabled

The stack script lives at `~/Entwicklung/bpp/bpp-backend/dev/apittrich/start_local_stack.sh` (`start|stop|status`; logs `/tmp/bpp-local-stack/`).

Restart even if `status` says UP — running services may predate the pull (stale code), and Java services were likely started without springdoc:

```bash
cd ~/Entwicklung/bpp/bpp-backend/dev/apittrich
./start_local_stack.sh stop
SPRINGDOC_APIDOCS_ENABLED=true SPRINGDOC_SWAGGERUI_ENABLED=true ./start_local_stack.sh start
```

The env vars are inherited by the `./mvnw spring-boot:run` children and are harmless for the dotnet services. Use the `bpp-start-local-stack` skill's bounded polling; a Java service can take ~60s+.

### 4. Fetch fresh specs

For each in-scope connector, overwrite the committed spec with the response **exactly as served** (formatting differs per connector — some minified, some indented; do NOT pretty-print or reformat, NSwag doesn't care and reformatting pollutes the diff):

```bash
curl -fsS -m 10 "$SPEC_URL" -o "$CONNECTOR_DIR/api-docs-<name>.json"
```

A 404 on a Java service means springdoc wasn't enabled → back to step 3. If `git diff` shows no spec change for a connector, its regen can be skipped (report as `up-to-date`).

**Judge drift semantically, not by diff size.** Committed specs weren't always saved as-served (indentation differs), so the first fetch can show a huge format-only diff. Compare parsed JSON (e.g. `python3` load old via `git show` vs new, check equality + `paths`/`components.schemas` keys) to classify: real drift vs format churn.

### 5. Regenerate: uncomment → build → re-comment

The NSwag `<Target>` blocks in the Connectors csproj are commented out by default and must end up commented again:

1. Edit the csproj: remove the `<!-- -->` wrapper around each in-scope `<Target Name="NSwag...">` (leave external connectors' targets commented).
2. **Join the `Command` attribute onto ONE line.** As committed, the command string wraps before `/variables:...`; on Linux `sh` executes the second line as a separate command → nswag runs without variables, then MSB3073 `exited with code 127` / `/variables:...: not found` fails the build. Single-line = clean run (the variables are redundant — every `nswag-*.json` hardcodes its namespace — but keep them for fidelity).
3. Build Debug — the targets run `BeforeTargets="PrepareForBuild"` with `Condition="'$(Configuration)' == 'Debug'"`:
   ```bash
   dotnet build "$CSPROJ" -c Debug
   ```
   Success looks like: `NSwag command line tool for .NET Core Net90, toolchain v14.x` … `Build succeeded. 0 Error(s)`.
4. Re-comment by restoring the csproj (tree was clean, only your uncommenting touched it):
   ```bash
   git -C $REPO restore "$CSPROJ"
   ```

**Toolchain-version churn:** the `.g.cs` header records the NSwag version. If the committed file was generated with a different version than the csproj-pinned `NSwag.MSBuild`, regen rewrites generator boilerplate (header, `#pragma`s, `ReadAsStringAsync` helpers) with zero API-surface change. The pinned version is authoritative — accept the churn. If BOTH the spec is semantically unchanged AND the `.g.cs` diff is boilerplate-only, `git restore` both files and report `up-to-date (churn reverted)`.

### 6. baseUrl ctor guard (CRITICAL — silent prod breakage)

Every generated client MUST keep the two-arg ctor so the `appsettings.json` URL (passed by `Connector*ServiceExtensions` `.AddTypedClient(...)`, marked with a `WICHTIG:` comment) overrides the hardcoded localhost URL:

```csharp
public ConnectorXyzClient(string baseUrl, System.Net.Http.HttpClient httpClient)
{
    BaseUrl = baseUrl;
    ...
```

Older NSwag toolchains regenerate a single-arg `Client(HttpClient)` ctor with `BaseUrl = "http://localhost:80xx";` — the connector then silently talks to localhost in every deployed environment. Check each regenerated `.g.cs`:

```bash
# className varies (e.g. JsReportConnectorClient) — match the ctor signature, not the class name
grep -L '(string baseUrl, System.Net.Http.HttpClient httpClient)' Connector*/*.g.cs
```

If a ctor regressed: **hand-patch the `.g.cs`** back to the two-arg form (re-add the `baseUrl` param, set `BaseUrl = baseUrl;`, drop the hardcoded URL). This is the one sanctioned manual edit to a generated file (per the Connectors module CLAUDE.md). Never "fix" it by changing `Connector*ServiceExtensions` to the single-arg call. Report every patch in the summary.

### 7. Verify call sites

Build the whole solution (Release avoids re-triggering any NSwag target):

```bash
dotnet build $REPO/*/*.sln -c Release 2>&1 | grep -E "error|Error" 
```

Compile errors = call sites broken by the new client (renamed methods/DTOs, changed signatures). **Do not fix them** — collect `file:line + error` and print them as the summary. If the repo has unit tests touching the connectors, a quick `dotnet test --filter "Category!=LocalIntegration&Category!=Integration"` is a bonus signal.

### 8. Summary output (always print)

Per connector: `regenerated | up-to-date | skipped (external) | FAILED (reason)`, spec paths added/removed (compare `"paths"` keys old vs new), `.g.cs` diff stat, ctor guard `ok | re-patched`, and the broken-call-sites list (or "none"). Leave all changes **uncommitted** for review; suggest `bpp-create-mr` as follow-up.

## Common mistakes

| Mistake | Reality |
|---|---|
| Curling `/swagger/v1/swagger.json` | 404 — BPP .NET services use route template `api-doc/{documentName}/swagger.json`. |
| Assuming Java api-docs work locally | Disabled by default; needs `SPRINGDOC_APIDOCS_ENABLED=true` at service start. |
| Building with the multi-line `Command` as committed | On Linux the embedded newline splits it into two shell commands → exit 127. Join to one line first (step 5). |
| Judging drift by `git diff` line count | Format + toolchain-boilerplate churn dominates; compare parsed JSON / API surface. |
| Pretty-printing fetched specs | Pointless churn — commit the byte-for-byte server response. |
| Regen against an already-running stale service | Pull first, then restart the stack. |
| Regen while the source repo is dirty/off-branch | Spec would reflect WIP code — skip that connector. |
| Leaving NSwag targets uncommented | Every teammate Debug build would hit the network. Always `git restore` the csproj. |
| Accepting a single-arg generated ctor | Silently pins connectors to localhost in prod. Guard + hand-patch (step 6). |
| Auto-fixing broken call sites or committing | Out of scope: report only, leave tree uncommitted. |
