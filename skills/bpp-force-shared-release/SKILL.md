---
name: bpp-force-shared-release
description: Use when a new BPP.Shared.NET NuGet package must be published without a code change and then rolled out to every consumer — phrases like "force a new bpp-shared package", "trigger a new shared release", "republish bpp-shared", "dummy commit to bpp-shared to get a new package", "new shared package then bump everywhere". Pushes a one-line commit to `.release-trigger` on bpp-shared `development` through the GitLab API, waits for the `publish-dotnet-dev` job to publish that commit's package, then runs bpp-bump-shared-version.
---

# bpp-force-shared-release

## Overview

bpp-shared publishes a package only from a pipeline on `development` (`publish-dotnet-dev`, version
`<yyyy.MM.dd>.<pipeline-iid>+<sha>`). When consumers need a fresh package without a code change — a
broken or ambiguous package in the registry, a runner that cached a stale one, a re-roll after a CI fix —
this skill makes the smallest possible commit that triggers that job, waits for the package, and hands off
to `bpp-bump-shared-version`.

**REQUIRED SUB-SKILL:** `bpp-bump-shared-version` (the fleet rollout). Don't re-implement it here.

## When NOT to use

- A real bpp-shared change was just merged to `development` → it publishes on its own; run
  `bpp-bump-shared-version` once the package is there.
- You only want consumers on the newest existing package → `bpp-bump-shared-version` alone.

## Steps

1. **Check nothing is in flight** that the trigger would race (a running `development` pipeline is fine,
   it just publishes first):
   ```bash
   glab api "/projects/lipso%2Fclients%2Fbrokernet%2Fbpp-shared/pipelines?ref=development&per_page=3" \
     | jq -r '.[] | "\(.id) \(.sha[0:8]) \(.status)"'
   ```
2. **Trigger and wait** — the script ships beside this file (kept out of SKILL.md so skill-argument
   substitution cannot rewrite its shell variables). Run it in the background; it polls every 30 s for up
   to 25 min (`WAIT_SECONDS`):
   ```bash
   bash ~/.claude/skills/bpp-force-shared-release/release.sh "<short reason>"
   ```
   - It writes **one line** (`Forced package release <UTC time>: <reason>`) to `.release-trigger` at the
     bpp-shared root on `development` via a GitLab API commit — no local checkout is touched (the main
     checkout usually carries local `DbMigrator/appsettings.json` edits).
   - Output `PUBLISHED <version>` = done. `FAIL pipeline …` lists the failed jobs; `FAIL timeout` → check
     the pipeline by hand. Never retry blindly on a red pipeline: a failing unit test on `development` is a
     real problem, not a reason to re-trigger.
3. **Verify the newest package is the one just published** — its version ends with `+<sha>` of the
   trigger commit, and it is the top row:
   ```bash
   glab api "/projects/lipso%2Fclients%2Fbrokernet%2Fbpp-shared/packages?package_name=BPP.Shared.NET&order_by=created_at&sort=desc&per_page=2" \
     | jq -r '.[] | "\(.version) \(.created_at)"'
   ```
4. **Roll out:** invoke `bpp-bump-shared-version`. Report its summary groups (updated local / API,
   skipped, unverified) as it prints them.
5. **Open MRs that pin the previous version** get a `Directory.Build.props` conflict on the
   `<BppSharedVersion>` line only if they changed that line themselves (e.g. an earlier bump on the
   branch). Check with
   `git merge-tree --write-tree --name-only origin/<branch> origin/development` and, if needed, merge
   `development` and take its value — never rebase.

## Common mistakes

| Mistake | Fix |
|---|---|
| Editing `Readme.md`/code for the trigger | Only `.release-trigger` — a real-looking change confuses reviewers and the daily audit |
| Committing in the main bpp-shared checkout | API commit (the script); the checkout has local edits and other agents share it |
| Assuming the newest package is yours | Match the `+<sha>` of the trigger commit (the script does) |
| Re-triggering after a red pipeline | Read the failed job first; fix the cause |
| Bumping before the package exists | Wait for `PUBLISHED`; the bump skill takes the newest package by `created_at` |
| Two packages on one day = same NuGet version | Fixed 2026-11-02 by the `<date>.<pipeline-iid>+<sha>` scheme; if a consumer still restores old code, check the registry for versions that differ only after `+` |

## Red flags — STOP

- The trigger commit would touch anything but `.release-trigger` → STOP.
- `development` pipeline is red before you trigger → STOP and report; a new package would not help.
- About to force-push or rewrite `development` history → STOP.
