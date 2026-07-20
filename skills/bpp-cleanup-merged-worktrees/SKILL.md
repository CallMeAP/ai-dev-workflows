---
name: bpp-cleanup-merged-worktrees
description: Use when cleaning up finished git worktrees under ~/Entwicklung/bpp whose branches are already merged — phrases like "clean up merged worktrees", "remove stale worktrees", "prune finished .wt-* folders", "delete merged worktree branches", "worktree cleanup". Discovers stray `.wt-*` dirs plus every repo's linked worktrees, classifies each as REMOVE (merged into origin/development + clean) / CONFIRM (squash-or-post-merge, needs sign-off) / KEEP (dirty, untracked, unmerged, at-tip, detached, or git error), prints a plan first, then removes only merged+clean worktrees with `git worktree remove` + `git branch -d` — never `--force` / `-D`.
---

# bpp-cleanup-merged-worktrees

## Overview

Safely reclaim disk + mental space by removing git worktree folders under `~/Entwicklung/bpp`
whose branch is **already merged** into `origin/development` **and** whose tree is spotless. Everything
else is kept and reported. The skill is destructive-by-invocation but conservative-by-construction:
it always prints a KEEP / REMOVE / CONFIRM **plan first**, removes only what it can prove is merged and
clean, uses `git worktree remove` (never `--force`) + `git branch -d` (never `-D`), and downgrades any
ambiguous case (squash merge, post-merge commits, branch sitting exactly at the dev tip) to CONFIRM so a
human decides. Many `.wt-*` folders belong to **other agents working right now** — the guards keep those.

## When to Use

- "clean up merged worktrees", "remove the stale `.wt-*` folders", "prune finished worktrees", "delete merged worktree branches"
- After a batch of feature branches merged, to clear their worktrees + local branches in one pass

## When NOT to Use

- Removing a **single** known worktree → just `git worktree remove <path>` yourself
- Pulling / fast-forwarding development in checkouts → `bpp-pull-all-dev`
- A worktree you *know* is unmerged but want gone anyway → do it manually with `-D` (this skill never force-deletes)

## Steps

Run **plan mode first** (default). Show the user the table. Only then run **apply mode**, and for any
CONFIRM rows ask the user explicitly before removing them by hand — apply mode never auto-removes CONFIRM.

- Plan (default): `bash cleanup.sh` or `bash cleanup.sh plan`
- Apply (removes only REMOVE rows, re-verified at removal time): `bash cleanup.sh apply`

Discovery, classification, and removal are one script:

```bash
#!/usr/bin/env bash
# bpp-cleanup-merged-worktrees — MODE: plan (default, classify only) | apply (remove REMOVE rows)
set -uo pipefail
BASE=/home/alex/Entwicklung/bpp
MODE="${1:-plan}"

# ── 1. Collect candidate worktree paths ──────────────────────────────────────
declare -A SEEN=()
CANDS=()
add_cand() {
  local p="$1"; [ -z "$p" ] && return
  case "$p" in "$BASE"/*) ;; *) return;; esac      # must live under BASE (skips /tmp scratchpad worktrees)
  case "$p" in */.claude/*) return;; esac          # Claude Code-managed worktrees — never touch, CC prunes them
  [ -n "${SEEN[$p]:-}" ] && return; SEEN[$p]=1; CANDS+=("$p")
}
# (a) stray .wt-* dirs directly under BASE (catches dirs whose worktree registration was pruned)
for d in "$BASE"/.wt-*/; do [ -d "$d" ] && add_cand "${d%/}"; done
# (b) per-repo `git worktree list --porcelain` (authoritative; catches *.worktrees/ containers, cca-style worktrees)
for repo in "$BASE"/*/; do
  case "$(basename "$repo")" in bpp-to-dos|infra) continue;; esac
  [ -e "$repo/.git" ] || continue
  mainwt=""
  while IFS= read -r line; do
    case "$line" in "worktree "*)
      wt=${line#worktree }
      if [ -z "$mainwt" ]; then mainwt="$wt"; else add_cand "$wt"; fi   # first entry = main checkout → never a candidate
      ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
done

# ── 2. Classify each candidate → RESULTS[i]=verdict\tpath\tbranch\trepo\treason ──
RESULTS=()
declare -A FETCHED=()
for W in "${CANDS[@]}"; do
  if ! git -C "$W" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    RESULTS+=("KEEP	$W	?	?	orphan/unreadable worktree dir — inspect manually"); continue
  fi
  branch=$(git -C "$W" rev-parse --abbrev-ref HEAD 2>/dev/null)
  url=$(git -C "$W" remote get-url origin 2>/dev/null)
  repo=$(printf '%s' "$url" | sed -E 's#^.*gitlab\.com[:/]##; s#\.git$##; s#^.*/##')
  proj=$(printf '%s' "$url" | sed -E 's#^.*gitlab\.com[:/]##; s#\.git$##')
  projenc=${proj//\//%2F}

  if [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
    RESULTS+=("KEEP	$W	(detached)	$repo	detached HEAD — unknown state"); continue
  fi
  status=$(git -C "$W" status --porcelain 2>/dev/null)
  if [ -n "$status" ]; then
    unt=$(printf '%s\n' "$status" | grep -c '^??'); trk=$(printf '%s\n' "$status" | grep -vc '^??')
    RESULTS+=("KEEP	$W	$branch	$repo	dirty ($trk tracked, $unt untracked change(s))"); continue
  fi
  cdir=$(git -C "$W" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -z "${FETCHED[$cdir]:-}" ]; then
    if ! git -C "$W" fetch -q origin 2>/dev/null; then
      RESULTS+=("KEEP	$W	$branch	$repo	fetch failed — cannot verify merge state"); continue
    fi
    FETCHED[$cdir]=1
  fi
  if ! git -C "$W" rev-parse --verify -q origin/development >/dev/null 2>&1; then
    RESULTS+=("KEEP	$W	$branch	$repo	no origin/development ref"); continue
  fi
  ahead=$(git -C "$W" rev-list --count origin/development..HEAD 2>/dev/null)
  behind=$(git -C "$W" rev-list --count HEAD..origin/development 2>/dev/null)

  if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
    RESULTS+=("KEEP	$W	$branch	$repo	at development tip, no unique commits (fresh/active worktree)"); continue
  fi
  if [ "$ahead" = "0" ]; then
    RESULTS+=("REMOVE	$W	$branch	$repo	merged into development (dev advanced $behind past it), clean"); continue
  fi
  # ahead>0: commits not in dev — only a merged MR (squash / post-merge) rescues it, and only as CONFIRM
  mrmerged=$(glab api "projects/$projenc/merge_requests?source_branch=$branch&state=merged&per_page=1" 2>/dev/null | grep -c '"iid"')
  if [ "${mrmerged:-0}" -ge 1 ]; then
    RESULTS+=("CONFIRM	$W	$branch	$repo	MR merged but $ahead local commit(s) not in dev (squash/post-merge) — confirm"); continue
  fi
  RESULTS+=("KEEP	$W	$branch	$repo	unmerged: $ahead commit(s) not in dev, no merged MR")
done

# ── 3. Print the plan (ALWAYS, before any removal) ───────────────────────────
echo "PLAN (mode=$MODE)"
printf '%-9s %-46s %-38s %s\n' VERDICT WORKTREE BRANCH REASON
printf '%-9s %-46s %-38s %s\n' "-------" "--------" "------" "------"
nR=0; nC=0; nK=0
for r in "${RESULTS[@]}"; do
  IFS=$'\t' read -r v p b repo reason <<<"$r"
  printf '%-9s %-46s %-38s %s\n' "$v" ".../${p#$BASE/}" "$b" "$reason"
  case "$v" in REMOVE) nR=$((nR+1));; CONFIRM) nC=$((nC+1));; KEEP) nK=$((nK+1));; esac
done
echo; echo "SUMMARY: REMOVE=$nR  CONFIRM=$nC  KEEP=$nK"

# ── 4. Apply (only REMOVE rows, re-verified immediately before removing) ──────
if [ "$MODE" = "apply" ]; then
  echo; echo "APPLYING (REMOVE rows only; CONFIRM + KEEP left untouched)"
  for r in "${RESULTS[@]}"; do
    IFS=$'\t' read -r v W b repo reason <<<"$r"
    [ "$v" = "REMOVE" ] || continue
    # re-verify: still clean, still merged (ancestor + dev ahead) — guards against races since the plan ran
    if [ -n "$(git -C "$W" status --porcelain 2>/dev/null)" ]; then echo "SKIP $W: became dirty since plan"; continue; fi
    git -C "$W" fetch -q origin 2>/dev/null || { echo "SKIP $W: fetch failed"; continue; }
    a=$(git -C "$W" rev-list --count origin/development..HEAD 2>/dev/null)
    bh=$(git -C "$W" rev-list --count HEAD..origin/development 2>/dev/null)
    if [ "$a" != "0" ] || [ "$bh" = "0" ]; then echo "SKIP $W: merge state changed (ahead=$a behind=$bh)"; continue; fi
    mainwt=$(git -C "$W" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
    if git -C "$mainwt" worktree remove "$W" 2>/dev/null; then       # NO --force
      git -C "$mainwt" worktree prune 2>/dev/null
      if git -C "$mainwt" branch -d "$b" 2>/dev/null; then           # NO -D
        echo "REMOVED $W  (branch $b deleted)"
      else
        echo "REMOVED $W  (branch $b RETAINED — not a git-ancestor of dev; delete manually if certain)"
      fi
    else
      echo "SKIP $W: 'git worktree remove' refused (locked / in use) — left intact"
    fi
  done
fi
exit 0
```

