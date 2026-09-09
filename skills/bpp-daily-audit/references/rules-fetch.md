# The rule set — fetch contract

`rules.md` in `bpp-audit-reports` is **the checklist of what the audit looks for**. It is data, not
prose in this skill. Phase A fetches it; Phase B drives the reviewer lenses from it.

## Where it comes from

Primary source is the local checkout — the same one `common-issues.md` and `known-non-issues.md` are
read from, so there is one code path and one pulled state:

```bash
REPORTS=~/Entwicklung/bpp/bpp-audit-reports
git -C "$REPORTS" pull --ff-only -q
cp "$REPORTS/rules.md" "$WORK/rules.md"
```

Fallback, when the checkout is absent or the pull failed (project id `86222771`, branch `main`):

```bash
glab api "/projects/86222771/repository/files/rules.md/raw?ref=main" > "$WORK/rules.md"
```

**`$WORK/rules.md` is the only copy anything else reads.** Phase B never re-fetches, so every
reviewer in a run sees the identical rule set. A rule edited mid-run does not take effect until the
next run — that is intended.

## Parse

Rules are `### \`<id>\`` headings with a fixed field list. Count them before use:

```bash
grep -cE '^### `[a-z0-9.-]+`$' "$WORK/rules.md"
```

Group membership comes from the `# Backend (.NET)` / `# Frontend` / `# Infra / CI / config` /
`# Cross-cutting` headings above each entry, and each rule repeats it in its `scope:` field. When the
two disagree, `scope:` wins — it is the field the filter reads.

## Failure handling — abort, do not degrade

**If both sources fail, or the file parses to zero rules: abort the run, write a partial report,
exit non-zero.** Same treatment as a `glab` / `acli` auth failure.

Why this is stricter than the other two memory files: `common-issues.md` and `known-non-issues.md`
are *modifiers* — they raise and lower a reviewer's sensitivity, and a run without them is a worse
run that still checks the right things. `rules.md` **is** the thing being checked. A run without it
reviews against nothing but the lenses' own judgement, produces a report that looks complete, and
records watermarks and fingerprints as though the rules had been applied — so the gap is invisible
tomorrow. Silently reviewing less is the one failure this pipeline cannot detect after the fact.

There is also no useful partial state: both sources failing means the reports repo is unreachable, so
the run could not commit its report or advance its ledger anyway.

**A partial parse is different.** If the file loads and *some* rules parse, continue with those and
name every unparseable entry in the report's Degradations section. Losing one rule is a degradation;
losing all of them is an abort.

## Scope filter — Phase B

A reviewer is given only the rules whose `scope` matches the repo under review, plus every `cross`
rule. A rule whose `applies-to` excludes the repo is dropped as well.

| Repo kind | Rules passed |
|---|---|
| .NET repo (`bpp-backend`, `bpp-auth`, `bpp-stella`, `bpp-file`, …) | `backend` + `infra` + `cross` |
| UI repo (`brokernet-cockpit-ui`, `bpp-stella-ui`, `servo-ui`, …) | `frontend` + `infra` + `cross` |
| `infra`, `brokernet-document-cms` | `infra` + `cross` |

**A frontend repo is never checked against backend rules.** Passing `be-mapper-shape-violation` to a
reviewer looking at Angular guarantees either silence or an invented finding.

**A rule that does not apply is skipped, never reported as clean.** "0 findings" must mean the rule
ran, or the report overstates coverage.

## Not the only standards a reviewer gets

`rules.md` is the checklist. **Two further standards files are fetched from a different repo** —
`.net/CLAUDE.md` and `angular/CLAUDE.md` in `lipso/internal/agentic-coding-knowledge` — and handed to
R3 beside the audited repo's own `CLAUDE.md`. They have their own contract, in
**`references/shared-standards-fetch.md`**, deliberately kept out of this file: their failure
behaviour is **degrade loudly**, the exact opposite of the abort above, and the two policies must not
sit under one heading where the wrong one gets copied. That file argues the difference.

Precedence in one line: **specific `be-*` / `fe-*` id → `cross-claudemd-convention-violation` →
`be|fe-shared-*-standard-violation`**. The audited repo's own `CLAUDE.md` always outranks the shared
file.

## Editing rules

Rules are edited **in `bpp-audit-reports/rules.md`**, committed there, and picked up by the next run.
Never in this skill — see `SKILL.md` → Common mistakes.

Ids go into finding fingerprints. Renaming one re-opens every finding it ever produced, including
findings already escalated, rejected or dismissed. Retire by deletion plus a note in the report; never
by rename.
