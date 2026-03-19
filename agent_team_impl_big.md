Source Spec: **@SPEC_MD**
Task: `@SPEC_MD_TASK`

Create a team of agents to implement **`@SPEC_MD_TASK`** defined in **`@SPEC_MD`**.

The team should consist of **four agents with clearly defined roles**:

## 1. Dispatcher Agent (Coordinator)

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
7. Provide **change summary**:
   * files modified
   * key decisions
   * assumptions

**Blocker escalation:** If during implementation the Implementer discovers that the task breakdown is wrong (missing dependency, scope too large, conflicting requirements), the Implementer must **stop and flag a blocker** to the Dispatcher instead of working around it. The Dispatcher re-splits or re-scopes the task before work continues.

---

## 3. Code Reviewer Agent A

Performs an **independent QA review** of the implementation.

Checks:

* correctness and logical soundness
* completeness against `@SPEC_MD`
* adherence to the Dispatcher's approved plan
* code quality and maintainability
* **`CLAUDE.md` convention compliance** (naming, patterns, field usage, LINQ style, etc.)
* security and reliability
* architectural issues
* edge cases and risks

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / spec / quality / security / convention / edge-case | Actionable fix description |

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
* security and reliability
* architectural issues
* edge cases and risks

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / spec / quality / security / convention / edge-case | Actionable fix description |

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Low severity** issues: optional fix (suggestion, not blocking). **Medium/high**: fix required before approval.

> **Isolation rule:** The Dispatcher hands the implementation to A and B **simultaneously**. Neither report is shared with the other until **both** are submitted.
>
> **Why two reviewers?** Code review is the last gate before approval — two independent reviewers increase defect detection and reduce blind spots. Their reports are merged by the Dispatcher before deciding the verdict.

---

# Severity Rubric

All reviewers must use this shared rubric when assigning severity:

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Data loss, security breach, crash, or core spec requirement completely missing/broken | SQL injection, unhandled null causing 500, entire feature not implemented |
| **medium** | Incorrect behavior, spec deviation, or degraded performance that affects users | Wrong business logic output, N+1 queries on hot paths, missing auth check on non-critical endpoint |
| **low** | Minor issues, style violations, edge cases unlikely to occur in practice | Missing `AsNoTracking()` on low-traffic read, naming convention mismatch, `CLAUDE.md` style violation |

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
