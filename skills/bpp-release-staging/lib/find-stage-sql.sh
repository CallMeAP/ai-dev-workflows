#!/usr/bin/env bash
# Lists SQL that a promotion may need, as a JSON array on stdout. Read-only: runs nothing.
# Usage: find-stage-sql.sh --repo <dir> --from <ref> --to <ref> --stage <development|staging|main> [--mr-json FILE]
# Entry: {source: convention|diff|mr-description, path|mr, timing, stages, idempotent, sql_file}
# Each sql_file is a temp copy of the SQL (git files taken at --to), so the caller runs what was listed.
# The copies live in one temp dir (dirname of any sql_file) that this script keeps; the caller removes it.
# Convention entries come only from files added on --to (moves count as added). StageSql files that were
# edited, or that lack a valid stages header, come out as diff entries; the bad header is warned on stderr.
# Exit: 0 ok, 2 bad arguments, 3 git or jq error.
set -u

repo='' from='' to='' stage='' mrjson=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2-}; shift 2 || exit 2 ;;
    --from) from=${2-}; shift 2 || exit 2 ;;
    --to) to=${2-}; shift 2 || exit 2 ;;
    --stage) stage=${2-}; shift 2 || exit 2 ;;
    --mr-json) mrjson=${2-}; shift 2 || exit 2 ;;
    *) echo "find-stage-sql: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$stage" in development|staging|main) ;; *) echo "find-stage-sql: --stage must be development, staging or main" >&2; exit 2 ;; esac
if [ -z "$repo" ] || [ -z "$from" ] || [ -z "$to" ]; then
  echo "find-stage-sql: --repo, --from and --to are required" >&2
  exit 2
fi
if [ -n "$mrjson" ] && [ ! -r "$mrjson" ]; then
  echo "find-stage-sql: cannot read $mrjson" >&2
  exit 2
fi

out=$(mktemp -d "${TMPDIR:-/tmp}/bpp-stage-sql.XXXXXX") || exit 3
entries="$out/entries.jsonl"
: > "$entries"
n=0

# header_stages <file> - prints the stages from "-- stages: a,b" as a JSON array
header_stages() {
  awk 'tolower($0) ~ /^--[ \t]*stages:/ { sub(/^[^:]*:/, ""); print; exit }' "$1" |
    tr ',' '\n' | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | grep -v '^$' | jq -R . | jq -s -c .
}

# header_idempotent <file> - prints true when "-- idempotent: yes" is there
header_idempotent() {
  if grep -iq '^--[[:space:]]*idempotent:[[:space:]]*yes' "$1"; then echo true; else echo false; fi
}

# timing_of <name>
timing_of() {
  case "$1" in
    *.pre-deploy.sql) echo pre-deploy ;;
    *.post-deploy.sql) echo post-deploy ;;
    *) echo unknown ;;
  esac
}

# add <source> <key> <value> <timing> <sql_file>
add() {
  jq -n -c --arg source "$1" --arg key "$2" --arg val "$3" --arg timing "$4" --arg f "$5" \
    --argjson stages "$(header_stages "$5")" --argjson idem "$(header_idempotent "$5")" \
    '{source: $source, ($key): $val, timing: $timing, stages: $stages, idempotent: $idem, sql_file: $f}' \
    >> "$entries" || exit 3
}

# Files added or changed on --to since the merge base; deleted files are left out.
# --no-renames: a moved file shows as added (A) instead of a rename (R) that the filter would drop.
names="$out/names"
if ! git -C "$repo" diff -z --no-renames --name-status --diff-filter=AM "$from...$to" -- '*.sql' > "$names" 2>/dev/null; then
  echo "find-stage-sql: git diff $from...$to failed in $repo" >&2
  exit 3
fi
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  case "/$path" in
    */CypressSql/*|*/SeedSql/*|*/InsertSql/*|*/SyncSql/*|*/Migrations/*) continue ;;
  esac
  n=$((n + 1))
  f="$out/$n.sql"
  git -C "$repo" show "$to:$path" > "$f" 2>/dev/null || exit 3
  base=$(basename "$path")
  case "/$path" in
    */StageSql/*)
      timing=$(timing_of "$base")
      stages=$(header_stages "$f")
      if [ "$status" = A ] && [ "$timing" != unknown ]; then
        if ! printf '%s' "$stages" | jq -e 'length > 0 and all(.[]; . == "development" or . == "staging" or . == "main")' >/dev/null; then
          echo "find-stage-sql: $path: missing or unknown stages header, listed as diff" >&2
        elif printf '%s' "$stages" | jq -e --arg s "$stage" 'index($s) != null' >/dev/null; then
          # Convention file: listed only when its stages header names this stage.
          add convention path "$path" "$timing" "$f"
          continue
        else
          continue
        fi
      fi
      ;;
  esac
  add diff path "$path" "$(timing_of "$base")" "$f"
done < "$names"

# SQL blocks in merged MR descriptions: ``` or ~~~ fences tagged sql, psql, pgsql, postgres or postgresql.
if [ -n "$mrjson" ]; then
  count=$(jq 'length' "$mrjson") || exit 3
  i=0
  while [ "$i" -lt "$count" ]; do
    ref=$(jq -r --argjson i "$i" '.[$i] | "\(.project)!\(.iid)"' "$mrjson") || exit 3
    # tr: descriptions from a web form can have CRLF line ends
    jq -r --argjson i "$i" '.[$i].description // ""' "$mrjson" | tr -d '\r' > "$out/desc" || exit 3
    prefix="$out/mr-$i-"
    awk -v p="$prefix" '
      inb && index($0, fence) && $0 ~ /^[ \t]*(```|~~~)[ \t]*$/ { inb = 0; close(f); next }
      inb { print > f; next }
      tolower($0) ~ /^[ \t]*(```|~~~)[ \t]*(sql|psql|pgsql|postgres|postgresql)[ \t]*$/ {
        fence = index($0, "~~~") ? "~~~" : "```"; b++; f = p b ".sql"; printf "" > f; inb = 1
      }
    ' "$out/desc"
    for f in "$prefix"*.sql; do
      [ -e "$f" ] || continue
      add mr-description mr "$ref" unknown "$f"
    done
    i=$((i + 1))
  done
fi

jq -s -c . "$entries" || exit 3
