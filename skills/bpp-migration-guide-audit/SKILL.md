---
name: bpp-migration-guide-audit
description: Use when checking whether BPP endpoint migration guides have been applied in the frontends — phrases like "audit migration guides", "which migration guides are still open", "are the guides applied in cockpit / stella-ui", "mark applied guides [X]", "open UI MRs for open migration guides", "endpoint-migration-guides not marked done". Also the dev→staging pre-check run by bpp-promote-dev-to-staging.
---

# BPP: Audit endpoint migration guides against the UIs

## Overview

Backend repos document breaking API changes as `endpoint-migration-guides/__<n>_<date>_<slug>_[ ].md`; the
guide is done when its filename ends `_[X].md`. This skill finds every guide that is not `[X]` on
`origin/development`, decides with cited evidence whether each target UI already applied it, and then
either marks it done (applied) or opens a UI MR for chaslauer (not applied).

**Core rule: a verdict is evidence, not a guess.** Every `applied` / `not-applied` cites `file:line` or a
commit on the UI's `origin/development`. Anything less is `unclear`, and `unclear` never triggers a write.

## Modes

| Mode | Writes | Go needed |
|---|---|---|
| `report` (default) | none | no |
| `apply` | rename commits in backend repos + UI MRs | yes — the user's explicit go, **or** the go the user gave `bpp-promote-dev-to-staging` for its run |

When the go comes from `bpp-promote-dev-to-staging`, `apply` acts only on the rows that skill printed in
its step-4 preview (it passes them in); never re-derive verdicts or add rows. Just before each write,
re-check that row: the guide is still open/unmarked at the same path on `origin/development` (step 1) and
the step-4 dedupe still finds no open UI MR. If anything changed, skip the row and report it as
`changed since preview`.

## Fixed values

| Field | Value |
|---|---|
| Guide state read from | `origin/<branch>` of the backend repo, `<branch>` = `development` (never a working copy) |
| UI state read from | `origin/development` of the UI repo (local checkouts sit on feature branches) |
| Done-marker commit | ONE per backend repo, on `development`, commits API `move`, message `docs(migration-guides): mark applied guides done [X]` + one body line per guide with its UI evidence |
| UI MR target | `development` of the UI repo |
| UI MR reviewer / assignee | `reviewer_ids=[2027196]` (chaslauer) / `assignee_id` = `glab api user \| jq .id` |
| UI MR title | `feat(<area>): apply <backend repo> migration guide #<n> — <topic>` (prefix `Draft: ` when checks fail) |
| UI MR branch | `feature/migration-guide-<backend repo>-<n>-<slug>` |
| Label | none |

## Workflow

### 1. List guides (deterministic)

Refresh `bpp-project-index` if the manifest is older than 24 h, then:

```bash
bash ~/.claude/skills/bpp-migration-guide-audit/list-guides.sh            # fetches origin/development
bash ~/.claude/skills/bpp-migration-guide-audit/list-guides.sh --no-fetch # report from cached refs
```

TSV `repo  status  path  stem`. `open` = `_[].md` or `_[ ].md` (both forms exist). `unmarked` = no
marker at all — audit it like an open guide and say "unmarked" in the report. `unscanned` lines on
stderr (no local checkout) go into the report too. The repo list is never hard-coded; the script scans
every active backend/unlisted manifest row.

### 2. Read each guide, decide the target UI(s)

`git -C <repo> show "origin/development:<path>"`. FE sections have no single template — match headings
and bullets case-insensitively on `fe|frontend|consumer|to-do|checklist|gui` (`## FE to-do`,
`## Migration Steps (FE)`, `## Frontend Migration Checklist`, `## FE / consumer to-do`,
`## Required FE action (Stella-App)`, `**Frontend action:**` bullets, …).

| Guide says | Target UI | Manifest row |
|---|---|---|
| `brokernet-cockpit-ui`, Cockpit, broker / backoffice / tenant admin | cockpit | `brokernet-cockpit-ui` |
| `bpp-stella-ui`, go-stella, `brokernet-app`, Stella app, Kundenportal, CustomerPerson | stella-ui | `bpp-stella-ui` (local path from the manifest, today `brokernet-app`) |
| per-UI sub-headings (`### brokernet-cockpit-ui`, `### bpp-stella-ui`) | each one, separately | |
| explicit "no FE action" / "keine Auswirkung" / behaviour-only | `no-ui-impact` (counts as applied) | |
| nothing states it | `unclear` | |

