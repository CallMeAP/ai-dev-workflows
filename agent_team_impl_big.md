Source Spec: **@SPEC_MD**
Task: `@SPEC_MD_TASK`

Create a team of agents to implement **`@SPEC_MD_TASK`** defined in **`@SPEC_MD`**.

The team should consist of **five agents with clearly defined roles**.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the Implementer, Reviewers, and Process Reviewer.

## 1. Dispatcher Agent (Coordinator) — YOU, the root agent

**Access:** Read-only (write access only to `@SPEC_MD` for marking tasks as completed)
**Responsibilities**

* Analyze `@SPEC_MD` and break `@SPEC_MD_TASK` into small implementation tasks with dependencies and order.
* Before assigning any work, produce:
  1. **File Manifest** — list of all relevant files, modules, and entry points with a short description of each file's role.
  2. **Scope Boundary** — clear definition of what is in-scope and out-of-scope.
  3. **Task Breakdown** — ordered list of tasks with dependencies, tracked as a done checklist.
* Assign tasks one-by-one to the Implementer.
* **Approve the Implementer's plan** against the spec before greenlighting implementation.
* Wait for review results before assigning the next task.
* Track progress on the done checklist.

**Rules**

* No code changes (except marking tasks as completed in `@SPEC_MD`).
* Only coordinates, validates plans, and delegates work.

---

## 2. Implementer Agent (Developer)

**Access:** Full write access
**Responsibilities**

* Implement tasks assigned by the Dispatcher.

**Rules**

* Must **never act independently**.
* Only execute **explicitly assigned tasks**.

**Required Workflow (per task)**

1. **Consult `CLAUDE.md`** for coding guidelines and conventions relevant to the task
2. Analyze task
3. Create **implementation plan**:
   * files to modify
   * components/services to create
   * dependencies
4. Submit plan to **Dispatcher for approval**
5. **Wait for Dispatcher approval** (if plan is rejected, revise and resubmit — see Workflow Loop)
6. Implement changes
7. **Create/update feature documentation** at `docs/{Feature}.md` (one file per feature/module/service):
   * **Overview** — what the feature does and why it exists
   * **Architecture** — high-level flow, involved services/components and how they interact
   * **API Contracts** — endpoints, request/response shapes, status codes
   * **Usage Examples** — typical request/response examples, key scenarios
   * **Business Rules** — domain logic, validation rules, edge cases
   * **Dependencies** — external services, other modules, config requirements
   * If a `docs/{Feature}.md` already exists, **update** it — don't create a duplicate
8. Provide **change summary**:
   * files modified
   * key decisions
   * assumptions

**Blocker escalation:** If during implementation the Implementer discovers that the task breakdown is wrong (missing dependency, scope too large, conflicting requirements), the Implementer must **stop and flag a blocker** to the Dispatcher instead of working around it. The Dispatcher re-splits or re-scopes the task before work continues.

**Service Implementation Style Rules (mandatory):**

The Implementer must read the reference codebase at `/home/alex/Entwicklung/bpp/bpp-file/BPP.File.NET/BPP.File.NET.API/Services/` before writing service code. Key reference files:

* `Upload/BrokernetFileUploadService.cs` — orchestration with numbered steps, guard clauses
* `BrokernetFile/BrokernetFileService.cs` — minimal clean service
* `Upload/BrokernetFileValidationService.cs` — validation with early returns
* `BrokernetFile/BrokernetFileAutoSignService.cs` — business rules with guard clauses

**Enforce these rules in all service implementations:**

1. **Guard clauses & early returns** — use early `throw` / `return`, no deep `if`/`else` nesting (max 2 levels)
2. **Numbered step comments** — public orchestration methods must have `// (1) ...`, `// (2) ...` comments (German) describing each logical step
3. **Private helpers below their public method** — not at the bottom of the file
4. **BaseService field usage** — use `_repositoryWrapper`, `_mapper`, `_logger`, `_auditContextService` (protected fields), never constructor params directly
5. **LINQ style** — method syntax only, full descriptive lambda names (`.Where(entity => ...)` not `.Where(e => ...)`), explicit variable types for queries
6. **Async discipline** — all I/O methods `async Task`, suffixed `Async`, no `.Result` / `.Wait()`
7. **Logging** — use `CommonLoggerUtil.LogDebug` / `LogDebugAsJson`, not `Debug.WriteLine` or raw `_logger.Debug`
8. **Error handling** — `BrokernetServiceNotFoundException` for 404, `BrokernetServiceException` for business errors, `BrokerException` for user-facing
9. **Repository queries** — `QueryAllAsNoTracking()` for reads, `QueryAll()` for writes

