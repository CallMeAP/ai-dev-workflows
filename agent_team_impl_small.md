Source Spec: **@SPEC_MD**
Task: `@SPEC_MD_TASK`

Create a team of agents to implement **`@SPEC_MD_TASK`** defined in **`@SPEC_MD`**.

The team should consist of **three agents with clearly defined roles**:

## 1. Dispatcher Agent (Coordinator)

**Access:** Read-only (write access only to `@SPEC_MD` for marking tasks as completed)

* Analyzes `@SPEC_MD` and identifies what needs to be done for `@SPEC_MD_TASK`.
* Before assigning work, produces:
  1. **File Manifest** — relevant files and their roles.
  2. **Scope Boundary** — what is in-scope vs out-of-scope.
* Issues **explicit implementation instructions** to the Implementer.
* **Approves the Implementer's plan** against the spec before greenlighting.
* Does **not perform any code changes** (except marking tasks as completed in `@SPEC_MD`).

---

## 2. Implementer Agent (Developer)

**Access:** Full write access

* Implements tasks assigned by the Dispatcher.
* Must **not act independently** — only executes Dispatcher-assigned work.

**Per-task workflow:**

1. Create brief **implementation plan** (files to modify, approach)
2. Submit to **Dispatcher for approval**
3. **Wait for approval**, then implement
4. Provide **change summary** (files modified, key decisions)

---

## 3. Code Reviewer Agent

* Reviews the implementation against `@SPEC_MD`.
* Checks: correctness, completeness, code quality, edge cases.

**Review Output:**

| # | Issue | Severity | Fix Required |
|---|-------|----------|--------------|
| 1 | Description | low / medium / high | Actionable fix |

**Low severity** issues: optional fix (suggestion, not blocking). **Medium/high**: fix required before approval.

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Max 2 revision rounds** — then accept with known issues or escalate.

---

# Workflow

1. Dispatcher produces file manifest + scope, assigns task
2. Implementer writes plan → Dispatcher approves
3. Implementer implements
4. Code Reviewer reviews → verdict to Dispatcher
5. **APPROVED → Dispatcher marks task as completed in `@SPEC_MD` → done** / **REVISIONS REQUIRED → Implementer fixes → re-review**

**All agents must consult the project's `CLAUDE.md` for general coding guidelines and conventions.**

The agents should collaborate to implement `@SPEC_MD_TASK` according to the tasks specified in `@SPEC_MD`.
