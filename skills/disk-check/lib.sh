#!/usr/bin/env bash
# disk-check / lib.sh — shared checks for report.sh, apply-cache.sh, apply-build.sh. Read-only; sourced, not run.
DEV_ROOT="${DEV_ROOT:-$HOME/Entwicklung}"
CY_CACHE="${CYPRESS_CACHE_FOLDER:-$HOME/.cache/Cypress}"
SCRATCH_ROOT="${DISK_CHECK_SCRATCH_ROOT:-/tmp/claude-$(id -u)}"   # override only for tests
ACTIVE_MIN="${ACTIVE_MIN:-120}"          # a session written to within this many minutes is active
NO_TOUCH_RE='bpp-agent|bpp-document-analysis'
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

mb() { timeout "${2:-60}" du -smx "$1" 2>/dev/null | cut -f1 | grep . || echo "?"; }

# a deletion root is usable only if it exists, is canonical, owned by me and at least 2 levels deep
# (refuses "", "/", "/tmp" (not mine), "$HOME" and symlinked roots) → prints the canonical path or nothing
safe_root() {
  local r=$1 c
  [ -n "$r" ] && [ -d "$r" ] && [ ! -L "$r" ] || return 1
  c=$(realpath -e -- "$r" 2>/dev/null) || return 1
  [ "$c" = "$r" ] || [ "$c" = "${r%/}" ] || return 1
  [ -O "$c" ] || return 1
  [ "$(printf '%s' "$c" | tr -cd / | wc -c)" -ge 2 ] || return 1
  [ "$c" != "$HOME" ] || return 1
  printf '%s' "$c"
}

