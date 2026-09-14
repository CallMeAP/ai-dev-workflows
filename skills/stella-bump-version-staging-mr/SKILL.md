---
name: stella-bump-version-staging-mr
description: Use when the user asks to bump go-stella's app version (minor or patch) and ship the bump to staging in the bpp-stella-ui (formerly brokernet-app) GitLab repo. Triggered by phrases like "raise the version", "bump version", "release a new version to staging", "create staging deployment MR", "cut a staging release", "bump and create staging MR", "increase version and open MR to staging". Do NOT use for prod releases — those use the `prod-deployment` label and a different process. Do NOT use for one-off file edits or staging MRs that aren't a release bump.
---

# Bump go-stella version + open staging-deployment MR

## When to use

- User wants to bump the app's version across **all** config files and ship the bump to staging.
- User has specified bump type: **`minor`** or **`patch`**. (Major bumps are NOT handled by this skill — STOP and confirm if asked for major.)
- The repo is `gitlab.com/lipso/clients/brokernet/bpp-stella-ui` (renamed from `brokernet-app` on 2026-09-01), target staging branch `staging`, source `development`.

Do NOT use for:
- Prod release (different label `prod-deployment`, different review path).
- A version-only edit without releasing (just edit by hand if you really need that).
- A staging MR that ISN'T a release bump (use a normal MR flow).

## Repo layout — the app is NOT at the repo root

`bpp-stella-ui` became an **npm-workspaces monorepo** (`BRO-1172`). Everything version-bearing lives under
`projects/bpp-stella-app/`:

| What | Path |
|---|---|
| App manifest (the release version) | `projects/bpp-stella-app/package.json` |
| Android | `projects/bpp-stella-app/android/app/build.gradle` (`versionName`) |
| iOS | `projects/bpp-stella-app/ios/App/App.xcodeproj/project.pbxproj` (`MARKETING_VERSION`) |
| Angular envs (12 files) | `projects/bpp-stella-app/src/environments/` (`appVersion`) |
| Lockfile workspace entry | `package-lock.json` at the **repo root**, key `"projects/bpp-stella-app"` |

**The root `package.json` is a pure workspace orchestrator pinned at `0.0.0` — it is NOT the app version
and must NEVER be bumped.** Sibling workspaces `projects/bpp-stella-common` and `projects/bpp-stella-web`
have their own versions and are out of scope for this skill.

## Why this needs a skill

The version string lives in 16 places across 4 ecosystems (npm workspaces, Gradle, Xcode pbxproj, Angular envs). Four failure modes that have bitten this repo:

1. **Missing a file** → app reports inconsistent versions (e.g. iOS shows old, Angular shows new). Always verify exactly **16 files changed** before commit.
2. **iOS pbxproj has 8 `MARKETING_VERSION` lines but only 6 belong to the main app.** The other 2 lines (currently `1.0.16`) belong to a separate Xcode target (share/notification extension) with its own release cadence. A naive global replace breaks them.
3. **`staging-deployment` is a GitLab MR label, not a git tag.** Several past attempts created git tags by mistake or omitted the label entirely, breaking the staging deployment automation.
4. **`npm version` is the wrong tool here.** In a workspace repo `npm version -w projects/bpp-stella-app`
   triggers a full `npm install` and rewrites unrelated `package-lock.json` entries (block reordering,
   `libc` arrays dropped, `devOptional` → `dev`) — a measured ~44 insertions / 50 deletions of noise on top
   of the one line you wanted. Patch the lockfile's workspace entry with an anchored `sed` instead.

## Required inputs

Ask once, then proceed:

- **Bump type** — `minor` or `patch`. Refuse `major` and ask the user to confirm — major bumps usually have a release plan.
- **Optional explicit new version** — if the user provides one (e.g. "bump to 1.23.0"), use it as-is and skip auto-compute.

Recent release history (`1.29.1 → 1.30.0 → 1.31.0 → 1.32.0`) is **minor**-cadenced; if the user says "bump"
without a type, confirm rather than guessing.

## Procedure

