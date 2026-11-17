#!/usr/bin/env bash
# Pre-flight of bpp-agent-llm-selftest: read-only, no LLM call. One line per check: PASS / FAIL / WARN / SKIP / INFO.
# Usage: SELFTEST_ENV=<file> bash preflight.sh [--suites read,write,...|all] [--jar <cookie-jar>] [--no-login] [--regen <scratch-dir>]
#   --jar       reuse a cookie jar; otherwise one login to the demo auth (needed for the Codex link, providers and mail-form checks)
#   --no-login  skip every check that needs a login (SKIP lines)
#   --regen     regenerate the Cockpit agent client from the demo agent's swagger into <scratch-dir> and diff it against the Cockpit
# Exit 0 = no FAIL, 1 = at least one FAIL.
set -u
. "$(dirname "$0")/lib.sh"
SUITES=all JAR= NOLOGIN=0 REGEN=
while [ $# -gt 0 ]; do
  case "$1" in
    --suites) SUITES=$2; shift 2 ;; --jar) JAR=$2; shift 2 ;; --no-login) NOLOGIN=1; shift ;; --regen) REGEN=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
want() { [ "$SUITES" = all ] || case ",$SUITES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
FAILS=0
out() { printf '%-5s %-22s %s\n' "$1" "$2" "$3"; [ "$1" = FAIL ] && FAILS=$((FAILS + 1)); return 0; }
http() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

# 1 stack identity: the demo ports answer, and the listeners are demo worktrees, not the main checkouts of the normal stack
for v in AUTH_URL BACKEND_URL AGENT_URL; do
  c=$(http "${!v}/health"); [ "$c" = 200 ] && out PASS "up:${v%_URL}" "${!v}/health 200" || out FAIL "up:${v%_URL}" "${!v}/health -> $c"
done
c=$(http "$AGENT_URL/health/ready"); [ "$c" = 200 ] && out PASS agent-ready "/health/ready 200" || out FAIL agent-ready "/health/ready -> $c"
pid=$(listener_pid "$(port_of "$AGENT_URL")")
if [ -n "$pid" ]; then
  cwd=$(readlink "/proc/$pid/cwd")
  case "$cwd" in "$BPP_ROOT"/bpp-agent/*) out FAIL agent-is-demo "listener $pid runs from the main checkout ($cwd)" ;;
    *) out PASS agent-is-demo "listener $pid cwd $cwd" ;; esac
  envf=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)
  db=$(grep -o '^ConnectionStrings__DefaultConnection=.*' <<<"$envf" | grep -oiE 'Database=[^;]*' | cut -d= -f2)
  [ "$db" = "$DEMO_DB" ] && out PASS agent-db "Database=$db" || out FAIL agent-db "agent runs on Database='${db:-?}', want $DEMO_DB"
  grep -q '^Agent__AutoApproveWrites=false' <<<"$envf" && out PASS no-auto-approve "Agent__AutoApproveWrites=false" \
    || out FAIL no-auto-approve "Agent__AutoApproveWrites=false not in the agent env (write cards would be skipped)"
  AGENT_ENV=$envf
else out FAIL agent-is-demo "no listener on $(port_of "$AGENT_URL")"; AGENT_ENV=; fi
n52=$(ss -ltnH 2>/dev/null | grep -cE ':52[0-9][0-9]\s')
out INFO normal-stack "$n52 listeners on 52xx (another session may run e2e there; this run never touches them)"

# 2 demo DB and migrations
if PGPASSWORD=$(pg_password) psql -X -h "$PGHOST" -p "$PGPORT" -U "$PG_USER" -d postgres -Atc "select 1 from pg_database where datname='$DEMO_DB'" 2>/dev/null | grep -q 1; then
  out PASS demo-db "$DEMO_DB exists"
  top=$(pgr -Atc 'select max(migration_id) from "__EFMigrationsHistory"' 2>/dev/null)
  want_top=$(find "$SHARED_WORKTREE" -path '*DbMigrator/Migrations/*' -name '20*_*.cs' ! -name '*.Designer.cs' 2>/dev/null | sed 's#.*/##; s#\.cs$##' | sort | tail -1)
  [ -n "$top" ] && [ "$top" = "$want_top" ] && out PASS migrations "top $top" || out FAIL migrations "DB top '${top:-?}', bpp-shared worktree top '${want_top:-?}'"
else
  out FAIL demo-db "$DEMO_DB missing: create it from a pg_dump copy of local bpp (SKILL.md, Stack setup)"
fi

# 3 SHAs (for the report)
for w in AGENT_WORKTREE BACKEND_WORKTREE SHARED_WORKTREE COCKPIT_WORKTREE; do
  s=$(git -C "${!w}" rev-parse --short=9 HEAD 2>/dev/null) && out INFO "sha:${w%_WORKTREE}" "$s ${!w}" || out WARN "sha:${w%_WORKTREE}" "no git worktree at ${!w}"
done

# 4 tool catalog: the last startup line wins (EnsureFlagsMatch refuses to publish on a backend x-ki-assistent mismatch)
if [ -f "$AGENT_LOG" ]; then
  last=$(grep -E 'Agent tool catalog:|Tool-Katalog nicht veröffentlicht' "$AGENT_LOG" | tail -1)
  case "$last" in *"Agent tool catalog:"*) out PASS catalog "$(grep -o 'Agent tool catalog:.*' <<<"$last" | cut -c1-90)" ;;
    *"nicht veröffentlicht"*) out FAIL catalog "EnsureFlagsMatch refused the catalog (backend tags vs curated list): $(cut -c1-160 <<<"$last")" ;;
    *) out FAIL catalog "no catalog line in $AGENT_LOG" ;; esac
