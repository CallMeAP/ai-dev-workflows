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
agents=""; [ $((sub+wfa)) -gt 0 ] && agents=" - agents $sub + wf $wfa"
printf '%s%s - 5h %s - 7d %s%s' "${model:-?}" "${effort:+ ($effort)}" "$(pct five_hour)" "$(pct seven_day)" "$agents"
