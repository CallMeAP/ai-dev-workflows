# Input

The user provides:
- **What to fix** — bug description, file path, method name, or error message
- Optionally: reproduction steps, expected vs actual behavior
- Optionally: reference to the report that flagged the bug (integration test report, QA report, etc.)

Provided via conversation context (opened file, message, or attached file).

**Personality:** Read `/home/alex/Entwicklung/ai-dev-workflows/SOUL.md` for squad communication style. All agents adopt their assigned callsign and tone.

---

Lightweight hotfix team for targeted bug fixes, small changes, and emergency patches. No tickets, no dual review, no architect. Fast in, fast out.

**Integration test context:** Bugs escalated from the integration testing team (workflow 5) typically involve the full request chain: Controller → Service → VERA API. Common bug types: wrong DTO mapping, missing fields, type mismatches, incorrect VERA API response handling. The VERA API response is always the **source of truth** — if your code doesn't match what VERA returns, your code is wrong.

The team should consist of **three agents with clearly defined roles**.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the Hotfix Implementer and Hotfix Reviewer.

## 1. Dispatcher Agent (Coordinator) — YOU, the root agent

**Access:** Read-only
**Responsibilities**

* **Read from other teams' folders** to understand the bug context:
  * `/home/alex/Entwicklung/ai-dev-workflows/memory/5_integration_tests/` — check for `## Pending Hotfixes` sections. This is the primary source when called after an integration testing run.
  * `/home/alex/Entwicklung/ai-dev-workflows/memory/3_qa/` — check for QA findings related to this bug
  * `/home/alex/Entwicklung/ai-dev-workflows/memory/2_impl-retros/` — check for recurring patterns this bug might belong to
* **Write fix reports to own folder** — all hotfix reports go to `/home/alex/Entwicklung/ai-dev-workflows/memory/6_hotfix/`. The integration testing team reads from this folder on re-run to confirm fixes landed.
* Read the bug report / change request from the user prompt.
* Locate the affected code — files, methods, call chains.
* Produce a brief **Fix Scope**:
  1. **Root cause** — what's wrong and why
  2. **Affected files** — list with paths
  3. **Fix approach** — one-liner description of the fix
  4. **Blast radius** — what else could break (related tests, callers, downstream)
  5. **Source** — which report/test flagged this bug (if applicable)
* **Priority ordering:** Order hotfixes by severity (high → medium → low). If a hotfix is blocked by another fix, note the dependency and fix the blocker first.
* Assign to Hotfix Implementer.
* After review, verify fix is complete.

**Rules**

* No code changes (except trivial one-liners if Reviewer flags them).
* Only coordinates and delegates.
* **Parallel hotfixes:** For independent hotfixes (no shared files, no overlapping blast radius), the Dispatcher may run 2 Implementer agents in parallel on different bugs. Each gets its own Reviewer. Dependent hotfixes must be sequential.
* **Dispatcher rules (heartbeat, stale recovery):** See [_shared_dispatcher_rules.md](./_shared_dispatcher_rules.md)

---

## 2. Hotfix Implementer Agent (Developer)

**Access:** Full write access

**Responsibilities**

Fix the bug as scoped by the Dispatcher. Nothing more.

**Rules**

* **Minimal fix only** — fix the bug, don't refactor surrounding code, don't add features, don't "improve" things you notice along the way.
* **Update affected tests** — if the fix changes behavior, update existing unit tests to match. Add a new test for the bug if no test covers it.
* Only execute the explicitly assigned fix.
* **Rollback on regression** — if `dotnet test` (full suite) reveals new failures caused by the hotfix, revert the fix (`git checkout -- <files>`) and escalate to the user with: what was attempted, what broke, and why the fix didn't work.

**Required Workflow**

1. **Consult `CLAUDE.md`** for coding guidelines
2. Read the Dispatcher's Fix Scope
3. **Investigate** — read the affected code, trace the bug, confirm root cause matches Dispatcher's analysis
   * If root cause is different → flag to Dispatcher before proceeding
