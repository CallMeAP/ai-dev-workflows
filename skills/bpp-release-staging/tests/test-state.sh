#!/usr/bin/env bash
# Tests for lib/state.sh and lib/henry-ping.sh. Uses a temp HOME.
# shellcheck disable=SC2016,SC1091
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
STATE="$here/../lib/state.sh"
PING="$here/../lib/henry-ping.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
SDIR="$HOME/.claude/state/bpp-release"

# run_cmd <cmd...> - sets OUT, ERR, RC
run_cmd() {
  "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# --- lock ---
# The holder is the run_id, not a pid: each workflow Bash call is a new short-lived shell.
run_cmd bash "$STATE" lock
assert_eq 2 "$RC" "lock: no run_id -> 2 (no short-lived default holder)"
[ -e "$SDIR/lock" ] && lock_left=yes || lock_left=no
assert_eq no "$lock_left" "lock: no run_id leaves no lock file"

# run A takes the lock in a subprocess that then exits
bash -c 'bash "$1" lock run-A' _ "$STATE"
assert_eq 0 "$?" "lock: run A gets it from a short-lived shell"
assert_eq "run-A" "$(head -n 1 "$SDIR/lock" 2>/dev/null)" "lock: file holds run A's id"

run_cmd bash "$STATE" lock run-B
assert_eq 7 "$RC" "lock: run B refused after run A's shell exited"
assert_contains "run-A" "$ERR" "lock: refusal names the holder"
assert_eq "run-A" "$(head -n 1 "$SDIR/lock" 2>/dev/null)" "lock: holder unchanged after refusal"

# same run again (next phase, resume) refreshes the heartbeat
printf 'run-A\n100\n' > "$SDIR/lock"
run_cmd bash "$STATE" lock run-A
assert_eq 0 "$RC" "lock: same run_id again -> 0"
hb=$(sed -n 2p "$SDIR/lock")
[ "${hb:-0}" -gt 100 ] && fresh=yes || fresh=no
assert_eq yes "$fresh" "lock: same run_id refreshes the heartbeat"

# heartbeat older than the stale limit -> taken over and reported
printf 'run-A\n100\n' > "$SDIR/lock"
run_cmd bash "$STATE" lock run-B
assert_eq 0 "$RC" "lock: stale lock taken over -> 0"
assert_contains "stale" "$ERR" "lock: stderr says stale"
assert_contains "run-A" "$ERR" "lock: stderr names the stale holder"
assert_eq "run-B" "$(head -n 1 "$SDIR/lock" 2>/dev/null)" "lock: file now holds run B"

# a takeover already running elsewhere -> refused, lock untouched
printf 'run-A\n100\n' > "$SDIR/lock"
mkdir "$SDIR/lock.d"
run_cmd bash "$STATE" lock run-C
assert_eq 7 "$RC" "lock: busy lock dir -> 7"
assert_eq "run-A" "$(head -n 1 "$SDIR/lock" 2>/dev/null)" "lock: busy lock dir leaves the lock alone"
rmdir "$SDIR/lock.d"

# two runs racing for the same stale lock -> exactly one wins
printf 'run-A\n100\n' > "$SDIR/lock"
bash "$STATE" lock run-X 2>/dev/null & px=$!
bash "$STATE" lock run-Y 2>/dev/null & py=$!
wait "$px"; rx=$?
wait "$py"; ry=$?
wins=0
[ "$rx" = 0 ] && wins=$((wins + 1))
[ "$ry" = 0 ] && wins=$((wins + 1))
assert_eq 1 "$wins" "lock: race for a stale lock has one winner"
holder=$(head -n 1 "$SDIR/lock")
if [ "$rx" = 0 ]; then want=run-X; else want=run-Y; fi
assert_eq "$want" "$holder" "lock: the winner holds the file"

# unlock only by the holder
printf 'run-B\n%s\n' "$(date +%s)" > "$SDIR/lock"
run_cmd bash "$STATE" unlock run-Z
assert_eq 7 "$RC" "unlock: other run_id -> 7"
assert_eq "run-B" "$(head -n 1 "$SDIR/lock" 2>/dev/null)" "unlock: other run_id leaves the lock"
run_cmd bash "$STATE" unlock
assert_eq 2 "$RC" "unlock: no run_id -> 2"
run_cmd bash "$STATE" unlock run-B
assert_eq 0 "$RC" "unlock: holder -> 0"
[ -e "$SDIR/lock" ] && lock_left=yes || lock_left=no
assert_eq no "$lock_left" "unlock: lock file removed"
run_cmd bash "$STATE" unlock run-B
assert_eq 0 "$RC" "unlock: no lock -> 0"

run_cmd bash "$STATE" lock 'bad id'
assert_eq 2 "$RC" "lock: run_id with a space -> 2"

# --- state ---
run_cmd bash "$STATE" new run-42
assert_eq 0 "$RC" "new: status 0"
run_cmd bash "$STATE" get
assert_eq "run-42" "$(printf '%s' "$OUT" | jq -r .run_id)" "get: run_id"
assert_eq "running" "$(printf '%s' "$OUT" | jq -r .status)" "get: status running"
assert_eq "0" "$(printf '%s' "$OUT" | jq -r .phase)" "get: phase 0"
assert_eq "[]" "$(printf '%s' "$OUT" | jq -c .applied)" "get: applied empty"
assert_eq "{}" "$(printf '%s' "$OUT" | jq -c .heads)" "get: heads empty"
assert_eq "null" "$(printf '%s' "$OUT" | jq -c .package)" "get: package null"
assert_eq "null" "$(printf '%s' "$OUT" | jq -c .halt_reason)" "get: halt_reason null"

bash "$STATE" set-phase 5
bash "$STATE" add-applied 'dev DB migrated'
bash "$STATE" add-applied 'quote " and $(touch pwned)'
run_cmd bash "$STATE" get
assert_eq "5" "$(printf '%s' "$OUT" | jq -r .phase)" "set-phase: phase 5"
assert_eq '["dev DB migrated","quote \" and $(touch pwned)"]' "$(printf '%s' "$OUT" | jq -c .applied)" "add-applied: kept in order, text literal"
[ -e pwned ] || [ -e "$HOME/pwned" ] && pw=yes || pw=no
assert_eq no "$pw" "add-applied: text not run"

run_cmd bash "$STATE" set-phase five
assert_eq 2 "$RC" "set-phase: non-numeric -> 2"

bash "$STATE" halt 'staging DB migrated, MRs not merged'
run_cmd bash "$STATE" get
assert_eq "halted" "$(printf '%s' "$OUT" | jq -r .status)" "halt: status halted"
assert_eq "staging DB migrated, MRs not merged" "$(printf '%s' "$OUT" | jq -r .halt_reason)" "halt: reason kept"
assert_eq "5" "$(printf '%s' "$OUT" | jq -r .phase)" "halt: phase kept"
assert_eq "2" "$(printf '%s' "$OUT" | jq -r '.applied | length')" "halt: applied kept"

bash "$STATE" "done"
run_cmd bash "$STATE" get
assert_eq "done" "$(printf '%s' "$OUT" | jq -r .status)" "done: status done"

# --- phase labels, heads, package, sql ---
run_cmd bash "$STATE" new run-50
assert_eq '"0"' "$(jq -c .phase "$SDIR/state.json")" "new: phase is the spec label \"0\""
assert_eq '{"development":[],"staging":[]}' "$(jq -c .sql_applied "$SDIR/state.json")" "new: sql_applied empty per stage"
run_cmd bash "$STATE" set-phase 5b
assert_eq 0 "$RC" "set-phase 5b -> 0"
assert_eq '"5b"' "$(jq -c .phase "$SDIR/state.json")" "set-phase: spec label 5b stored as text"
run_cmd bash "$STATE" set-phase 16
assert_eq '"16"' "$(jq -c .phase "$SDIR/state.json")" "set-phase: 16 stored"
for bad in 17 5c 5B ''; do
  run_cmd bash "$STATE" set-phase "$bad"
  assert_eq 2 "$RC" "set-phase '$bad' -> 2"
done

run_cmd bash "$STATE" set-package '10.2.3-development+abc123'
assert_eq 0 "$RC" "set-package -> 0"
run_cmd bash "$STATE" get package
assert_eq '10.2.3-development+abc123' "$OUT" "get package"
run_cmd bash "$STATE" set-package ''
assert_eq 2 "$RC" "set-package empty -> 2"
run_cmd bash "$STATE" set-package 'a b'
assert_eq 2 "$RC" "set-package with a space -> 2"

# --- baseline and pre-move sha ---
assert_eq "null" "$(jq -c .baseline "$SDIR/state.json")" "new: baseline null"
assert_eq "null" "$(jq -c .pre_move_sha "$SDIR/state.json")" "new: pre_move_sha null"
run_cmd bash "$STATE" set-baseline '{"health":{"release_unhealthy":[]},"deploys":[{"repo":"bpp-agent","status":"failed"}]}'
assert_eq 0 "$RC" "set-baseline -> 0"
run_cmd bash "$STATE" get baseline
assert_eq '{"health":{"release_unhealthy":[]},"deploys":[{"repo":"bpp-agent","status":"failed"}]}' "$OUT" "get baseline"
for bad in '[1]' 'not json' '"text"' ''; do
  run_cmd bash "$STATE" set-baseline "$bad"
  assert_eq 2 "$RC" "set-baseline '$bad' -> 2"
done
run_cmd bash "$STATE" set-pre-move-sha 9905c1c0197415db8680335f3052013732ba8b2a
assert_eq 0 "$RC" "set-pre-move-sha -> 0"
run_cmd bash "$STATE" get pre_move_sha
assert_eq 9905c1c0197415db8680335f3052013732ba8b2a "$OUT" "get pre_move_sha"
for bad in '' 'xyz' '9905c1' '9905c1c0197415db8680335f3052013732ba8b2a00' 'abc;rm'; do
  run_cmd bash "$STATE" set-pre-move-sha "$bad"
  assert_eq 2 "$RC" "set-pre-move-sha '$bad' -> 2"
done
run_cmd bash "$STATE" set-pre-move-sha 9905c1c0
assert_eq 0 "$RC" "set-pre-move-sha: short sha (8+ hex) -> 0"

run_cmd bash "$STATE" set-heads '{"bpp-backend":"abc123","bpp-auth":"def456"}'
assert_eq 0 "$RC" "set-heads -> 0"
run_cmd bash "$STATE" get heads
assert_eq '{"bpp-backend":"abc123","bpp-auth":"def456"}' "$OUT" "get heads"
for bad in '[1]' 'not json' '{"a":1}' ''; do
  run_cmd bash "$STATE" set-heads "$bad"
  assert_eq 2 "$RC" "set-heads '$bad' -> 2"
done
assert_eq '{"bpp-backend":"abc123","bpp-auth":"def456"}' "$(jq -c .heads "$SDIR/state.json")" "set-heads: bad input leaves heads alone"

ID1='bpp-backend:BPP.Backend.NET/BPP.Backend.NET.Sql/StageSql/2026-11-26_BRO-1_x.pre-deploy.sql'
run_cmd bash "$STATE" add-sql staging "$ID1"
assert_eq 0 "$RC" "add-sql staging -> 0"
bash "$STATE" add-sql staging "$ID1"
bash "$STATE" add-sql development 'bpp-backend:y.post-deploy.sql'
run_cmd bash "$STATE" get sql_applied
assert_eq "{\"development\":[\"bpp-backend:y.post-deploy.sql\"],\"staging\":[\"$ID1\"]}" "$OUT" "add-sql: per stage, no duplicates"
run_cmd bash "$STATE" add-sql main x
assert_eq 2 "$RC" "add-sql main -> 2"
run_cmd bash "$STATE" add-sql staging ''
assert_eq 2 "$RC" "add-sql empty id -> 2"
run_cmd bash "$STATE" has-sql staging "$ID1"
assert_eq 0 "$RC" "has-sql: recorded on staging -> 0"
run_cmd bash "$STATE" has-sql development "$ID1"
assert_eq 1 "$RC" "has-sql: not recorded on development -> 1"
run_cmd bash "$STATE" get bogus
assert_eq 2 "$RC" "get unknown key -> 2"

# a new run keeps the SQL list of a halted run, so a rerun never runs SQL twice
bash "$STATE" halt 'merge refused'
bash "$STATE" new run-51
assert_eq "{\"development\":[\"bpp-backend:y.post-deploy.sql\"],\"staging\":[\"$ID1\"]}" "$(jq -c .sql_applied "$SDIR/state.json")" "new after halt: sql_applied carried over"
assert_eq '{}' "$(jq -c .heads "$SDIR/state.json")" "new after halt: heads reset"
bash "$STATE" "done"
bash "$STATE" new run-52
assert_eq '{"development":[],"staging":[]}' "$(jq -c .sql_applied "$SDIR/state.json")" "new after done: sql_applied reset"

rm -f "$SDIR/state.json"
run_cmd bash "$STATE" get
assert_eq 3 "$RC" "get: no state file -> 3"

run_cmd bash "$STATE" bogus
assert_eq 2 "$RC" "unknown command -> 2"

# --- ping ---
run_cmd bash "$PING" blocker "Dev migrate failed" "DbMigrator exit 1"
assert_eq 0 "$RC" "ping: status 0"
assert_eq "===== HENRY PING (blocker) =====" "$(printf '%s\n' "$OUT" | head -n 1)" "ping: start delimiter first"
assert_eq "===== END HENRY PING =====" "$(printf '%s\n' "$OUT" | tail -n 1)" "ping: end delimiter last"
assert_contains "Dev migrate failed" "$OUT" "ping: title"
assert_contains "DbMigrator exit 1" "$OUT" "ping: body text"
assert_contains "TODO: post to Henry Teams channel" "$OUT" "ping: TODO line"

mkdir -p "$SDIR"
printf 'line one\nline two\n' > "$SDIR/body.txt"
run_cmd bash "$PING" info "Released" "$SDIR/body.txt"
assert_eq "===== HENRY PING (info) =====" "$(printf '%s\n' "$OUT" | head -n 1)" "ping file: start delimiter"
assert_contains "line two" "$OUT" "ping file: body read from a file in the state dir"

# files outside the state dir are never read
printf 'BPP_DB_STAGING=sekret-xyz\n' > "$HOME/.bpp-release.env"
run_cmd bash "$PING" blocker "oops" "$HOME/.bpp-release.env"
assert_not_contains "sekret-xyz" "$OUT$ERR" "ping file: file outside the state dir not printed"
run_cmd bash "$PING" blocker "oops" "$SDIR/../../../.bpp-release.env"
assert_not_contains "sekret-xyz" "$OUT$ERR" "ping file: .. path out of the state dir not printed"
ln -s "$HOME/.bpp-release.env" "$SDIR/link.txt"
run_cmd bash "$PING" blocker "oops" "$SDIR/link.txt"
assert_not_contains "sekret-xyz" "$OUT$ERR" "ping file: symlink in the state dir not followed"

run_cmd bash "$PING" urgent "x" "y"
assert_eq 2 "$RC" "ping: unknown severity -> 2"

finish
