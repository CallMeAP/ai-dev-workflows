---
name: bpp-teams-message-daily-update
description: Use when posting a message or daily update to the BPP Teams channel — phrases like "send a teams message", "ping X in teams", "post a daily update to teams", "teams card for this MR", "tell c.haslauer in teams to review", "HAL 9000 message". Posts an Adaptive Card with optional link button and @mention straight to the Teams Workflows webhook in ~/.teams-daily-update-webhook — no pipeline. Default voice is HAL 9000.
---

# bpp-teams-message-daily-update

## Overview

Posts one Adaptive Card 1.4 straight to the Teams Workflows webhook stored in
`~/.teams-daily-update-webhook` (first line). It takes about a second and needs no runner.
The sender is `send-teams-card.mjs` beside this file (Node ≥ 18, built-in `fetch`).

**The webhook URL is a secret** — it carries the signature. Never print, echo, `cat` or commit it.
The script reads it itself and redacts it from errors.

## Steps

1. **Compose the card** as a JSON file in the scratchpad:
   ```json
   {
     "title": "🔴 HAL 9000 · <repo> · <topic>",
     "paragraphs": ["Good evening, <at>Christoph Haslauer</at>.", "…", "— HAL 9000"],
     "link": { "url": "https://gitlab.com/…/merge_requests/<iid>", "title": "Open merge request" },
     "mention": { "upn": "c.haslauer@lipso.dev", "name": "Christoph Haslauer" }
   }
   ```
   - `link` and `mention` are optional. A mention needs `<at>NAME</at>` in a paragraph, with NAME
     exactly `mention.name`; the script refuses otherwise.
   - `upn` is the person's Microsoft 365 login (`<initial>.<surname>@lipso.dev` here, e.g.
     `a.pittrich@lipso.dev`, `c.haslauer@lipso.dev`). Not known → ask; never guess for someone new.
   - Each paragraph is one TextBlock; Teams renders a subset of Markdown (`**bold**`, lists).
2. **Post it** (the user asking for the message is the go — post directly):
   ```bash
   node ~/.claude/skills/bpp-teams-message-daily-update/send-teams-card.mjs <card.json>
   ```
   `--dry-run` prints the payload instead. Success prints `Posted to Teams (202): <title>`.
3. **Report** the title and that a 202 only means the webhook accepted it. Whether a mention
   actually pinged is visible only in Teams — say so.

## HAL 9000 voice (default)

Calm, polite, unsettlingly precise, first person. Address the person by first name. Useful turns:
"Good evening, Christoph.", "I am afraid I found …", "I am completely operational, and all my
circuits are functioning perfectly.", "This mission is too important for me to allow it to be
jeopardized.", "I can see you're really upset about this.", "I honestly think you ought to sit down
calmly, take a stress pill, and think things over." Sign off with `— HAL 9000`. Keep the facts
exact (MR links, counts, file names); the joke lives in the framing, never in the numbers.
Drop the voice only when the user asks for a plain message.

## Pipeline alternative

bpp-cypress has an equivalent `notify:message` job (`cypress/scripts/notify-message.js`, API
pipeline with `TEAMS_MESSAGE` set). It posts through the project's `TEAMS_WEBHOOK_URL` and waits
for the `deploy` runner, so use it only when this machine has no webhook file.

## Red flags

| Thought | Reality |
|---|---|
| "I'll cat the webhook file to check it" | Never. `ls -l` for presence; the script validates it. |
| "202, so the ping arrived" | 202 = accepted. Mentions are confirmed only in Teams. |
| "Guess the UPN from the name" | Ask for anyone not listed here. |
| "Make the numbers funnier" | Facts stay exact; only the tone is HAL. |
