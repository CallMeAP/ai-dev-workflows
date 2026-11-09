#!/usr/bin/env bash
# Read-only queries against Grafana https://grafana.telemetry.lipsum.services (Loki logs, Tempo traces).
# Bearer token = the only line of ~/.grafana_telemetry_lipsum; handed to curl on stdin (-K -), never printed.
#
#   bash grafana.sh labels                         service_name / deployment_environment_name values (30 d)
#   bash grafana.sh logs   '<LogQL>' [hours] [n]   newest n log lines (default 24 h, 50 lines)
#   bash grafana.sh count  '<LogQL metric>'        instant metric query, e.g. sum by (...) (count_over_time(...[24h]))
#   bash grafana.sh traces '<TraceQL>' [hours] [n] matching traces (default 24 h, 20)
#   bash grafana.sh trace  <traceId>               all spans of one trace: service, name, status, duration
set -uo pipefail
G=https://grafana.telemetry.lipsum.services
TOKFILE=${GRAFANA_TOKEN_FILE:-$HOME/.grafana_telemetry_lipsum}
LOKI=$G/api/datasources/proxy/uid/lokiloki/loki/api/v1
TEMPO=$G/api/datasources/proxy/uid/tempotempo/api
[ -r "$TOKFILE" ] || { echo "missing $TOKFILE (one line: Grafana API token)" >&2; exit 2; }
auth() { printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' < "$TOKFILE")"; }
get() { auth | curl -s -K - -G "$@"; }
now=$(date +%s)
mode=${1:-}; shift || true

case "$mode" in
  labels)
    st=$((now - 30*86400))
    for l in service_name deployment_environment_name; do
      printf '%s: ' "$l"
      get "$LOKI/label/$l/values" --data-urlencode "start=${st}000000000" --data-urlencode "end=${now}000000000" \
        | python3 -c 'import json,sys;print(", ".join(json.load(sys.stdin).get("data") or []))'
    done
    printf 'tempo services: '
    get "$TEMPO/v2/search/tag/resource.service.name/values" \
      | python3 -c 'import json,sys;print(", ".join(v["value"] for v in json.load(sys.stdin).get("tagValues",[])))'
    ;;
  logs)
    q=${1:?LogQL}; h=${2:-24}; n=${3:-50}
    get "$LOKI/query_range" --data-urlencode "query=$q" --data-urlencode "start=$((now - h*3600))000000000" \
      --data-urlencode "end=${now}000000000" --data-urlencode "limit=$n" --data-urlencode direction=backward \
      | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
if d.get("status") != "success": sys.exit(f"loki: {str(d)[:400]}")
rows = []
for r in d["data"]["result"]:
    s = r["stream"]
    for ts, line in r["values"]:
        rows.append((int(ts), s.get("detected_level", "?"), s.get("service_name"), s.get("deployment_environment_name"), s.get("trace_id", "-"), line))
for ts, lvl, svc, env, tid, line in sorted(rows, reverse=True):
    t = datetime.datetime.fromtimestamp(ts / 1e9, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"{t}Z {lvl:<5} {svc}/{env} trace={tid} | {line[:300]}")
print(f"{len(rows)} lines")'
    ;;
  count)
    q=${1:?LogQL metric query}
    get "$LOKI/query" --data-urlencode "query=$q" \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("status") != "success": sys.exit(f"loki: {str(d)[:400]}")
res = d["data"]["result"]
for r in res: print(r["value"][1], r["metric"])
if not res: print("0 series (no matching lines; also check the env label exists for that stage)")'
    ;;
  traces)
    q=${1:?TraceQL}; h=${2:-24}; n=${3:-20}
    get "$TEMPO/search" --data-urlencode "q=$q" --data-urlencode "start=$((now - h*3600))" \
      --data-urlencode "end=$now" --data-urlencode "limit=$n" \
      | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
tr = d.get("traces")
if tr is None: sys.exit(f"tempo: {str(d)[:400]}")
for t in tr:
    st = datetime.datetime.fromtimestamp(int(t["startTimeUnixNano"]) / 1e9, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    tid, svc, name, ms = t["traceID"], t.get("rootServiceName"), t.get("rootTraceName"), t.get("durationMs", 0)
    print(f"{st}Z {tid} {svc} {name} {ms}ms")
print(f"{len(tr)} traces")'
    ;;
  trace)
    id=${1:?traceId}
    get "$TEMPO/traces/$id" \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
def attrs(a): return {x["key"]: next(iter(x["value"].values()), None) for x in a or []}
spans = []
for b in d.get("batches", []) + d.get("resourceSpans", []):
    svc = attrs(b.get("resource", {}).get("attributes")).get("service.name")
    for ss in b.get("scopeSpans", []) + b.get("instrumentationLibrarySpans", []):
        for s in ss.get("spans", []):
            a = attrs(s.get("attributes"))
            dur = (int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e6
            code = a.get("http.response.status_code") or a.get("http.status_code") or ""
            spans.append((int(s["startTimeUnixNano"]), svc, s.get("name"), code, s.get("status", {}).get("code", ""), dur))
if not spans: sys.exit(f"no spans: {str(d)[:300]}")
t0 = min(x[0] for x in spans)
for st, svc, name, code, status, dur in sorted(spans):
    print(f"+{(st - t0) / 1e6:9.1f}ms {dur:9.1f}ms {svc:<26} {str(code):<4} {status:<18} {name}")'
    ;;
  *)
    sed -n '2,10p' "$0"; exit 2 ;;
esac
