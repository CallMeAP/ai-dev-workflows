#!/usr/bin/env bash
# run-stage-sql.sh [--readonly] <development|staging> (<file.sql> | --check | --query 'SQL')
# Runs SQL against a stage DB with psql. The Npgsql connection string from get_secret is turned
# into PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD inside this process only; all output goes
# through redact_stream. No main stage.
#   <file.sql>  psql -X -v ON_ERROR_STOP=1 -1 -f <file> (one transaction); refused (exit 6) when
#               the file has its own transaction lines (BEGIN;, COMMIT, ROLLBACK, START TRANSACTION)
#   --check     prints "connection OK, <n> migrations applied" (always read-only)
#   --query SQL runs one SQL string with psql -c
#   --readonly  sets PGOPTIONS='-c default_transaction_read_only=on'
# Exit: psql's exit; 1 bad file or args; 2 unknown stage; 3-5 from get_secret; 6 file has
#       transaction lines.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/secret-env.sh
. "$here/secret-env.sh"
# shellcheck source=SCRIPTDIR/redact.sh
. "$here/redact.sh"

usage() {
  echo "usage: run-stage-sql.sh [--readonly] <development|staging> (<file.sql> | --check | --query 'SQL')" >&2
  exit 1
}

readonly_mode=no
if [ "${1:-}" = --readonly ]; then
  readonly_mode=yes
  shift
fi

stage=${1:-}
case "$stage" in
  development|staging) ;;
  *)
    printf 'run-stage-sql: unknown stage "%s" (allowed: development, staging)\n' "$stage" >&2
    exit 2
    ;;
esac
shift

action=''
file=''
query=''
case "${1:-}" in
  '') usage ;;
  --check) action=check; [ $# -eq 1 ] || usage ;;
  --query) action=query; [ $# -eq 2 ] || usage; query=$2 ;;
  -*) usage ;;
  *) action='file'; [ $# -eq 1 ] || usage; file=$1 ;;
esac

if [ "$action" = file ]; then
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'run-stage-sql: file not found or not readable: %s\n' "$file" >&2
    exit 1
  fi
  # psql -1 wraps the file in one transaction; own transaction lines would break that.
  # A plain "BEGIN" line (plpgsql block in DO $$ ... $$) is allowed.
  if grep -Eiq '^[[:space:]]*((COMMIT|ROLLBACK|ABORT)([[:space:];]|$)|START[[:space:]]+TRANSACTION|BEGIN([[:space:]]*;|[[:space:]]+(TRANSACTION|WORK|ISOLATION|READ|DEFERRABLE|NOT)))' "$file"; then
    printf 'run-stage-sql: %s has its own BEGIN/COMMIT/ROLLBACK lines; remove them (the wrapper runs the file in one transaction)\n' "$file" >&2
    exit 6
  fi
fi

conn=$(get_secret "$stage") || exit $?

# Clear libpq vars from the caller so only the stage's values count.
unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE \
  PGSSLMODE PGOPTIONS PGCONNECT_TIMEOUT

# Npgsql "Key=Value;..." to libpq env vars. Values with ";" inside quotes are not supported.
rest=$conn
while [ -n "$rest" ]; do
  part=${rest%%;*}
  if [ "$part" = "$rest" ]; then rest=''; else rest=${rest#*;}; fi
  case "$part" in *=*) ;; *) continue ;; esac
  key=$(printf '%s' "${part%%=*}" | tr -d ' \t' | tr '[:upper:]' '[:lower:]')
  value=${part#*=}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  case "$key" in
    host|server) export PGHOST="$value" ;;
    port) export PGPORT="$value" ;;
    database|db) export PGDATABASE="$value" ;;
    username|userid|user) export PGUSER="$value" ;;
    password|pwd) export PGPASSWORD="$value" ;;
    sslmode)
      case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        verifyfull) export PGSSLMODE=verify-full ;;
        verifyca) export PGSSLMODE=verify-ca ;;
        *) PGSSLMODE=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]'); export PGSSLMODE ;;
      esac
      ;;
    timeout) export PGCONNECT_TIMEOUT="$value" ;;
  esac
done
if [ -z "${PGHOST:-}" ] || [ -z "${PGDATABASE:-}" ] || [ -z "${PGUSER:-}" ]; then
  printf 'run-stage-sql: connection string for %s lacks Host, Database or Username\n' "$stage" >&2
  exit 1
fi
export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-15}
export PGAPPNAME=bpp-release
export PGPASSFILE=/dev/null

if [ "$readonly_mode" = yes ] || [ "$action" = check ]; then
  export PGOPTIONS='-c default_transaction_read_only=on'
fi

case "$action" in
  check)
    out=$(psql -X -v ON_ERROR_STOP=1 -A -t -c 'SELECT count(*) FROM "__EFMigrationsHistory"' 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out" | redact_stream "$conn" >&2
      exit "$rc"
    fi
    n=$(printf '%s' "$out" | tr -d ' \t\r\n')
    case "$n" in
      ''|*[!0-9]*)
        echo 'run-stage-sql: unexpected answer from the migrations count' >&2
        exit 1
        ;;
    esac
    printf 'connection OK, %s migrations applied\n' "$n"
    exit 0
    ;;
  query)
    if [ "$readonly_mode" = yes ]; then
      psql -X -v ON_ERROR_STOP=1 -c "$query" 2>&1 | redact_stream "$conn"
    else
      psql -X -v ON_ERROR_STOP=1 -1 -c "$query" 2>&1 | redact_stream "$conn"
    fi
    exit "${PIPESTATUS[0]}"
    ;;
  file)
    psql -X -v ON_ERROR_STOP=1 -1 -f "$file" 2>&1 | redact_stream "$conn"
    exit "${PIPESTATUS[0]}"
    ;;
esac