# Cypress versions installed in any node_modules: "<version>\t<checkout>"
# DEV_ROOT (worktrees incl., symlinked node_modules followed), ~/.npm/_npx, the global npm root
cypress_installed() {
  local g; g=$(timeout 10 npm root -g 2>/dev/null)
  {
    find "$DEV_ROOT" -maxdepth 7 -path '*/node_modules/cypress/package.json' -not -path '*/node_modules/*/node_modules/*' 2>/dev/null
    find "$DEV_ROOT" -maxdepth 6 -name node_modules -type l -not -path '*/node_modules/*/*' 2>/dev/null |
      while IFS= read -r l; do [ -f "$l/cypress/package.json" ] && printf '%s\n' "$l/cypress/package.json"; done
    find "$HOME/.npm/_npx" -maxdepth 4 -path '*/node_modules/cypress/package.json' 2>/dev/null
    [ -n "$g" ] && [ -f "$g/cypress/package.json" ] && printf '%s\n' "$g/cypress/package.json"
  } | while IFS= read -r f; do
    v=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$f" | head -1)
    printf '%s\t%s\n' "$v" "${f%/node_modules/cypress/package.json}"
  done
}
# Cypress versions pinned in a lockfile (package-lock.json) without being installed: "<version>\t<checkout>"
cypress_pinned() {
  find "$DEV_ROOT" -maxdepth 4 -name package-lock.json -not -path '*/node_modules/*' 2>/dev/null |
  while IFS= read -r f; do
    v=$(grep -A2 '"node_modules/cypress": {' "$f" 2>/dev/null | sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$v" ] && printf '%s\t%s\n' "$v" "$(dirname "$f")"
  done
}
# Cypress versions a running process executes or maps right now
cypress_running() {
  for p in /proc/[0-9]*; do
    { readlink "$p/exe"; cat "$p/maps"; } 2>/dev/null | grep -o "$CY_CACHE/[^/ ]*"
  done 2>/dev/null | sed "s#$CY_CACHE/##" | sort -u
}
# verdict for one cache version dir → "DELETABLE<TAB>reason" or "KEEP<TAB>reason"
cypress_verdict() { # ver installed_list running_list [pinned_list]
  local v=$1 where pins
  [ "$v" = bundles ] && { printf 'KEEP\tbundles dir, never'; return; }
  printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { printf 'KEEP\tnot a version dir'; return; }
  printf '%s\n' "$3" | grep -Fqx -- "$v" && { printf 'KEEP\ta running process uses it'; return; }
  where=$(printf '%s\n' "$2" | awk -F'\t' -v v="$v" '$1==v{print $2}')
  [ -n "$where" ] && { printf 'KEEP\tinstalled in %s' "$(printf '%s' "$where" | sed "s#$DEV_ROOT/##" | paste -sd, | cut -c1-150)"; return; }
  pins=$(printf '%s\n' "${4:-}" | awk -F'\t' -v v="$v" '$1==v{print $2}' | grep -c .)
  if [ "$pins" -gt 0 ]; then
    printf 'DELETABLE\tnot installed anywhere, no process uses it; CAVEAT: pinned in %s lockfile(s) (%s) - the next npm ci there re-downloads it' \
      "$pins" "$(printf '%s\n' "$4" | awk -F'\t' -v v="$v" '$1==v{print $2}' | sed "s#$DEV_ROOT/##" | head -2 | paste -sd, )$( [ "$pins" -gt 2 ] && echo ",...")"
  else
    printf 'DELETABLE\tno node_modules/cypress has this version, no lockfile pins it, no process uses it'
  fi
}

# session ids with a process of mine holding an open fd or its cwd in the scratch tree (any process, not only "claude")
scratch_open_sessions() {
  local p
  for p in /proc/[0-9]*; do
    [ -O "$p" ] || continue
    { readlink "$p/cwd"; ls -l "$p/fd" 2>/dev/null | sed 's/.* -> //'; } 2>/dev/null
  done | grep -F "$SCRATCH_ROOT/" | grep -oE "$UUID_RE" | sort -u
}
# verdict for one scratch dir → "DELETABLE|KEEP<TAB>reason"
scratch_verdict() { # dir open_sessions
  local d=$1 sid now jl newest
  sid=$(printf '%s' "$d" | grep -oE "$UUID_RE" | tail -1)
  [ -z "$sid" ] && { printf 'KEEP\tnot a session dir'; return; }
  [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] && { printf 'KEEP\tCLAUDE_CODE_SESSION_ID unset: cannot rule out the current session'; return; }
  [ "$sid" = "$CLAUDE_CODE_SESSION_ID" ] && { printf 'KEEP\tcurrent session'; return; }
  printf '%s\n' "$2" | grep -Fqx -- "$sid" && { printf 'KEEP\tactive: a running process has files open or its cwd in it'; return; }
  now=$(date +%s)
  jl=$(find "$HOME/.claude/projects" -maxdepth 2 -name "$sid.jsonl" -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
  [ -n "$jl" ] && [ $((now - jl)) -lt $((ACTIVE_MIN * 60)) ] && { printf 'KEEP\tactive: session jsonl written %s' "$(date -d @"$jl" +%H:%M)"; return; }
  newest=$(timeout 30 find "$d" -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
  [ -n "$newest" ] && [ $((now - newest)) -lt $((ACTIVE_MIN * 60)) ] && { printf 'KEEP\tactive: scratch written %s' "$(date -d @"$newest" +%H:%M)"; return; }
  printf 'DELETABLE\tidle: jsonl %s, scratch %s, no open fd/cwd' "$( [ -n "$jl" ] && date -d @"$jl" '+%F %H:%M' || echo none)" "$( [ -n "$newest" ] && date -d @"$newest" '+%F %H:%M' || echo empty)"
}

# item 8: is worktree W idle (no source file newer than STAMP)? rc 0 idle, 1 active, 2 unknown (find timed out)
worktree_idle() { # W stamp
  local recent rc
  recent=$(timeout 10 find "$1" \( -name .git -o -name bin -o -name obj -o -name node_modules -o -name .angular -o -name dist \) -prune -o -type f -newer "$2" -print -quit 2>/dev/null); rc=$?
  [ $rc = 124 ] && return 2
  [ -n "$recent" ] && return 1
  return 0
}
