// UI suite: LLM states of the Cockpit agent panel against the demo agent, shot at desktop 1440x900 and mobile 390x844.
// Usage: node live.cjs <desktop|mobile> [read-only]     env: see lib.cjs; SELFTEST_RUN_ID tags the write.
// States: settings (Codex linked), welcome + prompt, running counter, answer done, heads-up bar, write card -> approve,
// write card -> reject with reason, activity + copy. Writes go to the demo DB only (the stack's own); "read-only" skips them.
// The settings shot shows the linked ChatGPT account's e-mail: keep the screenshots local.
const L = require('./lib.cjs');
const S = L.sleep;
const vp = process.argv[2];
if (!['desktop', 'mobile'].includes(vp)) { console.error('usage: live.cjs <desktop|mobile> [read-only]'); process.exit(2); }
const READ_ONLY = process.argv[3] === 'read-only';
const RUN = process.env.SELFTEST_RUN_ID ?? 'run';
const P = '';
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const dims = (p) => p.evaluate(() => {
  const h = (cy) => { const e = document.querySelector(`[data-cy=${cy}]`); return e ? Math.round(e.getBoundingClientRect().height) : null; };
  const panel = document.querySelector('[data-cy=agent-panel]'); const pr = panel?.getBoundingClientRect();
  const outside = panel ? [...panel.querySelectorAll('*')].filter(e => { const r = e.getBoundingClientRect(); return r.width && (r.right > pr.right + 1 || r.left < pr.left - 1); }).map(e => e.getAttribute('data-cy') || e.tagName).slice(0, 8) : [];
  return { thread: h('agent-panel-thread'), dock: h('agent-panel-card-dock'), headsUp: h('agent-heads-up-bar'), docScrollW: document.documentElement.scrollWidth, vw: innerWidth, outside };
});
const texts = (p, cy) => p.$$eval(`[data-cy=${cy}]`, es => es.map(e => e.innerText.replace(/\s+/g, ' ').trim()));
const count = (p, cy) => p.$$eval(`[data-cy=${cy}]`, es => es.length);

// Codex stop before every live turn (exit 3, rerun after the reset)
function quotaGuard() {
  try { require('child_process').execFileSync('bash', [require('path').join(__dirname, '..', 'quota-guard.sh')], { stdio: ['ignore', 'ignore', 'inherit'] }); }
  catch { console.error('QUOTA STOP'); process.exit(3); }
}

async function send(p, text) {
  quotaGuard();
  await p.$eval('[data-cy=agent-panel-composer]', (e, t) => { e.value = t; e.dispatchEvent(new Event('input', { bubbles: true })); }, text);
  await S(300);
  await L.clickCy(p, 'agent-panel-send');
  log('sent', text.slice(0, 60));
}

// Wait until no live turn and no busy card; shoot the running counter on the way.
async function waitIdle(p, tag, maxS = 300) {
  const t0 = Date.now(); let shotRun = 0;
  while ((Date.now() - t0) / 1000 < maxS) {
    const live = await count(p, 'agent-panel-live-turn'); const busy = await count(p, 'agent-card-busy');
    if (live || busy) {
      const st = [...await texts(p, 'agent-panel-working-status'), ...await texts(p, 'agent-card-busy')];
      if (shotRun < 2 && (Date.now() - t0) > (shotRun ? 9000 : 2500)) {
        log('running', tag, JSON.stringify(st)); await L.shot(p, `live-${P}${tag}-running${shotRun + 1}-${vp}`); shotRun++;
      }
    } else if ((Date.now() - t0) > 4000) { log('idle', tag, 'after', Math.round((Date.now() - t0) / 1000), 's'); return true; }
    await S(700);
  }
  log('TIMEOUT', tag); return false;
}

