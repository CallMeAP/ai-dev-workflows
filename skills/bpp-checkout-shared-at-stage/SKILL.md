---
name: bpp-checkout-shared-at-stage
description: Use when the local bpp-shared checkout must be moved to the exact commit a stage branch (staging/main/development) consumes, typically to run DbMigrator locally and apply the EF migrations a stage has but another does not — phrases like "revert bpp-shared to staging state", "which shared version does staging use", "set bpp-shared to the main/staging commit", "apply staging migrations to main", "promote migrations before promoting code", "restore bpp-shared after the migrator run". bpp-shared has only a development branch; this resolves a stage's shared commit from the +<sha> build metadata in every consumer's pinned <BppSharedVersion>. Moves the checkout and prints the migration delta only — it NEVER runs DbMigrator and never touches a connection string.
---

# bpp-checkout-shared-at-stage

## Overview

`bpp-shared` has **no stage branches** — only `development`. But every consumer repo's
`BPP.*/Directory.Build.props` pins `<BppSharedVersion>`, and that version's **`+<sha>` build
metadata IS the bpp-shared commit**. That is what makes a stage's shared state resolvable at all.

The skill resolves the stage's commit, moves the local `bpp-shared` main checkout onto it, prints
which EF migrations that state has over another stage, and stops. **The DbMigrator run is the
user's — this skill never executes it, never reads or edits a connection string, and never
touches a database.**

Typical trigger: promoting staging → main. `main`'s DB is missing the migrations staging already
applied, so the migrator has to run from the *staging* shared state before the code promotion.

## When to Use

- "revert bpp-shared to the staging state", "set bpp-shared to what main uses"
- "which bpp-shared version/commit does staging run?"
- "apply the migrations staging has but main doesn't" (before a `bpp-promote-dev-to-staging` main run)
- "put bpp-shared back" after the migrator run → **restore mode**

Not for: bumping pins (`bpp-bump-shared-version`), creating promotion MRs
(`bpp-promote-dev-to-staging`), running migrations (user does this by hand).

## Defaults (non-negotiable unless the user overrides)

