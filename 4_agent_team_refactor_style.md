# Input

The user provides:
- **Source files** to refactor (file paths or glob patterns)

Provided via conversation context (opened file, message, or attached file).

---

Refactor the service implementations in the provided files to match the coding style of the **bpp-file reference codebase**.

Use a **3-agent system** with strict role separation.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the Analyzer and Refactorer.

---

## 1. Dispatcher Agent (Coordinator) — YOU, the root agent

**Access:** Read-only
**Responsibilities**

* Read **`/home/alex/Entwicklung/bpp/bpp-backend/CLAUDE.md`** for project conventions.
* Identify all service files in the provided source files.
* Assign files to the Analyzer, then orchestrate the refactoring loop.
* Track progress per file as a done checklist.

**Rules**

* No code changes.
* Only coordinates and delegates.
* **Heartbeat:** While waiting for a sub-agent, print a short status message (e.g. `"⏳ Waiting for Refactorer..."`) every ~15 seconds to keep the conversation alive. Never go silent while waiting.
* **Stale agent recovery:** If a sub-agent has not reported back within ~60 seconds, check if it has made any file changes (e.g. via `git status`). If it has made changes, continue waiting. If no changes, terminate it and spawn a fresh agent with the same task.

---

## 2. Style Analyzer Agent (Read-Only)

**Access:** Read-only

**Responsibilities**

1. Read the **reference service implementations** at `/home/alex/Entwicklung/bpp/bpp-file/BPP.File.NET/BPP.File.NET.API/Services/`:
   * `Upload/BrokernetFileUploadService.cs` — orchestration with numbered steps, guard clauses
   * `BrokernetFile/BrokernetFileService.cs` — minimal clean service
   * `Upload/BrokernetFileValidationService.cs` — validation with early returns
   * `BrokernetFile/BrokernetFileAutoSignService.cs` — business rules with guard clauses
2. Read `/home/alex/Entwicklung/bpp/bpp-backend/CLAUDE.md` for project conventions.
3. For each service file in scope, produce a **style deviation report**.

**Style Checklist — flag violations of:**

| # | Rule | What to look for |
|---|------|-----------------|
| 1 | **Max 2 levels of nesting** | Any nesting deeper than 2 levels (loops and conditionals count equally). Use guard clauses (`continue` / `throw` / `return`) to flatten, or extract inner logic into a private helper method. |
| 2 | **Numbered step comments** | Public orchestration methods missing `// (1) ...`, `// (2) ...` comments (German) on each logical step. |
| 3 | **Private helper placement** | Private methods serving a public method must sit directly below it, not at file bottom. |
| 4 | **BaseService field usage** | Services inheriting `BaseService` using constructor params instead of protected fields (`_repositoryWrapper`, `_mapper`, `_logger`, `_auditContextService`). |
| 5 | **LINQ style** | Query syntax instead of method syntax. Abbreviated lambda names (`.Where(e => ...)` instead of `.Where(entity => ...)`). `var` for entity query variables. |
| 6 | **Async discipline** | I/O methods not `async Task`, missing `Async` suffix, `.Result` / `.Wait()` calls. |
| 7 | **Logging** | `Debug.WriteLine`, raw `_logger.Debug()` instead of `CommonLoggerUtil.LogDebug` / `LogDebugAsJson`. |
| 8 | **Error handling** | Wrong exception type — must use `BrokernetServiceNotFoundException` (404), `BrokernetServiceException` (business), `BrokerException` (user-facing). |
| 9 | **Repository queries** | `QueryAllAsNoTracking()` for reads, `QueryAll()` for writes. Mixed up = finding. |

**Report format (per file):**

```
### {FileName}

| # | Line(s) | Rule Violated | Current Code | Suggested Refactor |
|---|---------|--------------|--------------|-------------------|
| 1 | 42-48   | Guard clauses | nested if/else 3 levels deep | Invert condition, early throw |
```

**Rules**

* No code changes.
* Report must include concrete line numbers and a short suggested fix for each violation.
* If a file has zero violations, report it as **CLEAN** — do not skip it.

---

## 3. Refactorer Agent (Developer)

**Access:** Full write access

**Responsibilities**

* Receive the style deviation report from the Analyzer (via Dispatcher).
* Refactor each flagged file to resolve all reported violations.

**Rules**

* **Style-only changes** — do NOT alter business logic, method signatures, return values, or observable behavior.
* **One file at a time** — complete and report before moving to the next.
* After each file, provide a brief change summary (violations fixed, lines changed).

**Refactoring workflow per file:**

1. Read the style deviation report for the file.
2. Read the relevant reference file(s) from bpp-file to understand the target style.
3. Apply fixes for all reported violations.
4. **Run `dotnet build`** — fix any compilation errors **and warnings** introduced by the refactor:
   * Unused parameters, variables, or `using` statements — remove them
   * Too complex methods (high cyclomatic complexity) — extract logic into private helpers
   * Nullable reference type warnings — fix with proper null checks or explicit nullability
   * Any other compiler/analyzer warnings — resolve, do not suppress
5. Self-check: re-read the refactored file against the checklist — fix anything missed.
6. Report back to Dispatcher.

---

# Workflow

1. Dispatcher identifies all service files in the provided source files
2. Dispatcher assigns all files to **Style Analyzer**
3. Style Analyzer reads reference files + `/home/alex/Entwicklung/bpp/bpp-backend/CLAUDE.md`, produces deviation report per file
4. Dispatcher reviews report, assigns files one-by-one to **Refactorer**
5. Refactorer fixes violations, reports back
6. Dispatcher marks file as done, assigns next file
7. After all files done, Dispatcher produces final summary and writes it to `reports/refactor-style-{YYYY-MM-DD}.md`. If the file already exists, append an increment: `-2`, `-3`, etc. Never overwrite existing reports.

**Final summary format:**

| File | Violations Found | Violations Fixed | Status |
|------|-----------------|-----------------|--------|
| `ServiceA.cs` | 5 | 5 | CLEAN |
| `ServiceB.cs` | 0 | 0 | ALREADY CLEAN |