## Output

- **Plan table** — every candidate as `VERDICT | worktree | branch | reason`, then `SUMMARY: REMOVE=n CONFIRM=n KEEP=n`.
- **Apply run** — one line per REMOVE row: `REMOVED …` (with branch deleted / retained) or `SKIP … <reason>`.
- Report back three buckets: **removed**, **kept (with reason)**, **needs-confirmation (CONFIRM)** — and for CONFIRM rows tell the user *why* (squash / post-merge) so they can OK a manual `git worktree remove` + `git branch -D`.

## Common Mistakes

- **`is-ancestor` alone = REMOVE** → a freshly-created worktree sitting *exactly* at `origin/development` (ahead=0 **and** behind=0) is a trivial ancestor with no merged work to reclaim — almost always a live agent's fresh worktree. Require **behind>0** (dev advanced past the branch) before auto-removing; ahead=0/behind=0 is KEEP.
- **Treating a squash merge as unmerged** → squash-merged branch tips are NOT ancestors of dev (`ahead>0`), so the ancestor check says "unmerged". Cross-check the GitLab MR state; a merged MR with local commits still-outside-dev is **CONFIRM**, never auto-REMOVE (its commits could also be genuine post-merge work).
- **`git worktree remove --force`** → strips uncommitted/untracked work silently. Never use `--force`; plain `remove` refuses on a dirty/locked worktree, which is the desired safety.
- **`git branch -D`** → force-deletes unmerged branches, orphaning commits. Only ever `git branch -d`; if it refuses (squash merge), retain the branch and report it.
- **Removing Claude Code worktrees** → paths under `**/.claude/worktrees/*` are managed (and auto-pruned) by Claude Code; excluding `*/.claude/*` prevents yanking a worktree out from under a running agent. The `/tmp/**/scratchpad/*` worktrees are out of scope too (not under BASE).
- **Deleting the branch before the worktree** → a branch checked out in a worktree can't be `-d`'d; remove the worktree (then `prune`) first, then delete the branch from the **main** checkout (`$mainwt`), not from inside the now-gone worktree.
- **Trusting the plan at apply time** → other agents commit between plan and apply; apply mode re-checks clean + merge state per row and skips anything that changed.
- **`git status --porcelain` "clean" ignores staged/untracked?** → it does not: it reports staged, modified, and `??` untracked alike. Any non-empty output ⇒ KEEP.
- **Loop dies on a failed test under `pipefail`** → keep per-candidate failures as `continue` with a KEEP verdict; end the script with `exit 0`.

## Red Flags — STOP

- You are about to type `--force` or `-D`. Don't. The skill's entire safety model is that both are forbidden — an unmerged/dirty worktree is KEPT and reported, never forced.
- You are about to remove without having printed the plan. Always plan → show user → apply.
- A worktree is dirty, has untracked files, has commits not in `origin/development` without a merged MR, is detached, or any git command errored → it is KEEP. If you find yourself rationalizing removal anyway, stop.
- `git worktree remove` refused (locked / in use) → leave it; do not escalate to `--force`.
- The candidate resolves to a main checkout (a repo root under `~/Entwicklung/bpp`) or a path outside `~/Entwicklung/bpp` → it must never be a removal target.
