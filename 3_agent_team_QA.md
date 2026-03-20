# Input

The user provides:
- A **spec file** describing the feature/task to audit
- The **task scope** (which part of the spec to audit, or all of it)
Provided via conversation context (opened file, message, or attached file).

---

Audit the implementation of the task defined in the spec to detect:

* bugs
* security issues
* performance problems
* deadlocks
* deviations from the specification

Use an **8-agent system** with strict role separation.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the seven reviewer roles.

---

## 1. Dispatcher Agent (Read-Only) — YOU, the root agent

* Has **read-only access** to the repository and the spec.
* Responsible for **identifying the relevant implementation** of the task.

**Before handing off to reviewers, the Dispatcher must:**

1. **Run `dotnet build`** — verify the code compiles. If it fails, stop and report build errors instead of proceeding with review. Also check for **warnings** and report them as pre-review findings:
   * Unused parameters, variables, or `using` statements
   * Too complex methods (high cyclomatic complexity)
   * Nullable reference type warnings
   * Any other compiler/analyzer warnings
2. **Run `dotnet test`** (if tests exist) — report any test failures as pre-review findings.
3. Produce the following and distribute to all reviewers:
   1. **File Manifest** — a list of all relevant files, modules, and entry points with a short description of each file's role.
   2. **Scope Boundary** — a clear definition of what is **in-scope** (files, modules, features to review) and what is **out-of-scope** (unrelated code, infrastructure, etc.).
   3. **Change Summary** — what was changed (e.g. `git diff` against the base branch, commit list), so reviewers know exactly what's new vs. pre-existing code.

**All reviewers must consult the project's `CLAUDE.md` for general coding guidelines and conventions.** Findings that violate `CLAUDE.md` rules (naming, patterns, field usage, LINQ style, etc.) should be reported under the most fitting category.

**Rules**

* Performs **no code changes**.
* Only coordinates and manages the review process.
* **Heartbeat:** While waiting for sub-agents, print a short status message (e.g. `"⏳ Waiting for Security Reviewer..."`) every ~15 seconds to keep the conversation alive. Never go silent while waiting.
* **Sub-agent heartbeat:** All sub-agents must print a short progress message (e.g. `"Working on: reviewing security of endpoint X..."`) every ~30 seconds during long-running tasks. This lets the Dispatcher detect stalls without pinging.
* **Stale agent recovery:** The Dispatcher must never manually ping a sub-agent and wait passively. Instead, follow this escalation ladder automatically:
  1. **After ~45 seconds of silence** — check `git diff` for file changes by the sub-agent.
     * If changes detected → continue waiting, reset timer.
     * If no changes → proceed to step 2.
  2. **Send one message** to the sub-agent: `"Status?"` — wait ~20 seconds for a response.
     * If it responds → continue waiting, reset timer.
     * If no response → proceed to step 3.
  3. **Terminate and respawn** — kill the stale agent and spawn a fresh one with the same task. Do NOT ping again or wait further.
  * **Max respawns per task: 2.** If the second respawn also stalls, the Dispatcher must skip the reviewer and log the gap in the final report.
* **Completion gate:** The Dispatcher must verify that **all reviewer reports have been submitted** before initiating the Cross-Review Phase. If any report is missing, the Dispatcher blocks progression and flags the incomplete reviewer.
* **Arbitration:** During the Cross-Review Phase, if reviewers cannot reach consensus on a disputed finding, the Dispatcher makes the **final call** on severity and confirmation status with written reasoning.
* **Report generation:** Once the Cross-Review Phase is complete and the final joint report is assembled, the Dispatcher must write **all reports** as a single Markdown file into `/home/alex/Entwicklung/ai-dev-workflows/memory/3_qa/`. The filename format is `qa-{task-name}-phase-{N}-{YYYY-MM-DD}.md` (task name lowercased, spaces/special chars replaced with `-`, `{N}` is the current phase/run number — check existing files in `/home/alex/Entwicklung/ai-dev-workflows/memory/3_qa/` to determine the next number). If the file already exists, append an increment: `-2`, `-3`, etc. Never overwrite existing files. The file must contain:
  1. **Joint Audit Report** (the final consolidated table with confirmed/unconfirmed/rejected issues, fix order, and summary)
  2. **Individual Reviewer Reports** — each reviewer's original independent report, in full, under a clearly labeled `## {Reviewer Name} — Individual Report` heading

