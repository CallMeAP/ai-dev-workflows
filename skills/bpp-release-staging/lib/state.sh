#!/usr/bin/env bash
# Run state and run lock for bpp-release-staging.
# Usage:
#   state.sh lock <run_id>    take the lock for this run, or refresh it when this run holds it
#                             exit 7 if another run holds it with a heartbeat younger than 3 hours;
#                             an older lock is taken over and reported on stderr
#   state.sh unlock <run_id>  remove the lock if this run holds it (exit 7 if another run does)
#   state.sh new <run_id>   start a fresh state file; keeps sql_applied of a run that did not finish
#   state.sh get [key]      print the state JSON, or one key of it (exit 3 if no state file)
#   state.sh set-phase <spec label: 0 1 2 3 4 5 5b 6 ... 16>
#   state.sh set-heads <json object {repo: sha}> | set-package <version>
#   state.sh set-baseline <json object>   health + staging deploy baseline taken in Preflight
#   state.sh set-pre-move-sha <sha>       bpp-shared HEAD before phase 3 moved it (8-40 hex)
#   state.sh add-sql <development|staging> <file-id>   record a SQL file run on that stage
#   state.sh has-sql <development|staging> <file-id>   exit 0 if recorded, 1 if not
#   state.sh add-applied <text> | halt <reason> | done
# The lock holds the run_id, not a pid: each workflow Bash call is a new short-lived shell.
# Call "lock <run_id>" at the start of every phase so the heartbeat stays fresh.
# Exit 2 on bad usage.
# shellcheck disable=SC2016
set -u

DIR="$HOME/.claude/state/bpp-release"
STATE="$DIR/state.json"
LOCK="$DIR/lock"
# lock and unlock change the lock file only while they own this dir
LOCK_DIR="$DIR/lock.d"
STALE_SECS=10800

die() { printf 'state.sh: %s\n' "$2" >&2; exit "$1"; }

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

check_id() {
  case "$1" in
    '') die 2 "usage: state.sh $2 <run_id>" ;;
    *[!A-Za-z0-9._:-]*) die 2 "run_id may only hold letters, digits and ._:-: $1" ;;
  esac
}

# take the lock dir; wait up to 2 seconds for another lock/unlock call to finish
enter() {
  local i=0
  mkdir -p "$DIR" || die 1 "cannot create $DIR"
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 20 ] && die 7 "lock dir busy: $LOCK_DIR (remove it if no release run is active)"
    sleep 0.1
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
}

# write "<run_id>\n<epoch>" via a temp file and mv
write_lock() {
  if ! printf '%s\n%s\n' "$1" "$(date +%s)" > "$LOCK.tmp.$$" || ! mv "$LOCK.tmp.$$" "$LOCK"; then
    rm -f "$LOCK.tmp.$$"
    die 1 "cannot write $LOCK"
  fi
}

cmd_lock() {
  local id=$1 holder beat now age
  check_id "$id" lock
  enter
  if [ ! -e "$LOCK" ]; then write_lock "$id"; return 0; fi
  holder=$(sed -n 1p "$LOCK")
  beat=$(sed -n 2p "$LOCK")
  if [ "$holder" = "$id" ]; then write_lock "$id"; return 0; fi
  now=$(date +%s)
  is_num "$beat" || beat=0
  age=$((now - beat))
  if [ "$age" -lt "$STALE_SECS" ]; then
    die 7 "lock held by run ${holder:-?}, last heartbeat ${age}s ago ($LOCK)"
  fi
  printf 'state.sh: stale lock of run %s (last heartbeat %ss ago) taken over\n' "${holder:-?}" "$age" >&2
  write_lock "$id"
}

cmd_unlock() {
  local id=$1 holder
  check_id "$id" unlock
  enter
  [ -e "$LOCK" ] || return 0
  holder=$(sed -n 1p "$LOCK")
  [ "$holder" = "$id" ] || die 7 "lock held by run ${holder:-?}, not $id; left in place ($LOCK)"
  rm -f "$LOCK"
}

