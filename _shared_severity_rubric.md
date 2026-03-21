# Shared Severity Rubric

All reviewers must use this rubric when assigning severity:

| Severity | Definition | Examples |
|----------|-----------|----------|
| **high** | Data loss, security breach, crash, or core spec requirement completely missing/broken | SQL injection, unhandled null causing 500, entire feature not implemented |
| **medium** | Incorrect behavior, spec deviation, or degraded performance that affects users | Wrong business logic output, N+1 queries on hot paths, missing auth check on non-critical endpoint |
| **low** | Minor issues, style violations, edge cases unlikely to occur in practice | Missing `AsNoTracking()` on low-traffic read, naming convention mismatch, CLAUDE.md style violation |

## NOT a Finding (do not flag)

- Plan says 7 steps but implementation has 9 — step count mismatches are irrelevant if logic is complete
- Default `CancellationToken` parameter values — idiomatic C#
- Minor naming differences between plan and implementation
- Reordering of steps that doesn't affect behavior
- Implementation using a different (but correct) approach than the plan described
