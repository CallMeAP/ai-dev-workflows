#!/usr/bin/env bash
# bpp-cleanup-merged-worktrees / stale.sh — reclaim disk from idle, clean, PUSHED worktrees (merged or not).
#   stale.sh plan  [--days N] [--exclude repo1,repo2]   read-only table + per-repo totals; writes the candidate list
#   stale.sh apply <worktree>...                         remove ONLY the approved paths, each re-verified now
# A candidate is: clean tree (git status --porcelain empty), HEAD reachable from a remote-tracking ref
# (so no commit is lost), no file outside .git/bin/obj/node_modules/.angular/dist changed within N days (default 7),
# not locked, not a main checkout. Removal = `git worktree remove` (never --force) + prune.
# Local branches are KEPT (no branch -d/-D) — the branch may hold an open MR.
set -uo pipefail
ROOTS=(/home/alex/Entwicklung/bpp /home/alex/Entwicklung/brokernet)
DAYS=7; EXCLUDE="bpp-agent,bpp-document-analysis"
LIST="${STALE_LIST:-$HOME/.claude/state/stale-worktrees.tsv}"

idle_since() { find "$1" \( -name .git -o -name bin -o -name obj -o -name node_modules -o -name .angular -o -name dist \) -prune \
  -o -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1; }
mainwt_of() { git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'; }
check() { # W → empty when W is a candidate, else the reason it is kept
  local W=$1 m last
  m=$(mainwt_of "$W"); [ -z "$m" ] && { echo "not a worktree"; return; }
  [ "$m" = "$W" ] && { echo "main checkout"; return; }
  git -C "$m" worktree list --porcelain | grep -A6 -x "worktree $W" | grep -q '^locked' && { echo "locked"; return; }
  [ -n "$(git -C "$W" status --porcelain 2>/dev/null)" ] && { echo "dirty"; return; }
  [ -z "$(git -C "$W" branch -r --contains HEAD 2>/dev/null | grep -v -- '->')" ] && { echo "HEAD on no remote (unpushed)"; return; }
  last=$(idle_since "$W"); [ "${last:-0}" -gt "$(date -d "-$DAYS days" +%s)" ] && { echo "touched within ${DAYS}d"; return; }
  return 0
}

MODE="${1:-plan}"; shift || true
case "$MODE" in
plan)
  while [ $# -gt 0 ]; do case "$1" in --days) DAYS=$2; shift 2;; --exclude) EXCLUDE=$2; shift 2;; *) echo "unknown arg $1"; exit 2;; esac; done
  mkdir -p "$(dirname "$LIST")"; : > "$LIST"
  echo "STALE PLAN (idle >= ${DAYS}d, clean, HEAD pushed; excluded repos: ${EXCLUDE:-none}; refs as of last fetch)"
  for root in "${ROOTS[@]}"; do for g in "$root"/*/.git; do [ -d "$g" ] || continue
    r=$(dirname "$g"); repo=$(basename "$r")
    case ",$EXCLUDE," in *",$repo,"*) continue;; esac
    git -C "$r" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | tail -n +2 | while IFS= read -r W; do
      [ -d "$W" ] || continue
      case "$W" in */bpp-agent*) continue;; esac   # bpp-agent paths never, whatever repo owns them
      why=$(check "$W"); [ -n "$why" ] && continue
      sz=$(du -sm "$W" 2>/dev/null | cut -f1); b=$(git -C "$W" rev-parse --abbrev-ref HEAD)
      printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$W" "$b" "$sz" "$(date -d @"$(idle_since "$W")" +%F)" >> "$LIST"
    done
  done; done
  awk -F'\t' '{printf "  %6d MB  %s  %-70s %s\n",$4,$5,$2,$3}' "$LIST"
  echo; awk -F'\t' '{n[$1]++; s[$1]+=$4; t+=$4; c++} END{for(k in n) printf "  %-32s %3d wt %6.1f GB\n",k,n[k],s[k]/1024; printf "TOTAL: %d worktrees, %.1f GB\n",c,t/1024}' "$LIST"
  echo "Candidate list: $LIST  (apply with: stale.sh apply \$(cut -f2 $LIST)  — only after the user's go)"
  ;;
apply)
  [ $# -eq 0 ] && { echo "REFUSED: apply takes the approved worktree paths."; exit 2; }
  for W in "$@"; do W=${W%/}
    inroot=0; for b in "${ROOTS[@]}"; do case "$W" in "$b"/*) inroot=1;; esac; done
    [ $inroot = 0 ] && { echo "SKIP $W: outside ${ROOTS[*]}"; continue; }
    case "$W" in */bpp-agent*|*/bpp-document-analysis*) echo "SKIP $W: no-touch repo"; continue;; esac
    why=$(check "$W"); [ -n "$why" ] && { echo "SKIP $W: $why"; continue; }
    m=$(mainwt_of "$W")
    if git -C "$m" worktree remove "$W" 2>/dev/null; then git -C "$m" worktree prune; echo "REMOVED $W  (branch kept)"
    else echo "SKIP $W: 'git worktree remove' refused — left intact"; fi
  done
  ;;
*) echo "usage: stale.sh plan [--days N] [--exclude a,b] | stale.sh apply <worktree>..."; exit 2;;
esac
exit 0