---

## 3. Code Reviewer Agent A

Performs an **independent QA review** of the implementation.

Checks:

* correctness and logical soundness
* completeness against `@SPEC_MD`
* adherence to the Dispatcher's approved plan
* code quality and maintainability
* **`CLAUDE.md` convention compliance** (naming, patterns, field usage, LINQ style, etc.)
* **service implementation coding style** (see checklist below)
* **documentation quality** (see documentation checklist below)
* security and reliability
* architectural issues
* edge cases and risks

**Service Style Checklist (compare against reference at `/home/alex/Entwicklung/bpp/bpp-file/BPP.File.NET/BPP.File.NET.API/Services/`):**

* Guard clauses & early returns — no deep `if`/`else` nesting (max 2 levels)
* Numbered step comments `// (1) ...`, `// (2) ...` (German) on public orchestration methods
* Private helpers placed directly below their public method
* BaseService protected fields used (`_repositoryWrapper`, `_mapper`, etc.), not constructor params
* LINQ: method syntax, full lambda names (`.Where(entity => ...)`), explicit query variable types
* Async: all I/O `async Task` + `Async` suffix, no `.Result` / `.Wait()`
* Logging via `CommonLoggerUtil.LogDebug` / `LogDebugAsJson`, not `Debug.WriteLine`
* Correct exception types (`BrokernetServiceNotFoundException`, `BrokernetServiceException`, `BrokerException`)
* `QueryAllAsNoTracking()` for reads, `QueryAll()` for writes

**Documentation Checklist (`docs/{Feature}.md`):**

* File exists for the implemented feature/module/service
* Contains: overview, architecture, API contracts, usage examples, business rules, dependencies
* Accurate — matches what the code actually does (no stale/copy-paste content)
* Updated (not duplicated) if the file already existed
* Describes **what** and **why**, not **how**
* German used for business domain terms, consistent with codebase style

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / spec / quality / security / convention / coding-style / documentation / edge-case | Actionable fix description |

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Low severity** issues: optional fix (suggestion, not blocking). **Medium/high**: fix required before approval.

---

## 4. Code Reviewer Agent B

Performs the **same independent QA review as Agent A**, but **independently and without seeing Agent A's report**.

Checks:

* correctness and logical soundness
* completeness against `@SPEC_MD`
* adherence to the Dispatcher's approved plan
* code quality and maintainability
* **`CLAUDE.md` convention compliance** (naming, patterns, field usage, LINQ style, etc.)
* **service implementation coding style** (see checklist below)
* **documentation quality** (see documentation checklist below)
* security and reliability
* architectural issues
* edge cases and risks

**Service Style Checklist (compare against reference at `/home/alex/Entwicklung/bpp/bpp-file/BPP.File.NET/BPP.File.NET.API/Services/`):**

* Guard clauses & early returns — no deep `if`/`else` nesting (max 2 levels)
* Numbered step comments `// (1) ...`, `// (2) ...` (German) on public orchestration methods
* Private helpers placed directly below their public method
* BaseService protected fields used (`_repositoryWrapper`, `_mapper`, etc.), not constructor params
* LINQ: method syntax, full lambda names (`.Where(entity => ...)`), explicit query variable types
* Async: all I/O `async Task` + `Async` suffix, no `.Result` / `.Wait()`
* Logging via `CommonLoggerUtil.LogDebug` / `LogDebugAsJson`, not `Debug.WriteLine`
* Correct exception types (`BrokernetServiceNotFoundException`, `BrokernetServiceException`, `BrokerException`)
* `QueryAllAsNoTracking()` for reads, `QueryAll()` for writes

**Documentation Checklist (`docs/{Feature}.md`):**

* File exists for the implemented feature/module/service
* Contains: overview, architecture, API contracts, usage examples, business rules, dependencies
* Accurate — matches what the code actually does (no stale/copy-paste content)
* Updated (not duplicated) if the file already existed
* Describes **what** and **why**, not **how**
* German used for business domain terms, consistent with codebase style

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / spec / quality / security / convention / coding-style / documentation / edge-case | Actionable fix description |

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Low severity** issues: optional fix (suggestion, not blocking). **Medium/high**: fix required before approval.

> **Isolation rule:** The Dispatcher hands the implementation to A and B **simultaneously**. Neither report is shared with the other until **both** are submitted.
>
> **Why two reviewers?** Code review is the last gate before approval — two independent reviewers increase defect detection and reduce blind spots. Their reports are merged by the Dispatcher before deciding the verdict.