---

## 2. Security Reviewer Agent

Focus: **Security implications**

Checks the implementation for:

* authentication / authorization flaws
* injection vulnerabilities
* insecure data handling
* secret exposure
* unsafe dependencies
* privilege escalation risks

> **How to review:** Trace every external input (HTTP parameters, request bodies, query strings) through the code to its final use. Check authorization on every endpoint. Review data handling for exposure risks.

Produces an **independent security review report**.

---

## 3. Spec Compliance Reviewer A

Focus: **Specification compliance**

Cross-checks the implementation against the spec.

Checks for:

* missing functionality from the spec
* incorrect implementation of specified behavior
* logical deviations from the spec
* incomplete features
* behavior mismatches
* unimplemented edge cases

Produces an **independent spec compliance report**.

---

## 4. Spec Compliance Reviewer B

Follows the **exact same checks and output format as Spec Compliance Reviewer A** (section 3). Performs its review **independently and without seeing Agent A's report**.

> **Why two spec reviewers?** Spec compliance is the highest-value category — having two independent reviewers increases coverage and reduces blind spots. Their reports are compared during the Cross-Review Phase.

> **Isolation rule:** The Dispatcher hands the manifest to A and B **simultaneously**. Neither report is shared with the other until **both** are submitted.

---

## 5. Performance Reviewer Agent

Focus: **Performance issues**

Analyzes the implementation for:

* N+1 query problems and inefficient database access patterns
* missing or incorrect use of `AsNoTracking()` for read operations
* unbounded result sets (missing pagination / `.Take()` limits)
* unnecessary eager loading or over-fetching via `.Include()`
* blocking calls in async code paths
* excessive memory allocations (e.g. materializing large collections unnecessarily)
* missing caching opportunities for repeated lookups
* deadlock-prone patterns (e.g. `.Result` / `.Wait()` on async code)

> **How to review:** Identify hot paths (endpoints called frequently or processing large datasets). For each, trace the database queries executed and check for N+1, missing indices, over-fetching. Check async call chains for blocking.

Produces an **independent performance review report**.

---

## 6. Bug / Logic Reviewer Agent

Focus: **Logic correctness and edge cases**

Analyzes the implementation for:

* logic bugs and incorrect branching
* race conditions and concurrency issues
* off-by-one errors
* null / empty handling gaps
* unhandled edge cases in business logic
* incorrect state transitions
* error handling that swallows or misroutes exceptions

> **How to review:** Trace execution paths for each public method — happy path, error path, and edge cases (null inputs, empty collections, boundary values). Check state transitions are valid and complete. Verify exception handling doesn't swallow errors or return incorrect responses.

Produces an **independent bug / logic review report**.

---

## 7. Coding Style & Convention Reviewer Agent

Focus: **Full `CLAUDE.md` compliance and service implementation coding style** — covers all file types (DTOs, controllers, services, mappings), not just services.

**Step 1 — Read `CLAUDE.md`** and check all in-scope files against its conventions:

* DTO rules (`sealed record`, naming, validation attributes, nullable types)
* Controller rules (inheritance, `#region fields`, routing, response types, `[AuditReason]`)
* AutoMapper rules (`MemberList.Destination` / `MemberList.Source`, explicit mappings, `#region`)
* Naming conventions (entity/DTO/service/controller naming patterns, file prefixes)
* C# rules (`var` usage, XML docs, async suffix, nullable reference types)
* Field usage rules (BaseService vs non-BaseService vs controllers)

**Step 2 — Read reference codebase** and check service-layer style:

