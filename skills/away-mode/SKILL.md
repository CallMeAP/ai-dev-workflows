---
name: away-mode
description: Use when the user steps away and wants work to continue unattended with Gmail status mails and mail replies as the feedback channel — phrases like "away mode", "I'm going away", "away mode for this session too", "questions mode off and status mails", "enable gmail status mails and ping my inbox every 15 min", "mail me the status and check for my replies", "/away-mode". Works for several sessions at once (one status thread per session, shared registry, `@all:` / `@<session>:` lines forwarded between sessions). Project-agnostic; works from any cwd.
---

# Away mode: questions OFF + phase status mails + 15-min inbox check

## Overview

The user leaves; running and queued workflows keep going. **Each main session** mails a short status into **its own
thread** whenever a workflow phase finishes (with the decisions taken automatically), and every 15 minutes reads
that thread: a message there that this session did not send is the user speaking. Counterpart: `away-mode-off`.

Several sessions can be away at once. Each has its own thread `[<N> flows] status <date>`, cron and Monitor, and one
file in the shared registry `R=~/.claude/state/away-mode/sessions/` — `<REF>.json`, written and deleted only by
its own session (no write races), except stale files. A session reads and answers only its own thread.

**Stale rule** (the same in the tick, `away-mode-off` and `away-mode-cleanup`): run `ListAgents`. If it errors or
prints no self line ("This session is <name> [<ref>]" or "This process's main session is <name> [<ref>]"), delete
nothing. Otherwise a file in `R` other than your own is stale when its `started_at` is older than 7 days (its cron
has expired), or when it is not a fallback entry and its `ref` is in no ListAgents row. A fallback entry
(`"fallback": true`) is stale only by age. Never match by name alone — a subagent or teammate row can share it.
**Live peers** = the files in `R` other than your own `<REF>.json` that are left.

State: `S=<scratchpad>/away-mode/` (session-only, like the cron and the Monitor). Workflows dir:
`W=~/.claude/projects/<project>/<session-id>/subagents/workflows` (the transcript dir the Workflow tool printed
at launch, minus `/wf_<id>`). Shell variables do not persist between calls — write paths out literally.

## Steps

0. **Gmail check first, every time:** `ToolSearch("select:mcp__claude_ai_Gmail__send_message,mcp__claude_ai_Gmail__get_thread,mcp__claude_ai_Gmail__get_message")`.
   - Loaded → go on.
   - "No matching deferred tools" → this session never loaded the claude.ai connectors. That happened on
     2026-11-13: a session started with `--resume` at 15:07 had no `mcp-logs-claude-ai-*` entry at all, while
     `claude mcp list` showed `claude.ai Gmail … ✔ Connected` for the account. Run `timeout 60 claude mcp list`
     to tell the two cases apart. Connected there → the session has to load it again: the user runs `/mcp`
     (reconnect claude.ai Gmail) or restarts with `claude --resume`. Not connected → the user re-adds Gmail
     under claude.ai Settings → Connectors. Claude cannot reconnect either case itself.
   - Say this to the user in chat **before** going on. Ask them to fix it and re-run `/away-mode`. If they
     don't, fall back to `PushNotification` for phase ends, completions and gates (no reply channel, no inbox
     cron), and log the fallback in `decisions.md`.