| Field | Value |
|-------|-------|
| GitLab namespace | `lipso/clients/brokernet/<repo>` — **not** `brokernet/<repo>` |
| bpp-shared checkout | `~/Entwicklung/bpp/bpp-shared` (main checkout, never a worktree) |
| Migrations path | `BPP.Shared.NET/BPP.Shared.NET.DbMigrator/Migrations` |
| Pin source | **fleet max by ancestry** across all `bpp-*` consumers on the stage |
| On pin disagreement | **STOP and report** — do not silently take the newest |
| Mechanism | `git reset --hard <sha>` on `development` (user's explicit choice) |
| Restore | `git switch development && git pull` |
| Stage order | `development` > `staging` > `main` (delta defaults to the stage below) |

## Version parsing — do NOT assume `-development`

**The suffix is being removed.** bpp-shared commit `f8c42280` (2026-09-11, Stephan Kast) is
*"remove stage and release builds. remove missleading development name"*, and the first
suffix-less package `2026.9.11+f8c42280` was published the same day. Both shapes are live:

```
2026.9.2-development+28ce29c2    # old scheme, still pinned on staging/main
2026.9.11+f8c42280               # new scheme
```

**Parse the `+` build metadata only. Never grep for `-development`, never filter on it.**

```bash
sha=${version##*+}          # everything after the last '+' — works for both shapes
[ "$sha" = "$version" ] && { echo "no +sha metadata in '$version'"; }   # pre-metadata pin → STOP
```

Some very old pins carry no `+sha` at all (e.g. `2026.8.16-development` in
bpp-cca-connector-internal). Those are **unresolvable** — report them, never guess a commit.

## Workflow

### 1. Resolve the stage's shared commit (fleet max, report disagreement)

Read the pin from every `bpp-*` consumer on the target stage. Folder under the repo root varies
(`BPP.Backend.NET`, `BPP.Push.NET`, `BPP.DocumentAnalysis`, …) — probe root tree dirs matching
`^BPP\.`, take the first whose props contains `<BppSharedVersion>`.

```bash
STAGE=staging
declare -A PIN
for d in ~/Entwicklung/bpp/*/; do
  r=$(basename "$d"); case "$r" in *worktrees*|infra|bpp-shared) continue;; esac
  [ -d "$d/.git" ] || continue
  git -C "$d" fetch -q origin "$STAGE" 2>/dev/null || continue
  git -C "$d" rev-parse --verify -q "origin/$STAGE" >/dev/null || continue
  for dir in $(git -C "$d" ls-tree --name-only "origin/$STAGE" | grep '^BPP\.'); do
    v=$(git -C "$d" show "origin/$STAGE:$dir/Directory.Build.props" 2>/dev/null \
        | grep -oP '(?<=<BppSharedVersion>)[^<]+')
    [ -n "$v" ] && { PIN[$r]="$v"; break; }
  done
done
for r in "${!PIN[@]}"; do printf '%-32s %s\n' "$r" "${PIN[$r]}"; done | sort
```

Then reduce to one commit **by git ancestry, not by version string** — two repos can pin the same
version number with different SHAs (real case: staging pinned both `2026.9.2-development+28ce29c2`
and `2026.9.2-development+d6b4563e`; `d6b4563e` is an ancestor of `28ce29c2` and has one migration
fewer). String comparison picks wrong; ancestry does not.

```bash
cd ~/Entwicklung/bpp/bpp-shared && git fetch -q --all --tags
MAX=""
for v in "${PIN[@]}"; do
  s=${v##*+}; [ "$s" = "$v" ] && continue            # no metadata → handled as unresolvable
  git cat-file -e "$s^{commit}" 2>/dev/null || { echo "STOP — $s not in clone after full fetch"; exit 1; }
  if [ -z "$MAX" ]; then MAX=$s
  elif git merge-base --is-ancestor "$MAX" "$s"; then MAX=$s
  elif ! git merge-base --is-ancestor "$s" "$MAX"; then
    echo "STOP — $s and $MAX are on divergent branches, no fleet max"; exit 1
  fi
done
echo "fleet max on $STAGE: $MAX"
```

**Report disagreement, always.** If the pins do not all resolve to the same commit, print the
per-repo table, name the max and which repos lag, and **ask the user to confirm** before moving the
checkout. Divergent (non-linear) SHAs are a hard STOP — there is no "max".

Cross-check against the package registry when a version looks unpublished or a SHA is missing —
`created_at` is the authoritative publish order and works without a local clone:

```bash
glab api "projects/lipso%2Fclients%2Fbrokernet%2Fbpp-shared/packages?per_page=100&order_by=created_at&sort=desc" --paginate \
  | jq -r '.[] | [.version, .created_at] | @tsv'
```

### 2. Pre-flight the bpp-shared checkout (all guards must pass)

`reset --hard` destroys uncommitted work and moves the branch pointer. Every guard is mandatory:

```bash
cd ~/Entwicklung/bpp/bpp-shared
PRE=$(git rev-parse development)                                  # reflog safety net — PRINT IT
[ "$(git rev-parse --abbrev-ref HEAD)" = development ] || echo "STOP — not on development"
[ -z "$(git status --porcelain)" ]                || echo "STOP — dirty tree, reset would destroy it"
[ "$(git rev-list --count origin/development..development)" -eq 0 ] \
                                                   || echo "STOP — unpushed commits, git pull can't restore them"
git merge-base --is-ancestor "$MAX" origin/development \
  || echo "STOP — target is not an ancestor of origin/development; git pull would NOT restore"
```

The ancestor guard is what makes `reset --hard` safe here: restore is a plain fast-forward `git pull`.

### 3. Verify the checkout changes migrations ONLY

DbMigrator's `appsettings.json` is **tracked**. If it differed between the two commits, the checkout
would silently repoint the migrator at another database. Prove it does not:

```bash
git diff --name-only HEAD "$MAX" -- BPP.Shared.NET/BPP.Shared.NET.DbMigrator/ | grep -v 'Migrations/'
```

Non-empty → **report every file and stop for confirmation**. The user must know the migrator's own
config is about to change before they run it.

### 4. Move the checkout

```bash
git switch development && git reset --hard "$MAX"
git rev-parse --short HEAD; git rev-list --count HEAD..origin/development   # behind count
```

Report the pre-reset SHA (`$PRE`) so the move is recoverable from the reflog regardless.

### 5. Print the migration delta + flag data backfills

Compare the checked-out stage against the stage below (`staging` → `main`), i.e. what DbMigrator
would apply. Resolve `$LOWER_SHA` by re-running step 1 with `STAGE=<lower stage>`.
`.Designer.cs` files are noise — filter them out.

```bash
M=BPP.Shared.NET/BPP.Shared.NET.DbMigrator/Migrations
diff <(git ls-tree --name-only "$LOWER_SHA:$M" | grep '\.cs$' | grep -v Designer | sort) \
     <(git ls-tree --name-only "$MAX:$M"      | grep '\.cs$' | grep -v Designer | sort) | grep '^>'
```

**Call out `Backfill*` / data-touching migrations separately.** They write rows, not just schema —
on a production DB that is a materially different risk from a column add, and the user is about to
point the migrator at it.

Also report any migration present in the LOWER stage but missing in the target (`grep '^<'`) —
that means history diverged and is a hard STOP, not a delta.

### 6. Stop. Hand over.

Report: resolved commit + date + subject, the pin table, the delta with backfills flagged, the
pre-reset SHA, and the restore command. Then **stop** — the user runs DbMigrator.

### Restore mode

```bash
cd ~/Entwicklung/bpp/bpp-shared
git switch development && git pull
git rev-parse --short HEAD          # must equal origin/development
git status --porcelain              # must be empty
```

Verify both, then confirm. If `git pull` is not a fast-forward, report it rather than forcing.

## Quick Reference

| Step | Command |
|---|---|
| Pin on a stage | `git show origin/<stage>:BPP.*/Directory.Build.props \| grep -oP '(?<=<BppSharedVersion>)[^<]+'` |
| Version → commit | `sha=${version##*+}` — never grep `-development` |
| Packages | `glab api "projects/lipso%2Fclients%2Fbrokernet%2Fbpp-shared/packages?..."` |
| Newer of two SHAs | `git merge-base --is-ancestor A B` → B newer |
| Restore-safe? | `git merge-base --is-ancestor <target> origin/development` |
| Move | `git switch development && git reset --hard <sha>` |
| Restore | `git switch development && git pull` |

## Common Mistakes

- **Grepping `-development`** → the suffix is being removed (`f8c42280`, 2026-09-11); suffix-less
  packages already exist. Parse `+` metadata only.
- **Picking the newest pin by version string** → same version, different SHAs is real. Compare by
  `git merge-base --is-ancestor`.
- **Reading only bpp-backend's pin** → another repo can pin a newer shared. Read all, reduce by
  ancestry, report disagreement.
- **`reset --hard` without the ancestor guard** → if the target is not an ancestor of
  `origin/development`, `git pull` will not restore and the user is stranded.
- **`reset --hard` with a dirty tree or unpushed commits** → destroys them. Guard, don't stash.
- **Not printing the pre-reset SHA** → the reflog is the only recovery path; put it in the report.
- **Skipping the non-Migrations diff check** → a changed tracked `appsettings.json` silently
  repoints the migrator at a different database.
- **Counting `.Designer.cs` as migrations** → doubles every count. Filter them.
- **Using the `brokernet/<repo>` namespace** → it is `lipso/clients/brokernet/<repo>`; older skills
  still carry the stale path.
- **Touching a worktree** → this skill moves the main checkout only.
- **Running DbMigrator** → never. Out of scope, always.

## Red Flags — STOP

- About to **run DbMigrator**, `dotnet run` it, or read/edit any connection string → STOP. Out of scope.
- Consumer pins on the stage **disagree** → STOP, print the table, ask before moving.
- Two pinned SHAs are **divergent** (neither is an ancestor of the other) → STOP, there is no max.
- A pinned version has **no `+sha`** → STOP for that repo; never guess a commit from a version number.
- The SHA is **not in the clone after `git fetch --all --tags`** → STOP; it may be an unpushed or
  deleted branch.
- Target is **not an ancestor of `origin/development`** → STOP; `git pull` would not restore.
- Tree is **dirty** or `development` has **unpushed commits** → STOP; never stash, never force.
- The checkout would change a tracked file **outside `Migrations/`** → STOP and report it first.
- A migration exists on the LOWER stage but **not** on the target → STOP; history diverged.
- About to `git push`, `--force`, or `branch -D` anything → STOP. This skill only moves a local checkout.