Run sequentially — every step has a verification gate.

### 1. Pre-flight checks

All four must pass. STOP and ask the user if any fails:

```bash
[ -z "$(git status --porcelain)" ] || { echo "Working tree dirty"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "development" ] || { echo "Not on development"; exit 1; }
git fetch origin && git pull --ff-only origin development
glab auth status >/dev/null 2>&1 || { echo "glab not authenticated"; exit 1; }
```

If the main checkout is on another branch or has unrelated local work, do NOT switch it — add a detached
worktree at `origin/development` instead, bump there, and push with `git push origin HEAD:development`:

```bash
git worktree add --detach ../bpp-stella-ui.worktrees/version-bump origin/development
```

Note: the main checkout may carry untracked Capacitor build artefacts (`android/`, `ios/`, `www/` at the
repo root). Those are generated, not the real native projects — the real ones are under
`projects/bpp-stella-app/`. They also break the "clean tree" gate, which is another reason to use a worktree.

### 2. Compute new version

```bash
OLD=$(node -p "require('./projects/bpp-stella-app/package.json').version")   # e.g. 1.32.0
# patch: 1.32.0 → 1.32.1
# minor: 1.32.0 → 1.33.0
```

Read `OLD` from the **app** manifest, never from the root one (that is `0.0.0`).
Show `OLD → NEW` to the user before editing.

### 3. Update the 16 files

Use targeted, version-anchored patterns so dependency versions in `package-lock.json` and the iOS extension
lines at `1.0.16` are never touched. GNU `sed` — `sed -i "s/…/" <file>`, no `''` argument.

```bash
APP=projects/bpp-stella-app
OLD="1.32.0"
NEW="1.33.0"   # set per user's bump choice

# 1: app manifest (the workspace package — NOT the root shell at 0.0.0)
sed -i "s/^  \"version\": \"$OLD\",$/  \"version\": \"$NEW\",/" "$APP/package.json"

# 2: root package-lock.json — ONLY the workspace entry, never a bare s/$OLD/$NEW/
sed -i "/^    \"projects\/bpp-stella-app\": {$/,+2 s/^      \"version\": \"$OLD\",$/      \"version\": \"$NEW\",/" package-lock.json

# 3: android
sed -i "s/versionName = \"$OLD\"/versionName = \"$NEW\"/" "$APP/android/app/build.gradle"

# 4: iOS — only matching MARKETING_VERSION lines; the 1.0.16 lines stay untouched
sed -i "s/MARKETING_VERSION = $OLD;/MARKETING_VERSION = $NEW;/g" "$APP/ios/App/App.xcodeproj/project.pbxproj"

# 5–16: environments (.ts + appium.js)
for f in environment.ts environment.prod.ts environment.staging.ts environment.test.ts \
         environment.dev.ts environment.emulator.ts environment.nangert.ts \
         environment.mhochmair.ts environment.chaslauer.ts environment.aklaffenboeck.ts \
         environment.apittrich.ts environment.appium.js; do
  sed -i "s/appVersion: '$OLD'/appVersion: '$NEW'/" "$APP/src/environments/$f"
done
```

**Excluded on purpose:** `projects/bpp-stella-app/src/environments/environment.local-network.ts` is stale at
`1.5.0` and is intentionally NOT maintained. Do not update it.

**Never run `npm version`** here — see failure mode 4.

### 4. Verify before commit

```bash
git status --porcelain | wc -l    # MUST be 16
git diff --stat                   # MUST be 16 files, 21 insertions / 21 deletions
```

The `21/21` is exact and worth checking: 15 single-line changes + 6 pbxproj lines.

Three guard assertions that must all hold:

```bash
grep -c "MARKETING_VERSION = 1.0.16;" "$APP/ios/App/App.xcodeproj/project.pbxproj"   # MUST be 2
node -p "require('./package.json').version"                                          # MUST be 0.0.0
grep appVersion "$APP/src/environments/environment.local-network.ts"                 # MUST be 1.5.0
```