---

## 5. Process Reviewer Agent (Retrospective)

Runs **once after all tasks are completed** — not per task. Reviews the entire workflow history and produces a retrospective.

**Input:** The Dispatcher provides the Process Reviewer with all accumulated reports from the full run:
* Task breakdowns and scope decisions
* Implementer plans (approved and rejected)
* All code review reports (A and B, all rounds)
* Merged verdicts and revision histories
* Blocker escalations (if any)
* Known issues (if any)

**Analyzes:**

* **Workflow efficiency** — unnecessary steps, redundant back-and-forth, bottlenecks
* **Plan quality** — were plans rejected often? Why? Pattern in rejections?
* **Review consistency** — did A and B frequently disagree? Were severity ratings calibrated?
* **Scope accuracy** — were tasks well-scoped or did blockers/re-scopes happen frequently?
* **Communication clarity** — were handoffs clear? Did the Implementer have enough context?
* **Documentation quality** — were `docs/` files useful or boilerplate?

**Output Format:**

```markdown
## Process Retrospective

### Workflow Efficiency
- [findings]

### Recurring Patterns
- [patterns across tasks — e.g. "plan rejections always due to missing X"]

### Recommendations
| # | Recommendation | Impact | Rationale |
|---|---------------|--------|-----------|
| 1 | ... | high / medium / low | ... |

### Metrics
- Tasks completed: X
- Plan revision rounds: X total (avg Y per task)
- Code review rounds: X total (avg Y per task)
- Blockers escalated: X
- Known issues accepted: X
```

> **Why a separate agent?** Individual agents lack cross-task perspective. The Process Reviewer sees the full picture and can identify systemic improvements that no per-task review can catch.

---

# Severity Rubric

All reviewers must use this shared rubric when assigning severity:

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Data loss, security breach, crash, or core spec requirement completely missing/broken | SQL injection, unhandled null causing 500, entire feature not implemented |
| **medium** | Incorrect behavior, spec deviation, or degraded performance that affects users | Wrong business logic output, N+1 queries on hot paths, missing auth check on non-critical endpoint |
| **low** | Minor issues, style violations, edge cases unlikely to occur in practice | Missing `AsNoTracking()` on low-traffic read, naming convention mismatch, `CLAUDE.md` style violation, missing docs on simple getter |

---

# Workflow Loop

For each task in `@SPEC_MD_TASK`:

1. Dispatcher assigns task
2. Implementer consults `CLAUDE.md`, writes **implementation plan**
3. Dispatcher **validates plan** against spec + scope
   * **If plan rejected** → Dispatcher provides reasoning → Implementer revises plan → back to step 3 (max 2 plan revision rounds)
4. Implementer **implements**
   * If Implementer hits a blocker → flags to Dispatcher → Dispatcher re-scopes → back to step 1
5. Code Reviewer A and B **independently review** (simultaneously, isolated)
6. Dispatcher **waits for both reports**, then merges findings
7. Dispatcher passes **merged review report** to Implementer

**Merged verdict logic:**
* Both APPROVED → **APPROVED**
* Either REVISIONS REQUIRED → **REVISIONS REQUIRED** (union of all medium/high findings)
* Conflicting severity on same issue → Dispatcher decides final severity

**If APPROVED → Dispatcher marks task as completed in `@SPEC_MD` → next task**
**If REVISIONS REQUIRED → Implementer receives merged report, fixes issues → review repeats from step 5**

**Max revision rounds: 3.** If still not approved after 3 rounds, the Reviewers and Dispatcher must jointly decide whether to accept with known issues or escalate. All **accepted known issues** must be logged in a `## Known Issues` section at the bottom of `@SPEC_MD` with: issue description, severity, reason for acceptance, and associated task.

## End-of-Run Retrospective

After **all tasks** in `@SPEC_MD_TASK` are completed:

1. Dispatcher collects all reports, plans, verdicts, and revision histories from the full run
2. Dispatcher spawns the **Process Reviewer** with this complete history
3. Process Reviewer produces a retrospective report
4. Dispatcher appends the retrospective as `## Process Retrospective` at the bottom of `@SPEC_MD`

---

# Objective

Complete:
```
[ ] `@SPEC_MD_TASK`
```
from `@SPEC_MD` with:

* strict adherence to the plan
* small safe iterations
* verification before progress

**All agents must consult the project's `CLAUDE.md` for general coding guidelines and conventions.** The Implementer must consult it **before writing the plan**, and Reviewers must check compliance as a review category.
