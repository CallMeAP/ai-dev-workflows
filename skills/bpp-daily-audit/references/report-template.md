# Phase F — Report

Model **Haiku 4.5**, effort **low** — this is templating structured data, not analysis. The findings
are already decided; the report renders them.

Path: `reports/<YYYY>/<MM>/<YYYY-MM-DD-HHMM>-audit.md` in `bpp-audit-reports`.

**A report is written on every run, including zero-finding days and including partial runs.** A day
with no report file means nobody ran the audit — that distinction only survives if the empty days are
actually written.

## Template

```markdown
# BPP daily audit — <YYYY-MM-DD HH:MM>

**Run:** <RUN_ID> · **Status:** complete | partial
**Models:** reviewers Sonnet 5 · debate Sonnet 5 · adjudication Opus 5 · MRs Opus 5 · report Haiku 4.5

## Summary
<N> work items · <F> findings after dedup · <M> MRs · <E> escalations · <D> deferred

## Scanned
| Repo | Branch | From | To | Commits | Result |
|---|---|---|---|---|---|
| bpp-backend | development | d057741ba | 8f21c4e0a | 4 | 2 findings |
| bpp-stella | staging | — | — | — | no staging branch |
| bpp-file | development | a1b2c3d4e | — | — | ⚠ compare failed — ledger not advanced, retried next run |

## Findings
| Severity | Repo/branch | Ticket | Lens | Claim | Debate | Outcome |
|---|---|---|---|---|---|---|

## MRs opened
| Repo | MR | Target | Finding | Tests |
|---|---|---|---|---|

## Escalations
| Repo | Ticket | Why not an MR | File |
|---|---|---|---|

## NuGet sweep
| Repo | Outdated | Vulnerable | Action |
|---|---|---|---|

## Deferred to next run
| Repo | Branch | Reason |
|---|---|---|

## Degradations
<anything that reduced coverage: repos.md unreachable, caps hit, a dynamic verification downgraded,
an auth failure, a `rules.md` entry that failed to parse (name it — the check did not run), a shared
standards file unreachable (name the file AND the rule id it disabled, e.g. "`angular/CLAUDE.md`
unreachable — `fe-shared-angular-standard-violation` did not run on 2 UI repos"). Empty section
means nothing degraded — say so explicitly rather than omitting it.>
```

## Honesty rules

- A cap that fired is a **degradation**, listed with exactly what it deferred. Never present a capped
  run as a complete one.
- A repo whose compare failed appears in **Scanned** with the failure and the note that its ledger
  SHA was not advanced — not omitted, and not folded into "no changes".
- `no staging branch` is an expected topology outcome and is reported as such, never as an error.
- Test results are reported as they happened, including "not run".
- If `bpp/repos.md` was unreachable, the report says the repo cross-check was skipped and the repo
  set may be incomplete.
- **A shared standards file that could not be fetched is a degradation, never a silent skip.** Name
  the file, the rule id it disabled, and how many repos of that kind went unchecked as a result. The
  run is still complete — those rules are additive, not the checklist (`rules-fetch.md` vs
  `shared-standards-fetch.md`) — but "0 findings" from a rule that never ran overstates coverage.
- **The reverse delta is reported too.** Any audited repo the authoritative `bpp/repos.md` does not
  name is listed as "in the group but not in `repos.md`: …" — the run found a gap in the list of
  record, and it stays visible until someone fixes the list upstream. Measured 2026-09-09: three such
  repos, two of them committed to that day (`references/discovery.md` §A1).

## Status file and notification

```bash
mkdir -p "$HOME/.local/state/bpp-daily-audit"
printf '%s — %s: %d findings, %d MRs, %d escalations — %s\n' \
  "$RUN_ID" "$STATUS" "$F" "$M" "$E" "$REPORT_URL" \
  > "$HOME/.local/state/bpp-daily-audit/last-run.md"

if [ "$E" -gt 0 ] || [ "$STATUS" = "partial" ]; then
  command -v notify-send >/dev/null && notify-send "BPP audit: $STATUS" "$E escalations, $M MRs" || true
fi
```

Exit non-zero on a partial or failed run so the systemd unit enters `failed` state and shows up in
`systemctl --user list-units --failed`.