If file count ≠ 16, STOP. Likely causes:
- Working tree wasn't actually clean before — undo the changes you didn't expect.
- A new `environment.*` file was added that this skill doesn't know about — bail out and tell the user the skill needs updating.
- The OLD version computed wrong (e.g. you read the root `package.json` instead of the app's) — check and re-run.
- The lockfile sed matched nothing because the workspace key moved — `grep -n '"projects/bpp-stella-app"' package-lock.json` and re-anchor.

The expected file list:

```
package-lock.json
projects/bpp-stella-app/android/app/build.gradle
projects/bpp-stella-app/ios/App/App.xcodeproj/project.pbxproj
projects/bpp-stella-app/package.json
projects/bpp-stella-app/src/environments/environment.aklaffenboeck.ts
projects/bpp-stella-app/src/environments/environment.apittrich.ts
projects/bpp-stella-app/src/environments/environment.appium.js
projects/bpp-stella-app/src/environments/environment.chaslauer.ts
projects/bpp-stella-app/src/environments/environment.dev.ts
projects/bpp-stella-app/src/environments/environment.emulator.ts
projects/bpp-stella-app/src/environments/environment.mhochmair.ts
projects/bpp-stella-app/src/environments/environment.nangert.ts
projects/bpp-stella-app/src/environments/environment.prod.ts
projects/bpp-stella-app/src/environments/environment.staging.ts
projects/bpp-stella-app/src/environments/environment.test.ts
projects/bpp-stella-app/src/environments/environment.ts
```

Cross-check against the previous bump when in doubt:
`git show --stat $(git log --format=%H -1 --grep "bump version to")`

### 5. Commit and push

The user's invocation of this skill is the per-action approval the global GitLab rule requires. If anything in the diff looks unexpected (extra files, non-version lines), STOP and ask.

```bash
git add -u
git commit -m "chore: bump version to $NEW"
git push origin development        # detached worktree: git push origin HEAD:development
```

### 6. Create the staging MR

`staging-deployment` is a GitLab MR **label** (id 49482385, color `#0068B4`), NOT a git tag. Title pattern
matches recent history (`development -> staging`).

`glab mr create` is broken in this environment — use the API directly:

```bash
PROJ="lipso%2Fclients%2Fbrokernet%2Fbpp-stella-ui"
glab api --method POST "/projects/$PROJ/merge_requests" \
  -f source_branch=development \
  -f target_branch=staging \
  -f title="development -> staging" \
  -f description="Release v$NEW" \
  -f labels="staging-deployment" \
  --jq '.iid, .web_url'
```

If the label did not stick, set it separately:

```bash
glab mr update <iid> --label staging-deployment -R lipso/clients/brokernet/bpp-stella-ui
```

### 7. Print the MR URL as the final result

The `web_url` from step 6 is the result. Paste it back to the user.

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `git status --porcelain` shows >16 files after sed | Untracked root `android/`/`ios/`/`www/` build artefacts, stale `environment.local-network.ts` matched, or an unrelated change leaked in | Use a clean detached worktree; `git restore <file>` for the unexpected file; investigate before re-running |
| Only 15 files changed | The `package-lock.json` workspace-entry sed matched nothing | `grep -n '"projects/bpp-stella-app"' package-lock.json`, re-anchor the range |
| Root `package.json` jumped from `0.0.0` to the app version | Ran `npm version` at the repo root, or sed'd the wrong manifest | `git restore package.json`; the root is the workspace shell, never the app version |
| `package-lock.json` diff is ~90 lines instead of 1 | Used `npm version -w …`, which runs a full install | `git restore package-lock.json`, use the anchored sed |
| `package-lock.json` shows dependency versions changed (e.g. `lightningcss` 1.32.0) | Used a too-broad pattern like `s/$OLD/$NEW/g` on the lockfile | `git restore package-lock.json`, use the range-anchored sed |
| iOS `MARKETING_VERSION` lines at `1.0.16` got bumped | Someone replaced `MARKETING_VERSION = .*;` instead of `MARKETING_VERSION = $OLD;` | Revert the pbxproj, re-run with the version-anchored sed |
| `sed: can't read : No such file or directory` | BSD form `sed -i '' "s/…/"` copied from macOS — GNU sed reads `''` as the script | Drop the `''`: `sed -i "s/…/" <file>` |
| MR creation fails with `branch already has an open MR` | Earlier release attempt left an open MR | Either reuse it (`glab mr update <iid> --label staging-deployment`) or close + recreate; do NOT push another release commit on top |
| MR opens without the `staging-deployment` label | Label not passed, or typo | `glab mr update <iid> --label staging-deployment -R lipso/clients/brokernet/bpp-stella-ui` |
| Push rejected (non-fast-forward) | Someone else pushed to `development` since pre-flight | `git pull --ff-only`, re-verify the diff is still 16 version-only files, then push |

## Guardrails

- **NEVER skip the 16-file verification.** A partial bump leaves the app reporting inconsistent versions.
- **NEVER bump the root `package.json`** — it is the workspace orchestrator, pinned at `0.0.0`.
- **NEVER run `npm version`** in this repo — it drags a full `npm install` into the release commit.
- **NEVER replace `MARKETING_VERSION` without anchoring on the OLD version** — the iOS extension lines at `1.0.16` must stay untouched.
- **NEVER touch `projects/bpp-stella-app/src/environments/environment.local-network.ts`** — it's stale on purpose.
- **NEVER use BSD `sed -i ''`** — this environment is GNU sed.
- **NEVER force-push `development`** (global rule).
- **NEVER switch a main checkout's branch** — use a detached worktree.
- **NEVER push a major version bump through this skill.** If the user says `major`, STOP and confirm.
- **NEVER assume `staging-deployment` is a git tag.** It's a GitLab MR label. Do not run `git tag staging-deployment`.
- **If the diff doesn't match exactly the 16 files in the list above, STOP and ask the user.**

## Quick reference — full happy-path run

```bash
# Pre-flight (from a clean detached worktree at origin/development)
git fetch origin
APP=projects/bpp-stella-app

# Compute
OLD=$(node -p "require('./$APP/package.json').version")
NEW="1.33.0"   # minor — for patch: bump PATCH only

# Edit
sed -i "s/^  \"version\": \"$OLD\",$/  \"version\": \"$NEW\",/" "$APP/package.json"
sed -i "/^    \"projects\/bpp-stella-app\": {$/,+2 s/^      \"version\": \"$OLD\",$/      \"version\": \"$NEW\",/" package-lock.json
sed -i "s/versionName = \"$OLD\"/versionName = \"$NEW\"/" "$APP/android/app/build.gradle"
sed -i "s/MARKETING_VERSION = $OLD;/MARKETING_VERSION = $NEW;/g" "$APP/ios/App/App.xcodeproj/project.pbxproj"
for f in environment.ts environment.prod.ts environment.staging.ts environment.test.ts \
         environment.dev.ts environment.emulator.ts environment.nangert.ts \
         environment.mhochmair.ts environment.chaslauer.ts environment.aklaffenboeck.ts \
         environment.apittrich.ts environment.appium.js; do
  sed -i "s/appVersion: '$OLD'/appVersion: '$NEW'/" "$APP/src/environments/$f"
done

# Verify
[ "$(git status --porcelain | wc -l | tr -d ' ')" = "16" ] || { git status --short; exit 1; }
[ "$(grep -c 'MARKETING_VERSION = 1.0.16;' "$APP/ios/App/App.xcodeproj/project.pbxproj")" = "2" ] || exit 1
[ "$(node -p "require('./package.json').version")" = "0.0.0" ] || exit 1

# Commit + push + MR
git add -u
git commit -m "chore: bump version to $NEW"
git push origin HEAD:development
PROJ="lipso%2Fclients%2Fbrokernet%2Fbpp-stella-ui"
glab api --method POST "/projects/$PROJ/merge_requests" \
  -f source_branch=development -f target_branch=staging \
  -f title="development -> staging" -f description="Release v$NEW" \
  -f labels="staging-deployment" --jq '.web_url'   # ← paste this back to the user
```
