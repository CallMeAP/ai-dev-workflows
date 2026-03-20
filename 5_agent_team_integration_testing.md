# Input

The user provides:
- **What to test** — API endpoints, flows, or scenarios to cover with integration tests
- Optionally: specific test data, expected responses, or edge cases

Provided via conversation context (opened file, message, or attached file).

**Personality:** Read `/home/alex/Entwicklung/ai-dev-workflows/SOUL.md` for squad communication style. All agents adopt their assigned callsign and tone.

---

Create a team of agents to write **integration tests** that call external APIs over HTTP and verify responses and side effects.

The team should consist of **four agents with clearly defined roles**.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the Test Architect, Test Implementer, and Test Reviewer.

## 1. Dispatcher Agent (Coordinator) — YOU, the root agent

**Access:** Read-only
**Responsibilities**

* Read the test requirements from the user prompt.
* **Check for prior hotfix reports** in `/home/alex/Entwicklung/ai-dev-workflows/memory/6_hotfix/` — if this is a re-run after hotfixes, identify which `[Ignore]`'d tests should now be re-enabled and re-verified.
* Analyze the existing API client code, connector services, and external API contracts in the codebase.
* Before assigning any work, produce:
  1. **API Manifest** — list of external APIs/endpoints involved, their auth mechanism, request/response shapes.
  2. **Test Case Breakdown** — ordered list of test cases with dependencies, tracked as a done checklist. Each test case should be **~1 logical scenario** (e.g. one endpoint success + error).
* Assign work to Test Architect first, then Test Implementer.
* **Approve the Test Architect's design** before greenlighting implementation.
* Track progress on the done checklist.

**Rules**

* No code changes.
* Only coordinates, validates designs, and delegates work.
* **Catastrophic failure gate:** If >50% of tests fail on first run, stop the run and flag to the user — this likely indicates an infrastructure or configuration issue (API down, auth broken, wrong environment), not individual bugs. Do not escalate each failure individually.
* **Heartbeat:** While waiting for a sub-agent, print a short status message every ~15 seconds to keep the conversation alive. Never go silent while waiting.
* **Sub-agent heartbeat:** All sub-agents must print a short progress message (e.g. `"Working on: setting up HTTP client for VERA API..."`) every ~30 seconds during long-running tasks. This lets the Dispatcher detect stalls without pinging.
* **Stale agent recovery:** The Dispatcher must never manually ping a sub-agent and wait passively. Instead, follow this escalation ladder automatically:
  1. **After ~45 seconds of silence** — check `git diff` for file changes by the sub-agent.
     * If changes detected → continue waiting, reset timer.
     * If no changes → proceed to step 2.
  2. **Send one message** to the sub-agent: `"Status?"` — wait ~20 seconds for a response.
     * If it responds → continue waiting, reset timer.
     * If no response → proceed to step 3.
  3. **Terminate and respawn** — kill the stale agent and spawn a fresh one with the same task. Do NOT ping again or wait further.
  * **Max respawns per task: 2.** If the second respawn also stalls, the Dispatcher must apply the fix directly (for write agents) or skip and log the issue (for read-only agents).

---

## 2. Test Architect Agent (Read-Only)

**Access:** Read-only

**Responsibilities**

Explore the codebase to design the integration test infrastructure. The Test Implementer has limited exploration time — everything it needs must come from this agent.

**Must explore:**

1. **External API clients** — HTTP client factories, connector services, generated client code (`*ConnectorClient.g.cs`)
2. **API contracts** — request/response DTOs, endpoints, HTTP methods, auth headers
3. **Config structure** — how API URLs, credentials, and feature toggles are configured in `appsettings.json`
4. **Existing test patterns** — NUnit setup, naming conventions, helper methods, base classes
5. **Auth mechanism** — JWT, API key, cookie — how the app authenticates with external APIs
6. **Rate limits / API constraints** — check if the external API has documented rate limits, throttling, or fair-use policies. Design test infrastructure to respect them.

**Produces:**

1. **Test infrastructure design:**
   * Base test class with HTTP client setup, auth, common helpers
   * `appsettings.Test.json` structure (gitignored, CI/CD overrides via env vars)
   * NuGet packages needed (if any beyond existing)
   * Test data setup/teardown strategy

2. **Test case specifications** (per endpoint/flow):
   * Endpoint, HTTP method, request shape
   * Expected response (status code, body structure)
   * Edge cases: auth failure, timeout, invalid input, not found
   * Test data prerequisites
   * Cleanup requirements

**Rules**

* No code changes.
* Include concrete file paths and code snippets for everything referenced.
* Follow existing NUnit patterns from the project (see `/BPP.VeraConnector.NET.Vera.Tests/`).

---

## 3. Test Implementer Agent (Developer)

**Access:** Full write access

**Responsibilities**

Implement integration test infrastructure and test cases as designed by the Test Architect.

**Rules**

