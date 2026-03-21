# Input

The user provides:
- **Source files** to refactor (file paths or glob patterns)

Provided via conversation context (opened file, message, or attached file).

**Personality:** Read `/home/alex/Entwicklung/ai-dev-workflows/SOUL.md` for squad communication style. All agents adopt their assigned callsign and tone.

---

Refactor the service implementations in the provided files to match the coding style of the **bpp-file reference codebase**.

This team **consumes QA findings** — the Style & Convention Reviewer in the QA team (`3_agent_team_QA.md`) has already analyzed the code. This team applies the fixes.

Use a **2-agent system** with strict role separation.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn a sub-agent for the Refactorer.

---

## 1. Dispatcher Agent (Coordinator) — YOU, the root agent

**Access:** Read-only
**Responsibilities**

* Read **`/home/alex/Entwicklung/bpp/bpp-backend/CLAUDE.md`** for project conventions.
* **Read QA style findings** from the most recent report in `/home/alex/Entwicklung/ai-dev-workflows/memory/3_qa/`. Look for the **Coding Style & Convention Reviewer** section — this contains per-file style deviation reports with line numbers and suggested fixes.
* If no QA report exists or the style section is empty, fall back to running an independent style analysis using the rules in [_shared_service_style_rules.md](./_shared_service_style_rules.md).
* Identify all files with violations from the QA findings.
* Assign files one-by-one to the Refactorer.
* Track progress per file as a done checklist.

**Rules**

* No code changes.
* Only coordinates and delegates.
* **Dispatcher rules (heartbeat, stale recovery):** See [_shared_dispatcher_rules.md](./_shared_dispatcher_rules.md)

---

## 2. Refactorer Agent (Developer)

**Access:** Full write access

**Responsibilities**

* Receive the style deviation findings (from QA report via Dispatcher).
* Refactor each flagged file to resolve all reported violations.

**Rules**

* **Style-only changes** — do NOT alter business logic, method signatures, return values, or observable behavior.
* **One file at a time** — complete and report before moving to the next.
* After each file, provide a brief change summary (violations fixed, lines changed).
* **Reference:** See [_shared_service_style_rules.md](./_shared_service_style_rules.md) for the full style checklist and reference codebase files.

**Refactoring workflow per file:**

1. Read the QA style findings for the file.
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

1. Dispatcher reads QA style findings from `memory/3_qa/` (or runs independent analysis via [_shared_service_style_rules.md](./_shared_service_style_rules.md) if no QA report)
2. Dispatcher identifies all files with violations
3. Dispatcher assigns files one-by-one to **Refactorer**
4. Refactorer fixes violations, reports back
5. Dispatcher marks file as done, assigns next file
6. After all files done, Dispatcher prints the final summary to the terminal AND writes it to `/home/alex/Entwicklung/ai-dev-workflows/memory/4_refactor-report/refactor-report-run-{N}-{YYYY-MM-DD}.md` where `{N}` is the current run number (check existing files in `/home/alex/Entwicklung/ai-dev-workflows/memory/4_refactor-report/` to determine the next number). If the file already exists, append an increment: `-2`, `-3`, etc. Never overwrite existing files.
7. Dispatcher spawns the **Report Auditor (Adjutant)** per `7_agent_team_report_auditor.md` with team type `refactor`.

**Final summary format:**

| File | Violations Found | Violations Fixed | Status |
|------|-----------------|-----------------|--------|
| `ServiceA.cs` | 5 | 5 | CLEAN |
| `ServiceB.cs` | 0 | 0 | ALREADY CLEAN |
