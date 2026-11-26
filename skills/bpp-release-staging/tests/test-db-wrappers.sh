#!/usr/bin/env bash
# Tests for lib/redact.sh, lib/migrate-stage.sh, lib/run-stage-sql.sh.
# Uses a temp HOME, a fixture env file and stub dotnet/psql on PATH; never reads a real secret.
# shellcheck disable=SC1090,SC1091,SC2016
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
LIBDIR="$here/../lib"
MIGRATE="$LIBDIR/migrate-stage.sh"
RUNSQL="$LIBDIR/run-stage-sql.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/sql"
export BPP_RELEASE_SECRETS=envfile
unset BPP_RELEASE_ENV_FILE PGOPTIONS PGPASSWORD PGHOST PGUSER PGDATABASE PGPORT
PW='Zq7SecretPw'
CONN_STG="Host=stg.db.example;Port=5433;Database=bpp_stg;Username=bpp_rel;Password=$PW;SSL Mode=Require"
CONN_DEV="Server=dev.db.example;Database=bpp_dev;User Id=bpp_dev;Pwd=$PW"
printf 'BPP_DB_STAGING="%s"\nBPP_DB_DEVELOPMENT="%s"\n' "$CONN_STG" "$CONN_DEV" > "$HOME/.bpp-release.env"
chmod 600 "$HOME/.bpp-release.env"

# Stubs log argv and the env they see to files under $TMP/log.
mkdir -p "$TMP/log"
export STUB_LOG="$TMP/log" STUB_ALL="$TMP/all.argv"
cat > "$TMP/bin/dotnet" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/dotnet.argv"
printf '%s\n' "$*" >> "$STUB_ALL"
printf 'env=%s\n' "${ASPNETCORE_ENVIRONMENT:-}" >> "$STUB_LOG/dotnet.env"
echo "Applying pending EF Core migrations..."
echo "conn=${ConnectionStrings__DefaultConnection:-<unset>}"
echo "error: Npgsql failed for ${ConnectionStrings__DefaultConnection:-<unset>}" >&2
exit "${DOTNET_STUB_RC:-0}"
STUB
cat > "$TMP/bin/psql" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/psql.argv"
printf '%s\n' "$*" >> "$STUB_ALL"
{
  printf 'PGHOST=%s\n' "${PGHOST:-}"
  printf 'PGPORT=%s\n' "${PGPORT:-}"
  printf 'PGDATABASE=%s\n' "${PGDATABASE:-}"
  printf 'PGUSER=%s\n' "${PGUSER:-}"
  printf 'PGSSLMODE=%s\n' "${PGSSLMODE:-}"
  printf 'PGOPTIONS=%s\n' "${PGOPTIONS:-}"
} > "$STUB_LOG/psql.env"
case "$*" in
  *__EFMigrationsHistory*) echo 42; exit 0 ;;
esac
echo "psql: password PGPASSWORD=${PGPASSWORD:-} rejected"
echo "FATAL: password authentication failed (password ${PGPASSWORD:-})" >&2
exit "${PSQL_STUB_RC:-2}"
STUB
chmod +x "$TMP/bin/dotnet" "$TMP/bin/psql"
export PATH="$TMP/bin:$PATH"

# shared dir layout the migrator wrapper expects
SHARED="$TMP/bpp-shared"
mkdir -p "$SHARED/BPP.Shared.NET/BPP.Shared.NET.DbMigrator"