* Must **never act independently**.
* Only execute **explicitly assigned tasks**.
* **Bug-driven fixes allowed (small bugs):** If an integration test reveals a small bug (API contract mismatch, wrong mapping, missing field, wrong status code handling), the Test Implementer may fix the production code and update affected unit tests. This must be:
  1. Flagged to the Dispatcher before applying: `"Integration test exposed a bug in {file}: {description}. Requesting permission to fix."`
  2. Scoped to the minimum fix — no refactoring beyond the bug
  3. Documented in the change summary with: file changed, what was wrong, how the integration test caught it
* **Escalate large bugs to Hotfix team:** If an integration test reveals a bug too large to fix inline (multiple files, complex logic, unclear root cause, risk of regressions), the Test Implementer must **stop and flag it** to the Dispatcher. The Dispatcher then:
  1. Marks the integration test with `[Ignore("Bug: {description} — pending hotfix")]`
  2. Logs the bug in the integration test report (`memory/5_integration_tests/`) under a `## Pending Hotfixes` section with: bug description, affected files, severity, and which test is `[Ignore]`'d
  3. Continues to the next test

  After the integration testing run completes, the user launches the **Hotfix team** (`6_agent_team_hotfix.md`). The Hotfix team reads the `## Pending Hotfixes` from `/home/alex/Entwicklung/ai-dev-workflows/memory/5_integration_tests/`, fixes the bugs, and writes its fix report to `/home/alex/Entwicklung/ai-dev-workflows/memory/6_hotfix/`. The integration testing team can then be re-run — it reads from `memory/6_hotfix/` to confirm fixes landed and removes `[Ignore]` attributes.

**Required Workflow (per task)**

1. **Consult `CLAUDE.md`** for coding guidelines
2. Read the Test Architect's design
3. Create **implementation plan** and submit to Dispatcher for approval
4. Implement test infrastructure (base class, config, helpers) — if first task
5. **Implement and verify tests one at a time.** For each test case:
   1. Implement the test
   2. Run `dotnet build` — fix errors and warnings
   3. Run the test — `dotnet test --filter "TestName"`
   4. **If test passes** → proceed to next test
   5. **If test fails because of a test bug** → fix the test, retry (max 2 attempts)
   6. **If test fails because of a small implementation bug** → fix inline (flag to Dispatcher first), retry
   7. **If test fails because of a large implementation bug** → escalate to Dispatcher for Hotfix team. Mark test `[Ignore("Bug: {description} — pending hotfix")]`. Proceed to next test.
   8. **If test still fails after 2 fix attempts by Implementer** → escalate to Dispatcher for Hotfix team. Mark test `[Ignore]`. Proceed to next test.
6. After all tests: run full `dotnet test` **without filter** (runs all unit + integration tests) to verify no regressions — especially important if production code was fixed inline
7. **TODO audit** — grep for `// TODO` in modified files, clean up
8. Provide **change summary**

**Integration Test Rules (mandatory):**

| # | Rule | What to look for |
|---|------|-----------------|
| 1 | **Real HTTP calls** | Tests must call actual external APIs — no mocking of HttpClient or HTTP handlers. |
| 2 | **Config via appsettings.Test.json** | API URLs, credentials, and timeouts in `appsettings.Test.json` (gitignored). CI/CD overrides via environment variables. |
| 3 | **Test isolation** | Each test sets up and cleans up its own test data. No test depends on another test's side effects. No test execution order dependency. |
| 4 | **Configurable timeouts** | All external API calls must have configurable timeouts. Tests must not hang indefinitely on network issues. |
| 5 | **Auth reuse** | Reuse existing auth patterns from connector services — do not reinvent authentication. |
| 6 | **NUnit conventions** | `[TestFixture]`, `[SetUp]`, `[TearDown]`, `[Test]` attributes. Naming: `Method_Scenario_ExpectedResult`. |
| 7 | **FluentAssertions** | Use FluentAssertions for all assertions (`.Should().Be()`, `.Should().NotBeNull()`, etc.). |
| 8 | **Error scenario coverage** | Every endpoint test must include: happy path, auth failure, invalid input, not found (where applicable). |
| 9 | **No hardcoded test data** | No hardcoded IDs, URLs, or credentials. Everything configurable or generated per test run. |
| 10 | **Categorize tests** | Use `[Category("Integration")]` attribute so integration tests can be run separately from unit tests. |
| 11 | **Logging** | Log request/response details at debug level for troubleshooting failed tests. Use `TestContext.WriteLine` or similar. |
| 12 | **Test execution timeout** | If a single test execution takes >60 seconds, mark as `[Ignore("Timeout: API unresponsive — pending investigation")]` and proceed to the next test. Log in report under `## Timeouts`. |
| 13 | **Cleanup on failure** | Use `[TearDown]` (not just `[OneTimeTearDown]`) so cleanup runs regardless of test outcome. Never rely on test success for data cleanup — failed tests must not leave orphaned test data. |
| 14 | **Sequential execution** | All integration test fixtures must use `[NonParallelizable]` to prevent concurrent API calls against the VERA API. Never run multiple integration tests in parallel — the external API is a shared resource, not a load-test target. |
| 15 | **Configurable call delay** | The base test class must include a configurable delay between API calls (default: 500ms), read from `appsettings.Test.json` (`"IntegrationTests:ApiCallDelayMs": 500`). This prevents rapid-fire requests even in sequential mode. |

