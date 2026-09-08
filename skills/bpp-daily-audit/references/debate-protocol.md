# Phase C — Debate

Model **Sonnet 5**, effort **medium**. **Every** finding is debated — this is a deliberate choice,
not an oversight, and it is why the reviewer and debate tiers stay off Opus.

## Round structure

One round. Each of the three reviewers receives:

- its own findings for the work item,
- the other two agents' findings for the same work item,
- the same diff and file context it had in Phase B.

Each must, for **every** finding not its own, return exactly one of:

| Response | Meaning | Requires |
|---|---|---|
| `concur` | the finding is real as stated | — |
| `rebut` | the finding is wrong | a concrete counter-argument: the code path, guard or call site that makes it not fire |
| `refine` | real, but the claim or severity is wrong | the corrected claim and/or severity |
| `abstain` | outside this lens's competence | — |

And for **its own** findings, on seeing the rebuttals: `hold` or `concede`.

## Rules

- **Spot-check a citation before acting on it.** A cited file, guide or line number is an assertion,
  not a fact — verify it exists on `origin/<branch>` (`git show origin/<branch>:<path>`) before it
  changes an outcome. Real case 2026-09-08: a concurrence cited two migration guides that exist only
  in an unmerged sibling worktree.
- **A rebuttal must cite something.** "I don't think that's an issue" is not a rebuttal; it is an
  abstain. A rebuttal without a named code path or guard is discarded and treated as `abstain`.
- **Dissent is preserved, never averaged.** The output carries every position. Phase D reads the
  disagreement; it does not receive a score.
- **Conceding is cheap and expected.** An agent that concedes a wrong finding costs nothing; an agent
  that defends one costs a false-positive MR.
- No second round. If the three still disagree after one round, that *is* the signal — Phase D reads
  a contested finding as a candidate for `needs-human`.

## Output contract

```json
{
  "work_item": "bpp-backend/development/BRO-1234",
  "findings": [
    {
      "fingerprint_input": { "repo": "…", "branch": "…", "file": "…", "rule_id": "…", "claim": "…" },
      "origin": "r1",
      "positions": [
        { "agent": "r2", "response": "concur" },
        { "agent": "r3", "response": "rebut", "argument": "ContractStateCheckerUtil.ValidateContractNotNullOrThrow at line 190 already throws on null, so the dereference at 214 is unreachable." }
      ],
      "origin_final": "concede",
      "consensus": "disputed"
    }
  ]
}
```

`consensus` ∈ `agreed` (origin holds, no unrebutted rebuttal) | `withdrawn` (origin conceded) |
`disputed` (origin holds against a cited rebuttal) | `refined` (claim or severity changed).

`withdrawn` findings still reach the ledger as `false-positive`, so the same claim is not
re-generated and re-debated tomorrow.
