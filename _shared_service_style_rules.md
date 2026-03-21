# Shared Service Implementation Style Rules

## Reference Codebase

Read the reference codebase at `/home/alex/Entwicklung/bpp/bpp-file/BPP.File.NET/BPP.File.NET.API/Services/` before writing or reviewing service code. Key reference files:

* `Upload/BrokernetFileUploadService.cs` — orchestration with numbered steps, guard clauses
* `BrokernetFile/BrokernetFileService.cs` — minimal clean service
* `Upload/BrokernetFileValidationService.cs` — validation with early returns
* `BrokernetFile/BrokernetFileAutoSignService.cs` — business rules with guard clauses

## Style Checklist (18 Rules)

| # | Rule | What to look for |
|---|------|-----------------|
| 1 | **Max 2 levels of nesting** | Any nesting deeper than 2 levels (loops and conditionals count equally). Must use guard clauses (`continue` / `throw` / `return`) to flatten, or extract inner logic into a private helper. |
| 2 | **Numbered step comments** | Public orchestration methods missing `// (1) ...`, `// (2) ...` comments (German) on each logical step. |
| 3 | **Private helper placement** | Private methods serving a public method must sit directly below it, not at file bottom. |
| 4 | **BaseService field usage** | Services inheriting `BaseService` using constructor params instead of protected fields (`_repositoryWrapper`, `_mapper`, `_logger`, `_auditContextService`). |
| 5 | **LINQ style** | Query syntax instead of method syntax. Abbreviated lambda names (`.Where(e => ...)` instead of `.Where(entity => ...)`). `var` for entity query variables. |
| 6 | **Async discipline** | I/O methods not `async Task`, missing `Async` suffix, `.Result` / `.Wait()` calls. |
| 7 | **Logging** | `Debug.WriteLine`, raw `_logger.Debug()` instead of `CommonLoggerUtil.LogDebug` / `LogDebugAsJson`. |
| 8 | **Error handling** | Wrong exception type — must use `BrokernetServiceNotFoundException` (404), `BrokernetServiceException` (business), `BrokerException` (user-facing). |
| 9 | **Repository queries** | `QueryAllAsNoTracking()` for reads, `QueryAll()` for writes. Mixed up = violation. |
| 10 | **Validate before mutate / expensive I/O** | All validation and early-return checks must come before any persistent state changes AND before expensive operations (API calls, file downloads, etc.). Never modify entity state before confirming the operation should proceed. Never download/fetch before validating inputs. |
| 11 | **EF tracking verification** | Before submitting, verify every entity that is mutated or saved was loaded via a tracked query (`QueryAll()`), not `QueryAllAsNoTracking()`. This is a common source of silent data corruption. |
| 12 | **PII masking in logs** | Never log email addresses, phone numbers, or other PII in plaintext. Use masked/redacted values in log messages (e.g. `a***@example.com`). GDPR violation if debug logs reach centralized logging. |
| 13 | **Reuse existing utilities** | Before writing a new helper/utility method, check if an identical or similar one already exists in the codebase or sibling services. Duplicate static methods across services = violation. |
| 14 | **Fetch before clear** | When replacing collections (addresses, contacts, etc.), fetch the new data from the external API FIRST, then clear+replace only after the fetch succeeds. Never clear local state before confirming the replacement data is available. |
| 15 | **Defensive collection operations** | `.ToDictionary()` crashes on duplicate keys. Use `.GroupBy().ToDictionary(g => g.Key, g => g.First())` or check for duplicates first. Same applies to other collection methods that throw on duplicates. |
| 16 | **Cross-service consistency** | When implementing logic that also exists in a sibling service (e.g. email uniqueness, dedup, fallback chains), check how the sibling handles it and align behavior. Inconsistent handling of the same concern across services = finding. |
| 17 | **Test value capture** | In tests, capture primitive values (strings, numbers) before the service call, then assert on the captured value — not on entity properties post-operation. Services may mutate entity properties after the operation (e.g. nulling fields), causing assertions via object reference to fail silently. |
| 18 | **Safe serialization** | Never serialize exceptions or complex objects directly (e.g. `JsonSerializer.Serialize(exception)`). Exceptions contain non-serializable members (`TargetSite`, inner exceptions) that crash at runtime. Extract relevant fields (message, stack trace) into a plain DTO before serializing. |
