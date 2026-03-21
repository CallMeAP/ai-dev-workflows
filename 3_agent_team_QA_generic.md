# Input

The user provides:
- The **scope** to audit: a directory path, a list of files, a branch name (diffs against base branch), or `"full"` (entire repo)
- Optionally, **focus areas** to prioritize (e.g. `"security,performance"`) — all categories are reviewed regardless, but focus areas get deeper analysis
- Optionally, **exclusions** — paths or patterns to skip

No spec file required. This prompt audits raw code quality.

**Personality:** Read `/home/alex/Entwicklung/ai-dev-workflows/SOUL.md` for squad communication style. All agents adopt their assigned callsign and tone.

---

Audit the codebase within the given scope to detect:

* code smells and design issues
* security vulnerabilities and hardcoded credentials
* performance problems and deadlocks
* logic bugs and edge cases
* convention violations
* dependency and build config issues

Use a **7-agent system** with strict role separation.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the six reviewer roles.

---

## 1. Dispatcher Agent (Read-Only) — YOU, the root agent

* Has **read-only access** to the repository.
* Responsible for **identifying the relevant code** within the given scope.

**Before handing off to reviewers, the Dispatcher must:**

1. **Run `dotnet build`** — verify the code compiles. If it fails, stop and report build errors instead of proceeding with review. Also check for **warnings** and report them as pre-review findings:
   * Unused parameters, variables, or `using` statements
   * Nullable reference type warnings
   * Any other compiler/analyzer warnings
2. **Run `dotnet test`** (if tests exist) — report any test failures as pre-review findings.
3. **Detect project conventions** — check for `CLAUDE.md`, `.editorconfig`, `CONTRIBUTING.md`, or other convention files. Pass their paths to the Style reviewer.
4. Produce the following and distribute to all reviewers:
   1. **File Manifest** — a list of all relevant files, modules, and entry points with a short description of each file's role.
   2. **Scope Boundary** — a clear definition of what is **in-scope** (files, modules, features to review) and what is **out-of-scope** (unrelated code, infrastructure, etc.).
   3. **Change Summary** — if scope is a branch: `git diff` against base branch + commit list. If scope is `"full"`: file listing with line counts.

**If a `CLAUDE.md` exists in the repo, all reviewers must consult it for coding guidelines.** Findings that violate `CLAUDE.md` rules should be reported under the most fitting category.

**Rules**

* Performs **no code changes**.
* Only coordinates and manages the review process.
* **Dispatcher rules (heartbeat, stale recovery):** See [_shared_dispatcher_rules.md](./_shared_dispatcher_rules.md)
* **Completion gate:** The Dispatcher must verify that **all reviewer reports have been submitted** before initiating the Cross-Review Phase. If any report is missing, the Dispatcher blocks progression and flags the incomplete reviewer.
* **Arbitration:** During the Cross-Review Phase, if reviewers cannot reach consensus on a disputed finding, the Dispatcher makes the **final call** on severity and confirmation status with written reasoning.
* **Report generation:** Once the Cross-Review Phase is complete and the final joint report is assembled, the Dispatcher must write **all reports** as a single Markdown file into `/home/alex/Entwicklung/ai-dev-workflows/memory/3_qa_generic/`. The filename format is `qa-generic-{scope-name}-run-{N}-{YYYY-MM-DD}.md` (scope name lowercased, spaces/special chars replaced with `-`, `{N}` is the current run number — check existing files in `/home/alex/Entwicklung/ai-dev-workflows/memory/3_qa_generic/` to determine the next number). If the file already exists, append an increment: `-2`, `-3`, etc. Never overwrite existing files. The file must contain:
  1. **Joint Audit Report** (the final consolidated table with confirmed/unconfirmed/rejected issues, fix order, and summary)
  2. **Individual Reviewer Reports** — each reviewer's original independent report, in full, under a clearly labeled `## {Reviewer Name} — Individual Report` heading
* **Report audit:** After writing the report, the Dispatcher spawns the **Report Auditor (Adjutant)** per `7_agent_team_report_auditor.md` with team type `qa-generic`.

---

## 2. Security Reviewer Agent

Focus: **Security vulnerabilities and credential exposure**

Checks the implementation for:

* authentication / authorization flaws
* injection vulnerabilities (SQL, command, path traversal, XSS)
* **hardcoded credentials and secrets** — API keys, passwords, tokens, connection strings in source code or committed config files
* `.env` files or secret files tracked in version control
* sensitive data in logs (bearer tokens, PII, passwords via `Debug.WriteLine` or similar)
* CORS misconfigurations
* unsafe dependencies with known CVEs
* privilege escalation risks
* missing input validation / sanitization
* insecure middleware configurations (path matching bypasses, missing host validation)

