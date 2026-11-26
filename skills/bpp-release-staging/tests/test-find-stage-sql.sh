#!/usr/bin/env bash
# Tests for lib/find-stage-sql.sh. Builds a throwaway git repo; no network, no DB.
# shellcheck disable=SC1090,SC1091,SC2016
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
LIB="$here/../lib/find-stage-sql.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"
REPO="$TMP/repo"
SQLDIR="BPP.Backend.NET/BPP.Backend.NET.Sql"

g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

# put <path> <content> - writes a file in the repo and stages it
put() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  g add -- "$1"
}

# base: staging branch, with a file that development later deletes
mkdir -p "$REPO"
g init -q -b staging
put "Other/old.sql" "UPDATE t SET a = 1;"
put "Old/fix.sql" "-- stages: staging
UPDATE t SET a = 5;"
put "$SQLDIR/StageSql/2026-11-20_BRO-5_old.post-deploy.sql" "-- stages: staging
UPDATE t SET a = 6;"
g commit -q -m base
g branch development
g checkout -q development

# changes on development
put "$SQLDIR/StageSql/2026-11-26_BRO-1_x.post-deploy.sql" "-- stages: development,staging
-- idempotent: yes
UPDATE t SET a = 2 WHERE a = 1;"
put "$SQLDIR/StageSql/2026-11-26_BRO-2_y.pre-deploy.sql" "-- stages: main
-- idempotent: yes
UPDATE t SET a = 3;"
put "$SQLDIR/StageSql/2026-11-26_BRO-3_z.pre-deploy.sql" "-- stages: staging
-- idempotent: no
UPDATE t SET a = 4;"
put "$SQLDIR/SeedSql/a.sql" "INSERT INTO t VALUES (1);"
put "$SQLDIR/CypressSql/c.sql" "INSERT INTO t VALUES (2);"
put "BPP.Backend.NET/Migrations/m.sql" "ALTER TABLE t ADD b int;"
put "$SQLDIR/InsertSql/i.sql" "INSERT INTO t VALUES (3);"
put "$SQLDIR/SyncSql/s.sql" "INSERT INTO t VALUES (4);"
put "Other/b.sql" "DELETE FROM t WHERE a = 9;"
g rm -q "Other/old.sql"
# moved file: git would report a rename, it must still count as added
g mv "Old/fix.sql" "$SQLDIR/StageSql/2026-11-26_BRO-9_fix.post-deploy.sql"
# already on staging, edited on development: not a convention entry again
put "$SQLDIR/StageSql/2026-11-20_BRO-5_old.post-deploy.sql" "-- stages: staging
UPDATE t SET a = 7;"
put "$SQLDIR/StageSql/2026-11-26_BRO-6_up.post-deploy.sql" "-- Stages: Staging
UPDATE t SET a = 8;"
put "$SQLDIR/StageSql/2026-11-26_BRO-7_nohead.post-deploy.sql" "UPDATE t SET a = 10;"
put "$SQLDIR/StageSql/2026-11-26_BRO-8_typo.post-deploy.sql" "-- stages: stagng
UPDATE t SET a = 11;"
g commit -q -m dev

# MR list as the workflow passes it
cat > "$TMP/mrs.json" <<'EOF'
[
  {"iid": 42, "project": "bpp-backend", "description": "Fix data.\n\n```sql\nUPDATE x SET y = 1;\n```\n\nand\n\n```bash\necho no\n```"},
  {"iid": 43, "project": "bpp-auth", "description": "No SQL here."},
  {"iid": 44, "project": "bpp-auth", "description": null},
  {"iid": 45, "project": "bpp-file", "description": "CRLF.\r\n\r\n```sql\r\nUPDATE c SET d = 1;\r\n```\r\n"},
  {"iid": 46, "project": "bpp-file", "description": "~~~sql\nUPDATE e SET f = 1;\n~~~\n\n```pgsql\nUPDATE g SET h = 1;\n```\n\n```postgresql\nUPDATE i SET j = 1;\n```"}
]
EOF

OUT=$(bash "$LIB" --repo "$REPO" --from staging --to development --stage staging --mr-json "$TMP/mrs.json" 2>"$TMP/err")
RC=$?
assert_eq 0 "$RC" "exit 0"
assert_contains "BRO-7_nohead" "$(cat "$TMP/err")" "missing stages header -> warning on stderr"
assert_contains "BRO-8_typo" "$(cat "$TMP/err")" "unknown stage name -> warning on stderr"
assert_not_contains "BRO-1_x" "$(cat "$TMP/err")" "no warning for a valid header"
assert_eq array "$(printf '%s' "$OUT" | jq -r type)" "output is a JSON array"

# q <jq filter> - runs a jq filter on the output
q() { printf '%s' "$OUT" | jq -c "$1"; }

