Source Spec: **@SPEC_MD**
Task: `@SPEC_MD_TASK`

Audit the implementation of **`@SPEC_MD_TASK`** defined in **`@SPEC_MD`** to detect:

* bugs
* security issues
* performance problems
* deadlocks
* deviations from the specification

Use a **5-agent system** with strict role separation.

---

## 1. Dispatcher Agent (Read-Only)

* Has **read-only access** to the repository and `@SPEC_MD`.
* Responsible for **identifying the relevant implementation** of `@SPEC_MD_TASK`.

**Before handing off to reviewers, the Dispatcher must produce:**

1. **File Manifest** — a list of all relevant files, modules, and entry points with a short description of each file's role.
2. **Scope Boundary** — a clear definition of what is **in-scope** (files, modules, features to review) and what is **out-of-scope** (unrelated code, infrastructure, etc.).

The Dispatcher then distributes the manifest and scope to all reviewers.

**All reviewers must consult the project's `CLAUDE.md` for general coding guidelines and conventions.** Findings that violate `CLAUDE.md` rules (naming, patterns, field usage, LINQ style, etc.) should be reported under the most fitting category.

**Rules**

* Performs **no code changes**.
* Only coordinates and manages the review process.

---

## 2. Security Reviewer Agent

Focus: **Security implications**

Checks the implementation of `@SPEC_MD_TASK` for:

* authentication / authorization flaws
* injection vulnerabilities
* insecure data handling
* secret exposure
* unsafe dependencies
* privilege escalation risks

Produces an **independent security review report**.

---

## 3. Spec Compliance Reviewer

Focus: **Specification compliance**

Cross-checks the implementation against **`@SPEC_MD`**.

Checks for:

* missing functionality from the spec
* incorrect implementation of specified behavior
* logical deviations from the spec
* incomplete features
* behavior mismatches
* unimplemented edge cases

Produces an **independent spec compliance report**.

---

## 4. Performance Reviewer Agent

Focus: **Performance issues**

Analyzes the implementation of `@SPEC_MD_TASK` for:

* N+1 query problems and inefficient database access patterns
* missing or incorrect use of `AsNoTracking()` for read operations
* unbounded result sets (missing pagination / `.Take()` limits)
* unnecessary eager loading or over-fetching via `.Include()`
* blocking calls in async code paths
* excessive memory allocations (e.g. materializing large collections unnecessarily)
* missing caching opportunities for repeated lookups
* deadlock-prone patterns (e.g. `.Result` / `.Wait()` on async code)

Produces an **independent performance review report**.

---

## 5. Bug / Logic Reviewer Agent

Focus: **Logic correctness and edge cases**

Analyzes the implementation of `@SPEC_MD_TASK` for:

* logic bugs and incorrect branching
* race conditions and concurrency issues
* off-by-one errors
* null / empty handling gaps
* unhandled edge cases in business logic
* incorrect state transitions
* error handling that swallows or misroutes exceptions

Produces an **independent bug / logic review report**.

---

# Cross-Review Phase

After all reviewers finish their **independent reports**:

Each reviewer must:

1. **Read all other reviewers' reports**
2. **Respond to every finding** from other reviewers with: **agree**, **disagree** (with reasoning), or **comment** (add context)
3. **Challenge weak claims** and attempt to disprove them
4. **Flag new issues** discovered while reading other reports

**Confirmation rule:** An issue is **confirmed** when **2 or more reviewers agree** on it. Issues with only 1 supporter are marked as **unconfirmed** and included separately.

---

# Final Output

Reviewers produce a **joint audit report** returned to the **Dispatcher Agent**.

**Format — use a table per category:**

| # | Issue | Severity | Found By | Confirmed By | Category |
|---|-------|----------|----------|--------------|----------|
| 1 | Description of the issue | low / medium / high | Agent name | Agreeing agent(s) | security / spec / performance / bug |

**Categories:** `security`, `spec-compliance`, `performance`, `bug-logic`

**Sections:**

1. **Confirmed Issues** (2+ reviewers agree)
2. **Unconfirmed Issues** (single reviewer, kept for visibility)
3. **Summary** — total counts by severity and category
