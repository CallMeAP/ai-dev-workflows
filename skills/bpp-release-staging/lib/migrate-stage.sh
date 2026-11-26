#!/usr/bin/env bash
# migrate-stage.sh <local|development|staging> [--shared-dir DIR]
# Runs the bpp-shared DbMigrator (applies all pending EF migrations) against one stage.
# local uses the migrator's own appsettings.json (local DB, no secret).
# development/staging: the connection string comes from get_secret and is set only for the
# dotnet process; all output goes through redact_stream. No main stage.
# Exit: dotnet's exit; 2 unknown stage or bad args; 1 migrator project missing; 3-5 from get_secret.
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

shared_dir=$HOME/Entwicklung/bpp/bpp-shared
while [ $# -gt 0 ]; do
  case "$1" in
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

project=$shared_dir/BPP.Shared.NET/BPP.Shared.NET.DbMigrator
if [ ! -d "$project" ]; then
  printf 'migrate-stage: migrator project not found: %s\n' "$project" >&2
  exit 1
fi

# appsettings.<env>.json is loaded after env vars and would win over the injected string.
unset ASPNETCORE_ENVIRONMENT DOTNET_ENVIRONMENT
unset ConnectionStrings__DefaultConnection

if [ "$stage" = local ]; then
  dotnet run --no-launch-profile --project "$project"
  exit $?
fi

conn=$(get_secret "$stage") || exit $?
ConnectionStrings__DefaultConnection=$conn dotnet run --no-launch-profile --project "$project" 2>&1 \
  | redact_stream "$conn"
rc=${PIPESTATUS[0]}
exit "$rc"
