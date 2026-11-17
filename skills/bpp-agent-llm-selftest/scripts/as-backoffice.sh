#!/usr/bin/env bash
# Runs the backoffice_c fixture cases: the developer GoUser is the only Codex-linked user, so its user_unternehmens_funktion is
# flipped to backoffice_mitarbeiter in the DEMO DB for the round, only in a quiet window (no foreign agent turn for 180 s), and
# restored by a trap. Nothing else may chat with the demo agent meanwhile.
# Usage: SELFTEST_ENV=<file> JAR=<jar> SELFTEST_RUN_ID=<run> bash as-backoffice.sh <cases.json> <out-dir> [ids...]
set -u
. "$(dirname "$0")/lib.sh"
: "${OWNER_GO_USER_ID:?set OWNER_GO_USER_ID}"
q=0; for _ in $(seq 1 120); do
  q=$(pgr -Atc "select coalesce(extract(epoch from now()-max(t.created_at))::int, 9999) from agent_turn t" | tail -1)
  [ "$q" -ge 180 ] && break; echo "$(date -u +%T) last agent turn ${q}s ago, waiting"; timeout 30 tail -f /dev/null
done
[ "$q" -ge 180 ] || { echo "NO QUIET WINDOW" >&2; exit 5; }
old=$(pgr -Atc "select user_unternehmens_funktion from go_users where id='$OWNER_GO_USER_ID'" | tail -1)
[ -n "$old" ] || { echo "owner $OWNER_GO_USER_ID not found" >&2; exit 6; }
restore() { pgw -Atc "update go_users set user_unternehmens_funktion='$old' where id='$OWNER_GO_USER_ID'" >/dev/null && echo "$(date -u +%T) restored $old"; }
trap restore EXIT
pgw -Atc "update go_users set user_unternehmens_funktion='backoffice_mitarbeiter' where id='$OWNER_GO_USER_ID'" >/dev/null
echo "$(date -u +%T) flipped to backoffice_mitarbeiter"
SELFTEST_OWNER=backoffice_c bash "$SCRIPTS/run-round.sh" "$@"
