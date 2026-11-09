---
name: bpp-go-health
description: Use when checking the Brokernet/BPP service health dashboard https://health.go-plattform.at, or when a service shows unhealthy / red / down there on development, staging or main — phrases like "why is X unhealthy", "check go health", "health dashboard", "gatus", "which services are down", "health check failing", "404 on health". Covers login, the JSON API, the check config, and how to tell a stale check from a dead service.
---

# bpp-go-health

## Overview

`health.go-plattform.at` is **Gatus** (Vue SPA; the HTML is empty, the data comes from the JSON
API). Basic auth: user `go`, password = the single line of `~/.health_go_plattform`. **Never
print the password**: pass it to curl on stdin (`-K -`), as `health.sh` does.

The checks live in `brokernet-traefik` → `gatus/config/config.yaml` (branch `main`, built into
the `brokernet-traefik/gatus` image). Groups are `development`, `staging` and `main`. Each
endpoint has a URL and conditions such as `[STATUS] == 200` and `[RESPONSE_TIME] < 400`.

## Quick Reference

| Need | Command |
|---|---|
| Failing endpoints | `bash ~/.claude/skills/bpp-go-health/health.sh` |
| All endpoints | `bash ~/.claude/skills/bpp-go-health/health.sh all` |
| One service: URL, conditions, history | `bash ~/.claude/skills/bpp-go-health/health.sh show austria` |
| Its check definition | `bash ~/.claude/skills/bpp-go-health/health.sh config austria` |
| Raw API | `GET /api/v1/endpoints/statuses?page=1&pageSize=100`, or `/api/v1/endpoints/<key>/statuses` |

The API keeps only the last 100 results per endpoint (about 100 min at a 1m interval). It
cannot tell you when a failure started further back than that.

## Diagnosing an unhealthy endpoint

1. **Run `show <name>`** to see the checked hostname and which condition failed.
2. **Probe the URL yourself**, and also the hostname the service actually routes:
   - Locate the repo via the `bpp-project-index` manifest, not a glob (`*.worktrees` dirs match globs).
   - `git fetch origin`, then take the Host rule from `infra/docker/compose/docker-compose.<stage>.yml` on `origin/<stage>`.
   - `curl -s -D - https://<host>/health` returns `server: Kestrel` when the app answers.
   - The body `404 page not found`, text/plain, with no Kestrel header, is **Traefik**: no router for that host.
   - Wildcard DNS sends unknown `*.go-plattform.at` names to Traefik too, so a 404 never proves the app is broken.
3. **Classify the result:**
   - **The checked host differs from the compose Host rule:** the check is stale (renamed host). Fix `config.yaml` in brokernet-traefik.
   - **The compose host also gives a Traefik 404:** the swarm service has no running task. The app likely crashes on startup.
     - Reproduce it with the built dll: `ASPNETCORE_ENVIRONMENT=<stage> dotnet bin/Release/net*/<Api>.dll` in a detached worktree of `origin/<stage>`.
     - `dotnet run` reads launchSettings and switches the environment to `local`, which hides the crash.
     - Look for `OptionsValidationException`, i.e. a required setting that is empty on that stage.
   - **Kestrel 5xx/503:** the app is up but its readiness check is failing (DB, Redis). Check `/health/ready`.
   - **`[RESPONSE_TIME]` only:** the threshold is too tight. Compare with the `Losen resp-time` commits in brokernet-traefik.
4. **Read logs:**
   - development and staging logs are in Loki (Grafana token `~/.grafana_telemetry_lipsum`, uid `lokiloki`, label `service_name`).
   - Many main services export no OTel. There, state that container logs need swarm access (`docker service ps/logs main_<service>`), which this machine does not have.

## Common Mistakes

- Extrapolating across stages. When the same check fails on dev, staging and main, probe each stage. A stale hostname on dev/staging and a crash-looping service on main can look identical in Gatus (all 404).
- Concluding "DNS" from failures. Gatus `errors` stays empty and `status=404` means DNS resolved fine. A DNS fault shows up as an error string or `status=0`.
- Trusting the Gatus hostname. Compose Host rules get renamed (e.g. `idaustria-connector.*` → `bpp.id-austria-connector.*`, BRO-1225) without anyone updating the check.
- Fetching `/` and parsing the HTML. It is an empty SPA shell; use the API.
- Echoing or `cat`-ing `~/.health_go_plattform`, or putting the password in a URL or `-u` argv.
