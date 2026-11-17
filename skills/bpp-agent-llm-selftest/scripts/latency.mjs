// Chat latency after idle gaps against the demo agent only (env from selftest.env via latency-run.sh / latency-resume.sh).
// Usage:
//   node latency.mjs prime  <bucket> [sessions=3]   log in, start <sessions> new chats ("+ Neue Sitzung" = first send creates the session,
//                                                   title = first text, as the Cockpit does), ask the 3 prime questions in each
//   node latency.mjs resume <bucket>                log in again, ask the 3 resume questions in every chat of <bucket>
// Appends one JSON line per turn to $LAT_DIR/results.jsonl; keeps the chats of a bucket in $LAT_DIR/sessions-<bucket>.json.
// Client timings: send -> ReceiveTurnStarted, -> first ReceiveTurnToken, -> first ReceiveToolActivity, -> ReceiveTurnDone.
// The server phases come from agent_turn.tool_call_log (analyze.py). Prints no cookie, no password.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = process.env.LAT_DIR ?? dirname(fileURLToPath(import.meta.url));
const require = createRequire(join(process.env.NODE_MODULES_FROM, 'package.json'));
const WebSocket = require('ws');
const RS = '\x1e';

const AUTH = process.env.AUTH_URL ?? 'http://localhost:6240';
const AGENT = process.env.AGENT_URL ?? 'http://localhost:6253';
const EMAIL = process.env.SELFTEST_LOGIN_EMAIL;
if (!EMAIL) { console.error('set SELFTEST_LOGIN_EMAIL'); process.exit(2); }
const PASSWORD = process.env.SELFTEST_LOGIN_PASSWORD_FILE ? readFileSync(process.env.SELFTEST_LOGIN_PASSWORD_FILE, 'utf8').trim() : 'Start123$'; // fleet default dev password
const RESULTS = process.env.LAT_RESULTS ?? join(HERE, 'results.jsonl');
const TURN_TIMEOUT_MS = 240000;
// Codex stop before every turn (exit 3, recorded as skipped so the report shows the gap)
const SCRIPTS = dirname(fileURLToPath(import.meta.url));
function quotaGuard(bucket, mode) {
  try { execFileSync('bash', [join(SCRIPTS, 'quota-guard.sh')], { stdio: ['ignore', 'ignore', 'inherit'] }); }
  catch { appendFileSync(RESULTS, JSON.stringify({ bucket, phase: mode, skipped: 'codex quota stop' }) + '\n'); console.error('QUOTA STOP'); process.exit(3); }
}

const QUESTIONS = {
  prime: ['Wie viele Kunden habe ich?', 'Suche den Kunden Feldhofner.', 'Welche Verträge hat Lena Feldhofner?'],
  resume: ['Wie viele Kunden habe ich?', 'Suche den Kunden Zehetgruber.', 'Welche Verträge hat Georg Zehetgruber?'],
};

const [mode, bucket, nArg] = process.argv.slice(2);
if (!['prime', 'resume'].includes(mode) || !bucket) { console.error('usage: latency.mjs prime|resume <bucket> [sessions]'); process.exit(2); }
const sessionsFile = join(HERE, `sessions-${bucket}.json`);

