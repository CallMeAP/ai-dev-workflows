---
name: bpp-start-local-stack
description: Use when user wants to boot the local BPP service stack required by integration tests — phrases like "start local stack", "start backend", "boot local env", "spin up bpp services", "start bpp stack". Runs `./start_local_stack.sh` from `~/Entwicklung/bpp/bpp-backend/dev/apittrich/` and verifies via `status` afterward.
---

# bpp-start-local-stack

## Overview

Starts the local BPP service stack (bpp-auth, bpp-file, bpp-mail, bpp-js-report-connector, bpp-push) needed for integration tests. Logs land in `/tmp/bpp-local-stack/`.

## When to Use

- "start local stack", "start backend", "boot local env", "spin up bpp", "start bpp services"
- Before running BPP integration tests that hit the local stack

## Steps

1. Verify directory exists: `~/Entwicklung/bpp/bpp-backend/dev/apittrich/`. Abort with clear error if not.
2. Run: `cd ~/Entwicklung/bpp/bpp-backend/dev/apittrich && ./start_local_stack.sh`
3. After it returns, verify by running: `./start_local_stack.sh status`
4. Report which services are UP / DOWN to the user.

## Notes

- Script is idempotent — already-up services are skipped.
- If a service fails to start, point the user at its log file under `/tmp/bpp-local-stack/{service}.log`.