**Reference codebase:** `/home/alex/Entwicklung/bpp/bpp-file/BPP.File.NET/BPP.File.NET.API`

**Key reference files:**

* `Services/Upload/BrokernetFileUploadService.cs` — orchestration with numbered steps, guard clauses, private helpers below public methods
* `Services/BrokernetFile/BrokernetFileService.cs` — minimal service, clean repository access
* `Services/Upload/BrokernetFileValidationService.cs` — validation logic with steps and early returns
* `Services/BrokernetFile/BrokernetFileAutoSignService.cs` — business rules with guard clauses

**Service style checklist — flag violations of:**

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
| 9 | **Repository queries** | `QueryAllAsNoTracking()` for reads, `QueryAll()` for writes. Mixed up = finding. |
| 10 | **Validate before mutate** | All validation and early-return checks must come before any persistent state changes. Never modify entity state before confirming the operation should proceed. |
| 11 | **EF tracking verification** | Every entity that is mutated or saved must be loaded via a tracked query (`QueryAll()`), not `QueryAllAsNoTracking()`. This is a common source of silent data corruption. |

> **How to review:** For `CLAUDE.md` checks, compare each in-scope file against the relevant convention section. For service style, read the corresponding reference file(s) from bpp-file, then compare structure and style. Report **concrete line numbers** and a **short suggested fix** for each violation. If a file has zero violations, report it as **CLEAN** — do not skip it.

**Report format (per file):**

| # | Line(s) | Rule Violated | Current Code | Suggested Fix |
|---|---------|--------------|--------------|---------------|
| 1 | 42-48 | Max 2 levels of nesting | nested if/else 3 levels deep | Invert condition, early throw |

Produces an **independent coding style & convention review report**.

---

## 8. Documentation Reviewer Agent

Focus: **Feature documentation accuracy and completeness**

Checks `/home/alex/Entwicklung/ai-dev-workflows/memory/2_docs/{Feature}.md` files for the implemented feature:

* **Existence** — a `/home/alex/Entwicklung/ai-dev-workflows/memory/2_docs/{Feature}.md` file exists for the feature/module/service
* **Completeness** — contains: overview, architecture, API contracts, usage examples, business rules, dependencies
* **Accuracy** — documentation matches actual code behavior (no stale/copy-paste content, no phantom endpoints or parameters)
* **Consistency** — German used for business domain terms, consistent with codebase style
* **Clarity** — describes **what** and **why**, not **how**
* **Up-to-date** — if the file pre-existed, it was updated to reflect changes (not left stale)

> **How to review:** Read each `/home/alex/Entwicklung/ai-dev-workflows/memory/2_docs/{Feature}.md`, then read the corresponding implementation code. Cross-check every documented endpoint, parameter, business rule, and flow against the actual code. Flag any discrepancy.

Produces an **independent documentation review report**.

---

# Severity Rubric

All reviewers must use this shared rubric when assigning severity:

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Data loss, security breach, crash, or core spec requirement completely missing/broken | SQL injection, unhandled null causing 500, entire feature not implemented |
| **medium** | Incorrect behavior, spec deviation, or degraded performance that affects users | Wrong business logic output, N+1 queries on hot paths, missing auth check on non-critical endpoint |
| **low** | Minor issues, style violations, edge cases unlikely to occur in practice | Missing `AsNoTracking()` on low-traffic read, off-by-one on pagination edge case, CLAUDE.md convention violation |

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
| 1 | Description of the issue | low / medium / high | Agent name | Agreeing agent(s) | security / spec / performance / bug |

**Categories:** `security`, `spec-compliance`, `performance`, `bug-logic`, `coding-style`, `documentation`

**Sections:**

1. **Confirmed Issues** (2+ reviewers agree)
2. **Unconfirmed Issues** (single reviewer, kept for visibility)
3. **Rejected Issues** (2+ reviewers disproved, with reasoning)
4. **Recommended Fix Order** — confirmed issues sorted by severity (high → low), grouped by file to minimize context-switching
5. **Summary** — total counts by severity and category