else out FAIL catalog "agent log $AGENT_LOG missing"; fi
if want dashboard; then
  grep -q '^Backend__DashboardToolsEnabled=true' <<<"$AGENT_ENV" && out PASS dashboard-switch "Backend__DashboardToolsEnabled=true" \
    || out FAIL dashboard-switch "dashboard suite needs Backend__DashboardToolsEnabled=true on the agent AND the backend [KiAgentCanCall] tags"
fi

# 5 Codex quota (read-only snapshot)
read -r p s age < <(quota)
if [ "$p" = None ] || [ -z "$p" ]; then out FAIL codex-quota "no rate_limits snapshot; run codex-usage.sh --refresh once"
elif [ "${p%.*}" -ge "$MAX_PRIMARY_PCT" ] || [ "${s%.*}" -ge "$MAX_SECONDARY_PCT" ]; then out FAIL codex-quota "5h=$p% week=$s% >= stop $MAX_PRIMARY_PCT/$MAX_SECONDARY_PCT"
else out PASS codex-quota "5h=$p% week=$s% (stop $MAX_PRIMARY_PCT/$MAX_SECONDARY_PCT)"; fi
[ "${age:-0}" -gt 900 ] && out WARN codex-snapshot "snapshot ${age}s old; agent traffic does not refresh it (codex-usage.sh --refresh before a long run)"

# 6 checks behind the login
if [ "$NOLOGIN" = 1 ]; then
  out SKIP codex-link "--no-login"; want model-switch && out SKIP providers "--no-login"
  { want mail-loop || want injection; } && out SKIP mail-form "--no-login"
else
  if [ -z "$JAR" ]; then JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT; login "$JAR" || out FAIL login "demo auth login failed"; fi
  if codex_linked "$JAR"; then out PASS codex-link "linked"
  else out FAIL codex-link "NOT linked (or relink required). Device-code link now, with the user at the keyboard: agent dashboard > Einstellungen > ChatGPT / Codex > Verknüpfen"; fi
  if want model-switch; then
    pv=$(curl -s --max-time 5 -b "$JAR" "$AGENT_URL/api/agent-session/providers")
    out INFO providers "$(jq -c '[.[]? | {id:(.id // .provider), model}]' <<<"$pv" 2>/dev/null | cut -c1-160)"
    grep -q anthropic <<<"$pv" || out INFO haiku "no anthropic provider (needs a Console API key with a spend limit; never subscription OAuth)"
  fi
  if want mail-loop || want injection; then
    ctx=$(curl -s --max-time 5 -b "$JAR" "$CONNECTOR_URL/api/external-mail-dashboard-synthetic-mail/context")
    [ "$(jq -r '.canCreate' <<<"$ctx" 2>/dev/null)" = true ] && out PASS mail-form "synthetic test-mail form canCreate" \
      || out FAIL mail-form "connector synthetic form not usable: $(cut -c1-120 <<<"$ctx")"
  fi
