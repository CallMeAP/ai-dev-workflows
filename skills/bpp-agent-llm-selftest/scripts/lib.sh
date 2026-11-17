#!/usr/bin/env bash
# Shared helpers: loads $SELFTEST_ENV, refuses the normal stack and the real DB, psql against the demo DB, the Codex quota guard,
# the login. Source it: . "$(dirname "$0")/lib.sh". Prints no secret.
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$SKILL_DIR/scripts
: "${SELFTEST_ENV:?set SELFTEST_ENV to your selftest.env (copy of selftest.env.example)}"
[ -f "$SELFTEST_ENV" ] || { echo "REFUSING: $SELFTEST_ENV not found" >&2; exit 6; }
# shellcheck disable=SC1090
. "$SELFTEST_ENV"

# Allow-lists, not deny-lists: a demo copy on this machine and demo-stack URLs on localhost only.
case "${DEMO_DB:-}" in bpp_agent_demo_train) echo "REFUSING: bpp_agent_demo_train belongs to the train sessions" >&2; exit 6 ;; bpp_agent_demo_?*) ;; *) echo "REFUSING: DEMO_DB '${DEMO_DB:-}' is not a bpp_agent_demo_* copy" >&2; exit 6 ;; esac
case "${PGHOST:-}" in localhost|127.0.0.1|::1) ;; *) echo "REFUSING: PGHOST '${PGHOST:-}' is not local" >&2; exit 6 ;; esac
for v in AUTH_URL BACKEND_URL CONNECTOR_URL AGENT_URL COCKPIT_URL RABBIT_MGMT_URL; do
  case "${!v:-}" in http://localhost:52[0-9][0-9]*|http://127.0.0.1:52[0-9][0-9]*) echo "REFUSING: $v=${!v} points at the normal stack" >&2; exit 6 ;;
    http://localhost:[0-9]*|http://127.0.0.1:[0-9]*) ;; *) echo "REFUSING: $v='${!v:-}' is not a local demo URL" >&2; exit 6 ;; esac
done
MAX_PRIMARY_PCT=${MAX_PRIMARY_PCT:-95}; MAX_SECONDARY_PCT=${MAX_SECONDARY_PCT:-95}

pg_password() { [ -s "$PG_PASSWORD_FILE" ] || { echo "REFUSING: PG_PASSWORD_FILE empty or missing" >&2; return 6; }; cat "$PG_PASSWORD_FILE"; }
# psql against the demo DB. Reads go through pgr (read-only transaction); pgw is for the few documented demo-DB writes.
pgw() { PGPASSWORD=$(pg_password) psql -X -q -h "$PGHOST" -p "$PGPORT" -U "$PG_USER" -d "$DEMO_DB" -v ON_ERROR_STOP=1 "$@"; }
pgr() { PGOPTIONS='-c default_transaction_read_only=on' pgw "$@"; }

port_of() { local u=${1#*://}; u=${u%%/*}; echo "${u##*:}"; }
listener_pid() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; }

# "primary secondary age_s" from the newest Codex rollout (read-only; codex-usage.sh --refresh makes one tiny codex call)
quota() { bash "$SCRIPTS/codex-usage.sh" "$@"; }
# exit 3 when a live LLM call would cross the stop; 'None' (no snapshot) counts as unknown, not as a pass. Agent traffic does not
# refresh the snapshot, so a snapshot older than 15 min is refreshed with one tiny codex call first (as the live waves did).
# Never called by preflight.sh, which stays free of LLM calls.
quota_guard() {
  local p s age; read -r p s age < <(quota)
  [ "${age:-999999}" -gt 900 ] && read -r p s age < <(quota --refresh)
  echo "$(date -u +%FT%TZ) codex 5h=${p}% week=${s}% snapshot_age=${age}s"
  case "$p$s" in *None*|"") echo "QUOTA UNKNOWN: no rate_limits in the newest rollout; refresh with codex-usage.sh --refresh" >&2; return 3 ;; esac
  if [ "${p%.*}" -ge "$MAX_PRIMARY_PCT" ] || [ "${s%.*}" -ge "$MAX_SECONDARY_PCT" ]; then echo "QUOTA STOP"; return 3; fi
}

# refuse a global switch (agent restart/build swap) while the 13 h latency resumes are pending
no_latency_timers() {
  if systemctl --user list-timers 'selftest-latency-*' --no-legend 2>/dev/null | grep -q .; then
    echo "REFUSING: selftest-latency-* timers are pending (the resumes need this agent unchanged)" >&2; return 6; fi
}
# Codex link of the logged-in user (jar): 0 = linked and no relink required
codex_linked() {
  local st; st=$(curl -s --max-time 5 -b "$1" "$AGENT_URL/api/codex-auth/status")
  [ "$(jq -r '.linked' <<<"$st" 2>/dev/null)" = true ] && [ "$(jq -r '.relinkRequired // false' <<<"$st")" != true ]
}

login_password() {
  if [ -n "${SELFTEST_LOGIN_PASSWORD_FILE:-}" ]; then cat "$SELFTEST_LOGIN_PASSWORD_FILE"; else printf '%s' 'Start123$'; fi
}
# login <jar>: cookie jar for the demo auth; never prints the cookie
login() {
  : "${SELFTEST_LOGIN_EMAIL:?set SELFTEST_LOGIN_EMAIL in your selftest.env}"
  # body via stdin: the password never shows up in a process argv
  local code; code=$(jq -nc --arg e "$SELFTEST_LOGIN_EMAIL" --rawfile p <(login_password) '{loginEmail:$e,password:($p|rtrimstr("\n"))}' \
    | curl -s -o /dev/null -w '%{http_code}' -c "$1" -H 'content-type: application/json' --data-binary @- "$AUTH_URL/api/auth-go-user/login")
  chmod 600 "$1" 2>/dev/null
  [ "$code" = 200 ] || { echo "login failed: HTTP $code" >&2; return 1; }
}