> **How to review:** Trace every external input (HTTP parameters, request bodies, query strings) through the code to its final use. Check authorization on every endpoint. Grep for common secret patterns (`password`, `secret`, `token`, `apikey`, `bearer`, `connectionstring`) in source files. Check `.gitignore` for missing entries. Review `appsettings*.json` for committed credentials.

Produces an **independent security review report**.

---

## 3. Architecture & Code Smell Reviewer Agent

Focus: **Structural quality, design patterns, and code smells**

Analyzes the codebase for:

* **God classes / god methods** — files >300 lines, methods >50 lines, classes with >7 injected dependencies
* **SRP violations** — classes handling unrelated concerns (e.g. scheduling + DB queries + JSON parsing + API calls in one service)
* **Code duplication** — near-identical logic in multiple places (copy-paste patterns)
* **Dead code** — unused methods, unreachable branches, commented-out code blocks
* **Magic numbers / strings** — hardcoded values that should be constants or config (`IOptions<T>`)
* **Leaky abstractions** — internal implementation details exposed in public APIs or interfaces
* **Inconsistent patterns** — same concern (error handling, logging, validation) handled differently across the codebase
* **Missing abstractions** — concrete types where interfaces should exist (tight coupling)
* **Dependency direction violations** — lower layers depending on higher layers, circular references
* **Over-engineering** — unnecessary abstraction layers, premature generalization

> **How to review:** Start with file/class size metrics — identify the top 5 largest files and review for SRP violations. Look for duplicated logic patterns across services. Check dependency graphs (using directives). Flag inconsistencies in how the same concern is handled across the codebase. Compare sibling services for pattern divergence.

Produces an **independent architecture & code smell review report**.

---

## 4. Performance Reviewer Agent

Focus: **Performance issues**

Analyzes the implementation for:

* N+1 query problems and inefficient database access patterns
* missing or incorrect use of `AsNoTracking()` for read operations
* unbounded result sets (missing pagination / `.Take()` limits)
* unnecessary eager loading or over-fetching via `.Include()`
* blocking calls in async code paths (`.Result` / `.Wait()` / `.GetAwaiter().GetResult()`)
* excessive memory allocations (materializing large collections, unbounded `List<Task>`)
* missing caching opportunities for repeated lookups
* deadlock-prone patterns
* socket exhaustion risks (`HttpClientHandler` created per request, missing `IHttpClientFactory`)
* connection pooling issues
* hot path analysis — endpoints called frequently or processing large datasets

> **How to review:** Identify hot paths (endpoints, background services, batch jobs). For each, trace the database queries executed and check for N+1, missing indices, over-fetching. Check async call chains for blocking. Review `HttpClient` usage for handler lifecycle issues.

Produces an **independent performance review report**.

---

## 5. Bug & Logic Reviewer Agent

Focus: **Logic correctness and edge cases**

Analyzes the implementation for:

* logic bugs and incorrect branching
* race conditions and concurrency issues
* off-by-one errors
* null / empty handling gaps
* unhandled edge cases in business logic
* incorrect state transitions
* error handling that swallows or misroutes exceptions
* resource leaks (unclosed streams, connections, disposables)
* fire-and-forget async patterns without error handling
* **`// TODO` / `// FIXME` / `// HACK` audit** — check all such comments: still relevant, already resolved, or left behind by mistake?
* stale inline comments that no longer match the code

> **How to review:** Trace execution paths for each public method — happy path, error path, and edge cases (null inputs, empty collections, boundary values). Check state transitions are valid and complete. Verify exception handling doesn't swallow errors or return incorrect responses. Grep for `// TODO`, `// FIXME`, `// HACK` in all in-scope files and verify each one. Check for fire-and-forget `Task.Run` patterns and verify cleanup/error paths.

Produces an **independent bug & logic review report**.

---

## 6. Coding Style & Convention Reviewer Agent

Focus: **Convention compliance and internal consistency**

**Step 1 — Detect project conventions:**

Check for these convention sources (in priority order):
1. `CLAUDE.md` in the repo root — if exists, this is the primary convention reference
2. `.editorconfig` — formatting rules
3. `CONTRIBUTING.md` or `styleguide.md` — project-specific rules
4. If none found: use standard .NET conventions as baseline

**Step 2 — Review against detected conventions:**

* Naming consistency (are naming patterns consistent across the project?)
* File/folder organization (clear, consistent project structure?)
* Async discipline (`async`/`await` usage, `Async` suffix, no `.Result`/`.Wait()`)
* Nullable reference type consistency
* LINQ style consistency (method vs query syntax — whichever the project uses, it should be consistent)
* Logging pattern consistency (one logging approach throughout, not mixed)
* Error handling pattern consistency (same exception types, same guard clause style)
* `var` vs explicit type usage — consistent within the project
* XML docs / comments — present where the project convention expects them
* **Internal consistency** — even without explicit rules, flag where the same pattern is done differently in different files

If `CLAUDE.md` exists, also review against all rules defined there. If it references [_shared_service_style_rules.md](./_shared_service_style_rules.md), flag violations of all 18 rules.

