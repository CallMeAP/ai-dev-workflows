#!/usr/bin/env bash
# Ground truth for the dashboard suite: direct bpp-backend reads (demo backend) as the logged-in demo user, with the params the
# cases need; one JSON line {own, g1, own_2025, top5, postkorb}. Use as TRUTH_CMD for run-round.sh.
# Usage: SELFTEST_ENV=<file> bash dashboard-truth.sh <jar> [group-id, default SELFTEST_GROUP_G1]
# Nested output: score.py numbers take dotted keys (own.OpenClaims, g1.OpenClaims, postkorb).
set -u
. "$(dirname "$0")/lib.sh"
J=$1; G=${2:-${SELFTEST_GROUP_G1:-}}; : "${OWNER_GO_USER_ID:?set OWNER_GO_USER_ID}"; B=$BACKEND_URL/api/dashboard/$OWNER_GO_USER_ID
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -s -b "$J" "$B/kpis" > "$T/own"
if [ -n "$G" ]; then curl -s -b "$J" -H "X-Backoffice-Group-ID: $G" "$B/kpis?scope=ActiveGroup" > "$T/g1"; else echo '{}' > "$T/g1"; fi
curl -s -b "$J" "$B/kpis?gueltigVon=2025-01-01&gueltigBis=2025-12-31" > "$T/own_2025"
curl -s -b "$J" "$B/top-customers?count=5" > "$T/top5"
curl -s -b "$J" "$B/postkorb?PageNumber=1&PageSize=5" > "$T/postkorb"
python3 -I - "$T" <<'PY'
import json, os, sys
t = sys.argv[1]
def k(n):
    s = open(os.path.join(t, n)).read()
    try: d = json.loads(s)
    except ValueError: return s[:300]
    return {x['metric']: x['value'] for x in d} if isinstance(d, list) and d and 'metric' in d[0] else d
out = {n: k(n) for n in ['own', 'g1', 'own_2025', 'top5', 'postkorb']}
out['postkorb'] = out['postkorb'].get('unreadCount') if isinstance(out['postkorb'], dict) else out['postkorb']
print(json.dumps(out, ensure_ascii=False))
PY