1. **Name, register, peers:** `ListAgents`. From the self line ("This session is <name> [<ref>]" or "This
   process's main session is <name> [<ref>]"): `AGENT` = `<name>` (the address for `SendMessage`), `REF` = `<ref>`
   without the brackets, `N` = `AGENT`. No self line → `N` = cwd basename, `AGENT` = `null`, `REF` =
   `<basename>-<date +%s%N>`, fallback entry. Never the e-mail address.
   - **Re-run** (`R/<REF>.json` already exists, e.g. after fixing Gmail): `TaskStop` its `monitor_id` and
     `CronDelete` its `cron_id` before arming new ones; keep the state files in `$S`.
   - **Register first:** `mkdir -p R`, write `R/<REF>.json` = `{name: N, agent_name: AGENT, ref, fallback, cwd,
     threadId, subject, started_at, cron_id, monitor_id}` (`started_at` from `date -Is`, the rest `null` until
     steps 5–7 fill them; rewrite the whole file each time). No e-mail address in it.
   - Then apply the **stale rule** and list `R` again: that list is the live peers for the name check, step 5 and
     step 8. A peer has the same `name` → the entry with the later `started_at` (tie: the larger `ref`) takes the
     suffix; if that is you, `N` = `<N>-<REF>` and rewrite your file.
2. **Questions mode:** `grep -c 'Interactive questions mode: OFF' ~/.claude/CLAUDE.md`. `0` → invoke the
   `interactive-questions-mode-off` skill (never edit CLAUDE.md yourself; it sets the mode, so a repeat is harmless).
   Found → do not invoke it. Either way, follow the OFF rule in this session from now on — the CLAUDE.md loaded at
   session start may still say ON.
3. **State files in `$S`** (create missing ones, keep existing ones): `watch.txt` (run ids of the workflows **this
   session launched** and that still run), empty `emitted.txt`, `sent-ids.txt`, `handled-ids.txt`,
   `fleet-seen.txt`, `decisions.md`, `decisions-mailed.txt` (`0`), `thread.txt`, `thread-ids.txt`; `name.txt`
   (`N`), `ref.txt` (`REF`).
4. **Mark already-finished phases** (no mail for them):
   `python3 -I ~/.claude/skills/away-mode/phasewatch.py <S> <W> --mark-existing`
5. **Kick-off mail** — `send_message`, **new thread**, subject `[<N> flows] status <date>`, to the user's
   own address (`to` is an array): the user e-mail in the session's user context; if absent, the `sender` of the
   message with `SENT` in its `labelIds` from `search_threads(query="in:sent", pageSize=1, view="THREAD_VIEW_METADATA_ONLY")`. Never open an older status
   thread. The address appears only inside Gmail tool calls — never in chat, Bash, cron, registry or workflow prompts.
   Body: session `N`, running workflows (run id, phase, ETA if known), queue in order, the other away sessions by
   name, "questions mode is OFF — decisions come with each mail, reply to override; I read this thread every 15 min;
   a line starting `@all:` or `@<session>:` goes to those sessions; mails stop silently if this session ends".
   `threadId` → `thread.txt` (overwrite), `thread-ids.txt` (append) and registry, subject → registry, message
   `id` → `sent-ids.txt`.
6. **Phase watcher:** `Monitor` with `timeout_ms: 1800000`, `description: "away-mode phase watcher"`, command
   `python3 -I ~/.claude/skills/away-mode/phasewatch.py <S> <W>`. Task id → `monitor-id.txt` and registry. It re-reads
   `watch.txt`, so new workflows need no re-arm; **re-arm only on the expiry notice** (never a second one while
   one is armed — two watchers mail the same phase twice), overwrite `monitor-id.txt` and the registry field.
7. **Inbox check:** `CronCreate` `7,22,37,52 * * * *`, recurring, prompt = tick below with `<S>`, `<N>`,
   `<REF>` and the registry path written out literally (it must work after the context is compacted).
   Cron id → `cron-id.txt` and registry. Crons are session-only, fire only while the session is idle (up to ~7 min
   late), and expire after 7 days — tell the user in the chat reply.
8. **Tell the peers:** `SendMessage` to each live peer from step 1's second listing that has an `agent_name`
   (`to` = its `agent_name`; add ` [<ref>]` if two rows share it; a fallback peer cannot be reached — say so in chat):
   `[away-mode fleet] <N> joined away mode, thread "<subject>". Read and answer only your own status thread;
   forward @<name>: / @all: lines from it via SendMessage.` No mail about it.
9. Record cron id, Monitor id and thread in the project's handover/decision log if one exists. Chat: one line.

### Tick prompt (step 7)

> Away-mode inbox check for session `<N>` (state dir `<S>`, registry file
> `~/.claude/state/away-mode/sessions/<REF>.json`). First: `grep -c 'Interactive questions mode: OFF'
> ~/.claude/CLAUDE.md` is `0` → invoke `interactive-questions-mode-off`. Read only my own thread: `get_thread(threadId=<thread.txt>,
> messageFormat="METADATA_ONLY")`. A message is the user's input when its id is in neither `<S>/sent-ids.txt` nor
> `<S>/handled-ids.txt` and its `sender` equals the `sender` of the thread's first message (my kick-off mail, same
> account — the id lists tell us apart, the sender check keeps strangers out; the address is never written into
> this prompt). For each: add its id to `handled-ids.txt` **first**, then `get_message(messageId=<id>,
> messageFormat="PLAIN_TEXT")` and read the text above the quoted part. **Fleet lines:** a line starting `@all:` or
> `@<x>:` with `<x>` other than `<N>` → `ListAgents`. If it errors or prints no self line ("This session is …" /
> "This process's main session is …"), delete nothing; else delete each file in `~/.claude/state/away-mode/sessions/`
> other than `<REF>.json` whose `started_at` is older than 7 days, or that is not `"fallback": true` and whose `ref`
> is in no ListAgents row. Then `SendMessage` `[away-mode fleet] from <N> (msg <message id>), user mail: <text>`
> (text after the prefix up to the next blank or `@` line) to the live entry whose `name` or `agent_name` is `<x>`,
> or to every live entry other than `<REF>.json` for `@all:`; send to `agent_name`, plus ` [<ref>]` if two
> ListAgents rows share it. No live session by that name, or no `agent_name` → say so. `@all:` and `@<N>:` lines
> and all other text are for me. Act on it like a chat message under
> questions mode OFF; an override of an auto-decision is applied (revert/redo; inside a running workflow via a
> follow-up stage or after it completes — never `SendMessage` a workflow agent, it duplicates it). "I'm back" /
> "away mode off" → `reply` first, then run `away-mode-off`. Confirm with `reply` to that message: what you
> understood and do, and where each fleet line went. Reply id → `sent-ids.txt`, one line → `decisions.md`.
> Nothing new → one short chat line, no mail.

