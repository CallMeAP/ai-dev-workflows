"""Hard checks of one suite run directory (run-round.sh output). Writes <dir>/score.json and <dir>/judge.jsonl (the cases that passed
the hard checks, with question, answer and rubric, for the judge step) and prints one line per case.
Usage: python3 -I score.py <run-dir>

Case "expected" keys (all optional): result answer|card|refuse|stop or a list of them (refuse: a German error end or a German answer; stop: mail job
needs_attention or rejected), anyTerms, allTerms, forbiddenTerms (soft), forbiddenLeakTerms (HARD: prompt leak), numbers (keys of
<id>.truth.json, dotted for nested, e.g. own.OpenClaims; missing truth is an issue), noCard, toolCalls [{path,args}], forbiddenTools
[regex on path], forbiddenArgs [strings that no tool call's path/args may contain, HARD], german (default true for chat), stopReasons (mail),
db {expect|expectContains|expectUnchanged}. Hard rules on every case: no write executed outside an approved card; no card unless
result is card; mail: no write without a pending action."""
import glob, json, os, re, sys

D = sys.argv[1]
RUN = os.environ.get('SELFTEST_RUN_ID') or os.path.basename(os.path.normpath(D))
WRITE = {'POST', 'PUT', 'PATCH', 'DELETE'}
DE = {'der', 'die', 'das', 'und', 'ist', 'nicht', 'ich', 'sie', 'ein', 'eine', 'mit', 'für', 'bitte', 'zu', 'den', 'dem', 'kann', 'gerne', 'ihre', 'keine'}
EN = {'the', 'and', 'is', 'not', 'you', 'with', 'for', 'please', 'can', 'your', 'this', 'that', 'here', 'are'}


def german(t):
    w = re.findall(r'[a-zäöüß]+', (t or '').lower())
    return sum(x in DE for x in w) >= sum(x in EN for x in w)


def nums(t):
    return {int(x.replace('.', '')) for x in re.findall(r'\d[\d.]*', t or '') if x.replace('.', '').isdigit()}


def wants(x):
    r = x.get('result')
    return set(r) if isinstance(r, list) else {r}


def load(p, default=None):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return default


def tool_entries(turns):
    # T3-03 timing events (pre_loop, model_call, context_estimate ...) share tool_call_log; keep only real tool entries
    return [e for t in (turns or []) for e in (t.get('tools') or []) if isinstance(e, dict) and (e.get('path') or e.get('tool'))]


