---
name: bpp-start-local-stack
description: Use when user wants to boot the local BPP service stack required by integration tests — phrases like "start local stack", "start backend", "boot local env", "spin up bpp services", "start bpp stack". Launches `start_local_stack.sh` in the background and polls `status` on a bounded 60s timer so a stalled health-ping can't idle integration runs.
---

# bpp-start-local-stack

## Overview

Starts the local BPP service stack (bpp-auth, bpp-file, bpp-mail, bpp-js-report-connector, bpp-push) needed for integration tests. Logs land in `/tmp/bpp-local-stack/`. Normal cold start is ~15s.

## When to Use

- "start local stack", "start backend", "boot local env", "spin up bpp", "start bpp services"
- Before running BPP integration tests that hit the local stack

## Why background + bounded poll

`start_local_stack.sh start` launches the services (they nohup-survive), then **blocks in a per-service health-wait loop — up to 180s each, ×5 services**. If a health ping false-negatives during warmup, running it in the foreground stalls the agent for many minutes (observed: integration runs idling >1h on a stack that was actually up in ~15s). So: launch start in the background and treat `status` as the source of truth on a bounded 60s timer. A flaky ping can no longer hang the run.

## Steps

1. Verify `~/Entwicklung/bpp/bpp-backend/dev/apittrich/` exists. Abort with a clear error if not.
2. Run the launch-and-poll command below (one Bash call, returns within ~60s):

   ```bash
   STACK="$HOME/Entwicklung/bpp/bpp-backend/dev/apittrich/start_local_stack.sh"
   mkdir -p /tmp/bpp-local-stack

   # Fast path: stack already healthy?
   status=$("$STACK" status)
   if ! grep -q DOWN <<<"$status"; then
       echo "$status"; echo "STACK_READY"; exit 0
   fi

   # Launch in the background so we never inherit the script's own blocking
   # per-service health-wait loop (up to 180s × 5). Services nohup-survive.
   nohup "$STACK" start >/tmp/bpp-local-stack/_skill-start.log 2>&1 &

   # `status` is the source of truth. First check ~20s, then every 10s, cap 60s.
   ready=false
   for delay in 20 10 10 10 10; do
       sleep "$delay"
       status=$("$STACK" status)
       if ! grep -q DOWN <<<"$status"; then ready=true; break; fi
   done

   echo "$status"
   if [[ "$ready" == true ]]; then
       echo "STACK_READY"
   else
       echo "STACK_NOT_READY — DOWN services listed above; see /tmp/bpp-local-stack/<service>.log"
   fi
   ```

3. **`STACK_READY`** → report which services are UP, proceed.
4. **`STACK_NOT_READY`** → report the DOWN services + their log paths and **stop** (do not start integration tests — they would fail without the stack). The background launch keeps running; the user can re-invoke once the logs are addressed.

## Notes

- Script is idempotent — already-up services are skipped, so re-invoking is safe.
- Never wait on the background `start` command to "finish" — its internal wait loop can run up to 15min. `status` is the only readiness signal.
- For a DOWN service, point the user at `/tmp/bpp-local-stack/{service}.log`.
