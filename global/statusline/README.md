# Status line: model, effort, plan usage, cost, active agents

`statusline-usage.sh` is a Claude Code status line command. It prints one part per line, for example:

```
✳ Opus 5.5 ▂▃░░░ (medium)
⏳ 5h unlimited · 7d 43%
💰 session $4.8k · all $60.1k
🤖 bg agents 0 · wf agents 1
```

| Part | Source |
|---|---|
| `✳ Opus 5.5` | icon + colour by `model.id`: Fable ✦ blue, Opus ✳ purple, Sonnet ✻ orange, Haiku ✿ green, other ◇ grey (ANSI 256 colours); name from `model.display_name` |
| `▂▃░░░` | effort bar, 1-5 steps for low, medium, high, xhigh, max |
| `(medium)` | `effort.level` of the current session; left out when absent |
| `⏳ 5h …` / `7d …` | `rate_limits.five_hour` / `seven_day` `.used_percentage`; `unlimited` when `rate_limits` is present but the window is missing (the 5h window was dropped 2026-11); `?%` before the first API response |
| `💰 session` | `cost.total_cost_usd` from the stdin JSON: Claude Code's own estimate at API prices for this session (matches `/usage`) |
| `💰 all` | `~/.claude/state/cost-total.json`, written by `statusline-cost-total.py` (below). All-time usage at API prices, not what a subscription costs. |
| `🤖 bg agents N · wf agents M` | counted from the session's transcript folder (`transcript_path` without `.jsonl` + `/subagents`): background subagents (Agent tool) whose `.meta.json` lacks `"finished":true`, and workflow agents with a `started` but no `result` line in their workflow's `journal.jsonl`. A workflow usually runs its stages one agent at a time, so one running workflow often shows `wf agents 1`. Only agent transcripts written in the last 2 min count: a stopped agent still counts for up to 2 min, an agent silent for 2 min (a long test run) is not counted. The line is left out when both are 0. |

It also writes `rate_limits` to `~/.claude/state/usage.json` on every refresh, so an agent can read the current usage level.
Ultracode state is not shown: the stdin JSON has no field for it (checked 2026-11-11, Claude Code 2.1.322).

## All-time cost: `statusline-cost-total.py`

The `/usage` → Stats numbers are not passed to status line commands, so the script prices them itself:

- **History:** `~/.claude/stats-cache.json` (the Stats tab's source) holds all-time tokens per model through its
  `lastComputedDate`. Old transcripts are cleaned up, so they cannot be used for history.
- **Since then:** usage after that date comes from the transcripts under `~/.claude/projects` (deduplicated by message id).
- **Prices:** API rates per model in `PRICES` (from the claude-api skill, cached 2026-11-03). The stats cache has no
  TTL split for cache writes, so they are priced at the 1-hour rate; at the 5-minute rate the total is ~15 % lower.
- The status line starts it in the background (`flock`, `nice`) when `cost-total.json` is older than 10 minutes.
  A run takes a few seconds; transcript results are cached in `~/.claude/state/cost-total-cache.json`.
- Cross-check 2026-11-12: tokens matched the Stats tab (cache read 55.0b vs 55.1b, cache write 2.28b vs 2.3b).

## Placeholders

None. Personal files, literal paths only via `$HOME`.

## Prerequisites

- bash 4, `jq`, GNU `find` (`-mmin`), `grep`, `awk`, `flock` (util-linux), `python3`
- A terminal font with emoji (⏳ 💰 🤖)
- Linux (tested on Ubuntu, 2026-11-12). macOS: UNVERIFIED (no `flock` by default).
- Relies on the undocumented layouts `~/.claude/projects/<proj>/<session>/subagents/…` and `~/.claude/stats-cache.json`;
  if Claude Code changes them, the agent line or the `all` cost shows nothing or `?`.

## Install by hand

```bash
cp statusline-usage.sh statusline-cost-total.py ~/.claude/ && chmod +x ~/.claude/statusline-usage.sh
mkdir -p ~/.claude/state
```

`~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline-usage.sh", "refreshInterval": 60 }
```

## Verify

```bash
python3 -I ~/.claude/statusline-cost-total.py && cat ~/.claude/state/cost-total.json; echo
echo '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"medium"},"rate_limits":{"seven_day":{"used_percentage":43}},"cost":{"total_cost_usd":4808.8}}' \
  | ~/.claude/statusline-usage.sh; echo
# expected (plus colour codes):
# ✳ Opus 5.5 ▂▃░░░ (medium)
# ⏳ 5h unlimited · 7d 43%
# 💰 session $4.8k · all $<your total>
```
