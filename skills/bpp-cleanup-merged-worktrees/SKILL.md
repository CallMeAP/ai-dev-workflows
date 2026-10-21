---
name: bpp-cleanup-merged-worktrees
description: Use when cleaning up finished git worktrees under ~/Entwicklung/bpp whose branches are already merged — phrases like "clean up merged worktrees", "remove stale worktrees", "prune finished .wt-* folders", "delete merged worktree branches", "worktree cleanup". Discovers stray `.wt-*` dirs plus every repo's linked worktrees, classifies each as REMOVE (ancestor of origin/development + clean) / LANDED (squash- or post-merge, patch-identity proven automatically) / REMOVE-AFTER-SCAFFOLD (merged, dirt is only local scaffolding — removed on user go) / KEEP (real dirt, unmerged, unproven, at-tip, detached, or git error), prints a read-only plan first (no fetch unless `--fetch`), then removes only the worktree paths the user approved — `apply <path>…` for REMOVE/LANDED, `apply-scaffold <path>…` for scaffold rows, each re-verified — with `git worktree remove` + `git branch -d` — never `--force`; `-D` only as the fallback for a proven LANDED row.
---

# bpp-cleanup-merged-worktrees

## Overview

Safely reclaim disk + mental space by removing git worktree folders under `~/Entwicklung/bpp`
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

The script below is not shipped as a file. Write it to a temp file first (`f=$(mktemp --suffix=.sh)`), then:

- Plan (default, read-only, uses the refs of the last fetch): `bash "$f"` or `bash "$f" plan`; `bash "$f" plan --fetch` refreshes origin first
- After the user's go on specific REMOVE/LANDED rows: `bash "$f" apply <worktree> [<worktree>…]` — no paths ⇒ refuses, prints the plan
- After the user's go on specific REMOVE-AFTER-SCAFFOLD rows: `bash "$f" apply-scaffold <worktree> [<worktree>…]`
- Reuse the helpers: `source "$f"` stops before reading any argument as a mode

