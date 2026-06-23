---
name: bpp-create-mr
description: Use when turning current local work in a BPP .NET repo into a reviewed merge request — phrases like "create an MR", "open a merge request for my changes", "MR my pending work", "push this and make an MR", "create MR and run unit tests". Auto-branches off a protected branch, commits unstaged work, pushes, creates a GitLab MR targeting development with apittrich as reviewer, runs unit tests, and pings when ready for an e2e run.
---

# bpp-create-mr

## Overview

One-shot path from local work → reviewed MR in a BPP GitLab repo. Auto-creates a feature branch when on a protected branch, commits pending changes, pushes, creates (or reuses) an MR targeting `development` with **apittrich** as reviewer, then runs the **unit** test suite as a regression gate. On green it pings the user that e2e can start; on red it reports the failures and pings — it never runs the e2e/integration suite itself (that's `bpp-run-integration-tests`).

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

### 4. Push

```bash
git push -u origin "$BRANCH"
```

Never `--force`. A push to an existing MR's source branch updates that MR automatically — that satisfies "auto-push all changes to this MR".

### 5. Create or reuse the MR

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

### 6. Unit tests (regression gate)

Run unit tests only — exclude integration suites (they need the local stack and burn bpp-auth logins):

```bash
SLN=$(find . -maxdepth 2 -name '*.sln' | head -1)
dotnet test "$SLN" --filter "Category!=LocalIntegration&Category!=Integration" --nologo
```

If no `.sln`, run each `*.Tests.csproj` with the same `--filter`. Capture pass/fail counts + failing test names.

### 7. Report + ping

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
| Push | `git push -u origin <branch>` |
| Existing MR? | `glab api .../merge_requests?state=opened&source_branch=<b>&target_branch=development` |
| Create MR | `glab mr create -R brokernet/<repo> -b development --reviewer apittrich --fill --yes` |
| Unit tests | `dotnet test <sln> --filter "Category!=LocalIntegration&Category!=Integration"` |
| Ping | `PushNotification(status="proactive", message="…")` |

## Common Mistakes

- **Letting `glab` pick `glab-base`** → MR lands in bpp-shared. Always pin `-R brokernet/<repo>` from `origin`.
- **MR'ing from a protected branch** → `development→development` is empty / rejected. Auto-create a `feature/*` branch first.
- **Including integration tests in the gate** → they need the local stack and trip bpp-auth's 429; this skill is unit-only (`Category!=LocalIntegration&Category!=Integration`).
- **Duplicating an MR** → query open MRs for the source branch first; a push already updates an existing one.
- **`--force` push** → never.
- **Editing tests to go green** → out of scope; report red and stop.
- **Pinging e2e-ready when tests are red** → only ping "start e2e" on green.

## Red Flags — STOP

- `origin` is not `brokernet/*`, or resolves to `bpp-shared` → STOP, ask the user.
- About to create an MR without pinning `-R` → STOP.
- Clean tree with nothing ahead of `origin/development` → STOP, nothing to MR.
- About to `git push --force` or run e2e/integration tests → STOP (e2e is a separate, user-triggered run).