async function cardIndex(p, re) {
  return p.$$eval('[data-cy=agent-panel-card-dock-body] app-bpp-agent-approval-card', (cs, src) => cs.findIndex(c => new RegExp(src, 'i').test(c.innerText)), re);
}
async function cardsInfo(p) {
  return p.$$eval('[data-cy=agent-panel-card-dock-body] app-bpp-agent-approval-card', cs => cs.map(c => (c.querySelector('[data-cy=agent-card-label]')?.innerText || c.innerText).replace(/\s+/g, ' ').slice(0, 120)));
}
async function decide(p, re, action, tag) {
  const i = await cardIndex(p, re);
  if (i < 0) { log('no card for', re, JSON.stringify(await cardsInfo(p))); return false; }
  const card = (await p.$$('[data-cy=agent-panel-card-dock-body] app-bpp-agent-approval-card'))[i];
  await card.evaluate(c => c.scrollIntoView({ block: 'center' }));
  quotaGuard();
  if (action === 'approve') {
    await (await card.$('[data-cy=agent-card-approve] button')).click();
  } else {
    await (await card.$('[data-cy=agent-card-reject-open] button')).click(); await S(600);
    await (await card.$('[data-cy=agent-card-reject-reason]')).type('UI-Demo: bitte nicht ändern.');
    await S(300); await L.shot(p, `live-${P}${tag}-reject-form-${vp}`);
    await (await card.$('[data-cy=agent-card-reject-send] button')).click();
  }
  log('decided', action, re);
  await S(1200); await L.shot(p, `live-${P}${tag}-${action}-clicked-${vp}`);
  await waitIdle(p, `${tag}-${action}`, 240);
  await S(1500); await L.closeToasts(p);
  log('dock after', JSON.stringify(await cardsInfo(p)), 'rows', JSON.stringify(await texts(p, 'agent-action-row-status')));
  await p.$eval('[data-cy=agent-panel-thread]', e => e.scrollTop = e.scrollHeight).catch(() => {}); await S(500);
  await L.shot(p, `live-${P}${tag}-${action}-inline-${vp}`);
  return true;
}

async function turnDone(p, tag) {
  await waitIdle(p, tag);
  await S(1500); await L.closeToasts(p);
  log('thinking', JSON.stringify(await texts(p, 'agent-panel-thinking-time')), 'cards', JSON.stringify(await cardsInfo(p)),
    'headsUp', JSON.stringify(await texts(p, 'agent-heads-up-bar')), 'dims', JSON.stringify(await dims(p)));
  await L.shot(p, `live-${P}${tag}-done-${vp}`);
}

async function headsUps(p, tag) {
  if (!(await count(p, 'agent-heads-up-bar'))) { log('no heads-up bar', tag); return; }
  log('heads-up', tag, JSON.stringify(await texts(p, 'agent-heads-up-bar')));
  await L.shot(p, `live-${P}${tag}-headsup-queued-${vp}`);
  // first: "0: Ausblenden" (hidden for this conversation), the next one moves up
  await L.clickCy(p, 'agent-heads-up-dismiss'); await S(800);
  log('after dismiss', JSON.stringify(await texts(p, 'agent-heads-up-bar')));
  await L.shot(p, `live-${P}${tag}-headsup-after-dismiss-${vp}`);
  if (!(await count(p, 'agent-heads-up-bar'))) return;
  await L.clickCy(p, 'agent-heads-up-learn-more'); await S(800);
  await L.shot(p, `live-${P}${tag}-headsup-learn-more-${vp}`);
  const before = await p.$eval('[data-cy=agent-panel-composer]', e => e.value);
  quotaGuard(); await L.clickCy(p, 'agent-heads-up-discuss'); await S(2500);
  log('after discuss: composer', JSON.stringify(await p.$eval('[data-cy=agent-panel-composer]', e => e.value)), 'was', JSON.stringify(before),
    'live', await count(p, 'agent-panel-live-turn'), 'bar', JSON.stringify(await texts(p, 'agent-heads-up-bar')));
  await L.shot(p, `live-${P}${tag}-headsup-after-discuss-${vp}`);
  if (await count(p, 'agent-panel-live-turn')) { await waitIdle(p, `${tag}-discuss`); await L.shot(p, `live-${P}${tag}-headsup-discuss-answer-${vp}`); }
}

