---
name: bpp-status-local-stack
description: Use when user wants to check the health of the local BPP service stack — phrases like "status of local stack", "is bpp up", "check bpp services", "stack health", "are services running". Runs `./start_local_stack.sh status` from `~/Entwicklung/bpp/bpp-backend/dev/apittrich/`.
---

# bpp-status-local-stack

## Overview

Reports health (UP/DOWN) of each service in the local BPP stack: bpp-auth, bpp-file, bpp-mail, bpp-js-report-connector, bpp-push.

## When to Use

- "status of local stack", "is bpp up", "check stack", "stack health", "are services running"
- After a start/stop to verify state
- Before running integration tests, to confirm prerequisites

## Steps

1. Verify directory exists: `~/Entwicklung/bpp/bpp-backend/dev/apittrich/`. Abort with clear error if not.
2. Run: `cd ~/Entwicklung/bpp/bpp-backend/dev/apittrich && ./start_local_stack.sh status`
3. Report per-service UP/DOWN to the user.
