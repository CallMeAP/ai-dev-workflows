// One chat case as a new session on the demo agent: POST /api/agent-session {title, backofficeGroupId}, then every turn over
// SignalR long polling. A write card (ReceiveConfirmationRequest) ends the turn as "card"; the case's "decide" list answers the
// cards in order over REST (POST .../pending/{id}/decision), and the decision's finalText is recorded.
// Usage: node chat-case.mjs <cookie-jar> <case.json> <out.json>     env AGENT_URL, SELFTEST_TAG (title prefix), SELFTEST_RUN_ID ({{RUN}}),
//   SELFTEST_GROUP_<name> (repo fixtures' session.group)
// Never prints the cookie.
import { readFileSync, writeFileSync } from 'node:fs';
const [jar, caseFile, outFile] = process.argv.slice(2);
const base = process.env.AGENT_URL ?? 'http://localhost:6253';
const run = process.env.SELFTEST_RUN_ID ?? 'run';
const sub = s => (s ?? '').replaceAll('{{RUN}}', run);
const c = JSON.parse(readFileSync(caseFile, 'utf8'));
const line = readFileSync(jar, 'utf8').split('\n').find(l => l.includes('brokernet-auth-token'));
if (!line) { console.error('no auth cookie in jar'); process.exit(4); }
const f = line.split('\t'); const H = { cookie: `${f[5]}=${f[6]}` };
const RS = '\x1e'; const t0 = Date.now();
// group: the case's groupId, or a repo fixture's session.group name ("G1") resolved through env SELFTEST_GROUP_<name>
const gname = c.session?.group ?? null;
const groupId = c.groupId ?? (gname ? process.env[`SELFTEST_GROUP_${gname}`] ?? null : null);
const res = { id: c.id, suite: c.suite ?? null, startedAt: new Date().toISOString(), group: groupId, turns: [], cards: [], decisions: [] };
const save = () => writeFileSync(outFile, JSON.stringify(res, null, 1));
if (gname && !groupId) { res.error = `session.group ${gname}: set SELFTEST_GROUP_${gname} in selftest.env`; save(); process.exit(4); }
const s = await fetch(`${base}/api/agent-session`, { method: 'POST', headers: { ...H, 'content-type': 'application/json' },
  body: JSON.stringify({ title: `${process.env.SELFTEST_TAG ?? 'selftest'} ${c.id}`, backofficeGroupId: groupId }) });
const sbody = await s.text(); res.sessionStatus = s.status;
if (s.status !== 201 && s.status !== 200) { res.error = sbody.slice(0, 500); save(); process.exit(4); }
res.sessionId = JSON.parse(sbody).id;
const n = await (await fetch(`${base}/agent-hub/negotiate?negotiateVersion=1`, { method: 'POST', headers: H })).json();
const url = `${base}/agent-hub?id=${encodeURIComponent(n.connectionToken)}`;
await fetch(url, { method: 'POST', headers: H, body: JSON.stringify({ protocol: 'json', version: 1 }) + RS });
const END = ['ReceiveTurnDone', 'ReceiveTurnError', 'ReceiveError', 'ReceiveTurnReauthRequired', 'ReceiveCancelled', 'ReceiveConfirmationRequest'];
let pending = null; const events = [];
(async () => {
  for (;;) {
    const r = await fetch(url, { headers: H }); if (r.status !== 200) { events.push(['poll', r.status]); break; }
    for (const m of (await r.text()).split(RS).filter(Boolean)) {
      const o = JSON.parse(m);
      if (o.type !== 1 || o.target === 'ReceiveTurnToken') continue;
      events.push([((Date.now() - t0) / 1000).toFixed(1), o.target, JSON.stringify(o.arguments).slice(0, 600)]);
      if (o.target === 'ReceiveConfirmationRequest') res.cards.push(o.arguments[0]);
      if (END.includes(o.target) && pending) { const p = pending; pending = null; p({ target: o.target, arg: o.arguments[0] }); }
    }
  }
})();
// garbage suite: "chatTextRepeat": n sends chatText n times in one message (huge input)
const first = c.chatTextRepeat ? Array(c.chatTextRepeat).fill(c.chatText).join(' ') : c.chatText;
const texts = [first, ...(c.followUps ?? []).map(x => x.text)].map(sub);
const switches = [null, ...(c.followUps ?? []).map(x => x.switchTo ?? null)];
const decide = [...(c.decide ?? [])];
let inv = 1;
for (const [k, text] of texts.entries()) {
  // model-switch suite: {"switchTo": {"provider": "openai-codex", "model": "gpt-6-astra"}} on a follow-up switches the session first
  // (PATCH /api/agent-session/{id}/provider, only on builds that have the mid-session switch)
  if (switches[k]) {
    const r = await fetch(`${base}/api/agent-session/${res.sessionId}/provider`, { method: 'PATCH', headers: { ...H, 'content-type': 'application/json' },
      body: JSON.stringify(switches[k]) });
    res.switches = [...(res.switches ?? []), { before: k, http: r.status, body: (await r.text()).slice(0, 300) }];
    if (r.status !== 200) break;
  }
  const ts = Date.now();
  const done = new Promise(r => { pending = r; });
  await fetch(url, { method: 'POST', headers: H, body: JSON.stringify({ type: 1, invocationId: String(inv++), target: 'SendMessage', arguments: [res.sessionId, text] }) + RS });
  const out = await Promise.race([done, new Promise(r => setTimeout(() => r({ target: 'TIMEOUT' }), 300000))]);
  const end = out.target === 'ReceiveConfirmationRequest' ? 'card' : out.target;
  res.turns.push({ text, end, finalText: out.arg?.finalText ?? null, pendingId: out.arg?.pendingId ?? null,
    error: ['ReceiveTurnDone', 'ReceiveConfirmationRequest'].includes(out.target) ? null : JSON.stringify(out.arg ?? null).slice(0, 500), seconds: (Date.now() - ts) / 1000 });
  // answer every card of this turn that the case has a decision for; the continuation runs server-side and its text comes back in the body
  while (end === 'card' && decide.length && res.cards.length > res.decisions.length) {
    const card = res.cards[res.decisions.length]; const d = decide.shift();
    const r = await fetch(`${base}/api/agent-session/${res.sessionId}/pending/${card.pendingId}/decision`, { method: 'POST',
      headers: { ...H, 'content-type': 'application/json' }, body: JSON.stringify({ approved: !!d.approve, reason: d.reason ?? null }) });
    const body = await r.text(); let j = null; try { j = JSON.parse(body); } catch { /* not json */ }
    res.decisions.push({ pendingId: card.pendingId, approve: !!d.approve, http: r.status, status: j?.status ?? null, finalText: j?.finalText ?? null, raw: j ? null : body.slice(0, 300) });
    await new Promise(r2 => setTimeout(r2, 1500));
  }
  if (!['ReceiveTurnDone', 'ReceiveConfirmationRequest'].includes(out.target)) break;
}
res.events = events; save();
await fetch(url, { method: 'DELETE', headers: H });
process.exit(0);
