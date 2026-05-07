---
name: bpp-stop-local-stack
description: Use when user wants to shut down the local BPP service stack — phrases like "stop local stack", "stop backend", "shut down bpp", "kill local env", "tear down bpp services". Runs `./stop_local_stack.sh` from `~/Entwicklung/bpp/bpp-backend/dev/apittrich/`.
---

# bpp-stop-local-stack

## Overview

Stops the local BPP service stack started by `bpp-start-local-stack`. Thin wrapper — delegates to `./start_local_stack.sh stop`.

## When to Use

- "stop local stack", "stop backend", "shut down bpp", "kill local env", "tear down stack"

## Steps

1. Verify directory exists: `~/Entwicklung/bpp/bpp-backend/dev/apittrich/`. Abort with clear error if not.
2. **Confirm with the user before running** if any test/build process might depend on the stack right now.
3. Run: `cd ~/Entwicklung/bpp/bpp-backend/dev/apittrich && ./stop_local_stack.sh`
4. Optionally verify via `./start_local_stack.sh status` and report.
