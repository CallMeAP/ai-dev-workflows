Source Spec: **@SPEC_MD**
Task: `@SPEC_MD_TASK`

Create a team of agents to implement **`@SPEC_MD_TASK`** defined in **`@SPEC_MD`**.

The team should consist of **three agents with clearly defined roles**:

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

1. Analyze task
2. Create **implementation plan**:
   * files to modify
   * components/services to create
   * dependencies
3. Submit plan to **Dispatcher for approval**
4. **Wait for Dispatcher approval**
5. Implement changes
6. Provide **change summary**:
   * files modified
   * key decisions
   * assumptions

---

## 3. Code Reviewer Agent

Performs an **independent QA review** of the implementation.

Checks:

* correctness and logical soundness
* completeness against `@SPEC_MD`
* adherence to the Dispatcher's approved plan
* code quality and maintainability
* security and reliability
* architectural issues
* edge cases and risks

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / spec / quality / security / edge-case | Actionable fix description |

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Low severity** issues: optional fix (suggestion, not blocking). **Medium/high**: fix required before approval.

---

# Workflow Loop

For each task in `@SPEC_MD_TASK`:

1. Dispatcher assigns task
2. Implementer writes **implementation plan**
3. Dispatcher **approves plan** (validates against spec + scope)
4. Implementer **implements**
5. Code Reviewer **reviews** and produces verdict
6. Verdict returned to **Dispatcher**

**If APPROVED → Dispatcher marks task as completed in `@SPEC_MD` → next task**
**If REVISIONS REQUIRED → Implementer fixes → review repeats**

**Max revision rounds: 3.** If still not approved after 3 rounds, the Reviewer and Dispatcher must jointly decide whether to accept with known issues or escalate.

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

**All agents must consult the project's `CLAUDE.md` for general coding guidelines and conventions.**
