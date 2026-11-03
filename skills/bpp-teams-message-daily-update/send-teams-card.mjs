#!/usr/bin/env node
/*
 * Posts one Adaptive Card (1.4) straight to a Teams Workflows webhook — no pipeline.
 *
 *   node send-teams-card.mjs <card.json> [--dry-run]
 *
 * card.json:
 *   {
 *     "title": "🔴 HAL 9000 · bpp-shared · review requested",
 *     "paragraphs": ["Good evening, <at>Christoph Haslauer</at>.", "I am afraid ..."],
 *     "link": { "url": "https://gitlab.com/...", "title": "Open merge request" },   // optional
 *     "mention": { "upn": "c.haslauer@lipso.dev", "name": "Christoph Haslauer" }  // optional
 *   }
 *
 * A mention needs <at>NAME</at> in a paragraph, with NAME equal to mention.name.
 * Webhook URL: $TEAMS_WEBHOOK_FILE, default ~/.teams-daily-update-webhook (first line). The URL
 * carries the webhook signature: it is never printed, and errors are redacted.
 */
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const [specPath, flag] = process.argv.slice(2);
if (!specPath) {
  console.error('usage: send-teams-card.mjs <card.json> [--dry-run]');
  process.exit(2);
}
const spec = JSON.parse(readFileSync(specPath, 'utf8'));
const paragraphs = (spec.paragraphs ?? []).map((p) => String(p).trim()).filter(Boolean);
if (!spec.title || paragraphs.length === 0) {
  console.error('card.json needs a title and at least one paragraph');
  process.exit(2);
}
const mention = spec.mention?.upn && spec.mention?.name ? spec.mention : null;
if (mention && !paragraphs.some((p) => p.includes(`<at>${mention.name}</at>`))) {
  console.error(`mention set, but no paragraph contains <at>${mention.name}</at>`);
  process.exit(2);
}

const text = (t, extra = {}) => ({ type: 'TextBlock', text: t, wrap: true, ...extra });
const card = {
  type: 'AdaptiveCard',
  $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
  version: '1.4',
  msteams: { width: 'Full' },
  body: [text(spec.title, { weight: 'Bolder', size: 'Medium' }), ...paragraphs.map((p) => text(p, { spacing: 'Medium' }))],
  actions: spec.link?.url ? [{ type: 'Action.OpenUrl', title: spec.link.title || 'Open', url: spec.link.url }] : [],
};
if (mention) {
  card.msteams.entities = [{ type: 'mention', text: `<at>${mention.name}</at>`, mentioned: { id: mention.upn, name: mention.name } }];
}
const payload = { type: 'message', attachments: [{ contentType: 'application/vnd.microsoft.card.adaptive', contentUrl: null, content: card }] };

if (flag === '--dry-run') {
  console.log(JSON.stringify(payload, null, 2));
  process.exit(0);
}

const file = process.env.TEAMS_WEBHOOK_FILE || join(homedir(), '.teams-daily-update-webhook');
const webhook = readFileSync(file, 'utf8').split('\n')[0].trim();
if (!/^https:\/\//.test(webhook)) {
  console.error(`no https URL on the first line of ${file}`);
  process.exit(1);
}
const redact = (s) => String(s).split(webhook).join('[REDACTED]');

try {
  const res = await fetch(webhook, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) });
  if (!res.ok) {
    console.error(`Teams webhook answered ${res.status}: ${redact(await res.text())}`);
    process.exit(1);
  }
  console.log(`Posted to Teams (${res.status}): ${spec.title}`);
} catch (err) {
  console.error(`Teams webhook not reached: ${err.cause?.code ?? err.name}`);
  process.exit(1);
}
