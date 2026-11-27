#!/usr/bin/env bash
# migrate-stage.sh <local|development|staging> [--db bpp|document-analysis] [--shared-dir DIR] [--repo-dir DIR]
# Runs a DbMigrator (applies all pending EF migrations) against one stage.
#   --db bpp (default)       the bpp-shared DbMigrator in --shared-dir, against the bpp database
#   --db document-analysis   the bpp-document-analysis DbMigrator in --repo-dir, against the
#                            bpp_document_analysis database (its own Postgres, its own secret)
# local uses the migrator's own appsettings.json (local DB, no secret).
# development/staging: the connection string comes from get_secret and is set only for the
# dotnet process; all output goes through redact_stream. No main stage.
# Exit: dotnet's exit; 2 unknown stage, database or bad args; 1 migrator project missing;
#       3-5 from get_secret.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/secret-env.sh
. "$here/secret-env.sh"
# shellcheck source=SCRIPTDIR/redact.sh
. "$here/redact.sh"

stage=${1:-}
case "$stage" in
  local|development|staging) ;;
  *)
    printf 'migrate-stage: unknown stage "%s" (allowed: local, development, staging)\n' "$stage" >&2
    exit 2
    ;;
esac
shift

db=bpp
shared_dir=$HOME/Entwicklung/bpp/bpp-shared
repo_dir=$HOME/Entwicklung/bpp/bpp-document-analysis
while [ $# -gt 0 ]; do
  case "$1" in
    --db)
      [ $# -ge 2 ] || { echo 'migrate-stage: --db needs bpp or document-analysis' >&2; exit 2; }
      db=$2
      shift 2
      ;;
    --repo-dir)
      [ $# -ge 2 ] || { echo 'migrate-stage: --repo-dir needs a directory' >&2; exit 2; }
      repo_dir=$2
      shift 2
      ;;
    --shared-dir)
      [ $# -ge 2 ] || { echo 'migrate-stage: --shared-dir needs a directory' >&2; exit 2; }
      shared_dir=$2
      shift 2
      ;;
    *)
      printf 'migrate-stage: unknown argument "%s"\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$db" in
  bpp) project=$shared_dir/BPP.Shared.NET/BPP.Shared.NET.DbMigrator ;;
  document-analysis) project=$repo_dir/BPP.DocumentAnalysis/BPP.DocumentAnalysis.DbMigrator ;;
  *)
    printf 'migrate-stage: unknown database "%s" (allowed: bpp, document-analysis)\n' "$db" >&2
    exit 2
    ;;
esac
if [ ! -d "$project" ]; then
  printf 'migrate-stage: migrator project not found: %s\n' "$project" >&2
  exit 1
fi

# Both migrators read ConnectionStrings:DefaultConnection: appsettings.json first, then environment
# variables (so the injected string wins), then appsettings.<ASPNETCORE_ENVIRONMENT>.json.
# bpp-document-analysis: BPP.DocumentAnalysis.DbMigrator/Program.cs, docs/db-schema-lifecycle.md.
# A migrator that ignored the injected string would still exit 0 after migrating its local default,
# so the workflow checks the target's __EFMigrationsHistory afterwards (run-stage-sql.sh --readonly).
# appsettings.<env>.json is loaded after env vars and would win over the injected string.
unset ASPNETCORE_ENVIRONMENT DOTNET_ENVIRONMENT
unset ConnectionStrings__DefaultConnection

if [ "$stage" = local ]; then
  dotnet run --no-launch-profile --project "$project"
  exit $?
fi

conn=$(get_secret "$stage" "$db") || exit $?
ConnectionStrings__DefaultConnection=$conn dotnet run --no-launch-profile --project "$project" 2>&1 \
  | redact_stream "$conn"
rc=${PIPESTATUS[0]}
exit "$rc"
