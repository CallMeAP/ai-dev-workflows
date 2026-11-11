# Status line: model, effort, plan usage, active agents

`statusline-usage.sh` is a Claude Code status line command. It prints one line, for example:

```
Opus 5.5 (medium) - 5h unlimited - 7d 30% - agents 1 + wf 2
```

| Part | Source (the status line stdin JSON) |
|---|---|
| `Opus 5.5` | `model.display_name` |
| `(medium)` | `effort.level` of the current session; left out when absent |
| `5h …` / `7d …` | `rate_limits.five_hour` / `seven_day` `.used_percentage`; `unlimited` when `rate_limits` is present but the window is missing (the 5h window was dropped 2026-11); `?%` before the first API response |
| `agents N + wf M` | counted from the session's transcript folder (`transcript_path` without `.jsonl` + `/subagents`): background subagents whose `.meta.json` lacks `"finished":true`, and workflow agents with a `started` but no `result` line in their workflow's `journal.jsonl`. Only agent transcripts written in the last 2 min count, so a stopped agent still counts for up to 2 min and an agent silent for 2 min (a long test run) is not counted. Left out when both are 0. |

It also writes `rate_limits` to `~/.claude/state/usage.json` on every refresh, so an agent can read the current usage level.
Ultracode state is not shown: the stdin JSON has no field for it (checked 2026-11-11, Claude Code 2.1.322).

## Placeholders

None. Personal file, literal paths only via `$HOME`.

## Prerequisites

- bash 4, `jq`, GNU `find` (`-mmin`), `grep`
- Linux (tested on Ubuntu, 2026-11-11). macOS: UNVERIFIED (BSD `find` supports `-mmin`; nothing else was tried).
- Relies on the undocumented layout `~/.claude/projects/<proj>/<session>/subagents/…` for the agent count; if Claude Code changes it, the count shows nothing.

## Install by hand

```bash
cp statusline-usage.sh ~/.claude/statusline-usage.sh && chmod +x ~/.claude/statusline-usage.sh
mkdir -p ~/.claude/state
```

`~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline-usage.sh", "refreshInterval": 60 }
```

## Verify

```bash
echo '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"medium"},"rate_limits":{"seven_day":{"used_percentage":30}}}' \
  | ~/.claude/statusline-usage.sh; echo
# expected: Opus 5.5 (medium) - 5h unlimited - 7d 30%
```
