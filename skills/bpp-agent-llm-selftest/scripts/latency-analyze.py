"""Chat latency after idle gaps: joins results.jsonl (client timings) with agent_turn rows of the demo DB (read-only) and writes
REPORT-data.md (tables only; REPORT.md is written by hand around them). Usage: python3 -I latency-analyze.py <latency dir> [interim|final]
env DEMO_DB, PGHOST, PGPORT, PG_USER, PG_PASSWORD_FILE (from selftest.env); prints and stores no secret."""
import json, os, subprocess, sys, statistics
from datetime import datetime, timezone

HERE = sys.argv[1]
MODE = sys.argv[2] if len(sys.argv) > 2 else 'interim'
DB = os.environ['DEMO_DB']
if DB in ('', 'bpp', 'bpp_agent_demo'):
    sys.exit('REFUSING: DEMO_DB is not a demo copy')
BUCKETS = ['0s', '15m', '1h', '13h']


def pg(sql):
    pw = open(os.environ['PG_PASSWORD_FILE']).read().strip()
    env = dict(os.environ, PGPASSWORD=pw, PGOPTIONS='-c default_transaction_read_only=on')
    out = subprocess.run(['psql', '-X', '-h', os.environ.get('PGHOST', 'localhost'), '-p', os.environ.get('PGPORT', '5432'), '-U', os.environ.get('PG_USER', 'admin'),
                          '-d', DB, '-Atc', sql], env=env, capture_output=True, text=True, check=True)
    return [l for l in out.stdout.splitlines() if l]


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo))


def fmt(v):
    return '-' if v is None else str(v)


rows = [json.loads(l) for l in open(os.path.join(HERE, 'results.jsonl')) if l.strip()]
turns = [r for r in rows if r.get('turnId')]
skipped = [r for r in rows if r.get('skipped')]
ids = ",".join(f"'{r['turnId']}'" for r in turns)
server = {}
if ids:
    for line in pg(f"select json_build_object('id', id, 'latency', latency_ms, 'iterations', iterations, 'permit', permit_wait_ms, "
                   f"'input', input_tokens, 'cached', cached_input_tokens, 'status', status, 'model', model, 'log', tool_call_log)::text "
                   f"from agent_turn where id in ({ids})"):
        o = json.loads(line)
        server[o['id']] = o


def phases(log):
    d = {'pre': {}, 'ki': None, 'ki_ms': None, 'codex_refresh': 0, 'codex_ms': 0, 'calls': [], 'use_cap': 0, 'loaded': [], 'tools': 0}
    for e in log or []:
        k, s, ms = e.get('kind'), e.get('status'), e.get('durationMs')
        if k == 'pre_loop':
            d['pre'][s] = ms
        elif k == 'ki_token':
            d['ki'], d['ki_ms'] = s, ms
        elif k == 'codex_token':
            d['codex_refresh'] += s == 'refresh'
            d['codex_ms'] += ms or 0
        elif k == 'model_call':
            d['calls'].append(e)
        elif k == 'meta_tool' and e.get('tool') == 'use_capability':
            d['use_cap'] += 1
        elif k == 'capability_loaded':
            d['loaded'].append(s)
        elif k == 'tool_result':
            d['tools'] += 1
    return d


rec = []
for r in turns:
    s = server.get(r['turnId'], {})
    p = phases(s.get('log'))
    calls = p['calls']
    rec.append({**r, 'latency': s.get('latency'), 'iterations': s.get('iterations'), 'permit': s.get('permit'), 'input': s.get('input'),
                'cached': s.get('cached'), 'pre_total': p['pre'].get('total'), 'pre_prompt': p['pre'].get('prompt'),
                'pre_memory': p['pre'].get('memory'), 'pre_lease': p['pre'].get('lease'), 'pre_hub': p['pre'].get('hub'),
                'ki': p['ki'], 'ki_ms': p['ki_ms'], 'codex_refresh': p['codex_refresh'], 'codex_ms': p['codex_ms'],
                'calls': len(calls), 'call_ms': sum(c.get('durationMs') or 0 for c in calls),
                'call_first_ms': sum(c.get('firstTokenMs') or 0 for c in calls), 'first_call_first': calls[0].get('firstTokenMs') if calls else None,
                'first_call_ms': calls[0].get('durationMs') if calls else None, 'permit_calls': sum(c.get('permitWaitMs') or 0 for c in calls),
                'call_cached': sum(c.get('cachedInputTokens') or 0 for c in calls), 'use_cap': p['use_cap'], 'loaded': p['loaded'], 'tools': p['tools']})

