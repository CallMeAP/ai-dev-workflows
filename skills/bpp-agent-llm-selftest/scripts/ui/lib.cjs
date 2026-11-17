// Puppeteer helpers for the UI suite. env (selftest.env): PUPPETEER_CORE, CHROME, COCKPIT_URL, SELFTEST_LOGIN_EMAIL,
// SELFTEST_LOGIN_PASSWORD_FILE (else the fleet dev default), UI_OUT (screenshot dir). Prints no password.
const fs = require('fs');
const path = require('path');
const puppeteer = require(process.env.PUPPETEER_CORE);
const OUT = (process.env.UI_OUT ?? '.') + '/';
const BASE = process.env.COCKPIT_URL ?? 'http://localhost:4210';
const VP = { desktop: { width: 1440, height: 900 }, mobile: { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true } };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const password = () => process.env.SELFTEST_LOGIN_PASSWORD_FILE ? fs.readFileSync(process.env.SELFTEST_LOGIN_PASSWORD_FILE, 'utf8').trim() : 'Start123$';
// Throw-away Chrome profile (it holds the auth cookie): never next to the screenshots, removed on close and on exit.
// Under ~/.cache, not /tmp: snap Chromium sees a private /tmp.
const PROFILE = fs.mkdtempSync(path.join(require('os').homedir(), '.cache', 'selftest-ui-'));
const dropProfile = () => fs.rmSync(PROFILE, { recursive: true, force: true });
process.on('exit', dropProfile);
async function launch() {
  fs.mkdirSync(OUT, { recursive: true });
  return puppeteer.launch({ executablePath: process.env.CHROME ?? '/snap/bin/chromium', headless: true,
    userDataDir: PROFILE, args: ['--no-first-run', '--lang=de-DE'] });
}
async function close(b) { await b.close(); dropProfile(); }
async function page(b, vp) {
  const p = await b.newPage();
  await p.setViewport(VP[vp]);
  p.on('console', m => { if (m.type() === 'error') console.log('[console]', m.text().slice(0, 200)); });
  return p;
}
async function login(p) {
  if (!process.env.SELFTEST_LOGIN_EMAIL) throw new Error('set SELFTEST_LOGIN_EMAIL');
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' });
  await sleep(1500);
  if (await p.$('#email')) {
    await p.click('#email', { clickCount: 3 }); await p.type('#email', process.env.SELFTEST_LOGIN_EMAIL);
    await p.click('#password', { clickCount: 3 }); await p.type('#password', password());
    const resp = p.waitForResponse(r => r.url().includes('/auth-go-user/login'), { timeout: 20000 });
    await p.click('button[type=submit]');
    const r = await resp; console.log('login status', r.status());
    await sleep(3000);
    await p.waitForNetworkIdle({ idleTime: 800, timeout: 30000 }).catch(() => {});
  }
  console.log('after login url', p.url());
}
async function closeToasts(p) {
  await p.evaluate(() => document.querySelectorAll('.p-toast-close-button, .p-toast-icon-close, app-alert-with-description button').forEach(b => b.click())).catch(() => {});
  await sleep(600);
}
async function clickCy(p, cy) {
  const ok = await p.evaluate((cy) => { const e = document.querySelector(`[data-cy="${cy}"] button`) || document.querySelector(`[data-cy="${cy}"]`); if (!e) return false; e.click(); return true; }, cy);
  if (!ok) throw new Error('not found ' + cy);
  await sleep(1200);
}
async function openPanel(p) {
  await closeToasts(p);
  await clickCy(p, 'agent-panel-toggle');
  await p.waitForSelector('[data-cy=agent-panel]', { timeout: 15000 });
  await sleep(2000);
  await closeToasts(p);
}
async function shot(p, name) {
  const f = OUT + name + '.png'; await p.screenshot({ path: f }); console.log('shot', f); return f;
}
module.exports = { close, dropProfile, closeToasts, clickCy, launch, page, login, openPanel, shot, sleep, OUT, BASE };