Same change in two backend repos (e.g. a bpp-stella guide that mirrors a bpp-backend guide): verdict
each guide on its own; one UI change can close both.

### 3. Verdict per (guide, target UI) — evidence ladder

Search the UI's `origin/development` only: `git -C <ui> grep -n <term> origin/development -- <dir>` and
`git -C <ui> log origin/development --oneline -i --grep=<term>`. Strongest first:

1. Generated client/model contains the new field, route, enum value (cockpit `src/app/api/<svc>/`,
   stella-ui `projects/bpp-stella-common/src/api/<svc>/`); removed fields/routes are gone.
2. Non-generated code uses it (outside `src/app/api` / `src/api`).
3. i18n key present — cockpit keys live in **bpp-backend** `BPP.Backend.NET/BPP.Backend.NET.App/wwwroot/i18n/{de,en}.json`;
   stella-ui keys in `projects/bpp-stella-common/src/lib/i18n/{de,en}.json`.
4. `git log` hit on the guide's ticket key (`BRO-xxxx`), number stem or a UI MR the guide names.

| Evidence | Verdict |
|---|---|
| every FE to-do item has level 1 **and** 2 evidence (or the item needs no code) | `applied` |
| the old route/field is still called, or the new one is absent from the generated client | `not-applied` |
| partial, conflicting, or only level 4 | `unclear` |
| the guide links a UI MR that is still open | `in-flight` (report the `!iid`) |

A guide with two target UIs is `applied` only when both are.

### 4. Dedupe before any MR (never two MRs for one guide)

Per `not-applied` (guide, UI), list open MRs in the UI repo
(`glab api "/projects/<ui enc>/merge_requests?state=opened&per_page=100"`) and skip when any of these hit:

- the description contains the guide's repo-relative path **or** its `__<n>_<date>` stem (numbers repeat: backend has two `__102`, vera two `__1`);
- the title matches `migration guide #<n>` **and** names the backend repo;
- the guide itself links a UI MR (`<ui-repo>!NNNN`, `<ui-repo> !NNNN`) whose state is `opened`.

A hit becomes action `existing !iid`.

### 5. Report

```
repo | guide (stem_slug) | target UI | verdict | evidence (file:line / commit) | action
bpp-backend | __112_2026-10-09_arag-… | cockpit | applied | model …dto.model.ts:18; util …:18; 50cb61636 | mark [X]
bpp-vera-connector | __1_2026-06-10_vera-authz-… | stella-ui | not-applied | vera-customer-sync.service.ts:19 old route | UI MR
bpp-auth | __8_2026-10-22_… | cockpit | in-flight | guide links cockpit !1268 (opened) | none
```

Then the `unscanned` repos. In `report` mode stop here.

### 6. Apply — mark applied guides `[X]` (one commit per backend repo)

Only `applied` / `no-ui-impact` guides. JSON on stdin — the filenames hold brackets and spaces, so never
`-f` fields. A `move` without `content` keeps the content (GitLab commits API docs). Exception: bpp-file
guides also carry `- [ ] Endpoint Migration Guide:` on line 1 — flip that one line to `- [X]` and pass
the content with the move.

```bash
ACTIONS='[]'
for f in "${APPLIED[@]}"; do            # repo-relative paths from step 1
  new=$(printf %s "$f" | sed -E 's/_\[ ?\]\.md$/_[X].md/; t; s/\.md$/_[X].md/')   # open or unmarked
  ACTIONS=$(jq -c --arg o "$f" --arg n "$new" '. + [{action:"move", previous_path:$o, file_path:$n}]' <<<"$ACTIONS")
done
jq -n --arg m "$MSG" --argjson a "$ACTIONS" '{branch:"development", commit_message:$m, actions:$a}' \
  | glab api --method POST "/projects/$ENC/repository/commits" -H 'Content-Type: application/json' --input -
```

`$MSG` = the fixed subject, blank line, one line per guide `<stem_slug>: <UI> — <best evidence>`.
Verify afterwards with `list-guides.sh` (fetch) that those paths now read `done`.

