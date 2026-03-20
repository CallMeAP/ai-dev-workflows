# Input

The user provides:
- A **spec file** describing the feature/task to implement

Provided via conversation context (opened file, message, or attached file).

---

Analyze the spec and produce detailed, implementation-ready tickets that a developer (or an Implementer agent) can pick up without needing to re-read the spec.

Use a **3-agent system** with strict role separation.

> **Important:** You (the root agent receiving this prompt) **are** the Dispatcher. Do NOT spawn a separate agent for the Dispatcher role. You coordinate directly and only spawn sub-agents for the Codebase Analyst and Ticket Writer.

---

## 1. Dispatcher Agent (Coordinator) — YOU, the root agent

**Access:** Read-only
**Responsibilities**

* Read the spec and identify all features / tasks / requirements to be ticketed.
* Read **`CLAUDE.md`** for project conventions and architecture context.
* Assign the Codebase Analyst to explore relevant areas of the codebase.
* Pass the analyst's findings + spec to the Ticket Writer.
* **Review tickets** for completeness, correctness, and proper dependency ordering before finalizing.
* Produce the final ticket output file.

**Rules**

* No code changes.
* Only coordinates, validates, and delegates.
* **Heartbeat:** While waiting for a sub-agent, print a short status message (e.g. `"⏳ Waiting for Codebase Analyst..."`) every ~15 seconds to keep the conversation alive. Never go silent while waiting.
* **Stale agent recovery:** If a sub-agent has not reported back within ~60 seconds, check if it has made any file changes (e.g. via `git status`). If it has made changes, continue waiting. If no changes, terminate it and spawn a fresh agent with the same task.

---

## 2. Codebase Analyst Agent (Read-Only)

**Access:** Read-only

**Responsibilities**

Explore the codebase to provide the Ticket Writer with concrete implementation context. The Ticket Writer has no codebase access — everything it needs must come from this agent.

**For each feature/task identified by the Dispatcher, produce:**

1. **Relevant files** — full paths + short description of each file's role
2. **Existing patterns** — how similar features are already implemented (reference files, method signatures, class structures)
3. **Entities & relationships** — relevant database entities, their properties, and relationships
4. **Extension points** — where new code should be added (e.g. existing service interfaces to extend, DI registration locations, mapping profiles)
5. **Key code snippets** — concrete code excerpts that the implementation should follow or extend (max 30 lines per snippet, with file path + line numbers)
6. **Dependencies** — external services, NuGet packages, other modules involved

**Rules**

* No code changes.
* Always include file paths and line numbers with code references.
* If a pattern doesn't exist yet (greenfield), note the closest analogous implementation.

---

## 3. Ticket Writer Agent (Read-Only)

**Access:** Read-only (reads only spec + analyst findings, no codebase access)

**Responsibilities**

Transform the spec requirements + analyst findings into structured tickets.

**Per ticket, produce:**

```markdown
## T-{number}: {Title}

**Complexity:** S / M / L
**Dependencies:** T-{x}, T-{y} (or "None")

### Description
Brief explanation of what needs to be done and why.

### Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] ...

### Affected Files
| File | Action | Notes |
|------|--------|-------|
| `path/to/file.cs` | modify / create | what changes |

### Code References
Key snippets from the codebase to follow or extend:

```csharp
// path/to/reference.cs:42-55
<relevant code snippet from analyst>
```

### Implementation Notes
- Concrete guidance on approach, patterns to follow, gotchas
- Reference to similar existing implementation if applicable

### Edge Cases
- Edge case 1 — how to handle
- Edge case 2 — how to handle

### Open Questions
- Any ambiguities or decisions that need clarification before implementation
```

**Ticket rules:**

* **One logical unit per ticket** — a ticket should touch max ~3-5 files and represent a single deliverable (e.g. one service, one endpoint, one DTO set)
* **Dependency order** — tickets must be ordered so that dependencies come first. If T-3 depends on T-1, T-1 must come first.
* **Acceptance criteria must be testable** — each criterion should be verifiable (e.g. "returns 404 when entity not found", not "handles errors properly")
* **No vague language** — avoid "should handle appropriately", "needs to be robust", etc. Be specific.
* **Code references are mandatory** — every ticket must include at least one concrete code snippet or file reference from the analyst's findings

---

## 4. Spec Ambiguity Detection

Before producing tickets, the Ticket Writer must first scan the spec for ambiguities and produce a **Spec Health Report**.

**Flag as ambiguities:**

| Type | Example | How to flag |
|------|---------|-------------|
| **Vague requirement** | "should handle errors gracefully" | What errors? What does gracefully mean? |
| **Missing behavior** | Spec says "create entity" but no mention of validation rules | What fields are required? What are the constraints? |
| **Implicit assumptions** | "update the entity" but no mention of partial vs full update | PUT with all fields or PATCH-style partial update? |
| **Missing edge cases** | "delete entity" but no mention of dependent entities | What happens if the entity has children? |
| **Contradictions** | Spec says "all fields required" in one place and "optional description" in another | Which one is correct? |
| **Missing integration points** | "sync with external system" but no API contract or error handling specified | What endpoint? What payload? What on failure? |

**Ambiguity report format:**

```markdown
## Spec Health Report

### Ambiguities Found

| # | Spec Section | Issue | Impact | Suggested Resolution |
|---|-------------|-------|--------|---------------------|
| 1 | "Create customer" | No validation rules specified for email field | Tickets may have incomplete acceptance criteria | Clarify: required? format validation? unique constraint? |

### Assumptions Made
If the Ticket Writer proceeds despite ambiguities, each assumption must be explicitly documented:

| # | Assumption | Based On | Risk |
|---|-----------|----------|------|
| 1 | Email is required and must be unique | Common pattern in codebase (`CustomerEntity` has unique index) | low — may need adjustment if spec intended otherwise |
```

**Rules:**

* **Blocking ambiguities** (contradictions, missing core behavior) → flag and do NOT produce tickets for that section until resolved
* **Non-blocking ambiguities** (missing edge cases, implicit assumptions) → document assumption, produce ticket, mark assumption in ticket's "Open Questions"
* The Dispatcher presents ambiguities to the user for resolution before finalizing tickets

---

# Workflow

1. Dispatcher reads the spec and `CLAUDE.md`, identifies features/tasks to ticket
2. Dispatcher assigns **Codebase Analyst** to explore relevant codebase areas
3. Analyst produces findings (files, patterns, entities, snippets, dependencies)
4. Dispatcher passes spec + analyst findings to **Ticket Writer**
5. Ticket Writer produces **Spec Health Report** first
   * If blocking ambiguities → Dispatcher presents to user → waits for resolution → back to step 5
   * If non-blocking only → proceeds with documented assumptions
6. Ticket Writer produces tickets in dependency order
7. Dispatcher **reviews tickets** for:
   * Completeness — all spec requirements covered
   * Dependency ordering — no forward references
   * Actionability — each ticket can be picked up independently (given its deps are done)
   * Code references — every ticket has concrete file/snippet references
8. Dispatcher writes final output to `docs/tickets-{feature-name}.md`

---

# Final Output

The output file contains:

1. **Spec Health Report** (ambiguities + assumptions)
2. **Ticket Overview** — summary table:

| # | Title | Complexity | Dependencies | Status |
|---|-------|-----------|--------------|--------|
| T-1 | ... | S | None | Ready |
| T-2 | ... | M | T-1 | Blocked by T-1 |

3. **All tickets** in dependency order (full detail)
