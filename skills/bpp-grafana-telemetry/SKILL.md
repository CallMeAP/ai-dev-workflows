---
name: bpp-grafana-telemetry
description: Use when BPP service logs or traces are needed from Grafana https://grafana.telemetry.lipsum.services (Loki, Tempo) — phrases like "check the logs", "grafana", "loki", "tempo", "find the trace", "error count on dev/staging", "what did bpp-file log", "why did this request fail", "no error logs in X", "OTel logs". Covers token handling, datasource uids, label names, and which stages and services are actually exported.
---

# bpp-grafana-telemetry

## Overview

Grafana API with the bearer token in `~/.grafana_telemetry_lipsum`. **Never print the token**:
pass it to curl on stdin (`-K -`), as `grafana.sh` does. Datasource uids: Loki `lokiloki`,
Tempo `tempotempo`, Mimir `mimirmimir`. Access goes through `/api/datasources/proxy/uid/<uid>/…`.

## Quick Reference

| Need | Command (`bash ~/.claude/skills/bpp-grafana-telemetry/grafana.sh …`) |
|---|---|
| Which services and stages export at all | `labels` |
| Error lines, newest first | `logs '{service_name="bpp-backend",deployment_environment_name="development"} \| detected_level="error"' 24 50` |
| Text search | `logs '{service_name="bpp-file"} \|= "MinRequestBodyDataRate"' 48` |
| Counts per service and stage | `count 'sum by (service_name, deployment_environment_name) (count_over_time({service_name=~"bpp-.*"} \|= "Name does not resolve" [5d]))'` |
| Failed requests as traces | `traces '{resource.service.name="bpp-file" && resource.deployment.environment.name="staging" && span.http.response.status_code>=400}' 6 100` |
| One request end to end | `trace <traceId>` (the trace id comes from a log line's `trace=` field) |

**Loki labels:**
- Stream labels: `service_name`, `deployment_environment_name` (not `deployment_environment`), `service_instance_id`.
- Fields you can filter on with `| field="x"`: `detected_level`, `severity_text`, `trace_id`, `span_id`, `http_route`, `RequestId`, `exception_type`, `exception_message`, `bpp_tenant_id`, `user_id`.

**Arguments:** `logs` and `traces` take `[hours] [limit]` after the query. The defaults are 24 h, with 50 lines for `logs` and 20 traces for `traces`. A full page means the output is truncated, so raise the limit before counting.

**Tempo:** filter by stage with `resource.deployment.environment.name`. Other useful attributes are `resource.service.name`, `span.http.route` and `span.http.response.status_code`, plus `duration>2s`.

## Coverage — check it before concluding anything

- Run `labels` first. A stage or service missing from it has **no telemetry**, so a 0 there proves nothing.
  - As of 2026-11-09: development and staging only, no main/prod.
  - Staging starts on 2026-11-09 (~10:35 UTC), and it covers fewer services than Loki.
- Not exported at all: jsreport and bpp-js-report-connector.
- Mimir holds only the telemetry stack's own metrics, not service memory or CPU.
- For those cases, say "not in telemetry; needs `docker service logs` on the swarm (no access from here)".
- Loki under-counts some errors. One check found 6 `Name does not resolve` in Loki against 53 in the docker log. Treat counts as lower bounds.
- "No error logs" does not mean no failures. Rejected requests (400/401/429, or framework exceptions turned into 400s by model binding) often log nothing; traces show them, so search Tempo by status code.

## Common Mistakes

- Printing, `cat`-ing or putting the token in argv (`-H "Authorization: Bearer …"` on the command line).
- Querying without a stage filter and mixing development and staging.
- Reading a log line's `RequestId`, which is the ASP.NET connection id, as the trace id. Use the `trace_id` field.
- Times are UTC. Convert before matching a user's screenshot (Vienna is UTC+1 in winter).