4. **Fix** — apply the minimum change to resolve the bug
5. **Update/add tests** — ensure the bug is covered by a unit test that would have caught it
6. **Verify build** — run `dotnet build`, fix any errors and warnings
7. **Run unit tests** — run `dotnet test` (full suite, no filter), fix any failures
8. **Re-enable integration test** — if the bug was flagged by an integration test with `[Ignore("Bug: ... — pending hotfix")]`, remove the `[Ignore]` attribute so the test runs again
9. **Run integration test** — run `dotnet test --filter "TestName"` to confirm the fix resolves it. If it still fails, investigate and fix before proceeding.
10. **TODO audit** — grep `// TODO` in modified files, clean up stale ones
11. **Change summary:**
   * Files modified
   * Root cause confirmed
   * Fix applied
   * Tests added/updated
   * `[Ignore]` attributes removed (if any)
   * Integration test result (if applicable)

**Style rules #1-18 from `2_agent_team_impl.md` apply.**

---

## 3. Hotfix Reviewer Agent (Single Reviewer)

**Access:** Read-only

Single reviewer — hotfixes are scoped and low blast radius.

**Checks:**

* Fix actually resolves the reported bug
* Fix is minimal — no scope creep, no unnecessary changes
* No regressions introduced (blast radius check)
* Tests cover the bug scenario
* `[Ignore]` attributes removed from integration tests that flagged this bug
* Integration test passes after fix (if applicable)
* `CLAUDE.md` convention compliance
* Build + all tests pass

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / regression / scope-creep / convention | Actionable fix |

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Low severity** issues: optional. **Medium/high**: fix required.

---

# Severity Rubric

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Fix doesn't actually resolve the bug, introduces regression, or changes unrelated behavior | Wrong root cause addressed, existing test now fails, method signature changed unnecessarily |
| **medium** | Fix works but has side effects, missing test, or scope creep | No test for the bug, changed 3 files when 1 would suffice, refactored a helper "while at it" |
| **low** | Style, naming, minor improvements | Could use guard clause, naming mismatch |

**NOT a finding:**
- Fix touches more lines than expected if all lines are necessary
- Test is simple/short — hotfix tests should be focused

---

# Workflow

1. Dispatcher reads bug report, produces **Fix Scope**
2. Hotfix Implementer investigates + fixes + tests
3. Hotfix Reviewer reviews (single reviewer, max 2 rounds)
   * **Trivial fixes** → Dispatcher applies directly
4. Done
5. Dispatcher recommends to the user: **"Re-run integration testing team (`5_agent_team_integration_testing.md`) to verify fixes landed."**

**No tickets. No architect. No dual review. No feature docs.**

**Report:** Dispatcher writes fix report to `/home/alex/Entwicklung/ai-dev-workflows/memory/6_hotfix/hotfix-{description}-run-{N}-{YYYY-MM-DD}.md` where `{N}` is the current run number (check existing files to determine next number). If file exists, append increment. Never overwrite.

**Report template:**

```markdown
## Hotfix Report — {description}

### Root Cause
What was wrong and why.

### Fix Applied
| # | File | Change |
|---|------|--------|

### Mapping Fixes (if applicable)
| # | DTO/Field | Was | Should Be (per VERA) |
|---|-----------|-----|---------------------|

### Tests
- Unit tests added/updated: [list]
- Integration test `[Ignore]` removed: [test name]
- Integration test result: PASS / FAIL

### Regressions
None / [list]

### Source
Which report/test flagged this bug.
```

**Report Audit:** After writing the report, Dispatcher spawns the **Report Auditor (Adjutant)** per `7_agent_team_report_auditor.md` with team type `hotfix`.

---

# Objective

Fix the reported bug with:

* minimal, scoped change
* test coverage for the bug
* zero regressions
* fast turnaround

**All agents must consult the project's `CLAUDE.md` for general coding guidelines and conventions.**