conv=$(q '[.[] | select(.source == "convention")]')
assert_eq 4 "$(printf '%s' "$conv" | jq length)" "convention: only added files whose stages list staging"
x=$(q '.[] | select(.path | tostring | endswith("BRO-1_x.post-deploy.sql"))')
assert_eq convention "$(printf '%s' "$x" | jq -r .source)" "post-deploy file is a convention entry"
assert_eq post-deploy "$(printf '%s' "$x" | jq -r .timing)" "post-deploy timing"
assert_eq '["development","staging"]' "$(printf '%s' "$x" | jq -c .stages)" "stages parsed"
assert_eq true "$(printf '%s' "$x" | jq -r .idempotent)" "idempotent yes"
xf=$(printf '%s' "$x" | jq -r .sql_file)
assert_contains "UPDATE t SET a = 2" "$(cat "$xf" 2>/dev/null)" "convention sql_file holds the file content"
z=$(q '.[] | select(.path | tostring | endswith("BRO-3_z.pre-deploy.sql"))')
assert_eq pre-deploy "$(printf '%s' "$z" | jq -r .timing)" "pre-deploy timing kept, not post-deploy"
assert_eq false "$(printf '%s' "$z" | jq -r .idempotent)" "idempotent no"
assert_eq "" "$(q '.[] | select(.path | tostring | contains("BRO-2"))')" "stages: main only -> no entry"
assert_eq "" "$(q '.[] | select(.path | tostring | test("SeedSql|CypressSql|InsertSql|SyncSql|Migrations"))')" "excluded folders -> no entry"
assert_eq "" "$(q '.[] | select(.path == "Other/old.sql")')" "deleted file -> no entry"

mv9=$(q '.[] | select(.path | tostring | endswith("BRO-9_fix.post-deploy.sql"))')
assert_eq convention "$(printf '%s' "$mv9" | jq -r .source)" "moved file -> convention entry"
assert_contains "UPDATE t SET a = 5" "$(cat "$(printf '%s' "$mv9" | jq -r .sql_file)" 2>/dev/null)" "moved file sql_file content"
assert_eq "" "$(q '.[] | select(.path == "Old/fix.sql")')" "old path of a moved file -> no entry"
o5=$(q '.[] | select(.path | tostring | contains("BRO-5"))')
assert_eq diff "$(printf '%s' "$o5" | jq -r .source)" "StageSql file edited after staging -> diff entry, not convention"
u6=$(q '.[] | select(.path | tostring | contains("BRO-6"))')
assert_eq convention "$(printf '%s' "$u6" | jq -r .source)" "upper-case stages header -> convention entry"
assert_eq '["staging"]' "$(printf '%s' "$u6" | jq -c .stages)" "stage names lower-cased"
assert_eq diff "$(q '.[] | select(.path | tostring | contains("BRO-7")) | .source' | tr -d '"')" "no stages header -> diff entry"
assert_eq diff "$(q '.[] | select(.path | tostring | contains("BRO-8")) | .source' | tr -d '"')" "unknown stage name -> diff entry"

b=$(q '.[] | select(.path == "Other/b.sql")')
assert_eq diff "$(printf '%s' "$b" | jq -r .source)" "other .sql file -> diff entry"
assert_eq unknown "$(printf '%s' "$b" | jq -r .timing)" "diff entry timing unknown"

mr=$(q '[.[] | select(.source == "mr-description")]')
assert_eq 5 "$(printf '%s' "$mr" | jq length)" "sql blocks from MR descriptions (sql, CRLF, ~~~sql, pgsql, postgresql)"
assert_eq 'bpp-backend!42' "$(printf '%s' "$mr" | jq -r '.[0].mr')" "mr reference"
assert_eq unknown "$(printf '%s' "$mr" | jq -r '.[0].timing')" "mr timing unknown"
mf=$(printf '%s' "$mr" | jq -r '.[0].sql_file')
assert_eq "UPDATE x SET y = 1;" "$(cat "$mf" 2>/dev/null)" "mr sql_file holds only the sql block"
cr=$(printf '%s' "$mr" | jq -r '.[] | select(.mr == "bpp-file!45") | .sql_file')
assert_eq "UPDATE c SET d = 1;" "$(cat "$cr" 2>/dev/null)" "CRLF description -> block found, no CR kept"
assert_eq 3 "$(printf '%s' "$mr" | jq '[.[] | select(.mr == "bpp-file!46")] | length')" "~~~sql, pgsql and postgresql fences found"
t46=$(for f in $(printf '%s' "$mr" | jq -r '.[] | select(.mr == "bpp-file!46") | .sql_file'); do cat "$f"; done)
assert_contains "UPDATE e SET f = 1;" "$t46" "~~~sql block content"
assert_contains "UPDATE i SET j = 1;" "$t46" "postgresql block content"

# no --mr-json -> no mr-description entries; staging stage of a stage with nothing new
OUT=$(bash "$LIB" --repo "$REPO" --from staging --to development --stage staging 2>/dev/null)
assert_eq 0 "$(q '[.[] | select(.source == "mr-description")] | length')" "no --mr-json -> no mr entries"
OUT=$(bash "$LIB" --repo "$REPO" --from development --to development --stage staging 2>/dev/null)
assert_eq '[]' "$(q '.')" "no changes -> empty array"

# bad input
assert_status 2 bash "$LIB" --repo "$REPO" --from staging --to development
assert_status 2 bash "$LIB" --repo "$REPO" --from staging --to development --stage prod
assert_status 3 bash "$LIB" --repo "$REPO" --from staging --to nope --stage staging

finish