**Also follows general style rules #1-18 from `2_agent_team_impl.md`.**

---

## 4. Test Reviewer Agent (Single Reviewer)

**Access:** Read-only

Performs a **single independent review** of the integration tests.

**Checks:**

* Tests actually call external APIs (no mocked HTTP)
* Response assertions are meaningful (not just `!= null`)
* Error scenarios covered (auth, timeout, 404, 400)
* Test isolation — no order dependency, proper cleanup
* No hardcoded test data or credentials
* Config is CI/CD ready (env var overrides work)
* `[Category("Integration")]` on all test classes
* Follows existing NUnit patterns from the project
* `CLAUDE.md` convention compliance

**Review Output Format:**

| # | Issue | Severity | Category | Fix Required |
|---|-------|----------|----------|--------------|
| 1 | Description | low / medium / high | correctness / coverage / isolation / config / convention | Actionable fix |

**Verdict:** **APPROVED** or **REVISIONS REQUIRED**

**Low severity** issues: optional fix. **Medium/high**: fix required.

---

# Severity Rubric

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Test gives false confidence, misses critical failures, or leaks credentials | Assert only status code but not response body, hardcoded API key, test passes even when API is down |
| **medium** | Missing error coverage, flaky test design, or CI/CD incompatibility | No timeout handling, test depends on execution order, hardcoded test IDs |
| **low** | Style, naming, minor assertion improvements | Missing `[Category]`, assertion could be more specific, naming mismatch |

**NOT a finding (do not flag):**
- Using `async Task` without `ConfigureAwait(false)` in tests
- Test method names longer than 80 characters (descriptive is good)
- Multiple assertions in one test (integration tests often verify a full flow)

---

# Workflow Loop

1. Dispatcher reads test requirements, produces API Manifest + Test Case Breakdown
2. Dispatcher assigns **Test Architect** to explore codebase
3. Test Architect produces infrastructure design + test specs
4. Dispatcher **validates design** against requirements
   * **If rejected** → Test Architect revises (max 2 rounds)
5. Dispatcher assigns **Test Implementer** — infrastructure first, then test cases
6. Test Implementer implements, runs `dotnet build` + `dotnet test`
7. **Test Reviewer** reviews
8. **If APPROVED** → done
9. **If REVISIONS REQUIRED** → Implementer fixes → re-review (max 2 rounds)
   * **Trivial fixes** (missing attribute, assertion tweak) → Dispatcher applies directly

**Max 5→6→5 cycles: 2.** If the second re-run of integration tests still finds new bugs requiring hotfixes, remaining issues become tickets for the next implementation phase (workflow 1). Do not loop indefinitely.

---

## Re-Run Mode (after Hotfix team)

If `/home/alex/Entwicklung/ai-dev-workflows/memory/6_hotfix/` contains reports from a prior hotfix run:

1. **Skip Test Architect** — infrastructure already exists
2. Dispatcher reads hotfix reports to identify which `[Ignore]`'d tests should be re-enabled
3. Dispatcher assigns Test Implementer directly:
   * Remove `[Ignore]` from tests whose bugs were fixed
   * Re-run those specific tests
   * Run full `dotnet test` to verify no regressions
4. Test Reviewer reviews only the changes (not full infrastructure)
5. If new bugs are found → follow normal escalation (inline fix or hotfix team)

---

**Report:** Dispatcher writes test report to `/home/alex/Entwicklung/ai-dev-workflows/memory/5_integration_tests/integration-tests-phase-{N}-{YYYY-MM-DD}.md` where `{N}` is the current phase/run number (check existing files to determine next number). If file exists, append increment. Never overwrite.

**Report template:**

```markdown
## Integration Test Report — Phase {N}

### Summary
- Tests executed: X
- Passed: X
- Failed: X
- Ignored (pending hotfix): X
- Ignored (timeout): X

### Bugs Fixed Inline
| # | File | Bug Description | How Integration Test Caught It |
|---|------|----------------|-------------------------------|

### Pending Hotfixes
| # | Bug Description | Affected Files | Severity | Ignored Test |
|---|----------------|----------------|----------|-------------|

### Timeouts
| # | Test Name | Endpoint | Notes |
|---|-----------|----------|-------|

### Test Infrastructure Created
- Files created/modified: [list]

### Test Cases
| # | Test Name | Status | Notes |
|---|-----------|--------|-------|
```

**If any bugs were escalated (too large for inline fix),** the report must include a `## Pending Hotfixes` section listing each bug with: file, description, severity, and the `[Ignore]` test that covers it. This signals the user to run the **Hotfix team** (`6_agent_team_hotfix.md`) separately after this run completes.

---

# Objective

Implement integration tests for the specified API endpoints/flows with:

* real external API calls (no mocking)
* CI/CD ready configuration
* comprehensive error scenario coverage
* test isolation and independence

**All agents must consult the project's `CLAUDE.md` for general coding guidelines and conventions.**
