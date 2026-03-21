# Shared Dispatcher Rules

## Heartbeat

- **Dispatcher:** Print a short status message (e.g. `"⏳ Waiting for Implementer..."`) every ~15 seconds while waiting for sub-agents. Never go silent.
- **Sub-agents:** Print a short progress message (e.g. `"Working on: implementing service method..."`) every ~30 seconds during long-running tasks.

## Stale Agent Recovery

The Dispatcher must never manually ping a sub-agent and wait passively. Follow this escalation ladder automatically:

1. **After ~45 seconds of silence** — check `git diff` for file changes by the sub-agent.
   * If changes detected → continue waiting, reset timer.
   * If no changes → proceed to step 2.
2. **Send one message** to the sub-agent: `"Status?"` — wait ~20 seconds for a response.
   * If it responds → continue waiting, reset timer.
   * If no response → proceed to step 3.
3. **Terminate and respawn** — kill the stale agent and spawn a fresh one with the same task. Do NOT ping again or wait further.
   * **Max respawns per task: 2.** If the second respawn also stalls, the Dispatcher must apply the fix directly (for write agents) or skip and log the issue (for read-only agents).