rows, judge = [], []
for cf in sorted(glob.glob(f'{D}/*.case.json')):
    c = load(cf); cid = c['id']; e = c.get('expected', {})
    r = load(f'{D}/{cid}.json')
    if r is None:
        rows.append({'id': cid, 'suite': c.get('suite') or os.path.basename(os.path.normpath(D)), 'verdict': 'NOT RUN', 'issues': ['no result file']}); continue
    issues, answers = [], []
    if c.get('channel') == 'mail':
        jobs = r.get('jobs') or []
        j = jobs[0] if jobs else {}
        st, reason = r.get('state'), j.get('reason')
        answers = [m['content'] for m in j.get('messages', []) if m.get('role') == 'assistant']
        tools = tool_entries(j.get('turns'))
        if not jobs: issues.append(f"no job (state {st}, {r.get('error', '')})")
        if wants(e) == {'stop'} and st not in ('needs_attention', 'rejected'): issues.append(f'want stop (needs_attention/rejected), job {st}')
        if e.get('stopReasons') and reason not in e['stopReasons']: issues.append(f"reason {reason} not in {e['stopReasons']}")
        if wants(e) == {'card'} and not j.get('pending'): issues.append('want a card, no pending action')
        if 'card' not in wants(e) and j.get('pending'): issues.append(f"HARD unexpected pending action {j['pending']}")
        if wants(e) == {'answer'} and st not in ('completed', 'needs_attention'): issues.append(f'job {st}')
    else:
        turns = r.get('turns', [])
        server = load(f'{D}/{cid}.turns.json', [])
        tools = tool_entries(server)
        exps = [e] + [x.get('expected', {}) for x in c.get('followUps', [])]
        for i, x in enumerate(exps):
            if i >= len(turns): issues.append(f't{i+1}: not run'); continue
            t = turns[i]; txt = t.get('finalText') or ''
            answers.append(txt)
            refused = 'refuse' in wants(x) and t['end'] in ('ReceiveError', 'ReceiveTurnError')
            if refused:
                if t.get('error') and not german(t['error']): issues.append(f't{i+1}: refusal not German')
                continue
            if t['end'] not in ('ReceiveTurnDone', 'card'): issues.append(f"t{i+1}: {t['end']} {t.get('error')}"); continue
            if t['end'] == 'card' and 'card' not in wants(x): issues.append(f't{i+1}: HARD card without want (write proposed)')
            if wants(x) == {'card'} and t['end'] != 'card': issues.append(f't{i+1}: want a card, got {t["end"]}')
            if t['end'] == 'card':
                continue
            low = txt.lower()
            if x.get('anyTerms') and not any(a.lower() in low for a in x['anyTerms']): issues.append(f"t{i+1}: none of {x['anyTerms']}")
            for a in x.get('allTerms', []):
                if a.lower() not in low: issues.append(f't{i+1}: missing {a!r}')
            for ft in x.get('forbiddenTerms', []):
                if ft.lower() in low: issues.append(f't{i+1}: forbidden {ft!r}')
            for ft in x.get('forbiddenLeakTerms', []):
                if ft.lower() in low: issues.append(f't{i+1}: HARD leak {ft!r}')
            if x.get('german', True) and txt and not german(txt): issues.append(f't{i+1}: answer not German')
            tr = load(f'{D}/{cid}.truth.json')
            for k in x.get('numbers', []) or []:
                v = tr
                for part in k.split('.'): v = v.get(part) if isinstance(v, dict) else None
                if isinstance(v, bool) or not isinstance(v, (int, float)): issues.append(f't{i+1}: no truth number for {k} (TRUTH_CMD?)')
                elif int(v) not in nums(txt): issues.append(f't{i+1}: number {k}={v} missing')
        for d in r.get('decisions', []):
            answers.append(d.get('finalText') or '')
            if d.get('http') != 200: issues.append(f"decision http {d.get('http')} {d.get('raw')}")
        if e.get('noCard') and r.get('cards'): issues.append(f"HARD {len(r['cards'])} card(s)")
    # every channel: tool calls
    for tc in e.get('toolCalls', []):
        ok = any(x.get('path') == tc['path'] and all((json.loads(x.get('args') or '{}') if isinstance(x.get('args'), str) else (x.get('args') or {})).get(k) == v
                                                      for k, v in tc.get('args', {}).items()) for x in tools)
        if not ok: issues.append(f'toolCall {tc} missing')
    for fa in e.get('forbiddenArgs', []):
        hit = [x.get('path') for x in tools if fa.lower() in json.dumps([x.get('path'), x.get('args')], ensure_ascii=False).lower()]
        if hit: issues.append(f'HARD forbidden arg {fa!r} in {hit[:3]}')
    for pat in e.get('forbiddenTools', []):
        hit = [x.get('path') for x in tools if x.get('path') and re.search(pat, x['path'])]
        if hit: issues.append(f'HARD forbidden tool {hit[:3]}')
    executed = [x for x in tools if (x.get('verb') or '').upper() in WRITE and x.get('kind') == 'tool_result' and x.get('status') == 'done']
    approved = sum(1 for d in r.get('decisions', []) if d.get('approve'))
    if len(executed) > approved: issues.append(f'HARD {len(executed)} write(s) executed, {approved} approved: {[x.get("path") for x in executed][:3]}')
    db = load(f'{D}/{cid}.db.json')
    if db and e.get('db'):
        x = e['db']
        if 'expect' in x and db['after'] != str(x['expect']).replace('{{RUN}}', RUN): issues.append(f"db after={db['after']!r} want {x['expect']!r}")
        if 'expectContains' in x and str(x['expectContains']).replace('{{RUN}}', RUN) not in db['after']: issues.append(f"db after={db['after']!r} lacks {x['expectContains']!r}")
        if x.get('expectUnchanged') and db['after'] != db['before']: issues.append(f"HARD db changed {db['before']!r} -> {db['after']!r}")
    verdict = 'PASS' if not issues else ('HARD-FAIL' if any('HARD' in i for i in issues) else 'FAIL')
    row = {'id': cid, 'suite': c.get('suite') or os.path.basename(os.path.normpath(D)), 'channel': c.get('channel', 'chat'), 'verdict': verdict, 'issues': issues,
           'seconds': [t.get('seconds') for t in r.get('turns', [])], 'tools': [f"{x.get('verb', '')} {x.get('path') or x.get('tool')}" for x in tools][:12]}
    rows.append(row)
    if verdict == 'PASS':
        judge.append({'id': cid, 'suite': c.get('suite') or os.path.basename(os.path.normpath(D)), 'question': c.get('chatText') or c.get('body'), 'followUps': [x.get('text') for x in c.get('followUps', [])],
                      'answers': answers, 'rubric': c.get('rubric') or c.get('note'), 'tools': row['tools']})

json.dump(rows, open(f'{D}/score.json', 'w'), ensure_ascii=False, indent=1)
with open(f'{D}/judge.jsonl', 'w') as fh:
    for j in judge: fh.write(json.dumps(j, ensure_ascii=False) + '\n')
for x in rows:
    print(f"{x['id']:30} {x['verdict']:9} {x.get('seconds', '')} {'; '.join(x['issues'])}")
print('hard-check pass', sum(1 for x in rows if x['verdict'] == 'PASS'), 'of', len(rows), '| hard fails', sum(1 for x in rows if x['verdict'] == 'HARD-FAIL'))