out = [f"# Latency data ({MODE}, generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%MZ')})", '',
       f"Turns: {len(rec)} ({sum(1 for r in rec if r['phase'] == 'prime')} prime, {sum(1 for r in rec if r['phase'] == 'resume')} resume); "
       f"ended other than done: {[(r['bucket'], r['phase'], r['session'], r['q'], r['end']) for r in rec if r['end'] != 'done'] or 'none'}; "
       f"skipped resumes: {[(r['bucket'], r['skipped']) for r in skipped] or 'none'}.", '']


def table(title, sel, note=''):
    out.append(f"## {title}")
    if note:
        out.append('')
        out.append(note)
    out.append('')
    out.append('| bucket | n | gap s (median) | send->first token p50/p95 | send->done p50/p95 | latency_ms p50/p95 | pre_loop total p50 (prompt p50) | '
               'model calls p50 (max) | first call: first-token p50 / stream p50 | sum call stream p50 | KI token | Codex refresh | permit wait sum | '
               'use_capability / turn | client overhead p50 | input tok p50 | cached/input |')
    out.append('|' + '---|' * 17)
    for b in BUCKETS:
        xs = [r for r in rec if r['bucket'] == b and sel(r)]
        if not xs:
            out.append(f"| {b} | 0 | | | | | | | | | | | | | | | |")
            continue
        g = lambda k: [r[k] for r in xs]
        overhead = [r['doneMs'] - (r['latency'] or 0) - (r['pre_total'] or 0) for r in xs if r['doneMs'] is not None and r['latency'] is not None]
        ki = {}
        for r in xs:
            ki[r['ki']] = ki.get(r['ki'], 0) + 1
        inp, cach = sum(r['input'] or 0 for r in xs), sum(r['cached'] or 0 for r in xs)
        out.append(f"| {b} | {len(xs)} | {fmt(pct(g('gapS'), .5))} | {fmt(pct(g('firstTokenMs'), .5))} / {fmt(pct(g('firstTokenMs'), .95))} | "
                   f"{fmt(pct(g('doneMs'), .5))} / {fmt(pct(g('doneMs'), .95))} | {fmt(pct(g('latency'), .5))} / {fmt(pct(g('latency'), .95))} | "
                   f"{fmt(pct(g('pre_total'), .5))} ({fmt(pct(g('pre_prompt'), .5))}) | {fmt(pct(g('calls'), .5))} ({max(g('calls'))}) | "
                   f"{fmt(pct(g('first_call_first'), .5))} / {fmt(pct(g('first_call_ms'), .5))} | {fmt(pct(g('call_ms'), .5))} | "
                   f"{', '.join(f'{k} {v}' for k, v in ki.items())} (max {max((r['ki_ms'] or 0) for r in xs)} ms) | {sum(g('codex_refresh'))} | "
                   f"{sum(g('permit_calls'))} ms | {round(statistics.mean(g('use_cap')), 2)} | {fmt(pct(overhead, .5))} | {fmt(pct(g('input'), .5))} | "
                   f"{round(cach / inp, 3) if inp else '-'} |")
    out.append('')


table('Resume, first turn after the gap (the cold turn)', lambda r: r['phase'] == 'resume' and r['q'] == 0)
table('Resume, all 3 turns', lambda r: r['phase'] == 'resume')
table('Prime (fresh chats, gap 0 between turns), by the bucket the chats belong to', lambda r: r['phase'] == 'prime')

