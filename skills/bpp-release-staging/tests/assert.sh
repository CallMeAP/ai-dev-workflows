# shellcheck shell=bash
# Small assert helpers for the plain bash tests. Source it, call finish at the end.

FAILS=0
PASSES=0

_pass() { PASSES=$((PASSES + 1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$1"; }

# assert_eq <expected> <actual> <msg>
assert_eq() {
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (expected [$1], got [$2])"; fi
}

# assert_status <code> <cmd...> - runs cmd, compares its exit code
assert_status() {
  local want=$1 got
  shift
  "$@" >/dev/null 2>&1
  got=$?
  if [ "$want" = "$got" ]; then _pass "status $want: $*"; else _fail "status $want: $* (got $got)"; fi
}

# assert_not_contains <needle> <haystack> <msg>
assert_not_contains() {
  case "$2" in
    *"$1"*) _fail "$3 (found forbidden text)" ;;
    *) _pass "$3" ;;
  esac
}

# assert_contains <needle> <haystack> <msg>
assert_contains() {
  case "$2" in
    *"$1"*) _pass "$3" ;;
    *) _fail "$3 (missing [$1])" ;;
  esac
}

# finish - prints totals, exits non-zero when any assert failed
finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSES" "$FAILS"
  [ "$FAILS" -eq 0 ]
  exit $?
}