async function activityAndCopy(p, tag) {
  await p.$$eval('[data-cy=agent-panel-activity]', ds => { ds.forEach(d => d.open = true); ds[ds.length - 1]?.scrollIntoView({ block: 'center' }); }); await S(600);
  log('activity', JSON.stringify(await texts(p, 'agent-panel-activity')));
  await L.shot(p, `live-${P}${tag}-activity-open-${vp}`);
  const copies = await p.$$('[data-cy=agent-panel-copy-answer] button');
  if (copies.length) {
    await copies[copies.length - 1].evaluate(e => e.scrollIntoView({ block: 'center' }));
    await copies[copies.length - 1].click(); await S(300); await L.shot(p, `live-${P}${tag}-copy-clicked-${vp}`);
    log('clipboard', JSON.stringify((await p.evaluate(() => navigator.clipboard.readText().catch(e => 'ERR ' + e.message))).slice(0, 200)));
  }
  await p.$$eval('[data-cy=agent-panel-activity]', ds => ds.forEach(d => d.open = false));
}

async function newSession(p) {
  await L.clickCy(p, 'agent-panel-tab-chat');
  await L.clickCy(p, 'agent-panel-new-session'); await S(1500);
  await L.shot(p, `live-${P}c03-welcome-${vp}`);
  log('welcome prompts', JSON.stringify(await texts(p, 'agent-panel-welcome-prompt')), 'dims', JSON.stringify(await dims(p)));
  await L.clickCy(p, 'agent-panel-welcome-prompt');
  log('composer after prompt', JSON.stringify(await p.$eval('[data-cy=agent-panel-composer]', e => e.value)), 'live', await count(p, 'agent-panel-live-turn'));
  await L.shot(p, `live-${P}c03-prompt-clicked-${vp}`);
  await p.$eval('[data-cy=agent-panel-composer]', e => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })); });
}

async function settings(p) {
  await L.clickCy(p, 'agent-panel-tab-settings'); await S(2000);
  log('codex', JSON.stringify(await texts(p, 'agent-codex-section')));
  await L.shot(p, `live-${P}c02-settings-linked-${vp}`);
  await L.clickCy(p, 'agent-panel-tab-chat'); await S(800);
}

(async () => {
  const b = await L.launch();
  await b.defaultBrowserContext().overridePermissions(L.BASE, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write']);
  const p = await L.page(b, vp);
  p.on('dialog', d => d.dismiss());
  await L.login(p);
  await L.openPanel(p);
  await settings(p);
  await newSession(p);
  await send(p, 'Wie viele Kunden habe ich, und welche Verträge hat Stefan Stadlmayr?');
  await turnDone(p, 'read'); await headsUps(p, 'read');
  if (!READ_ONLY) {
    await send(p, `Setze beim Vertrag POL-EV-1121 von Stefan Stadlmayr die Anmerkung auf "UI-Selftest ${RUN}".`);
    await turnDone(p, 'write-approve'); await headsUps(p, 'write-approve');
    await decide(p, 'Vertrag|Anmerkung', 'approve', 'card');
    await send(p, 'Setze beim Vertrag POL-EV-1131 von Maria Edelsbacher den Vertragsstatus auf gekündigt.');
    await turnDone(p, 'write-reject'); await headsUps(p, 'write-reject');
    await decide(p, 'Vertrag', 'reject', 'card');
  }
  await activityAndCopy(p, 'activity');
  log('final dims', JSON.stringify(await dims(p)));
  await L.close(b);
})().catch(e => { console.error(e); L.dropProfile(); process.exit(1); });
