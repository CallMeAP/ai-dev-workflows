#!/usr/bin/env bash
# Restarts the DEMO agent with the challenger configured (up) or on its plain config (down). GLOBAL SWITCH: nothing else may chat
# with the demo agent meanwhile (the main skill's rule for restarts).
# Two arm modes, because only openai-codex and llamacpp are selectable per GoUser (ProvidersLlmPreferenceUtil.Selectable, D-660):
#   pref     CHALLENGER_PROVIDER=llamacpp: the challenger sits in the Llm:LlamaCpp slot (llama.cpp, or any key-less local
#            OpenAI-compatible server such as Ollama or vLLM). Both arms stay up; ab-run.sh switches per case with
#            PUT /api/llm-provider-preference. The slot carries the llamacpp-only engine paths (no-think client, compact mail prompt).
#   restart  any other id (hosted, or a keyed server): Llm:OpenAiCompatible:<id>, which no GoUser can select. "up" restarts the agent
#            with ONLY the challenger allowed and as the default provider; "down" brings Luna back. ab-run.sh runs one arm per block.
#            Needs a start.sh whose agent line reads Llm__DefaultProvider="${AGENT_DEFAULT_PROVIDER:-openai-codex}".
# up [overlay.env] also passes the KEY=VALUE lines of overlay.env (tuning candidates; Llm__* keys only, never Codex or the shared prompt).
# Refuses: hosted without SYNTHETIC_DATA_CONFIRMED=yes, a key file missing or not mode 600, an Anthropic subscription OAuth token
# (sk-ant-oat...) instead of a Console API key, a hosted run without BUDGET_USD, a local endpoint that does not answer, pending
# 13 h latency timers. The key goes in by variable name (ApiKeyEnv), never printed; it is readable in /proc/<agent pid>/environ.
# Usage: SELFTEST_ENV=<file> COMPARE_ENV=<file> JAR=<jar> bash challenger.sh up [overlay.env] | down | mode
set -u
SELFTEST_SKILL=${SELFTEST_SKILL:-$HOME/.claude/skills/bpp-agent-llm-selftest}
. "$SELFTEST_SKILL/scripts/lib.sh"
: "${COMPARE_ENV:?set COMPARE_ENV (copy of compare.env.example)}"; . "$COMPARE_ENV"
: "${DEMO_HOME:?}"; : "${JAR:?set JAR}"
ACTION=${1:?up|down|mode}; OVERLAY=${2:-}
P=$CHALLENGER_PROVIDER
ARM_MODE=restart; [ "$P" = llamacpp ] && ARM_MODE=pref
[ "$ACTION" = mode ] && { echo "$ARM_MODE"; exit 0; }
wait_ready() { for _ in $(seq 1 60); do curl -fsS -o /dev/null --max-time 5 "$AGENT_URL/health/ready" && return 0; timeout 5 tail -f /dev/null; done; return 1; }
no_latency_timers || exit 6
restart() { "$DEMO_HOME/stop.sh" agent; timeout 30 tail -f /dev/null; env "$@" "$DEMO_HOME/start.sh" agent; wait_ready || { echo "agent not ready" >&2; exit 5; }; }
pref() { curl -s -b "$JAR" --max-time 10 "$AGENT_URL/api/llm-provider-preference" | jq -r '.provider // empty'; }

if [ "$ACTION" = down ]; then restart; echo "agent back on its plain config; new sessions start on: $(pref)"; exit 0; fi