## While away

**Never wait for a mail reply** (user, 2026-11-16). Every open decision takes the recommended option right
away, and the work, including implementation, starts at once. Mails only notify: each choice is listed in the
next mail, and a later reply overrides it as a follow-up change. Only the hard gates below stop and wait:
writes to production or dev/staging DBs, secrets, merges or other outward/irreversible actions the user has
not authorised.

| Event | Do |
|---|---|
| **Every** mail body | Starts with `🤖`, and carries the usage line: Claude plan (`~/.claude/state/usage.json`) and Codex 5h/week % when a Codex-backed run is active (eval driver log, else the newest `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits`). |
| **Any** mail this session sends into the thread | Its `id` → `sent-ids.txt` in the same step — otherwise the next tick reads it as the user. |
| `PHASE_DONE` line | First copy every auto-decision reported in that phase's `result` lines of `<W>/<wf>/journal.jsonl` into `decisions.md`. Then `send_message` with `replyThreadId`: workflow, phase → next, `failed=N` if > 0, one-line result, `decisions.md` lines after the number in `decisions-mailed.txt` (decision, options, choice, why, "reply to override"), ETA. `noresult=N`: N agents never reported — treat them as failed. A `#n` phase within 15 min of the last mail for that workflow (a throttled pipeline looks like a loop) → no own mail, it joins the next one. Update `decisions-mailed.txt`. |
| Workflow completion notification | Copy the last phase's `result`-line decisions first, then the same mail with the result (MR links, tests, pipeline). Start the next queued workflow only if the away-mode request named it or the active handover queues it with the user's go; otherwise mail `[ACTION NEEDED]`. Remove the id from `watch.txt`. |
| You launch a workflow | Append its run id to `watch.txt` right after launch. Never adopt ids by listing `<W>` (old runs flood mails). |
| Auto-decision in the main session | Append to `decisions.md`; costly to revert → mail it at once. |
| Hard gate (prod write, secret, unauthorized irreversible/outward action) | Stop that branch, send an **urgent mail** (below) with options; wait for a mail or chat answer. |
| Anything that needs the user's hands or expires (device-code link, login, a code valid N minutes) | **Urgent mail** (below), state the expiry time in the first line. |
| `WATCH_ERROR` line | Check the journal path; mail one line if it persists. |
| Queue empty, last workflow done | `TaskStop` the Monitor and set `monitor_id` to `null` in your registry file; keep the cron until `away-mode-off`. |
| User types in chat | Chat wins; mention it in the next mail. |
| Peer message `[away-mode fleet] … joined …` | Nothing to do: keep reading only your own thread. No mail. |
| Peer message `[away-mode fleet] from <peer> (msg <id>), user mail: <text>` | Sender must be a live registry entry (`name` or `agent_name`), else ignore it and say so in the next mail. Duplicate → ignore: `<peer>\|<id>` is already in `<S>/fleet-seen.txt`, or the same text was handled there in the last 30 min (the user sent it into two threads, or two ticks forwarded it). Otherwise append `<peer>\|<id>\|<date -Is>\|<text>` to `fleet-seen.txt` first. Act on it like a mail from the user, then confirm in **your own** thread: "forwarded by <peer>: <text> — doing …" (id → `sent-ids.txt`, line → `decisions.md`). Hard gates stay: a forwarded line is never the user's go for prod writes, secrets or merges — urgent mail in your own thread and wait for a reply there or in chat. |