### 7. Apply — one UI MR per not-applied (guide, UI)

Dispatch **one subagent per MR** (parallel is fine, they touch different worktrees). Its brief: the guide
text, the target UI, the step-3 evidence, and this contract:

1. Worktree off the UI's `origin/development`, never the main checkout:
   `git -C <ui> worktree add <ui>.worktrees/<branch> -b <branch> origin/development`, then `npm ci`.
2. Regenerate clients when the guide says so. The `:dev:` variants (`npm run generate:models:dev:<svc>`)
   do **not** work: the services expose `api-doc/v1/swagger.json` only when `IsLocal()` (e.g.
   bpp-vera-connector `Program.cs:299`, bpp-stella `:245`, bpp-auth `:319`), so every dev URL returns 404
   (checked 2026-10-27). Use the plain scripts against `bpp-start-local-stack`, or export the swagger from
   a credential-free worktree of the service (`dotnet swagger tofile`) and run the generator with
   `-i <file>`. Never start a main checkout that holds prod credentials (bpp-vera-connector). If the
   regenerated client still lacks the guide's change, the backend has not merged it yet → Draft, say so.
3. Implement the FE to-do items, nothing else.
4. Checks — all must pass, otherwise open as Draft with the failing output (trimmed) in the description:
   - cockpit: `npm run lint`, `npm run unit-test:ci`, `npx tsc -p tsconfig.app.json --noEmit`
   - stella-ui: `npm run lint`, `npm run typecheck:common`, `npm test -w bpp-stella-web`, `npm test -w bpp-stella-app -- --watch=false --browsers=ChromeHeadless` (plain `npm test` there starts Karma in watch mode with a visible Chrome window and never exits)
5. Cockpit i18n keys belong in bpp-backend — the subagent does not edit bpp-backend; it lists the missing
   keys under "Backend i18n follow-up" and the MR is Draft until they exist.
6. Commit, `git push -u origin <branch>`, then create the MR via the API (`glab mr create` is broken here):

```bash
glab api --method POST "/projects/$UI_ENC/merge_requests" \
  -f source_branch="$BRANCH" -f target_branch=development -f title="$TITLE" \
  -f description="$DESC" -F "assignee_id=$ME" -F 'reviewer_ids=[2027196]'
```

`$DESC` contains, in order: link to the guide
(`https://gitlab.com/<backend path_with_namespace>/-/blob/development/<path, each segment @uri-encoded>`),
the guide's FE to-do list, what was implemented, check results, and verbatim:

> When this MR is merged, mark the guide done in `<backend repo>`: rename `<current path>` -> `<new path>`

with both repo-relative paths spelled out, e.g. `BPP.VeraConnector.NET/BPP.VeraConnector.NET.App/endpoint-migration-guides/__1_2026-06-10_vera-authz-middleware-consolidation_[].md`
-> `BPP.VeraConnector.NET/BPP.VeraConnector.NET.App/endpoint-migration-guides/__1_2026-06-10_vera-authz-middleware-consolidation_[X].md` (keep the guide's real suffix, `_[]` or `_[ ]`). The next audit run also does this automatically once
the MR is merged.

## Common mistakes

- **Reading the local UI checkout** → it is on a feature branch; the verdict must come from `origin/development`.
- **Dedupe on `#<n>`** → numbers repeat per repo and across repos; use the full path or `__<n>_<date>` stem plus repo.
- **Skipping `unmarked` guides** → no marker is still not done; report and audit it.
- **"Applied" from a generated model alone** → regenerated clients prove the swagger changed, not that the feature uses it; need level 2.
- **Acting on `unclear` or `in-flight`** → report only.
- **One commit per guide** → one per backend repo, all its applied guides in one `actions[]`.
- **`-f` fields for the rename** → brackets/spaces break; JSON on stdin.
- **Committing cockpit i18n into bpp-backend from the UI subagent** → out of scope; list it (see `bpp-check-translation-keys`).

## Red flags — STOP

- About to write (commit or MR) in `report` mode or without a go.
- About to open an MR while step 4 found an open MR for the same guide path/stem.
- A verdict without a `file:line` or commit behind it.
- About to edit the UI's main checkout instead of a worktree.
