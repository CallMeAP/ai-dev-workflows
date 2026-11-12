#!/usr/bin/env bash
# Status line: shows plan usage (5h / 7d) and snapshots rate_limits to ~/.claude/state/usage.json
# so Claude can read the current usage level during a session.
input=$(cat)
out="$HOME/.claude/state/usage.json"

rl=$(jq -c '.rate_limits // empty' <<<"$input" 2>/dev/null)
if [ -n "$rl" ]; then
  tmp="$out.tmp.$$"
  jq -n --argjson rl "$rl" --arg at "$(date -Iseconds)" '{captured_at: $at, rate_limits: $rl}' >"$tmp" && mv "$tmp" "$out"
fi

model=$(jq -r '.model.display_name // empty' <<<"$input" 2>/dev/null)
fmt() { jq -r --arg w "$1" '.rate_limits[$w].used_percentage // empty | floor' <<<"$input" 2>/dev/null; }
# A window missing while rate_limits is present has no limit (the 5h window was dropped): show "unlimited".
# No rate_limits at all (no API response yet): "?".
pct() { local v; v=$(fmt "$1"); if [ -n "$v" ]; then echo "$v%"; elif [ -n "$rl" ]; then echo unlimited; else echo '?%'; fi; }
effort=$(jq -r '.effort.level // empty' <<<"$input" 2>/dev/null)

# Active agents of this session: background subagents whose meta lacks "finished": true, and workflow agents
# with a "started" but no "result" line in their journal. Only transcripts written in the last 2 min count, so
# stopped or killed agents drop out (an agent silent for 2 min, e.g. during a long test run, is not counted; a stopped one still counts for up to 2 min).
tp=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
sub=0; wfa=0
if [ -n "$tp" ] && [ -d "${tp%.jsonl}/subagents" ]; then
  while IFS= read -r f; do
    m=${f%.jsonl}.meta.json; d=$(dirname "$f"); id=$(basename "$f" .jsonl); id=${id#agent-}
    if [ "$(basename "$(dirname "$d")")" = workflows ]; then
      grep -F "\"agentId\":\"$id\"" "$d/journal.jsonl" 2>/dev/null | grep -qF '"type":"result"' || wfa=$((wfa+1))
    else
      grep -q '"finished":true' "$m" 2>/dev/null || sub=$((sub+1))
    fi
  done < <(find "${tp%.jsonl}/subagents" -name 'agent-*.jsonl' -mmin -2 2>/dev/null)
fi
# Labels: "bg" = background subagents (Agent tool), "wf" = agents running inside workflows (a workflow
# usually runs its stages one agent at a time, so one running workflow often shows "wf 1").
agents=""; [ $((sub+wfa)) -gt 0 ] && agents="🤖 bg agents $sub · wf agents $wfa"
# Cost at API prices: this session from Claude Code's own estimate (cost.total_cost_usd); all recorded
# sessions from ~/.claude/state/cost-total.json, refreshed in the background at most every 10 min.
usd() { awk -v v="$1" 'BEGIN { if (v == "") print "?"; else if (v >= 1000) printf "$%.1fk", v/1000; else printf "$%.2f", v }'; }
scost=$(jq -r '.cost.total_cost_usd // empty' <<<"$input" 2>/dev/null)
tfile="$HOME/.claude/state/cost-total.json"
if [ ! -f "$tfile" ] || [ -n "$(find "$tfile" -mmin +10 2>/dev/null)" ]; then
  (flock -n 9 || exit 0; nice python3 -I "$HOME/.claude/statusline-cost-total.py" >/dev/null 2>&1) 9>"$HOME/.claude/state/cost-total.lock" &
fi
tcost=$(jq -r '.total_usd // empty' "$tfile" 2>/dev/null)
cost="💰 session $(usd "$scost") · all $(usd "$tcost")"
# Model icon + colour (by model id) and a 5-step effort bar (low..max).
mid=$(jq -r '.model.id // empty' <<<"$input" 2>/dev/null)
case "$mid" in
  *fable*)  icon='✦'; col='38;5;75'  ;;  # blue
  *opus*)   icon='✳'; col='38;5;141' ;;  # purple
  *sonnet*) icon='✻'; col='38;5;209' ;;  # orange
  *haiku*)  icon='✿'; col='38;5;114' ;;  # green
  *)        icon='◇'; col='38;5;250' ;;  # other / unknown
esac
case "$effort" in low) n=1 ;; medium) n=2 ;; high) n=3 ;; xhigh) n=4 ;; max) n=5 ;; *) n=0 ;; esac
bar=""; steps=(▂ ▃ ▅ ▆ █)
if [ "$n" -gt 0 ]; then for i in 0 1 2 3 4; do if [ $i -lt $n ]; then bar+="${steps[$i]}"; else bar+='░'; fi; done; bar=" $bar"; fi
# One part per line: model + effort, plan limits, cost, running agents (only while some run).
printf '\033[%sm%s %s\033[0m%s%s\n⏳ 5h %s · 7d %s\n%s' "$col" "$icon" "${model:-?}" "$bar" "${effort:+ ($effort)}" "$(pct five_hour)" "$(pct seven_day)" "$cost"
[ -n "$agents" ] && printf '\n%s' "$agents"
exit 0