async function login() {
  const t = Date.now();
  const r = await fetch(`${AUTH}/api/auth-go-user/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ loginEmail: EMAIL, password: PASSWORD }),
  });
  if (!r.ok) throw new Error(`login ${r.status}`);
  const set = r.headers.getSetCookie().find(c => c.startsWith('brokernet-auth-token'));
  if (!set) throw new Error('login: no auth cookie');
  return { cookie: set.split(';')[0], loginMs: Date.now() - t };
}

// Minimal SignalR JSON-protocol client over WebSockets (the Cockpit's default transport), with the auth cookie as a header.
async function connect(cookie) {
  const t = Date.now();
  const n = await (await fetch(`${AGENT}/agent-hub/negotiate?negotiateVersion=1`, { method: 'POST', headers: { cookie } })).json();
  const ws = new WebSocket(`${AGENT.replace('http', 'ws')}/agent-hub?id=${encodeURIComponent(n.connectionToken)}`, { headers: { cookie } });
  const handlers = new Map(); let inv = 0; const pending = new Map();
  await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  let handshake;
  const shaken = new Promise(res => { handshake = res; });
  ws.on('message', data => {
    for (const m of data.toString().split(RS).filter(Boolean)) {
      const o = JSON.parse(m);
      if (o.type === undefined) { handshake(o); continue; }
      if (o.type === 1) for (const h of handlers.get(o.target) ?? []) h(o.arguments?.[0]);
      else if (o.type === 3 && pending.has(o.invocationId)) { const p = pending.get(o.invocationId); pending.delete(o.invocationId); o.error ? p.rej(new Error(o.error)) : p.res(o.result); }
      else if (o.type === 6) ws.send(JSON.stringify({ type: 6 }) + RS);
      else if (o.type === 7) for (const h of handlers.get('ReceiveError') ?? []) h({ close: o.error ?? 'closed' });
    }
  });
  ws.send(JSON.stringify({ protocol: 'json', version: 1 }) + RS);
  const hs = await shaken; if (hs.error) throw new Error(`handshake ${hs.error}`);
  const conn = {
    on: (k, h) => handlers.set(k, [...(handlers.get(k) ?? []), h]),
    off: (k, h) => handlers.set(k, (handlers.get(k) ?? []).filter(x => x !== h)),
    invoke: (target, ...args) => new Promise((res, rej) => {
      const id = String(++inv); pending.set(id, { res, rej });
      ws.send(JSON.stringify({ type: 1, invocationId: id, target, arguments: args }) + RS);
    }),
    stop: async () => ws.close(),
  };
  return { conn, connectMs: Date.now() - t, transport: 'WebSockets' };
}

// One turn: sends, waits for the end event, returns the client timings.
function turn(conn, sessionId, text) {
  return new Promise(resolve => {
    const t0 = performance.now();
    const ms = () => Math.round(performance.now() - t0);
    const rec = { turnId: null, startedMs: null, firstTokenMs: null, firstActivityMs: null, doneMs: null, end: null, tokens: 0, activities: 0, finalTextLen: null, error: null };
    const mine = a => !rec.turnId || !a?.turnId || a.turnId === rec.turnId;
    const handlers = {
      ReceiveTurnStarted: a => { if (rec.turnId) return; rec.turnId = a?.turnId ?? null; rec.startedMs = ms(); },
      ReceiveTurnToken: a => { if (!mine(a)) return; rec.tokens++; rec.firstTokenMs ??= ms(); },
      ReceiveToolActivity: a => { if (!mine(a)) return; rec.activities++; rec.firstActivityMs ??= ms(); },
      ReceiveTurnDone: a => { if (!mine(a)) return; rec.finalTextLen = (a?.finalText ?? '').length; finish('done'); },
      ReceiveTurnError: a => { if (!mine(a)) return; rec.error = JSON.stringify(a).slice(0, 300); finish('turn_error'); },
      ReceiveError: a => { rec.error = JSON.stringify(a).slice(0, 300); finish('error'); },
      ReceiveTurnReauthRequired: () => finish('reauth'),
      ReceiveConfirmationRequest: () => finish('confirmation'),
      ReceiveCancelled: () => finish('cancelled'),
    };
    let timer;
    function finish(end) {
      if (rec.end) return;
      rec.end = end; rec.doneMs = ms(); clearTimeout(timer);
      for (const [k, h] of Object.entries(handlers)) conn.off(k, h);
      resolve(rec);
    }
    for (const [k, h] of Object.entries(handlers)) conn.on(k, h);
    timer = setTimeout(() => finish('timeout'), TURN_TIMEOUT_MS);
    conn.invoke('SendMessage', sessionId, text).catch(e => { rec.error = String(e).slice(0, 300); finish('invoke_error'); });
  });
}

const { cookie, loginMs } = await login();
const H = { cookie, 'content-type': 'application/json' };
const groups = await (await fetch(`${AGENT}/api/backoffice-groups`, { headers: H })).json().catch(() => []);
const groupId = Array.isArray(groups) && groups.length === 1 ? (groups[0]?.metadata?.id ?? groups[0]?.id ?? null) : null;

let sessions;
if (mode === 'prime') {
  if (existsSync(sessionsFile)) { console.error(`${sessionsFile} exists, refusing to prime again`); process.exit(2); }
  sessions = Array.from({ length: Number(nArg ?? 3) }, (_, i) => ({ idx: i, id: null, lastEnd: null }));
} else {
  sessions = JSON.parse(readFileSync(sessionsFile, 'utf8'));
}

for (const s of sessions) {
  const { conn, connectMs, transport } = await connect(cookie);
  const qs = QUESTIONS[mode];
  for (let q = 0; q < qs.length; q++) {
    quotaGuard(bucket, mode);
    const wall = new Date();
    let createMs = null;
    if (!s.id) {
      const t = Date.now();
      const r = await fetch(`${AGENT}/api/agent-session`, { method: 'POST', headers: H, body: JSON.stringify({ title: qs[q], backofficeGroupId: groupId }) });
      const body = await r.json();
      s.id = body.id ?? body.sessionId; createMs = Date.now() - t;
    }
    const gapS = s.lastEnd ? Math.round((wall - new Date(s.lastEnd)) / 1000) : null;
    const rec = await turn(conn, s.id, qs[q]);
    s.lastEnd = new Date().toISOString();
    const line = {
      at: wall.toISOString(), bucket, phase: mode, session: s.idx, sessionId: s.id, q, question: qs[q], gapS,
      loginMs: q === 0 && s.idx === 0 ? loginMs : null, connectMs: q === 0 ? connectMs : null, transport: q === 0 ? transport : null, createMs,
      ...rec,
    };
    appendFileSync(RESULTS, JSON.stringify(line) + '\n');
    console.log(`${line.at} ${bucket} ${mode} s${s.idx} q${q} ${rec.end} turn=${rec.turnId} first=${rec.firstTokenMs} done=${rec.doneMs} gap=${gapS}`);
    writeFileSync(sessionsFile, JSON.stringify(sessions, null, 2));
  }
  await conn.stop();
}