reset_logs() { rm -f "$STUB_LOG"/*; }

# run_cap <cmd...> - sets OUT (stdout+stderr) and RC
run_cap() {
  OUT=$("$@" 2>&1)
  RC=$?
}

# ---- redact_stream
. "$LIBDIR/redact.sh"
R=$(printf 'a %s b\nx Password=%s; y\nPGPASSWORD=%s\nlast %s' "$CONN_STG" "$PW" "$PW" "$PW" | redact_stream "$CONN_STG")
assert_not_contains "$PW" "$R" "redact: password removed everywhere"
assert_contains 'a *** b' "$R" "redact: whole connection string replaced"
assert_contains 'last ***' "$R" "redact: last line without newline kept and redacted"
assert_eq 4 "$(printf '%s\n' "$R" | wc -l | tr -d ' ')" "redact: line count kept"
R=$(printf 'pwd here: %s\n' "$PW" | redact_stream "$CONN_DEV")
assert_eq 'pwd here: ***' "$R" "redact: Pwd= key recognised"
R=$(printf 'plain line\n' | redact_stream "Host=h;Database=d")
assert_eq 'plain line' "$R" "redact: no password in conn string, text unchanged"

# ---- migrate-stage.sh
reset_logs
run_cap bash "$MIGRATE" staging --shared-dir "$SHARED"
assert_eq 0 "$RC" "migrate staging: exit 0"
assert_not_contains "$PW" "$OUT" "migrate staging: output has no password"
assert_contains '***' "$OUT" "migrate staging: output redacted with ***"
assert_contains 'Applying pending EF Core migrations' "$OUT" "migrate staging: dotnet output passed through"
assert_eq "run --no-launch-profile --project $SHARED/BPP.Shared.NET/BPP.Shared.NET.DbMigrator" "$(cat "$STUB_LOG/dotnet.argv")" "migrate staging: dotnet argv"
assert_not_contains "$PW" "$(cat "$STUB_LOG/dotnet.argv")" "migrate staging: password not in dotnet argv"

reset_logs
( ASPNETCORE_ENVIRONMENT=Development; export ASPNETCORE_ENVIRONMENT; bash "$MIGRATE" development --shared-dir "$SHARED" ) >/dev/null 2>&1
assert_eq 'env=' "$(cat "$STUB_LOG/dotnet.env")" "migrate development: ASPNETCORE_ENVIRONMENT cleared (else appsettings.<env>.json wins)"

reset_logs
run_cap env DOTNET_STUB_RC=3 bash "$MIGRATE" staging --shared-dir "$SHARED"
assert_eq 3 "$RC" "migrate: exit is dotnet's exit"
assert_not_contains "$PW" "$OUT" "migrate failing: output has no password"

reset_logs
run_cap bash "$MIGRATE" main --shared-dir "$SHARED"
assert_eq 2 "$RC" "migrate main: exit 2"
assert_eq no "$( [ -e "$STUB_LOG/dotnet.argv" ] && echo yes || echo no)" "migrate main: dotnet not called"
run_cap bash "$MIGRATE" prod
assert_eq 2 "$RC" "migrate prod: exit 2"
run_cap bash "$MIGRATE"
assert_eq 2 "$RC" "migrate without stage: exit 2"

reset_logs
( ConnectionStrings__DefaultConnection=leak; export ConnectionStrings__DefaultConnection
  BPP_RELEASE_ENV_FILE="$TMP/none.env"; export BPP_RELEASE_ENV_FILE
  bash "$MIGRATE" local --shared-dir "$SHARED" ) > "$TMP/out" 2>&1
RC=$?
assert_eq 0 "$RC" "migrate local: exit 0 without any secret"
assert_contains 'conn=<unset>' "$(cat "$TMP/out")" "migrate local: no connection string passed"

reset_logs
run_cap env BPP_RELEASE_ENV_FILE="$TMP/none.env" bash "$MIGRATE" staging --shared-dir "$SHARED"
assert_eq 3 "$RC" "migrate staging, secret missing: exit 3"
assert_eq no "$( [ -e "$STUB_LOG/dotnet.argv" ] && echo yes || echo no)" "migrate staging, secret missing: dotnet not called"

run_cap bash "$MIGRATE" staging --shared-dir "$TMP/nope"
assert_eq 1 "$RC" "migrate: missing migrator project gives exit 1"

# ---- run-stage-sql.sh
printf 'UPDATE ui_configs SET x = 1 WHERE app = %s;\n' "'cockpit'" > "$TMP/sql/ok.sql"
printf 'BEGIN;\nUPDATE t SET x = 1;\nCOMMIT;\n' > "$TMP/sql/with-begin.sql"
printf 'UPDATE t SET x = 1;\n  commit;\n' > "$TMP/sql/with-commit.sql"
printf 'DO $$\nBEGIN\n  IF NOT EXISTS (SELECT 1) THEN\n    UPDATE t SET committed = true;\n  END IF;\nEND $$;\n' > "$TMP/sql/do-block.sql"

reset_logs
run_cap bash "$RUNSQL" staging "$TMP/sql/ok.sql"
assert_eq 2 "$RC" "run-sql: psql failure exit passed through"
assert_not_contains "$PW" "$OUT" "run-sql failing: output has no password"
assert_contains '***' "$OUT" "run-sql failing: password replaced by ***"
assert_eq "-X -v ON_ERROR_STOP=1 -1 -f $TMP/sql/ok.sql" "$(cat "$STUB_LOG/psql.argv")" "run-sql write: psql argv"
assert_contains 'PGHOST=stg.db.example' "$(cat "$STUB_LOG/psql.env")" "run-sql: PGHOST from Host"
assert_contains 'PGPORT=5433' "$(cat "$STUB_LOG/psql.env")" "run-sql: PGPORT from Port"
assert_contains 'PGDATABASE=bpp_stg' "$(cat "$STUB_LOG/psql.env")" "run-sql: PGDATABASE from Database"
assert_contains 'PGUSER=bpp_rel' "$(cat "$STUB_LOG/psql.env")" "run-sql: PGUSER from Username"
assert_contains 'PGSSLMODE=require' "$(cat "$STUB_LOG/psql.env")" "run-sql: PGSSLMODE from SSL Mode"
assert_contains 'PGOPTIONS=' "$(cat "$STUB_LOG/psql.env")" "run-sql write: stub ran"
assert_not_contains 'read_only' "$(cat "$STUB_LOG/psql.env")" "run-sql write: not read-only"

reset_logs
run_cap env PGOPTIONS='-c default_transaction_read_only=on' bash "$RUNSQL" development "$TMP/sql/ok.sql"
assert_not_contains 'read_only' "$(cat "$STUB_LOG/psql.env")" "run-sql write: inherited PGOPTIONS dropped"
assert_contains 'PGHOST=dev.db.example' "$(cat "$STUB_LOG/psql.env")" "run-sql dev: PGHOST from Server"
assert_contains 'PGUSER=bpp_dev' "$(cat "$STUB_LOG/psql.env")" "run-sql dev: PGUSER from User Id"
assert_not_contains "$PW" "$OUT" "run-sql dev: output has no password (Pwd key)"

reset_logs
run_cap bash "$RUNSQL" --readonly staging --query 'SELECT 1'
assert_contains 'PGOPTIONS=-c default_transaction_read_only=on' "$(cat "$STUB_LOG/psql.env")" "run-sql --readonly: PGOPTIONS read-only"
assert_eq '-X -v ON_ERROR_STOP=1 -c SELECT 1' "$(cat "$STUB_LOG/psql.argv")" "run-sql --query readonly: psql argv"

reset_logs
run_cap bash "$RUNSQL" staging --check
assert_eq 0 "$RC" "run-sql --check: exit 0"
assert_eq 'connection OK, 42 migrations applied' "$OUT" "run-sql --check: message"
assert_contains 'PGOPTIONS=-c default_transaction_read_only=on' "$(cat "$STUB_LOG/psql.env")" "run-sql --check: always read-only"

reset_logs
run_cap bash "$RUNSQL" staging "$TMP/sql/with-begin.sql"
assert_eq 6 "$RC" "run-sql: file with BEGIN/COMMIT refused with exit 6"
assert_eq no "$( [ -e "$STUB_LOG/psql.argv" ] && echo yes || echo no)" "run-sql BEGIN file: psql not called"
run_cap bash "$RUNSQL" staging "$TMP/sql/with-commit.sql"
assert_eq 6 "$RC" "run-sql: file with lower-case commit refused with exit 6"

reset_logs
run_cap env PSQL_STUB_RC=0 bash "$RUNSQL" staging "$TMP/sql/do-block.sql"
assert_eq 0 "$RC" "run-sql: DO block with plpgsql BEGIN/END accepted"

reset_logs
run_cap bash "$RUNSQL" main "$TMP/sql/ok.sql"
assert_eq 2 "$RC" "run-sql main: exit 2"
run_cap bash "$RUNSQL" --readonly main --check
assert_eq 2 "$RC" "run-sql --readonly main: exit 2"
assert_eq no "$( [ -e "$STUB_LOG/psql.argv" ] && echo yes || echo no)" "run-sql main: psql not called"
run_cap bash "$RUNSQL" staging "$TMP/sql/missing.sql"
assert_eq 1 "$RC" "run-sql: missing file exit 1"
run_cap bash "$RUNSQL" staging
assert_eq 1 "$RC" "run-sql: no action exit 1"

reset_logs
run_cap env BPP_RELEASE_ENV_FILE="$TMP/none.env" bash "$RUNSQL" staging --check
assert_eq 3 "$RC" "run-sql, secret missing: exit 3"
assert_eq no "$( [ -e "$STUB_LOG/psql.argv" ] && echo yes || echo no)" "run-sql, secret missing: psql not called"

# argv of every stub call over the whole test never held the password
assert_eq yes "$( [ -s "$STUB_ALL" ] && echo yes || echo no)" "stubs: argv log written"
assert_not_contains "$PW" "$(cat "$STUB_ALL")" "stubs: password never in argv"

finish
