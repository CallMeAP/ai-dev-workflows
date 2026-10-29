---
name: bpp-cleanup-merged-worktrees
description: Use when cleaning up finished git worktrees under ~/Entwicklung/bpp and ~/Entwicklung/brokernet whose branches are already merged — phrases like "clean up merged worktrees", "remove stale worktrees", "prune finished .wt-* folders", "delete merged worktree branches", "worktree cleanup". Discovers stray `.wt-*` dirs plus every repo's linked worktrees, classifies each as REMOVE (ancestor of origin/development + clean) / LANDED (squash- or post-merge, patch-identity proven automatically) / REMOVE-AFTER-SCAFFOLD (merged, dirt is only local scaffolding — removed on user go) / KEEP (real dirt, unmerged, unproven, at-tip, detached, or git error), prints a read-only plan first (no fetch unless `--fetch`), then removes only the worktree paths the user approved — `apply <path>…` for REMOVE/LANDED, `apply-scaffold <path>…` for scaffold rows, each re-verified — with `git worktree remove` + `git branch -d` — never `--force`; `-D` only as the fallback for a proven LANDED row.
---

# bpp-cleanup-merged-worktrees

## Overview

Safely reclaim disk + mental space by removing git worktree folders under `~/Entwicklung/bpp` and `~/Entwicklung/brokernet` (both by default; `BASE=<root>` limits a run to one)
whose branch content is **already in** `origin/development` **and** whose tree is spotless. Everything
else is kept and reported. The skill is destructive-by-invocation but conservative-by-construction:
it always prints a **read-only plan first**, removes only the worktree paths the user approved and only
if it can still prove them landed, uses `git worktree remove`
(never `--force`) + `git branch -d`, and settles squash/post-merge cases with an automatic
patch-identity proof instead of a human guess. Many `.wt-*` folders belong to **other agents working
right now** — the guards keep those.

## When to Use

- "clean up merged worktrees", "remove the stale `.wt-*` folders", "prune finished worktrees", "delete merged worktree branches"
- After a batch of feature branches merged, to clear their worktrees + local branches in one pass

**Discovery here is deliberately filesystem-driven, not `bpp-project-index`-driven.** The unit of work is
a *worktree*, which exists only on disk and in `git worktree list` — no GitLab listing knows about it, so
a manifest-driven loop could only ever be less complete.

## When NOT to Use

- Removing a **single** known worktree → just `git worktree remove <path>` yourself
- Pulling / fast-forwarding development in checkouts → `bpp-pull-all-dev`
- A worktree you *know* is unmerged but want gone anyway → do it manually with `-D` (this skill never force-deletes unproven work)

## Quick Reference