out.append('## Sticky tool groups (D-911): the contract question')
out.append('')
out.append('| phase | question | n | iterations p50 (max) | use_capability / turn | groups loaded in the turn | send->done p50 |')
out.append('|---|---|---|---|---|---|---|')
for ph in ['prime', 'resume']:
    xs = [r for r in rec if r['phase'] == ph and r['q'] == 2]
    if xs:
        loaded = {}
        for r in xs:
            for t in r['loaded']:
                loaded[t] = loaded.get(t, 0) + 1
        out.append(f"| {ph} | {xs[0]['question']} | {len(xs)} | {fmt(pct([r['iterations'] for r in xs], .5))} ({max(r['iterations'] or 0 for r in xs)}) | "
                   f"{round(statistics.mean(r['use_cap'] for r in xs), 2)} | {loaded or 'none'} | {fmt(pct([r['doneMs'] for r in xs], .5))} |")
out.append('')

out.append('## Per question (all buckets)')
out.append('')
out.append('| phase | q | n | iterations p50 | tool results p50 | send->first token p50 | send->done p50 / p95 | per-call stream p50 | per-call first-token p50 |')
out.append('|---|---|---|---|---|---|---|---|---|')
for ph in ['prime', 'resume']:
    for q in range(3):
        xs = [r for r in rec if r['phase'] == ph and r['q'] == q]
        if not xs:
            continue
        per_call = [r['call_ms'] / r['calls'] for r in xs if r['calls']]
        per_first = [r['call_first_ms'] / r['calls'] for r in xs if r['calls']]
        out.append(f"| {ph} | {q} {xs[0]['question']} | {len(xs)} | {fmt(pct([r['iterations'] for r in xs], .5))} | {fmt(pct([r['tools'] for r in xs], .5))} | "
                   f"{fmt(pct([r['firstTokenMs'] for r in xs], .5))} | {fmt(pct([r['doneMs'] for r in xs], .5))} / {fmt(pct([r['doneMs'] for r in xs], .95))} | "
                   f"{fmt(pct(per_call, .5))} | {fmt(pct(per_first, .5))} |")
out.append('')

allcalls = [c for r in rec for c in [r]]
tot_calls = sum(r['calls'] for r in rec)
out.append(f"Model calls in all turns: {tot_calls}; sum stream {sum(r['call_ms'] for r in rec)} ms; sum time-to-first-update of the calls "
           f"{sum(r['call_first_ms'] for r in rec)} ms; turn latency sum {sum(r['latency'] or 0 for r in rec)} ms; pre_loop total sum "
           f"{sum(r['pre_total'] or 0 for r in rec)} ms (+ prompt {sum(r['pre_prompt'] or 0 for r in rec)} ms); KI mints "
           f"{sum(1 for r in rec if r['ki'] == 'mint')}; Codex refreshes {sum(r['codex_refresh'] for r in rec)}; permit wait {sum(r['permit_calls'] for r in rec)} ms; "
           f"cached tokens reported {sum(r['cached'] or 0 for r in rec)} of {sum(r['input'] or 0 for r in rec)} input.")
out.append('')
open(os.path.join(HERE, 'REPORT-data.md'), 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))

# REPORT.md keeps its hand-written part above the marker; the tables below it are replaced on every run (the final unit included).
MARK = '<!-- DATA: everything below is generated by latency-analyze.py -->'
rp = os.path.join(HERE, 'REPORT.md')
head = open(rp).read().split(MARK)[0] if os.path.exists(rp) else '# Chat latency after idle gaps\n\n'
if MODE == 'final':
    head = head.replace('Status: INTERIM', 'Status: FINAL tables (13 h bucket included); the text above was written at the interim and is not re-read')
open(rp, 'w').write(head.rstrip() + '\n\n' + MARK + '\n\n' + '\n'.join(out) + '\n')
