#!/usr/bin/env bash
# Prints a "Henry" ping block to the terminal.
# Usage: henry-ping.sh <info|blocker> <title> <body-file-or-text>
# A body that names a regular file in ~/.claude/state/bpp-release/ is read from that file.
# Any other body is printed as text, so a path to a secret file is never read.
set -u

# true when $1 is a regular file (not a symlink) directly in the state dir
in_state_dir() {
  local sdir fdir
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  sdir=$(cd "$HOME/.claude/state/bpp-release" 2>/dev/null && pwd -P) || return 1
  fdir=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  [ "$fdir" = "$sdir" ]
}

sev=${1:-}
title=${2:-}
body=${3:-}
case "$sev" in
  info|blocker) ;;
  *) printf 'henry-ping.sh: usage: henry-ping.sh <info|blocker> <title> <body-file-or-text>\n' >&2; exit 2 ;;
esac

printf '===== HENRY PING (%s) =====\n' "$sev"
printf '%s\n\n' "$title"
if [ -n "$body" ] && in_state_dir "$body"; then
  cat "$body"
else
  printf '%s\n' "$body"
fi
printf '\nTODO: post to Henry Teams channel\n'
printf '===== END HENRY PING =====\n'