| Verdict | Condition | Apply does |
|---|---|---|
| REMOVE | clean, HEAD ancestor of dev, dev advanced past it (behind>0) | `apply <path>…` (approved paths only): `worktree remove` + `branch -d` |
| LANDED | clean, merged MR, `git cherry` all `-`, and (two-dot diff empty **or** merge-tree == dev tree **or** every branch-touched file still differing is a version dev's own history once had) | `apply <path>…` (approved paths only): `worktree remove` + `branch -d`, fallback `-D` (proof re-run first) |
| REMOVE-AFTER-SCAFFOLD | REMOVE/LANDED except every dirty file is LOCAL-SCAFFOLDING | nothing; `apply-scaffold <path>…` only on the user's explicit go |
| KEEP | any REAL-CHANGE dirt, cherry `+`, unproven, no merged MR, at dev tip, detached, locked/fresh Claude worktree, git error | nothing — reported with evidence |

**LOCAL-SCAFFOLDING** (uncommitted, never meant to ship; everything else is REAL-CHANGE):

| Pattern | Typical example |
|---|---|
| Added lines carry a `never commit` marker (tracked or untracked) | `<!-- LOCAL perf sweep … only, never commit -->` ItemGroup in `Directory.Build.props`; untracked `Directory.Build.targets` marked `LOCAL-ONLY, untracked, never commit` |
| `Directory.Build.{props,targets,local.props}` where every changed line is bpp-shared wiring (`ProjectReference`, `BPP.Shared`/`BppShared*`, `Exists(`, `Condition=`, `ItemGroup`/`PropertyGroup`, comments) | apittrich/klaffi `ProjectReference` repointed at a sibling `.wt-*-bpp-shared` worktree |
| Untracked repo-root `Directory.Build.local.props` | the per-checkout local build override |
| Local secrets file — **name only, content never printed** | `appsettings*.local.json` (tracked with empty secrets by convention, filled locally), `*DebugTestConsts.cs`, `.env*`, `*.pfx/.p12/.pem/.key` |
| Comment-out only: every `+` line is a `//` copy of a `-` line | a test-factory safety guard (e.g. forcing the dev tenant URL) commented out for one local run — flagged **DISABLES CODE**, must never ship |

## Steps

Run **plan mode first** (default, read-only: no fetch, no removal). Show the user the table. Then run
`apply` with **exactly the REMOVE/LANDED worktree paths the user approved** — never a re-discovered set:
a worktree sitting at the dev tip (e.g. a running workflow's) reads KEEP in the plan and flips to REMOVE
the moment dev advances. `apply` with no paths refuses and prints the plan. REMOVE-AFTER-SCAFFOLD rows
are removed only after the user OKs the listed files per worktree, via `apply-scaffold <path>…`. KEEP
rows are never touched. Both apply modes fetch and re-verify each named path immediately before removing it.

### How a squash/post-merge row is proven (automatic, in `merge_state`)

`ahead>0` only means the branch tip is not an *ancestor* of dev. It does **not** mean the content is
missing: a squash-, rebase- or staging/main-merged branch has its work in dev under **different hashes**.
With a merged MR present, the script runs, in order:

1. `git cherry origin/development HEAD` — any `+` ⇒ **KEEP**, listing the unmerged commits.
2. `git diff --quiet origin/development HEAD` — empty ⇒ **LANDED**.
3. "Did development move on after the merge?" (two-dot non-empty because dev advanced, or the branch was cut from staging/main and its base is staging's older copy of dev):
   - `git merge-tree --write-tree origin/development HEAD` equals `origin/development^{tree}` ⇒ merging adds nothing ⇒ **LANDED**.
   - else for every file in the branch's own diff (`origin/development...HEAD`) that still differs two-dot: the branch's blob must appear as a version in `git log -m --raw origin/development -- <file>` (dev once had exactly this content, then changed it later — covers MRs that targeted staging/main and arrived via merge-back). All match ⇒ **LANDED**; otherwise **KEEP** with the unproven files.
4. Evidence also records the MR target and whether the MR's merge/squash commit equals the branch on the branch-touched files.

🔴 **Never judge with `git diff origin/development...<branch>` (three dots) alone.** Three-dot measures
merge-base→branch, so every squash/rebase merge reads as "unsafe". And never require the plain two-dot
diff to be empty as the only proof — it can never be empty once dev moved past the branch.

`git branch -d` usually succeeds even on LANDED rows (git accepts "merged to its upstream" with a
warning). Only when it refuses does apply fall back to `-D` — and only for a LANDED row whose proof
was just re-run and still holds.

The script ships as `cleanup.sh` beside this file. It is not inlined: Claude Code substitutes positional placeholders (dollar sign + digit) in skill text when the skill is invoked with arguments; on 2026-10-28 that turned the awk record variable into `--fetch` and broke the script. Keep dollar-digit sequences out of this file. Run it by path:

- Plan (default, read-only, uses the refs of the last fetch): `bash ~/.claude/skills/bpp-cleanup-merged-worktrees/cleanup.sh` or `… cleanup.sh plan`; `… cleanup.sh plan --fetch` refreshes origin first
- After the user's go on specific REMOVE/LANDED rows: `… cleanup.sh apply <worktree> [<worktree>…]` — no paths ⇒ refuses, prints the plan
- After the user's go on specific REMOVE-AFTER-SCAFFOLD rows: `… cleanup.sh apply-scaffold <worktree> [<worktree>…]`
- Reuse the helpers: `source ~/.claude/skills/bpp-cleanup-merged-worktrees/cleanup.sh` stops before reading any argument as a mode

## Output

- **Plan table** — every candidate as `VERDICT | worktree | branch | reason`, then `SUMMARY: REMOVE=n LANDED=n REMOVE-AFTER-SCAFFOLD=n KEEP=n`. Reasons carry the evidence: MR iid + target, which proof landed it, the cherry `+` SHAs, or the unproven files.
- **Apply run** — one line per named path: `VERIFIED … <verdict>` then `REMOVED …` (branch deleted with `-d` / `-D: proven LANDED` / retained), or `SKIP … <reason>`; `REFUSED` + the plan when no path was named.
- Report back four buckets: **removed**, **kept (with evidence)**, **REMOVE-AFTER-SCAFFOLD** (the exact files per worktree and what discarding loses — e.g. local creds in `appsettings.local.json`, or a sibling worktree that another `.wt-*` `Directory.Build.props` still points at), **REAL-CHANGE dirt** (file names only). Ask for the go per row, then run `apply` / `apply-scaffold` for the approved paths only.

## Common Mistakes

- **`is-ancestor` alone = REMOVE** → a freshly-created worktree sitting *exactly* at `origin/development` (ahead=0 **and** behind=0) is almost always a live agent's fresh worktree. Require **behind>0**; ahead=0/behind=0 is KEEP.
- **Requiring an empty two-dot diff as the only proof** → once dev moved on after the merge (or the MR targeted staging/main and the branch was cut from staging), `git diff origin/development <branch>` is never empty. Use the `merge_state` chain: cherry → two-dot → merge-tree identity → per-file "branch blob is in dev history".
- **Judging with a three-dot diff** → reports every squash/rebase merge as unsafe. It is only used to list the files the branch touched.
- **Treating a squash merge as unmerged / escalating to `-D` without proof** → `-D` is allowed only inside `remove_wt` for a LANDED row whose proof was re-run at apply time. Everywhere else: retain the branch.
- **Calling every dirty tree KEEP** → classify each file. A merged branch whose only dirt is LOCAL-SCAFFOLDING (bpp-shared `ProjectReference` redirects, `never commit` markers, local secrets) is REMOVE-AFTER-SCAFFOLD, not silent KEEP — but still no auto-remove.
- **Printing a secrets file's diff while classifying** → `chg` output is consumed, never echoed. Report `appsettings*.local.json` / `*DebugTestConsts.cs` by name only.
- **Calling a commented-out safety guard harmless** → it is scaffolding (must not ship) but flagged DISABLES CODE; say so in the report.
- **`git worktree remove --force`** → strips uncommitted/untracked work silently. `apply-scaffold` discards exactly the approved scaffolding files, re-checks the tree is clean, then uses plain `remove`.
- **Removing a Claude Code worktree an agent is still using** → `**/.claude/worktrees/*` are in scope only when not `locked` and nothing outside `.git`/`bin`/`obj` was written in the last `IDLE_DAYS` (default 7). The `/tmp/**/scratchpad/*` worktrees stay out of scope.
- **Deleting the branch before the worktree** → remove the worktree (then `prune`) first, then delete the branch from the **main** checkout.
- **Trusting the plan at apply time** → apply re-fetches, re-classifies the dirt and re-runs `merge_state` per named path, and skips anything no longer REMOVE/LANDED.
- **Letting apply re-discover its targets** → rows can flip between plan and apply (a live worktree at the dev tip becomes REMOVE once dev advances). `apply` acts only on the paths passed to it; with none it refuses.
- **Fetching in plan mode** → plan is read-only; it uses the last-fetched refs unless `--fetch` is passed. The apply modes always fetch before re-verifying.
- **Loop dies on a failed test under `pipefail`** → keep per-candidate failures as `continue` with a KEEP verdict; end the script with `exit 0`.

## Red Flags — STOP

- You are about to type `--force`. Don't — ever.
- You are about to type `-D` outside `remove_wt` for a re-proven LANDED row. Don't.
- You are about to remove without having printed the plan. Always plan → show user → apply.
- You are about to run `apply` on a path the user did not approve, or to make it work without paths. Pass only the approved worktree paths.
- You are about to run `apply-scaffold` on a worktree the user did not explicitly OK, or the file list changed since you showed it. Stop and re-show.
- A dirty file classifies as REAL-CHANGE, cherry shows `+`, the proof says NOT proven, the HEAD is detached, or any git command errored → KEEP. If you find yourself rationalizing removal anyway, stop.
- You are about to print the contents of an `appsettings*.local.json`, `*DebugTestConsts.cs` or other secrets file. Names only.
- `git worktree remove` refused (locked / in use) → leave it; do not escalate to `--force`.
- The candidate resolves to a main checkout (a repo root under either root) or a path outside both roots → it must never be a removal target.