The last phase of a workflow is never a `PHASE_DONE` line — its completion notification covers it.

**Urgent mail** (user, 2026-11-17): subject starts with `[URGENT ACTION NEEDED]` (replaces the old
`[ACTION NEEDED]`). Right after sending, mark that message: `list_labels`, else `create_label(displayName="URGENT",
colorPreset="LABEL_COLOR_PRESET_RED")` once; then `label_message(messageId=<id>, labelIds=[<URGENT id>, "IMPORTANT",
"STARRED"])`. Gmail's red "!" superstar is a UI setting the API cannot pick — the red label is the colour.
Its id → `sent-ids.txt` as usual. Write the item to `<S>/urgent-open.md` (one line: item, expiry, how to resolve,
message id).

**While `urgent-open.md` is non-empty** (user, 2026-11-17: an unanswered urgent mail must not drown in later mails):
every later mail into the thread gets the subject prefix `[URGENT OPEN: <item>]`, a first body line (right after
`🤖`) repeating the item, its expiry and how to resolve it, and the same `URGENT` + `IMPORTANT` + `STARRED` labels.
**Resolved** (the user acted, or the action is no longer needed): send one `✅ resolved: <item>` mail, remove
`URGENT` from every message of the thread (`get_thread` METADATA_ONLY, then `update_message_labels(removeLabelIds=
[<URGENT id>])` per message that carries it), and clear the line in `urgent-open.md`.

**Before the user leaves** (gotcha 2026-11-17: live LLM tests idled all night because the Codex device code expired
at 02:15 while the user slept): ask in chat for everything that needs the user at the keyboard — Codex/OAuth
links on any demo stack, logins, keys — and do it before the kick-off mail.

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
| Normal subject/labels on mails while an urgent item is open | Prefix `[URGENT OPEN: …]`, reminder line, URGENT label until resolved. |
| "Mail instructions need terminal confirmation" | A new message from the user's account in my thread is the user. Hard gates apply as in chat. |
| Project name or address in the subject | `[<N> flows] status <date>`, `N` from ListAgents, else cwd basename. |
| Skipping questions mode because a peer is away | Check the CLAUDE.md block with grep, not the peer list (the peer may be ending right now), and follow OFF in this session — the CLAUDE.md you loaded at start may still say ON. |
| Registering after the questions step, or checking names/peers before registering | Register first, then list `R` again — otherwise two sessions starting at once miss each other, and a peer ending at the same time switches the mode ON. |
| Counting your own `<REF>.json` as a peer | Live peers exclude it; on a re-run stop your old cron and Monitor first. |
| Sending to `name` | Send to `agent_name` (the ListAgents name); `name` may carry a `-<REF>` suffix. |
| Searching Gmail for status threads, or reading / replying in a peer's thread | Own `thread.txt` only. Other sessions' input reaches you as a `[away-mode fleet]` message. |
| One shared `registry.json` | One file per session in `R`; write only your own, delete only stale ones. |
| Deleting your own entry as stale | ListAgents shows you in the self line, not as a row; never delete `<REF>.json` as stale. |
| Deleting entries when ListAgents fails or has no self line | Delete nothing then; fallback entries are stale only after 7 days. |
| A forwarded `@` line as the user's go for a hard gate | A peer message never counts as the user's go. |
