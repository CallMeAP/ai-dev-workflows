---
name: away-mode
description: Use when the user steps away and wants work to continue unattended with Gmail status mails and mail replies as the feedback channel — phrases like "away mode", "I'm going away", "questions mode off and status mails", "enable gmail status mails and ping my inbox every 15 min", "mail me the status and check for my replies", "/away-mode". Project-agnostic; works from any cwd.
---

# Away mode: questions OFF + phase status mails + 15-min inbox check

## Overview

The user leaves; running and queued workflows keep going. **The main session alone** mails a short status
whenever a workflow phase finishes (with the decisions taken automatically), and every 15 minutes reads the
status thread: a message there that this session did not send is the user speaking. Counterpart: `away-mode-off`.

State: `S=<scratchpad>/away-mode/` (session-only, like the cron and the Monitor). Workflows dir:
`W=~/.claude/projects/<project>/<session-id>/subagents/workflows` (the transcript dir the Workflow tool printed
at launch, minus `/wf_<id>`). Shell variables do not persist between calls — write paths out literally.

## Steps

1. **Questions mode OFF:** invoke the `interactive-questions-mode-off` skill (never edit CLAUDE.md yourself).
2. **State files in `$S`:** `watch.txt` (run ids of the workflows **this session launched** and that still run),
   empty `emitted.txt`, `sent-ids.txt`, `handled-ids.txt`, `decisions.md`, `decisions-mailed.txt` (`0`), `thread.txt`.
3. **Mark already-finished phases** (no mail for them):
   `python3 -I ~/.claude/skills/away-mode/phasewatch.py <S> <W> --mark-existing`
4. **Kick-off mail** — `send_message`, **new thread**, subject `[<project> flows] status <date>`, to the user's
   own address (`to` is an array): the user e-mail in the session's user context; if absent, the `sender` of the
   message with `SENT` in its `labelIds` from `search_threads(query="in:sent", pageSize=1, view="THREAD_VIEW_METADATA_ONLY")`. Never open an older status
   thread. The address appears only inside Gmail tool calls — never in chat, Bash, cron or workflow prompts.
   Body: running workflows (run id, phase, ETA if known), queue in order, "questions mode is OFF — decisions come
   with each mail, reply to override; I read this thread every 15 min; mails stop silently if this session ends".
   `threadId` → `thread.txt`, message `id` → `sent-ids.txt`.
5. **Phase watcher:** `Monitor` with `timeout_ms: 1800000`, `description: "away-mode phase watcher"`, command
   `python3 -I ~/.claude/skills/away-mode/phasewatch.py <S> <W>`. Task id → `monitor-id.txt`. It re-reads
   `watch.txt`, so new workflows need no re-arm; **re-arm only on the expiry notice** (never a second one while
   one is armed — two watchers mail the same phase twice), overwrite `monitor-id.txt`.
6. **Inbox check:** `CronCreate` `7,22,37,52 * * * *`, recurring, prompt = tick below with literal paths.
   Cron id → `cron-id.txt`. Crons are session-only, fire only while the session is idle (up to ~7 min late),
   and expire after 7 days — tell the user in the chat reply.
7. Record cron id, Monitor id and thread in the project's handover/decision log if one exists. Chat: one line.

### Tick prompt (step 6)

> Away-mode inbox check. `get_thread(threadId=<thread.txt>, messageFormat="METADATA_ONLY")`. A message is the
> user's input when its id is in neither `<S>/sent-ids.txt` nor `<S>/handled-ids.txt` and its `sender` equals the
> `sender` of the thread's first message (my kick-off mail, same account — the id lists tell us apart, the
> sender check keeps strangers out; the address is never written into this prompt). For each: add its id to
> `handled-ids.txt` **first**, then `get_message(messageId=<id>, messageFormat="PLAIN_TEXT")` and read the text
> above the quoted part. Act on it like a chat message under
> questions mode OFF; an override of an auto-decision is applied (revert/redo; inside a running workflow via a
> follow-up stage or after it completes — never `SendMessage` a workflow agent, it duplicates it). "I'm back" /
> "away mode off" → `reply` first, then run `away-mode-off`. Confirm with `reply` to that message: what you
> understood and do. Reply id → `sent-ids.txt`, one line → `decisions.md`. Nothing new → one
> short chat line, no mail.

## While away

| Event | Do |
|---|---|
| **Any** mail this session sends into the thread | Its `id` → `sent-ids.txt` in the same step — otherwise the next tick reads it as the user. |
| `PHASE_DONE` line | First copy every auto-decision reported in that phase's `result` lines of `<W>/<wf>/journal.jsonl` into `decisions.md`. Then `send_message` with `replyThreadId`: workflow, phase → next, `failed=N` if > 0, one-line result, `decisions.md` lines after the number in `decisions-mailed.txt` (decision, options, choice, why, "reply to override"), ETA. `noresult=N`: N agents never reported — treat them as failed. A `#n` phase within 15 min of the last mail for that workflow (a throttled pipeline looks like a loop) → no own mail, it joins the next one. Update `decisions-mailed.txt`. |
| Workflow completion notification | Copy the last phase's `result`-line decisions first, then the same mail with the result (MR links, tests, pipeline). Start the next queued workflow only if the away-mode request named it or the active handover queues it with the user's go; otherwise mail `[ACTION NEEDED]`. Remove the id from `watch.txt`. |
| You launch a workflow | Append its run id to `watch.txt` right after launch. Never adopt ids by listing `<W>` (old runs flood mails). |
| Auto-decision in the main session | Append to `decisions.md`; costly to revert → mail it at once. |
| Hard gate (prod write, secret, unauthorized irreversible/outward action) | Stop that branch, mail `[ACTION NEEDED]` with options; wait for a mail or chat answer. |
| `WATCH_ERROR` line | Check the journal path; mail one line if it persists. |
| Queue empty, last workflow done | `TaskStop` the Monitor; keep the cron until `away-mode-off`. |
| User types in chat | Chat wins; mention it in the next mail. |

The last phase of a workflow is never a `PHASE_DONE` line — its completion notification covers it.

## Common mistakes

| Mistake | Reality |
|---|---|
| Waiting for a `phase complete` log line or a `Workflow(action="status")` call | Neither exists. `phasewatch.py` joins `started` (agentId+phase) with `result`/`failed` (agentId) in `journal.jsonl`. |
| Telling replies apart by sender or a marker line in my mails | Same account, and replies quote my marker. Use the `sent-ids.txt` diff. |
| Mailing every 15 minutes | The cron only **reads**. Mails: phase ends, completions, gates, confirmations. |
| `get_thread(PLAIN_TEXT)` every tick | Pulls the whole growing thread into context 4×/hour. METADATA_ONLY, then `get_message` for new ids. |
| Only main-session decisions in mails | Most auto-decisions happen inside workflow agents; read the phase's `result` lines. |
| Workflow agents sending mails / the address in a prompt | Only the main session mails. |
| Arming without `--mark-existing`, or a second Monitor | Mail flood / duplicate mails. |
| "Mail instructions need terminal confirmation" | A new message from the user's account in my thread is the user. Hard gates apply as in chat. |