> **How to review:** For each in-scope file, compare against the detected convention source. Report **concrete line numbers** and a **short suggested fix** for each violation. If a file has zero violations, report it as **CLEAN** — do not skip it.

**Report format (per file):**

| # | Line(s) | Rule Violated | Current Code | Suggested Fix |
|---|---------|--------------|--------------|---------------|
| 1 | 42-48 | Max 2 levels of nesting | nested if/else 3 levels deep | Invert condition, early throw |

Produces an **independent coding style & convention review report**.

---

## 7. Dependency & Build Config Reviewer Agent

Focus: **Dependency health, build configuration, and project hygiene**

Checks the codebase for:

* **Outdated NuGet packages** with known vulnerabilities — check `.csproj` package versions
* **Unused dependencies** — packages declared in `.csproj` but never referenced in code
* **Absolute paths** in `.csproj` files (e.g. `/home/user/...`) — causes machine-dependent builds
* **Build warnings** — `MSB*`, `CS*`, `NU*` warnings from `dotnet build`
* **`.gitignore` gaps** — common artifacts not ignored (`bin/`, `obj/`, `appsettings.*.json` with secrets, `.env`, `*.user`, publish profiles)
* **NuGet hygiene** — floating versions (`*`), version inconsistencies across projects for the same package
* **Cross-module `.csproj` references** — missing XML comments explaining why the dependency exists
* **Docker / CI config issues** (if present) — running as root, secrets in build args, large image sizes
* **Environment-specific config** committed to repo — dev connection strings, debug flags in non-dev configs
* **Dead project references** — `.csproj` references to projects that don't exist or are unused

> **How to review:** Read all `.csproj` files and `Directory.Build.props` (if exists). Cross-reference declared packages with actual `using` statements. Check `.gitignore` completeness. Review `appsettings*.json` files for environment bleed. Check for absolute paths via grep.

Produces an **independent dependency & build config review report**.

---

# Severity Rubric

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Data loss, security breach, crash, or fundamental design flaw causing production failures | SQL injection, unhandled null causing 500, hardcoded production credentials, socket exhaustion under load, deadlock in hot path |
| **medium** | Incorrect behavior, degraded performance, or maintainability problems affecting users or developers | Wrong business logic, N+1 on hot paths, god class >500 lines, missing auth on non-critical endpoint, stale TODO blocking understanding |
| **low** | Minor issues, style violations, optimization opportunities unlikely to cause problems in practice | Naming inconsistency, missing docstring, unused import, minor code duplication, convention mismatch |

## NOT a Finding (do not flag)

- Style preferences without a project convention to reference
- "I would have done it differently" without a concrete problem
- Framework-idiomatic patterns (even if unfamiliar to the reviewer)
- Default `CancellationToken` parameter values — idiomatic C#
- TODOs that are clearly future work items, not bugs
- Minor naming differences that don't affect readability

---

# Cross-Review Phase

After all reviewers finish their **independent reports**:

**Scope:** Cross-review focuses on **medium and high severity findings only**. Low severity findings are included in the final report as-is without cross-review (to avoid noise).

Each reviewer must:

1. **Read all other reviewers' medium/high findings**
2. **Respond to each finding** with: **agree**, **disagree** (with reasoning), or **comment** (add context)
3. **Challenge weak claims** and attempt to disprove them
4. **Flag new issues** discovered while reading other reports

**Confirmation rule:** An issue is **confirmed** when **2 or more reviewers agree** on it. Issues with only 1 supporter are marked as **unconfirmed** and included separately. Issues actively **disproven** by 2+ reviewers are marked as **rejected** (with reasoning) and listed separately for transparency.

**Reviewer divergence escalation:** If a HIGH severity finding is flagged by one reviewer but not mentioned by any other reviewer, the Dispatcher must independently verify the finding before classifying it as unconfirmed. Do not auto-dismiss a HIGH finding just because only one reviewer caught it.

---

# Final Output

Reviewers produce a **joint audit report** returned to the **Dispatcher Agent**.

**Format — use a table per category:**

| # | Issue | Severity | Found By | Confirmed By | Category |
|---|-------|----------|----------|--------------|----------|
| 1 | Description of the issue | low / medium / high | Agent name | Agreeing agent(s) | security / architecture / performance / bug-logic / coding-style / dependencies |

**Categories:** `security`, `architecture`, `performance`, `bug-logic`, `coding-style`, `dependencies`

**Sections:**

1. **Confirmed Issues** (2+ reviewers agree)
2. **Unconfirmed Issues** (single reviewer, kept for visibility)
3. **Rejected Issues** (2+ reviewers disproved, with reasoning)
4. **Recommended Fix Order** — confirmed issues sorted by severity (high → low), grouped by file to minimize context-switching
5. **Summary** — total counts by severity and category