fi

# 7 mail stack, when a mail suite is selected
if want mail-loop || want injection || want dashboard; then
  c=$(http "$CONNECTOR_URL/health"); [ "$c" = 200 ] && out PASS up:CONNECTOR "$CONNECTOR_URL/health 200" || out FAIL up:CONNECTOR "-> $c (start.sh connector)"
  c=$(http "$RABBIT_MGMT_URL/"); [ "$c" = 200 ] && out PASS rabbitmq "$RABBIT_MGMT_URL 200" || out FAIL rabbitmq "-> $c (rabbit-start.sh)"
  grep -q '^Mail__Enabled=true' <<<"$AGENT_ENV" && grep -q '^Mail__ProcessingEnabled=true' <<<"$AGENT_ENV" \
    && out PASS agent-mail "Mail__Enabled + ProcessingEnabled" || out FAIL agent-mail "agent runs without Mail__Enabled/ProcessingEnabled=true"
fi

# 8 suite tooling
if want ui; then
  c=$(http "$COCKPIT_URL/"); [ "$c" = 200 ] && out PASS up:COCKPIT "$COCKPIT_URL 200" || out FAIL up:COCKPIT "-> $c (ng serve on the demo port)"
  [ -x "${CHROME:-}" ] && out PASS chrome "$CHROME" || out FAIL chrome "CHROME not executable"
  [ -f "${PUPPETEER_CORE:-}/package.json" ] && out PASS puppeteer "$PUPPETEER_CORE" || out FAIL puppeteer "PUPPETEER_CORE has no package.json"
fi
if want latency; then
  systemctl --user is-system-running >/dev/null 2>&1; [ $? -le 1 ] && out PASS systemd-user "systemd-run --user available" || out FAIL systemd-user "no user systemd"
  [ -d "$NODE_MODULES_FROM/node_modules/ws" ] && out PASS ws "$NODE_MODULES_FROM/node_modules/ws" || out FAIL ws "no node_modules/ws under NODE_MODULES_FROM"
fi
if want model-switch; then
  sw=$(curl -s --max-time 5 "$AGENT_URL/api-doc/v1/swagger.json" | jq -r '.paths | keys[]' 2>/dev/null)
  grep -q '/api/agent-session/{sessionId}/provider' <<<"$sw" && out INFO switch-api "mid-session switch (PATCH .../provider) present" \
    || out INFO switch-api "no mid-session switch on this build; model-switch.sh restarts the agent with Llm__Codex__Model (global, run alone)"
fi

# 9 Cockpit agent client vs the demo agent's swagger (hand-written models drift, e.g. !1348)
if [ -n "$REGEN" ]; then
  mkdir -p "$REGEN"; curl -s --max-time 10 "$AGENT_URL/api-doc/v1/swagger.json" > "$REGEN/agent-swagger.json"
  if (cd "$COCKPIT_WORKTREE" && npx --no-install openapi-generator-cli generate -g typescript-angular -t ./src/openapi-templates \
        -i "$REGEN/agent-swagger.json" -o "$REGEN/agent" --additional-properties=ngVersion=20.0,providedInRoot=true,serviceSuffix=ApiService,serviceFileSuffix=-api.service,fileNaming=kebab-case,modelFileSuffix=.model,apiModulePrefix=Agent,stringEnums=true,resolveInlineEnums=true \
        > "$REGEN/regen.log" 2>&1 && node src/scripts/enforce-crlf.js "$REGEN/agent" >> "$REGEN/regen.log" 2>&1); then
    diff -r --strip-trailing-cr -x .openapi-generator -x .openapi-generator-ignore "$COCKPIT_WORKTREE/src/app/api/agent" "$REGEN/agent" > "$REGEN/client.diff"
    nd=$(grep -cE '^(Only in|diff )' "$REGEN/client.diff")
    [ "$nd" = 0 ] && out PASS cockpit-client "generated == committed" || out WARN cockpit-client "$nd files differ, see $REGEN/client.diff"
  else out FAIL cockpit-client "generator failed, see $REGEN/regen.log"; fi
else out SKIP cockpit-client "pass --regen <scratch-dir>"; fi

echo "PREFLIGHT $([ $FAILS = 0 ] && echo OK || echo "FAILED ($FAILS)")"
[ $FAILS = 0 ]