# apply a jq filter to the state file, write back via a temp file
update() {
  local tmp
  [ -f "$STATE" ] || die 3 "no state file: $STATE"
  tmp="$STATE.tmp.$$"
  if ! jq "$@" "$STATE" > "$tmp" || ! mv "$tmp" "$STATE"; then
    rm -f "$tmp"
    die 1 "cannot update $STATE"
  fi
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  lock) cmd_lock "${1:-}" ;;
  unlock) cmd_unlock "${1:-}" ;;
  new)
    [ -n "${1:-}" ] || die 2 "usage: state.sh new <run_id>"
    mkdir -p "$DIR" || die 1 "cannot create $DIR"
    # SQL already run by a halted or crashed run must not run again
    sql='{"development":[],"staging":[]}'
    if [ -f "$STATE" ] && [ "$(jq -r .status "$STATE" 2>/dev/null)" != "done" ]; then
      sql=$(jq -c '{development: (.sql_applied.development // []), staging: (.sql_applied.staging // [])}' "$STATE") ||
        die 1 "cannot read $STATE"
    fi
    if ! jq -n --arg id "$1" --argjson sql "$sql" \
      '{run_id: $id, phase: "0", status: "running", applied: [], halt_reason: null, heads: {}, package: null, baseline: null, pre_move_sha: null, sql_applied: $sql}' \
      > "$STATE.tmp.$$" || ! mv "$STATE.tmp.$$" "$STATE"; then
      rm -f "$STATE.tmp.$$"
      die 1 "cannot write $STATE"
    fi
    ;;
  get)
    [ -f "$STATE" ] || die 3 "no state file: $STATE"
    case "${1:-}" in
      '') cat "$STATE" ;;
      run_id|phase|status|applied|halt_reason|heads|package|baseline|pre_move_sha|sql_applied)
        jq -r --arg k "$1" '.[$k] | if type == "string" then . else tojson end' "$STATE" ;;
      *) die 2 "unknown key: $1 (run_id|phase|status|applied|halt_reason|heads|package|baseline|pre_move_sha|sql_applied)" ;;
    esac
    ;;
  set-phase)
    case "${1:-}" in
      0|1|2|3|4|5|5b|6|7|8|9|10|11|12|13|14|15|16) ;;
      *) die 2 "usage: state.sh set-phase <spec label: 0-16 or 5b>" ;;
    esac
    update --arg n "$1" '.phase = $n'
    ;;
  set-heads)
    printf '%s' "${1:-}" | jq -e 'type == "object" and all(.[]; type == "string")' >/dev/null 2>&1 ||
      die 2 "usage: state.sh set-heads '{\"<repo>\":\"<sha>\",...}'"
    update --argjson h "$1" '.heads = $h'
    ;;
  set-package)
    case "${1:-}" in
      ''|*[!A-Za-z0-9.+_-]*) die 2 "usage: state.sh set-package <version> (letters, digits and .+_- only)" ;;
    esac
    update --arg v "$1" '.package = $v'
    ;;
  set-baseline)
    printf '%s' "${1:-}" | jq -e 'type == "object"' >/dev/null 2>&1 ||
      die 2 "usage: state.sh set-baseline '<json object>'"
    update --argjson b "$1" '.baseline = $b'
    ;;
  set-pre-move-sha)
    case "${1:-}" in
      *[!0-9a-f]*|'') die 2 "usage: state.sh set-pre-move-sha <sha> (8-40 lowercase hex)" ;;
    esac
    if [ "${#1}" -lt 8 ] || [ "${#1}" -gt 40 ]; then
      die 2 "usage: state.sh set-pre-move-sha <sha> (8-40 lowercase hex)"
    fi
    update --arg v "$1" '.pre_move_sha = $v'
    ;;
  add-sql|has-sql)
    case "${1:-}" in
      development|staging) ;;
      *) die 2 "usage: state.sh $cmd <development|staging> <file-id>" ;;
    esac
    [ -n "${2:-}" ] || die 2 "usage: state.sh $cmd <development|staging> <file-id>"
    if [ "$cmd" = add-sql ]; then
      update --arg s "$1" --arg f "$2" \
        '.sql_applied[$s] = ((.sql_applied[$s] // []) | if index([$f]) then . else . + [$f] end)'
    else
      [ -f "$STATE" ] || die 3 "no state file: $STATE"
      jq -e --arg s "$1" --arg f "$2" '(.sql_applied[$s] // []) | index([$f]) != null' "$STATE" >/dev/null
      exit $?
    fi
    ;;
  add-applied)
    [ -n "${1:-}" ] || die 2 "usage: state.sh add-applied <text>"
    update --arg t "$1" '.applied += [$t]'
    ;;
  halt)
    [ -n "${1:-}" ] || die 2 "usage: state.sh halt <reason>"
    update --arg r "$1" '.status = "halted" | .halt_reason = $r'
    ;;
  done) update '.status = "done"' ;;
  *) die 2 "unknown command: $cmd (lock|unlock|new|get|set-phase|set-heads|set-package|set-baseline|set-pre-move-sha|add-sql|has-sql|add-applied|halt|done)" ;;
esac
