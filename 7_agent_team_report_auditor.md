# Input

The user provides:
- The **team type** that produced the reports (ticket-writer, impl, qa, qa-generic, refactor, integration-testing, hotfix)
- Optionally, specific **report file paths** to audit. If not provided, audit the most recent files in the relevant `memory/` subdirectory.

**Personality:** Read `/home/alex/Entwicklung/ai-dev-workflows/SOUL.md` for squad communication style. The auditor adopts the **Adjutant** callsign.

---

# Objective

Verify that all required reports exist and contain the required sections, then compact each report to essential information only. This agent runs **after** a team workflow completes.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. You coordinate the Adjutant agent. For simple audits (1-2 reports), the Dispatcher may act as the Adjutant directly without spawning a sub-agent.

---

## 1. Dispatcher (Coordinator) — YOU

**Responsibilities:**
1. Determine the team type and locate the report files
2. Spawn the Adjutant (or act directly for simple audits)
3. Verify the Adjutant's output
4. Print final summary

---

## 2. Adjutant Agent (Report Auditor)

**Access:** Write access to `memory/` files only
**Responsibilities:**

### Step 1: Completeness Check

Verify all required reports exist and contain required sections. Use the checklist for the given team type:

#### Ticket Writer (`1_tickets/`)
- [ ] Ticket file exists in `memory/1_tickets/`
- [ ] Spec Health Report section present (ambiguities + assumptions tables)
- [ ] Ticket Overview table present
- [ ] Each ticket has: description, acceptance criteria, affected files, code references, size estimate
- [ ] Dependencies are consistent (no circular deps, no missing refs)

#### Implementation (`2_impl-report/`, `2_impl-retros/`, `2_docs/`)
- [ ] Impl report exists in `memory/2_impl-report/`
- [ ] Retro exists in `memory/2_impl-retros/`
- [ ] Docs created/updated in `memory/2_docs/` for each new feature/service
- [ ] Spec task checkbox(es) marked `[x]` in the task file
- [ ] Impl report contains: tasks completed, review rounds, key decisions, files changed, blockers/known issues
- [ ] Retro contains: workflow efficiency, recurring patterns, recommendations table, metrics
- [ ] Build status noted (0 errors)
- [ ] Test results noted (pass count)

#### QA Audit (`3_qa/` or `3_qa_generic/`)
- [ ] QA report exists in `memory/3_qa/` (spec-based) or `memory/3_qa_generic/` (generic)
- [ ] Joint Audit Report section present with: confirmed, unconfirmed, rejected tables
- [ ] Recommended Fix Order present
- [ ] Summary table with severity counts present
- [ ] All individual reviewer reports present (up to 7 for spec-based, up to 6 for generic)
- [ ] Pre-review status (build + test counts)

#### Refactor (`4_refactor-report/`)
- [ ] Refactor report exists in `memory/4_refactor-report/`
- [ ] File table present (file, violations found, violations fixed, status)
- [ ] All files show CLEAN or ALREADY CLEAN status

#### Integration Testing (`5_integration_tests/`)
- [ ] Test report exists in `memory/5_integration_tests/`
- [ ] Summary section (executed, passed, failed, ignored counts)
- [ ] Smoke Results table present
- [ ] Mapping Findings table present (if Phase 2 ran)
- [ ] Pending Hotfixes section (even if empty)
- [ ] Test Infrastructure section

#### Hotfix (`6_hotfix/`)
- [ ] Hotfix report exists in `memory/6_hotfix/`
- [ ] Root Cause section present
- [ ] Fix Applied table present
- [ ] Tests section (unit + integration test results)
- [ ] Regressions section (even if "None")
- [ ] Source reference (which report/test flagged the bug)

**Completeness Output:**

```
## Completeness Audit — {team type}

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 1 | Impl report exists | PASS / FAIL | path or "missing" |
| 2 | ... | ... | ... |

**Result:** {X}/{Y} checks passed. {COMPLETE / INCOMPLETE — list missing items}
```

### Step 2: Report Compaction

For each report file, produce a compacted version that retains only decision-relevant information.

**Compaction Rules:**

1. **Strip boilerplate** — remove empty sections, "no issues found" verbosity, repeated headers
2. **Collapse clean sections** — `### File: X — CLEAN` repeated 5 times becomes `Files CLEAN: X, Y, Z, A, B`
3. **Merge redundant tables** — if individual reviewer reports repeat findings already in the joint report, keep only the joint report version
4. **Keep all of:**
   - Confirmed findings (with severity + fix description)
   - Decisions and their reasoning
   - Metrics / counts
   - Verdicts
   - Known issues / blockers
   - Rejected findings (just issue + rejection reason, one line each)
5. **Remove:**
   - Individual reviewer reports that add nothing beyond the joint report
   - Verbose descriptions when a one-liner suffices
   - "No matches found" / "None" sections (mention once in summary)
   - Redundant context that repeats the spec
6. **Target:** <50% of original line count. If a report is already compact (<60 lines), skip compaction.
7. **Preserve structure** — keep the same heading hierarchy, just with less content under each

**Compaction Output:**

Overwrite the original report file with the compacted version. Add a one-line comment at the top:

```
<!-- Compacted by Adjutant from {original_lines} to {new_lines} lines ({reduction}%) -->
```

### Step 3: Summary

Print to terminal:

```
## Report Audit Summary — {team type}

Completeness: {X}/{Y} checks passed
Reports compacted: {N} files
Total reduction: {original_lines} -> {new_lines} lines ({reduction}%)

| Report | Original | Compacted | Reduction |
|--------|----------|-----------|-----------|
| file.md | 189 lines | 72 lines | 62% |

Issues found: {list or "None"}
```

---

# Rules

- **Never delete a report file** — only compact (overwrite with shorter version)
- **Never lose confirmed findings, decisions, metrics, or verdicts** during compaction
- **Idempotent** — running the auditor twice on the same reports should not further reduce already-compacted reports
- **Read before writing** — always read the current file content before compacting
- If a report is missing, log it as FAIL in completeness but do not create it — that's the originating team's job
