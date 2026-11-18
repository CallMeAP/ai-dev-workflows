#!/usr/bin/env bash
# disk-check / apply-cache.sh — delete ONLY approved, explicit paths of two kinds:
#   ~/.cache/Cypress/<x.y.z>               (never bundles, never an installed or running version)
#   /tmp/claude-<uid>/<project>/<session>  or /tmp/claude-<uid>/<project-session>  (never current/active session)
# Each path's verdict is re-checked right before deletion; anything not DELETABLE now is SKIPPED.
# No globs, no other locations, no sudo. Worktrees go through bpp-cleanup-merged-worktrees, not here.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
[ $# -eq 0 ] && { echo "REFUSED: pass the approved paths explicitly."; exit 2; }
CYR=$(safe_root "$CY_CACHE") || CYR=""        # "" => no Cypress path can match below
SCR=$(safe_root "$SCRATCH_ROOT") || SCR=""
INST=""; PIN=""; LOADED_CY=0
for arg in "$@"; do
  [ -n "$arg" ] || { echo "SKIP '': empty argument"; continue; }
  [ -L "${arg%/}" ] && { echo "SKIP $arg: symlink"; continue; }
  P=$(realpath -e -- "$arg" 2>/dev/null) || { echo "SKIP $arg: does not exist"; continue; }
  [ -n "$P" ] && [ "$P" != / ] || { echo "SKIP $arg: resolves to /"; continue; }
  [ -d "$P" ] && [ ! -L "$P" ] || { echo "SKIP $P: not a directory"; continue; }
  [ -O "$P" ] || { echo "SKIP $P: not owned by me"; continue; }
  verdict=KEEP; why="outside ${CYR:-<Cypress root refused>} and ${SCR:-<scratch root refused>}"
  if [ "$P" = "$CYR" ] || [ "$P" = "$SCR" ]; then why="a deletion root itself, never"
  elif [ -n "$CYR" ] && [ "${P#"$CYR"/}" != "$P" ]; then
    v=${P#"$CYR"/}
    case "$v" in */*|"") why="not a top-level version dir";;
    *) [ $LOADED_CY = 0 ] && { INST=$(cypress_installed); PIN=$(cypress_pinned); LOADED_CY=1; }
       IFS=$'\t' read -r verdict why < <(cypress_verdict "$v" "$INST" "$(cypress_running)" "$PIN") ;;   # running: fresh per path
    esac
  elif [ -n "$SCR" ] && [ "${P#"$SCR"/}" != "$P" ]; then
    rel=${P#"$SCR"/}
    if printf '%s' "$rel" | grep -qE "^[^/]+/$UUID_RE$" || printf '%s' "$rel" | grep -qE "^[^/]+-$UUID_RE$"; then
      IFS=$'\t' read -r verdict why < <(scratch_verdict "$P" "$(scratch_open_sessions)")
    else why="not a session dir (project/session or project-session only)"; fi
  fi
  if [ "$verdict" = DELETABLE ]; then
    s=$(mb "$P" 30); rm -rf --one-file-system -- "$P" && echo "DELETED $P ($s MB)" || echo "FAILED $P"
  else echo "SKIP $P: $why"; fi
done
