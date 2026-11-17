#!/usr/bin/env bash
# Prints "primary secondary age_s": used percent of the Codex 5 h window and of the week, from the newest ~/.codex rollout file,
# plus the snapshot's age. Read-only by default: agent chat traffic does NOT refresh that file, only Codex CLI runs do.
# --refresh: one tiny codex exec first (costs a sliver of the same quota; never in pre-flight).
# Prints "None None <age>" when no rollout carries rate_limits.
if [ "${1:-}" = --refresh ]; then
  (cd /tmp && timeout 120 codex exec --skip-git-repo-check -s read-only -m gpt-6-luna -c model_reasoning_effort=low "Reply with OK only." \
     </dev/null >/dev/null 2>&1)
fi
f=$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
[ -n "$f" ] || { echo "None None 999999"; exit 0; }
age=$(( $(date +%s) - $(stat -c %Y "$f") ))
python3 -I - "$f" "$age" <<'PY'
import json, sys
p = s = None
def walk(x):
    global p, s
    if isinstance(x, dict):
        r = x.get('rate_limits')
        if isinstance(r, dict) and r.get('primary'):
            p = r['primary'].get('used_percent'); s = (r.get('secondary') or {}).get('used_percent')
        for v in x.values(): walk(v)
    elif isinstance(x, list):
        for v in x: walk(v)
for line in open(sys.argv[1]):
    if '"rate_limits"' not in line: continue
    try: walk(json.loads(line))
    except ValueError: pass
print(p, s, sys.argv[2])
PY
