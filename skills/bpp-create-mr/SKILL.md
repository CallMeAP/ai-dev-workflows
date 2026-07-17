---
name: bpp-create-mr
description: Use when turning current local work in a BPP .NET repo into a reviewed merge request — phrases like "create an MR", "open a merge request for my changes", "MR my pending work", "push this and make an MR", "create MR and run unit tests". Auto-branches off a protected branch, commits unstaged work, pushes, creates a GitLab MR targeting development with apittrich as reviewer, runs unit tests, and pings when ready for an e2e run.
---

# bpp-create-mr

## Overview

One-shot path from local work → reviewed MR in a BPP GitLab repo. Auto-creates a feature branch when on a protected branch, commits pending changes, **verifies the new public surface the branch adds (controller endpoints, public `I*Service` methods, DTO validation/mapper classes) is covered by tests**, pushes, creates (or reuses) an MR targeting `development` with **apittrich** as reviewer, then runs the **unit** test suite as a regression gate. On green it pings the user that e2e can start; on red it reports the failures and pings — it never runs the e2e/integration suite itself (that's `bpp-run-integration-tests`).

## When to Use

- "create an MR", "open a merge request", "MR my changes / pending work"
- "push this and make an MR", "create MR and run unit tests"
- After finishing a chunk of work that should go up for review + regression-checked before e2e.

Not for: bulk dev→staging promotion (`bpp-promote-dev-to-staging`), running e2e/integration tests (`bpp-run-integration-tests`).

## Defaults (non-negotiable unless user overrides)

| Field | Value |
|-------|-------|
| Push remote | `origin` (the cwd repo — **never** `glab-base`) |
| Target branch | `development` |
| Reviewer | `apittrich` |
| Protected branches | `development`, `staging`, `main`, `master` |
| New branch prefix | `feature/` + kebab slug from the diff |
| Commit message | auto-generated, conventional (`feat:`/`fix:`/`chore:` …) from the diff |
| MR title/desc | `glab --fill` (from commit history) |
| Unit test filter | `Category!=LocalIntegration&Category!=Integration` |

## The `glab-base` trap (read first)

BPP repos carry **two** remotes: `origin` → the repo itself, and `glab-base` → `brokernet/bpp-shared`. Bare `glab` may resolve to `glab-base` and create the MR **in bpp-shared**. Always derive the project from `origin` and pin `-R brokernet/<repo>` on every `glab` call.

```bash
REPO=$(git remote get-url origin | sed -E 's#.*/brokernet/([^/]+?)(\.git)?$#\1#')   # e.g. bpp-backend
PROJ="brokernet/${REPO}"
```

## Workflow

### 1. Preflight

```bash
glab auth status >/dev/null 2>&1 || { echo "FAIL — glab not authenticated"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "FAIL — not a git repo"; exit 1; }
```

Resolve `REPO` / `PROJ` as above. If `origin` does not point at `brokernet/*`, STOP and ask.

### 2. Branch resolution

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

- **On a protected branch** (`development`/`staging`/`main`/`master`): generate a concise kebab-case slug (3–6 words) describing the change from `git status` + `git diff` (staged + unstaged), then:
  ```bash
  git switch -c "feature/<slug>"   # uncommitted changes follow into the new branch
  BRANCH="feature/<slug>"
  ```
- **Already on a feature branch**: keep it.

### 3. Commit pending work

```bash
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "<auto conventional message from the diff>"
fi
```

Show the committed message to the user. If the tree was clean AND the branch has no commits ahead of `origin/development`, STOP — nothing to MR.

### 4. Coverage gate — new public surface MUST ship with tests

New functionality is covered by tests or it does not go up. Run this **before** the push/MR so any gap is fixed in the same branch. This gate checks that tests *exist*; the unit suite in step 7 checks that they *pass*.

```bash
git fetch -q origin development
BASE=origin/development
git diff "$BASE...HEAD" --stat   # what this branch changes vs development
```

**4a — Enumerate the NEW public surface** the branch adds (added lines / new files only):

| Surface | Find it |
|---|---|
| New controller endpoints | `git diff "$BASE...HEAD" -- '*Controller.cs' \| grep -E '^\+.*\[Http(Get\|Post\|Put\|Delete)'` |
| New public service methods | `git diff "$BASE...HEAD" -- '*/Services/Interfaces/*' \| grep -E '^\+\s*Task'` |
| New DTO validators / mappers | `git diff "$BASE...HEAD" --name-status --diff-filter=A \| grep -E '(Attribute\|DtoMapper)\.cs$'` |

Write down the concrete members found (route + verb, `I*Service` method names, new `*Attribute` / `*DtoMapper` classes). That list is the gate's input. The grep rows are starting aids, not the source of truth: `--diff-filter=A` surfaces only new *files*, so also read the raw `git diff "$BASE...HEAD"` for public members added to **existing** files (a new method on an existing `I*Service`, a new mapping in a `*DtoMapper`, a new `ValidationAttribute`). If you did not read the diff, you have not enumerated.

**4b — Genuinely no new surface → gate passes.** Passes ONLY when you have read the diff and it adds no endpoint, no `I*Service` method, and no DTO/mapper class — a pure refactor / rename / config-only change. Record "no new public surface" and continue to step 5. A grep that matched nothing is NOT a confirmed-empty diff: a member the grep missed still needs a test.

**4c — For every enumerated member, prove coverage** — in the branch diff OR already present in the repo:

| New member | Coverage it needs |
|---|---|
| Controller endpoint | an integration/e2e test hitting the route (`[Category("Integration")]` / `LocalIntegration`, per the repo's convention) **and** a unit test on the service method behind it |
| Public `I*Service` method | a `{Service}Tests` unit test — happy path **and** the error/404 branch |
| `*DtoMapper` | a `{Entity}DtoMapperTests` asserting each mapped property (read, projection, create, update) |
| Custom `ValidationAttribute` | an `{Attribute}Tests` unit test — one valid + one invalid case |

```bash
git diff "$BASE...HEAD" --name-only | grep -E 'Tests?\.cs$'   # tests added/changed on the branch
git grep -n '<RouteOrMethodName>' -- '*Tests*'                # pre-existing coverage in the repo
```

A test-file match is a lead, not proof — open it and confirm it actually calls/asserts the new member, not merely mocks or name-mentions it.

**4d — Any member without coverage → STOP. Do not push or create the MR yet.** List every uncovered member to the user, then close the gap:

- **Unit gap** → write the `{Class}Tests` / `{Entity}DtoMapperTests` / `{Attribute}Tests` now, `git add -A && git commit`, then continue.
- **Integration/e2e gap for a new endpoint or flow** → add the test per the **`bpp-add-integration-tests`** skill and commit it. (This skill still does NOT run e2e — it only makes the test EXIST; running it stays with `bpp-run-integration-tests`.)
- **Explicit user waiver** → only a statement from the user, in this session, to skip coverage for a *named* member counts. Record which member and that the user waived it.

A green unit suite is NOT coverage: it proves the tests that exist pass, never that a member no test calls is exercised. Never create the MR with uncovered new surface and no named waiver.

| Rationalization | Reality |
|---|---|
| "The unit suite is green, so it's covered" | Green = the tests that exist pass. A new method no test calls is still untested. Coverage = a test that exercises THIS member. |
| "This endpoint/method is too simple to test" | The 404 / validation / auth branch is where simple public surface breaks in prod. Public surface gets a test. |
| "The mapper/attribute is trivial" | Mappers drift silently — that's why every one has `{Entity}DtoMapperTests` per property. Trivial ≠ exempt. |
| "Add the e2e later / in a follow-up MR" | "Later" is exactly how untested surface reached prod before. It lands in THIS branch or the user waives it by name. |
| "Local stack isn't up, so skip the e2e" | This skill doesn't RUN e2e — it requires the test to EXIST. Missing infra is no reason to skip WRITING it. |
| "I'll just note the gap in the MR description" | A note is not a test. STOP and write it, or get a named waiver. |

### 5. Push

```bash
git push -u origin "$BRANCH"
```

Never `--force`. A push to an existing MR's source branch updates that MR automatically — that satisfies "auto-push all changes to this MR".

### 6. Create or reuse the MR

```bash
IID=$(glab api "/projects/$(printf %s "$PROJ" | sed 's#/#%2F#')/merge_requests?state=opened&source_branch=${BRANCH}&target_branch=development" \
  | jq -r '.[0].iid // empty')

if [ -n "$IID" ]; then
  echo "Reusing existing MR !${IID} (push updated it)"
else
  glab mr create -R "$PROJ" \
    --source-branch "$BRANCH" \
    --target-branch development \
    --reviewer apittrich \
    --fill --yes
fi
```

Capture the MR `!iid` + web URL for the final report.

### 7. Unit tests (regression gate)

Run unit tests only — exclude integration suites (they need the local stack and burn bpp-auth logins):

```bash
SLN=$(find . -maxdepth 2 -name '*.sln' | head -1)
dotnet test "$SLN" --filter "Category!=LocalIntegration&Category!=Integration" --nologo
```

If no `.sln`, run each `*.Tests.csproj` with the same `--filter`. Capture pass/fail counts + failing test names.

### 8. Report + ping

- **Green** → ping the user that e2e can start:
  ```
  PushNotification(status="proactive",
    message="<repo> !<iid> ready — unit tests green, start e2e run")
  ```
  Then report the MR URL + test summary in-session.
- **Red** → do NOT signal e2e-ready. Report failing tests in-session and ping:
  ```
  PushNotification(status="proactive",
    message="<repo> !<iid> created but unit tests RED: <n> failed — needs a look")
  ```
  Leave the diagnosis to the user / `bpp-run-integration-tests`; do not edit tests to make them green.

## Quick Reference

| Step | Command |
|---|---|
| Repo from origin | `git remote get-url origin \| sed -E 's#.*/brokernet/([^/]+?)(\.git)?$#\1#'` |
| New branch | `git switch -c feature/<slug>` |
| Commit | `git add -A && git commit -m "<msg>"` |
| New endpoints in diff | `git diff origin/development...HEAD -- '*Controller.cs' \| grep -E '^\+.*\[Http'` |
| New service methods in diff | `git diff origin/development...HEAD -- '*/Services/Interfaces/*' \| grep '^\+.*Task'` |
| Find a member's coverage | `git grep -n <route-or-method> -- '*Tests*'` |
| Push | `git push -u origin <branch>` |
| Existing MR? | `glab api .../merge_requests?state=opened&source_branch=<b>&target_branch=development` |
| Create MR | `glab mr create -R brokernet/<repo> -b development --reviewer apittrich --fill --yes` |
| Unit tests | `dotnet test <sln> --filter "Category!=LocalIntegration&Category!=Integration"` |
| Ping | `PushNotification(status="proactive", message="…")` |

## Common Mistakes

- **Creating the MR before checking new-surface coverage** → new endpoints / `I*Service` methods / DTO mappers ship untested. Enumerate the diff's new public surface (step 4) and prove each has a test — or get a named waiver — first.
- **Treating "unit suite green" as coverage** → the suite passes without ever calling a member no test references. Green ≠ covered; only a test that exercises THIS member counts.
- **Skipping e2e coverage because the local stack is down** → this skill only requires the test to EXIST, not to run; write it (per `bpp-add-integration-tests`) and let `bpp-run-integration-tests` run it later.
- **Letting `glab` pick `glab-base`** → MR lands in bpp-shared. Always pin `-R brokernet/<repo>` from `origin`.
- **MR'ing from a protected branch** → `development→development` is empty / rejected. Auto-create a `feature/*` branch first.
- **Including integration tests in the gate** → they need the local stack and trip bpp-auth's 429; this skill is unit-only (`Category!=LocalIntegration&Category!=Integration`).
- **Duplicating an MR** → query open MRs for the source branch first; a push already updates an existing one.
- **`--force` push** → never.
- **Editing tests to go green** → out of scope; report red and stop.
- **Pinging e2e-ready when tests are red** → only ping "start e2e" on green.

## Red Flags — STOP

- A new endpoint / `I*Service` method / `*DtoMapper` / `ValidationAttribute` in the diff has no matching test and no named user waiver → STOP, do not push the MR (write the test or get the waiver).
- Justifying a skipped test with "too simple", "trivial", "e2e later", or "the stack isn't up" → STOP, write the test or get a named waiver.
- Downgrading missing coverage to an MR-description note instead of a test → STOP.
- `origin` is not `brokernet/*`, or resolves to `bpp-shared` → STOP, ask the user.
- About to create an MR without pinning `-R` → STOP.
- Clean tree with nothing ahead of `origin/development` → STOP, nothing to MR.
- About to `git push --force` or run e2e/integration tests → STOP (e2e is a separate, user-triggered run).
