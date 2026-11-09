#!/usr/bin/env bash
# Query the Brokernet Gatus health dashboard (https://health.go-plattform.at) via its JSON API.
# Basic auth: user "go", password = the only line of ~/.health_go_plattform (never printed;
# handed to curl on stdin via -K -, so it appears in neither argv nor output).
#
#   bash health.sh               failing endpoints only (default)
#   bash health.sh all           every endpoint, OK and FAIL
#   bash health.sh show <text>   details for keys containing <text>: URL, conditions, history
#   bash health.sh config <text> the Gatus config entries mentioning <text> (brokernet-traefik, ref main)
set -uo pipefail
BASE=https://health.go-plattform.at
PWFILE=${HEALTH_GO_PWFILE:-$HOME/.health_go_plattform}
mode=${1:-failing}
filter=${2:-}

[ -r "$PWFILE" ] || { echo "missing $PWFILE (one line: the password of user 'go')" >&2; exit 2; }

if [ "$mode" = config ]; then
  glab api 'projects/lipso%2Fclients%2Fbrokernet%2Fbrokernet-traefik/repository/files/gatus%2Fconfig%2Fconfig.yaml/raw?ref=main' \
    | grep -n -i -B2 -A10 -- "$filter"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
code=$(printf 'user = "go:%s"\n' "$(tr -d '\n' < "$PWFILE")" \
  | curl -s -K - "$BASE/api/v1/endpoints/statuses?page=1&pageSize=100" -o "$tmp" -w '%{http_code}')
[ "$code" = 200 ] || { echo "HTTP $code from $BASE (401 = wrong password in $PWFILE)" >&2; exit 1; }

python3 -I - "$tmp" "$mode" "$filter" <<'PY'
import json, sys
path, mode, flt = sys.argv[1], sys.argv[2], sys.argv[3]
eps = json.load(open(path))
print(f"{len(eps)} endpoints")
for e in sorted(eps, key=lambda x: (x["group"], x["name"])):
    res = e.get("results") or []
    last = res[-1] if res else {}
    ok = bool(last.get("success"))
    if mode == "failing" and ok:
        continue
    if mode == "show" and flt.lower() not in e["key"].lower():
        continue
    failed = [c["condition"] for c in last.get("conditionResults", []) if not c["success"]]
    print(f"{'OK  ' if ok else 'FAIL'} {e['group']:<12} {e['name']:<28} {last.get('hostname')}  "
          f"status={last.get('status')} {failed or ''} {last.get('errors') or ''}")
    if mode == "show":
        bad = [r for r in res if not r.get("success")]
        print(f"     key={e['key']}  kept={len(res)} failed={len(bad)}  "
              f"window {res[0]['timestamp'] if res else '-'} .. {last.get('timestamp')}")
        for c in last.get("conditionResults", []):
            print(f"     {'ok ' if c['success'] else 'BAD'} {c['condition']}")
        for ev in e.get("events", [])[-5:]:
            print(f"     event {ev.get('type')} {ev.get('timestamp')}")
PY