[ "$P" = "$LUNA_PROVIDER" ] && { echo "REFUSING: challenger equals Luna's provider" >&2; exit 6; }
case "$CHALLENGER_KIND" in local|hosted) ;; *) echo "REFUSING: CHALLENGER_KIND must be local or hosted" >&2; exit 6 ;; esac
if [ "$CHALLENGER_KIND" = hosted ]; then
  [ "${SYNTHETIC_DATA_CONFIRMED:-no}" = yes ] || { echo "REFUSING: hosted challengers see synthetic data only; DEMO_DB=$DEMO_DB counts as a bpp copy until the developer confirms otherwise" >&2; exit 6; }
  { [ -s "${CHALLENGER_KEY_FILE:-}" ] && [ "$(stat -c %a "$CHALLENGER_KEY_FILE")" = 600 ]; } || { echo "REFUSING: CHALLENGER_KEY_FILE missing, empty or not mode 600" >&2; exit 6; }
  case "$(head -c 12 "$CHALLENGER_KEY_FILE")" in sk-ant-oat*) echo "REFUSING: that is a Claude subscription OAuth token; Anthropic only via a Console API key with a spend limit" >&2; exit 6 ;; esac
  awk "BEGIN{exit !(${BUDGET_USD:-0} > 0)}" || { echo "REFUSING: BUDGET_USD must be > 0 for a hosted challenger" >&2; exit 6; }
  BPP_COMPARE_KEY=$(cat "$CHALLENGER_KEY_FILE"); export BPP_COMPARE_KEY
else
  # local = this machine: anything else is hosted (synthetic data only) and must say so
  case "$CHALLENGER_ENDPOINT" in http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
    *) echo "REFUSING: CHALLENGER_KIND=local needs a loopback endpoint (http://127.0.0.1:<port>/v1), got $CHALLENGER_ENDPOINT; use KIND=hosted" >&2; exit 6 ;; esac
  curl -fsS --max-time 5 -o /dev/null "$CHALLENGER_ENDPOINT/models" || { echo "REFUSING: nothing answers on $CHALLENGER_ENDPOINT (start the runtime first)" >&2; exit 6; }
fi
if [ "$ARM_MODE" = pref ]; then
  E=("Llm__AllowedProviders=$LUNA_PROVIDER,llamacpp" "Llm__LlamaCpp__Endpoint=$CHALLENGER_ENDPOINT" "Llm__LlamaCpp__Model=$CHALLENGER_MODEL"
     "Llm__LlamaCpp__ContextTokens=$CHALLENGER_CONTEXT_TOKENS")
else
  grep -q 'Llm__DefaultProvider="\?\${AGENT_DEFAULT_PROVIDER' "$DEMO_HOME/start.sh" || {
    echo "REFUSING: $DEMO_HOME/start.sh hard-codes Llm__DefaultProvider; change its agent line to Llm__DefaultProvider=\"\${AGENT_DEFAULT_PROVIDER:-openai-codex}\" while the stack is free" >&2; exit 6; }
  export AGENT_DEFAULT_PROVIDER=$P
  S="Llm__OpenAiCompatible__${P}__"
  E=("Llm__AllowedProviders=$P" "${S}Endpoint=$CHALLENGER_ENDPOINT" "${S}Model=$CHALLENGER_MODEL" "${S}ContextTokens=$CHALLENGER_CONTEXT_TOKENS")
  [ -n "${CHALLENGER_MAX_TOOLS:-}" ] && E+=("${S}MaxToolsPerRequest=$CHALLENGER_MAX_TOOLS")
  [ "$CHALLENGER_KIND" = hosted ] && E+=("${S}ApiKeyEnv=BPP_COMPARE_KEY")
fi
if [ -n "$OVERLAY" ]; then
  while IFS= read -r l; do
    case "$l" in ''|'#'*) continue ;;
      Llm__Codex__*|Llm__SystemPrompt=*|Llm__DefaultProvider=*|Llm__AllowedProviders=*) echo "REFUSING overlay line (touches Luna, the shared prompt or the arms): ${l%%=*}" >&2; exit 6 ;;
      Llm__*=*) E+=("$l") ;; *) echo "REFUSING overlay line (only Llm__ keys): ${l%%=*}" >&2; exit 6 ;; esac
  done < "$OVERLAY"
fi
restart "${E[@]}"
echo "agent up, arm mode $ARM_MODE, challenger $P ($CHALLENGER_MODEL); new sessions start on: $(pref)"
