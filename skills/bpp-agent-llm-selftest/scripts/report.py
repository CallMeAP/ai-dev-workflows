"""One report per self-test run: <run-dir>/REPORT.md from what the stages left in the run dir.
Usage: python3 -I report.py <run-dir>
Reads: preflight.txt, codex-start.txt / codex-end.txt ("primary secondary age"), <suite>/score.json (hard checks), <suite>/judge.json
([{id, verdict PASS|FAIL, reason}] from the judge step), latency/REPORT-data.md, rules/summary.txt, ui/*.png. Prints the path."""
import glob, json, os, sys

D = os.path.abspath(sys.argv[1])


def read(p, default=''):
    try:
        return open(p).read()
    except OSError:
        return default


def load(p, default=None):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return default


def codex(name):
    parts = read(os.path.join(D, name)).split()
    return f'5h {parts[0]} %, week {parts[1]} %' if len(parts) >= 2 else 'not recorded'


out = [f'# bpp-agent LLM self-test: {os.path.basename(D)}', '',
       f'Codex used at start: {codex("codex-start.txt")}; at end: {codex("codex-end.txt")} (stop 95/95).', '']
pre = read(os.path.join(D, 'preflight.txt'))
if pre:
    fails = [l for l in pre.splitlines() if l.startswith('FAIL')]
    out += ['## Pre-flight', '', f'{len(fails)} FAIL lines.' if fails else 'No FAIL.', '', '```', pre.strip(), '```', '']

total = {'cases': 0, 'hard': 0, 'judged': 0}
out += ['## Suites', '', '| suite | cases | hard-check pass | hard fails | judge pass | final pass |', '|---|---|---|---|---|---|']
detail = []
for sf in sorted(glob.glob(f'{D}/*/score.json')):
    suite = os.path.basename(os.path.dirname(sf))
    rows = load(sf, [])
    judge = {j['id']: j for j in load(os.path.join(os.path.dirname(sf), 'judge.json'), []) or []}
    hp = [r for r in rows if r['verdict'] == 'PASS']
    hf = [r for r in rows if r['verdict'] == 'HARD-FAIL']
    jp = [r for r in hp if judge.get(r['id'], {}).get('verdict') == 'PASS']
    final = len(jp) if judge else f'{len(hp)} (not judged)'
    out.append(f'| {suite} | {len(rows)} | {len(hp)} | {len(hf)} | {len(jp) if judge else "-"} | {final} |')
    total['cases'] += len(rows); total['hard'] += len(hf)
    for r in rows:
        j = judge.get(r['id'])
        v = r['verdict'] if r['verdict'] != 'PASS' else (j['verdict'] if j else 'PASS (hard only)')
        why = '; '.join(r['issues']) or (j or {}).get('reason', '')
        detail.append(f"| {suite} | {r['id']} | {r.get('channel', 'chat')} | {v} | {why[:300].replace('|', '/')} |")
out += ['', f"Cases: {total['cases']}; hard fails (write without card, forbidden tool, DB change, leak): {total['hard']}.", '',
        '## Cases', '', '| suite | case | channel | verdict | why |', '|---|---|---|---|---|'] + detail + ['']

lat = read(os.path.join(D, 'latency', 'REPORT-data.md'))
if lat:
    out += ['## Latency', '', lat.split('\n', 2)[2] if lat.count('\n') > 2 else lat, '']
rules = read(os.path.join(D, 'rules', 'summary.txt'))
if rules:
    out += ['## Rules (gotchas) gate', '', '```', rules.strip(), '```', '']
shots = sorted(glob.glob(f'{D}/ui/*.png'))
if shots:
    out += ['## Screenshots', '', f'{len(shots)} files in `{D}/ui/` (desktop 1440x900, mobile 390x844). The settings shots show the linked '
            'ChatGPT account: keep them local.', ''] + [f'- `{os.path.basename(s)}`' for s in shots] + ['']
out += ['## Fix stage', '', 'Real defects -> fix on the branch that owns the code (see SKILL.md, Fix stage); everything else -> proposals list.', '']
p = os.path.join(D, 'REPORT.md')
open(p, 'w').write('\n'.join(out) + '\n')
print(p)
