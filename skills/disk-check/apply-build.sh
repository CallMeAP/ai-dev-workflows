#!/usr/bin/env bash
# disk-check / apply-build.sh — item 8: delete ONLY approved build-output dirs listed by report.sh, re-checked now:
#   the path is a line of the build list (written < MAX_AGE_H hours ago), its basename is
#   bin|obj|node_modules|.angular|dist, it sits inside the recorded worktree, the worktree is a LINKED git
#   worktree (not a main checkout) outside bpp-document-analysis*, still idle (no source file
#   changed in 7 d), and nothing under the path is tracked by git. Anything else is SKIPPED. No globs, no sudo.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
LIST="${DISK_CHECK_BUILD_LIST:-$HOME/.claude/state/disk-check-build-dirs.tsv}"
MAX_AGE_H="${MAX_AGE_H:-6}"
[ $# -eq 0 ] && { echo "REFUSED: pass the approved paths explicitly."; exit 2; }
[ -f "$LIST" ] || { echo "REFUSED: $LIST missing - run report.sh first."; exit 2; }
[ $(( $(date +%s) - $(stat -c %Y "$LIST") )) -lt $((MAX_AGE_H * 3600)) ] || { echo "REFUSED: $LIST older than $MAX_AGE_H h - run report.sh again."; exit 2; }
STAMP=$(mktemp); trap 'rm -f "$STAMP"' EXIT; touch -d '-7 days' "$STAMP"
for arg in "$@"; do
  a=${arg%/}
  [ -n "$a" ] || { echo "SKIP '$arg': empty or /"; continue; }
  W=$(awk -F'\t' -v p="$a" '$2==p{print $3; exit}' "$LIST")
  [ -n "$W" ] || { echo "SKIP $a: not in the build list"; continue; }
  [ -L "$a" ] && { echo "SKIP $a: symlink"; continue; }
  P=$(realpath -e -- "$a" 2>/dev/null) || { echo "SKIP $a: does not exist"; continue; }
  [ "$P" = "$a" ] || { echo "SKIP $a: not canonical (resolves to $P)"; continue; }
  [ -d "$P" ] && [ -O "$P" ] || { echo "SKIP $P: not a directory I own"; continue; }
  case "$(basename "$P")" in bin|obj|node_modules|.angular|dist) ;; *) echo "SKIP $P: not a build-output name"; continue;; esac
  printf '%s' "$P$W" | grep -qE "$NO_TOUCH_RE" && { echo "SKIP $P: no-touch repo"; continue; }
  [ "${P#"$W"/}" != "$P" ] || { echo "SKIP $P: not inside worktree $W"; continue; }
  gd=$(git -C "$W" rev-parse --absolute-git-dir 2>/dev/null); cd_=$(git -C "$W" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  top=$(git -C "$W" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$gd" ] && [ -n "$cd_" ] && [ "$gd" != "$cd_" ] && [ "$top" = "$W" ] || { echo "SKIP $P: $W is not a linked git worktree"; continue; }
  worktree_idle "$W" "$STAMP"; rc=$?
  [ $rc = 0 ] || { echo "SKIP $P: worktree $( [ $rc = 1 ] && echo 'is active again' || echo 'idle check timed out')"; continue; }
  [ -z "$(git -C "$W" ls-files -- "${P#"$W"/}" 2>/dev/null | head -1)" ] || { echo "SKIP $P: contains tracked files"; continue; }
  s=$(mb "$P" 30); rm -rf --one-file-system -- "$P" && echo "DELETED $P ($s MB)" || echo "FAILED $P"
done