```bash
#!/usr/bin/env bash
# bpp-cleanup-merged-worktrees — MODE: plan [--fetch] (default) | apply <worktree>... | apply-scaffold <worktree>...
set -uo pipefail
BASE=/home/alex/Entwicklung/bpp
IDLE_DAYS="${IDLE_DAYS:-7}"   # a .claude/worktrees candidate must be untouched this long before it is even classified
SECRET_RE='(^|/)(appsettings[^/]*\.local\.json|[^/]*DebugTestConsts\.cs|\.env[^/]*|[^/]*\.(pfx|p12|pem|key))$'
WIRING_RE='ProjectReference|BPP\.Shared|BppShared|Exists\(|Condition=|ItemGroup|PropertyGroup|</?Project|<!--|-->|^[[:space:]]*$'

# ── helpers ───────────────────────────────────────────────────────────────────
chg() { # W file untracked(0/1) → changed lines with +/- prefix. NEVER printed (may hold secrets).
  if [ "$3" = 1 ]; then sed 's/^/+/' "$1/$2"
  else git -C "$1" diff HEAD -- "$2" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) '; fi
}
classify_file() { # W XY file → "SCAFFOLD:<why>" | "REAL:<why>"
  local W=$1 xy=$2 f=$3 u=0 c
  [ "$xy" = "??" ] && u=1
  case "$xy" in R*|C*) echo "REAL:rename/copy"; return;; esac
  if printf '%s' "$f" | grep -qE "$SECRET_RE"; then echo "SCAFFOLD:local secrets, content not shown"; return; fi
  c=$(chg "$W" "$f" $u 2>/dev/null)
  if printf '%s\n' "$c" | grep '^+' | grep -qi 'never commit'; then echo "SCAFFOLD:marked never-commit"; return; fi
  case "$f" in Directory.Build.local.props) [ $u = 1 ] && { echo "SCAFFOLD:untracked repo-root local build override"; return; };; esac
  case "$f" in */Directory.Build.props|*/Directory.Build.targets|*/Directory.Build.local.props|Directory.Build.*)
    if [ -n "$c" ] && ! printf '%s\n' "$c" | sed 's/^[+-]//' | grep -qvE "$WIRING_RE"; then
      echo "SCAFFOLD:local bpp-shared wiring"; return; fi;;
  esac
  if [ -n "$c" ] && printf '%s\n' "$c" | awk '
      function t(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      /^-/{ m[t(substr($0,2))]++; nm++ }
      /^\+/{ p=t(substr($0,2)); if (p !~ /^\/\//) bad=1; sub(/^\/\/[ \t]*/,"",p); pl[p]++; np++ }
      END{ if (bad || nm==0 || nm!=np) exit 1; for (k in m) if (m[k]!=pl[k]) exit 1 }'; then
    echo "SCAFFOLD:comment-out only, DISABLES CODE"; return
  fi
  echo "REAL:uncommitted change"
}
classify_wt() { # W → sets SCAF, REAL, SCAF_T (tracked paths), SCAF_U (untracked paths)
  local W=$1 l xy f c
  SCAF=""; REAL=""; SCAF_T=(); SCAF_U=()
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    xy=${l:0:2}; f=${l:3}
    c=$(classify_file "$W" "$xy" "$f")
    case "$c" in
      SCAFFOLD:*) SCAF+="$f [${c#SCAFFOLD:}]; "; if [ "$xy" = "??" ]; then SCAF_U+=("$f"); else SCAF_T+=("$f"); fi;;
      *)          REAL+="$f [${c#REAL:}]; ";;
    esac
  done < <(git -C "$W" status --porcelain --untracked-files=all 2>/dev/null)
}
merge_state() { # W branch projenc → "VERDICT<TAB>reason"; VERDICT = REMOVE | LANDED | KEEP
  local W=$1 b=$2 pe=$3 ahead behind mr iid tgt mc plus files f bb bad="" mrres="n.a."
  ahead=$(git -C "$W" rev-list --count origin/development..HEAD 2>/dev/null)
  behind=$(git -C "$W" rev-list --count HEAD..origin/development 2>/dev/null)
  [ -z "$ahead" ] && { printf 'KEEP\tgit rev-list failed'; return; }
  [ "$ahead" = 0 ] && [ "$behind" = 0 ] && { printf 'KEEP\tat development tip, no unique commits (fresh/active worktree)'; return; }
  [ "$ahead" = 0 ] && { printf 'REMOVE\tmerged into development (dev advanced %s past it)' "$behind"; return; }
  mr=$(glab api "projects/$pe/merge_requests?source_branch=$b&state=merged&per_page=1" 2>/dev/null)
  iid=$(printf '%s' "$mr" | jq -r '.[0].iid // empty' 2>/dev/null)
  [ -z "$iid" ] && { printf 'KEEP\tunmerged: %s commit(s) not in dev, no merged MR' "$ahead"; return; }
  tgt=$(printf '%s' "$mr" | jq -r '.[0].target_branch')
  mc=$(printf '%s' "$mr" | jq -r '.[0].squash_commit_sha // .[0].merge_commit_sha // empty')
  plus=$(git -C "$W" cherry origin/development HEAD 2>/dev/null | awk '/^\+/{n++; if (n<=10) printf "%s ", substr($2,1,9)} END{if (n>10) printf "(+%d more) ", n-10}')
  [ -n "$plus" ] && { printf 'KEEP\tMR !%s->%s merged, but cherry "+" (not in dev): %s(see git cherry -v)' "$iid" "$tgt" "$plus"; return; }
  git -C "$W" diff --quiet origin/development HEAD && { printf 'LANDED\tMR !%s->%s; cherry all "-", two-dot diff empty' "$iid" "$tgt"; return; }
  files=$(git -C "$W" diff --name-only origin/development...HEAD 2>/dev/null)   # silences "multiple merge bases"
  if [ -n "$mc" ] && git -C "$W" cat-file -e "$mc^{commit}" 2>/dev/null; then
    if git -C "$W" diff --quiet "$mc" HEAD -- $files; then mrres=yes; else mrres=no; fi
  fi
  if [ "$(git -C "$W" merge-tree --write-tree origin/development HEAD 2>/dev/null | head -1)" = \
       "$(git -C "$W" rev-parse 'origin/development^{tree}')" ]; then
    printf 'LANDED\tMR !%s->%s (MR result==branch: %s); cherry all "-", merge-tree into dev == dev tree (dev moved on)' "$iid" "$tgt" "$mrres"; return
  fi
  for f in $files; do
    git -C "$W" diff --quiet origin/development HEAD -- "$f" && continue
    bb=$(git -C "$W" rev-parse -q --verify "HEAD:$f") || { bad+="$f(deleted on branch) "; continue; }
    git -C "$W" log -m --format= --raw --no-abbrev origin/development -- "$f" | awk '{print $4}' | grep -qx "$bb" \
      || bad+="$f "
  done
  if [ -z "$bad" ]; then
    printf 'LANDED\tMR !%s->%s (MR result==branch: %s); cherry all "-", every differing branch file is an older dev version (dev moved on)' "$iid" "$tgt" "$mrres"
  else
    printf 'KEEP\tMR !%s->%s, cherry all "-" but NOT proven landed; branch content absent from dev history: %s' "$iid" "$tgt" "$bad"
  fi
}
projenc_of() { local u; u=$(git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^.*gitlab\.com[:/]##; s#\.git$##'); printf '%s' "${u//\//%2F}"; }
mainwt_of() { git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}'; }
remove_wt() { # W branch verdict — NO --force; -D only for a re-proven LANDED row
  local W=$1 b=$2 v=$3 m; m=$(mainwt_of "$W")
  if ! git -C "$m" worktree remove "$W" 2>/dev/null; then echo "SKIP $W: 'git worktree remove' refused — left intact"; return; fi
  git -C "$m" worktree prune 2>/dev/null
  if git -C "$m" branch -d "$b" 2>/dev/null; then echo "REMOVED $W  (branch $b deleted with -d)"
  elif [ "$v" = LANDED ] && git -C "$m" branch -D "$b" >/dev/null 2>&1; then echo "REMOVED $W  (branch $b deleted with -D: proven LANDED)"
  else echo "REMOVED $W  (branch $b RETAINED — -d refused)"; fi
}
reverify() { # W branch → echoes current verdict line after a fresh fetch; empty on failure
  git -C "$1" fetch -q origin 2>/dev/null || return
  merge_state "$1" "$2" "$(projenc_of "$1")"
}
guard_target() { # W → empty if W may be a removal target, else the reason it may not
  local m
  case "$1" in "$BASE"/*) ;; *) echo "outside $BASE"; return;; esac
  m=$(mainwt_of "$1"); [ -z "$m" ] && { echo "not a worktree"; return; }
  [ "$m" = "$1" ] && echo "main checkout — never a removal target"
}

# Sourced (to reuse the helpers): stop here, so no argument is ever consumed as MODE.
(return 0 2>/dev/null) && return 0
MODE="${1:-plan}"; shift || true
FETCH=0
if [ "$MODE" = --fetch ]; then MODE=plan; FETCH=1
elif [ "$MODE" = plan ] && [ "${1:-}" = --fetch ]; then FETCH=1; shift; fi
case "$MODE" in plan|apply|apply-scaffold) ;; *) echo "unknown mode '$MODE' (plan [--fetch] | apply <worktree>... | apply-scaffold <worktree>...)"; exit 2;; esac

# ── apply / apply-scaffold: ONLY the worktrees the user approved, each re-verified now ──
if [ "$MODE" != plan ] && [ $# -eq 0 ]; then
  echo "REFUSED: '$MODE' takes the worktree paths the user approved ($MODE <worktree>...). Nothing removed; read-only plan follows."
  echo; MODE=plan
fi
if [ "$MODE" != plan ]; then
  for W in "$@"; do
    W=${W%/}
    g=$(guard_target "$W"); [ -n "$g" ] && { echo "SKIP $W: $g"; continue; }
    b=$(git -C "$W" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$b" ] || [ "$b" = HEAD ]; then echo "SKIP $W: detached HEAD / unreadable"; continue; fi
    classify_wt "$W"
    [ -n "$REAL" ] && { echo "SKIP $W: REAL-CHANGE now present: $REAL"; continue; }
    if [ "$MODE" = apply ]; then
      [ -n "$SCAF" ] && { echo "SKIP $W: LOCAL-SCAFFOLDING present — needs apply-scaffold on the user's go: $SCAF"; continue; }
    else
      [ -z "$SCAF" ] && { echo "SKIP $W: clean now — use apply"; continue; }
    fi
    ms=$(reverify "$W" "$b"); v=${ms%%$'\t'*}
    case "$v" in REMOVE|LANDED) ;; *) echo "SKIP $W: not removable now (${ms:+${ms#*$'\t'}}${ms:-fetch failed})"; continue;; esac
    if [ "$MODE" = apply-scaffold ]; then
      [ ${#SCAF_T[@]} -gt 0 ] && git -C "$W" restore --source=HEAD --staged --worktree -- "${SCAF_T[@]}"
      for f in "${SCAF_U[@]}"; do rm -f -- "$W/$f"; done
      [ -n "$(git -C "$W" status --porcelain 2>/dev/null)" ] && { echo "SKIP $W: still dirty after discarding scaffolding"; continue; }
      echo "DISCARDED in $W: $SCAF"
    fi
    echo "VERIFIED $W ($b): $ms"
    remove_wt "$W" "$b" "$v"
  done
  exit 0
fi

# ── 1. Collect candidate worktree paths ──────────────────────────────────────
declare -A SEEN=()
CANDS=()
add_cand() {
  local p="$1"; [ -z "$p" ] && return
  case "$p" in "$BASE"/*) ;; *) return;; esac      # must live under BASE (skips /tmp scratchpad worktrees)
  case "$p" in */.claude/worktrees/*) ;;           # Claude Code-managed: IN scope, but gated by the idle check below
                */.claude/*) return;; esac          # any other .claude/ internals — never a worktree, skip
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
  # ── Claude Code worktrees: only consider ones no agent has touched in IDLE_DAYS ──
  # A live agent's worktree is either dirty (caught below) or freshly written (caught here).
  # Locked worktrees are never candidates. Both guards must pass before the normal rules apply.
  case "$W" in */.claude/worktrees/*)
    if git -C "$W" worktree list --porcelain 2>/dev/null | grep -q '^locked'; then
      RESULTS+=("KEEP	$W	?	?	Claude Code worktree is LOCKED — an agent may be using it"); continue
    fi
    newest=$(find "$W" -type f -not -path '*/.git/*' -not -path '*/bin/*' -not -path '*/obj/*' \
               -newermt "-${IDLE_DAYS} days" -print -quit 2>/dev/null)
    if [ -n "$newest" ]; then
      RESULTS+=("KEEP	$W	?	?	Claude Code worktree touched within ${IDLE_DAYS}d — assume an agent is working in it"); continue
    fi
    ;;
  esac
  branch=$(git -C "$W" rev-parse --abbrev-ref HEAD 2>/dev/null)
  repo=$(git -C "$W" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*/##')
  if [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
    RESULTS+=("KEEP	$W	(detached)	$repo	detached HEAD — unknown state"); continue
  fi
  classify_wt "$W"
  if [ -n "$REAL" ]; then
    RESULTS+=("KEEP	$W	$branch	$repo	dirty, REAL-CHANGE: $REAL${SCAF:+| LOCAL-SCAFFOLDING: $SCAF}"); continue
  fi
  cdir=$(git -C "$W" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ "$FETCH" = 1 ] && [ -z "${FETCHED[$cdir]:-}" ]; then   # plan is read-only unless --fetch
    if ! git -C "$W" fetch -q origin 2>/dev/null; then
      RESULTS+=("KEEP	$W	$branch	$repo	fetch failed — cannot verify merge state"); continue
    fi
    FETCHED[$cdir]=1
  fi
  if ! git -C "$W" rev-parse --verify -q origin/development >/dev/null 2>&1; then
    RESULTS+=("KEEP	$W	$branch	$repo	no origin/development ref"); continue
  fi
  ms=$(merge_state "$W" "$branch" "$(projenc_of "$W")"); v=${ms%%$'\t'*}; why=${ms#*$'\t'}
  if [ -n "$SCAF" ]; then
    case "$v" in
      REMOVE|LANDED) RESULTS+=("REMOVE-AFTER-SCAFFOLD	$W	$branch	$repo	$why; discard on user go: $SCAF");;
      *)             RESULTS+=("KEEP	$W	$branch	$repo	$why; dirt is LOCAL-SCAFFOLDING only: $SCAF");;
    esac
    continue
  fi
  RESULTS+=("$v	$W	$branch	$repo	$why")
done

# ── 3. Print the plan (read-only; removal happens only via apply <worktree>...) ──
if [ "$FETCH" = 1 ]; then echo "PLAN (origin refs fetched now)"
else echo "PLAN (origin refs as of the last fetch — pass --fetch to refresh)"; fi
printf '%-22s %-46s %-38s %s\n' VERDICT WORKTREE BRANCH REASON
printf '%-22s %-46s %-38s %s\n' "-------" "--------" "------" "------"
declare -A N=()
for r in "${RESULTS[@]}"; do
  IFS=$'\t' read -r v p b repo reason <<<"$r"
  printf '%-22s %-46s %-38s %s\n' "$v" ".../${p#$BASE/}" "$b" "$reason"
  N[$v]=$(( ${N[$v]:-0} + 1 ))
done
echo; echo "SUMMARY: REMOVE=${N[REMOVE]:-0}  LANDED=${N[LANDED]:-0}  REMOVE-AFTER-SCAFFOLD=${N[REMOVE-AFTER-SCAFFOLD]:-0}  KEEP=${N[KEEP]:-0}"
exit 0
```

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
- The candidate resolves to a main checkout (a repo root under `~/Entwicklung/bpp`) or a path outside `~/Entwicklung/bpp` → it must never be a removal target.
