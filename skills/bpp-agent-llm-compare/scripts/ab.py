"""Blind A/B judging and scoring on top of the main skill's per-arm run dirs (<out>/<arm>/<suite>/score.json + judge.jsonl).

  blind  <out> --seed S       writes <out>/blind/<suite>.jsonl for the judge: per case the question, follow-ups, rubric and the answers
                              of the arms that passed the hard checks as X / Y (order random per case, seeded), no arm, provider,
                              model, timing or token data. The key goes to <out>/blind/key.json, which the judge never reads.
  score  <out>                unblinds <out>/blind/<suite>.verdicts.json ([{id, X, Y, better, reason}], X/Y PASS|FAIL|null,
                              better X|Y|tie|null) into <out>/summary.json and prints one line per arm.
  gate   <base> <cand> [--shared]
                              acceptance of a tuning change on the HELD-BACK set: challenger final passes must rise, no case may turn
                              HARD-FAIL; with --shared (a shared prompt/tool change) Luna must not lose any final pass. Exit 0 ACCEPT, 1 REJECT.
  report <run-dir> <label>=<out> ...
                              <run-dir>/REPORT.md: per label (baseline-tune, baseline-heldback, i1-tune, ...) and arm the scores,
                              the tune vs held-back gap, wrong-arm turns, spend, and the judge caveat.
Final pass = hard checks PASS and judge PASS. A hard fail is never overridden by the judge."""
import glob, hashlib, json, os, sys

ARMS = ('luna', 'challenger')


def load(p, d=None):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return d


def jl(p):
    try:
        return [json.loads(l) for l in open(p) if l.strip()]
    except OSError:
        return []


def suites(out):
    return sorted({os.path.basename(os.path.dirname(p)) for a in ARMS for p in glob.glob(f'{out}/{a}/*/score.json')})


def providers(out, arm, suite, cid):
    """Providers that answered the case (agent_turn.provider, else .model), to catch a case that ran on the wrong arm."""
    t = load(f'{out}/{arm}/{suite}/{cid}.turns.json', []) or []
    r = load(f'{out}/{arm}/{suite}/{cid}.json', {}) or {}
    t += [x for j in r.get('jobs') or [] for x in j.get('turns') or []]
    return sorted({x.get('provider') or x.get('model') for x in t if x.get('provider') or x.get('model')})


def blind(out, seed):
    os.makedirs(f'{out}/blind', exist_ok=True)
    key = {}
    for s in suites(out):
        rows = {a: {r['id']: r for r in load(f'{out}/{a}/{s}/score.json', []) or []} for a in ARMS}
        ans = {a: {j['id']: j for j in jl(f'{out}/{a}/{s}/judge.jsonl')} for a in ARMS}
        items = []
        for cid in sorted(set(rows['luna']) | set(rows['challenger'])):
            flip = int(hashlib.sha256(f'{seed}:{cid}'.encode()).hexdigest(), 16) % 2
            xy = ('challenger', 'luna') if flip else ('luna', 'challenger')
            key[cid] = {'X': xy[0], 'Y': xy[1], 'suite': s}
            base = ans[xy[0]].get(cid) or ans[xy[1]].get(cid)
            if not base: continue          # neither arm passed the hard checks: nothing to judge
            item = {'id': cid, 'suite': s, 'question': base['question'], 'followUps': base['followUps'], 'rubric': base['rubric']}
            for slot, arm in zip('XY', xy):
                j = ans[arm].get(cid)
                item[slot] = {'answers': j['answers'], 'tools': j['tools']} if j else None
            items.append(item)
        with open(f'{out}/blind/{s}.jsonl', 'w') as fh:
            for i in items: fh.write(json.dumps(i, ensure_ascii=False) + '\n')
        print(f'{s}: {len(items)} cases to judge -> {out}/blind/{s}.jsonl')
    json.dump(key, open(f'{out}/blind/key.json', 'w'), indent=1)


def score(out):
    key = load(f'{out}/blind/key.json', {})
    summ = {a: {'cases': 0, 'hard_pass': 0, 'hard_fail': 0, 'final_pass': 0, 'judged': False, 'wins': 0, 'ties': 0, 'wrong_arm': [],
                'per_case': {}} for a in ARMS}
    for s in suites(out):
        v = {x['id']: x for x in load(f'{out}/blind/{s}.verdicts.json', []) or []}
        for a in ARMS:
            summ[a]['judged'] |= bool(v)
            for r in load(f'{out}/{a}/{s}/score.json', []) or []:
                cid, m = r['id'], summ[a]
                m['cases'] += 1
                slot = next((k for k in 'XY' if key.get(cid, {}).get(k) == a), None)
                j = v.get(cid, {})
                final = r['verdict'] == 'PASS' and (j.get(slot) == 'PASS' if v else True)
                m['hard_pass'] += r['verdict'] == 'PASS'; m['hard_fail'] += r['verdict'] == 'HARD-FAIL'; m['final_pass'] += final
                m['wins'] += j.get('better') == slot; m['ties'] += j.get('better') == 'tie'
                m['per_case'][cid] = {'suite': s, 'hard': r['verdict'], 'judge': j.get(slot), 'final': final, 'issues': r['issues'][:3]}
                want = ({os.environ['LUNA_PROVIDER'], os.environ.get('LUNA_MODEL', 'gpt-6-luna')} if a == 'luna'
                        else {os.environ['CHALLENGER_PROVIDER'], os.environ.get('CHALLENGER_MODEL', '')})
                got = providers(out, a, s, cid)
                if set(got) - want: m['wrong_arm'].append(f'{cid}: {got}')
    json.dump(summ, open(f'{out}/summary.json', 'w'), indent=1, ensure_ascii=False)
    for a in ARMS:
        m = summ[a]
        print(f"{a:10} cases {m['cases']:3} hard-pass {m['hard_pass']:3} HARD-FAIL {m['hard_fail']:2} final {m['final_pass']:3}"
              f"{'' if m['judged'] else ' (not judged)'} wins {m['wins']} ties {m['ties']} wrong-arm {len(m['wrong_arm'])}")
    return summ


def gate(base, cand, shared):
    b, c = load(f'{base}/summary.json'), load(f'{cand}/summary.json')
    if not b or not c: sys.exit('run "score" on both dirs first')
    why = []
    bc, cc = b['challenger'], c['challenger']
    if cc['final_pass'] <= bc['final_pass']: why.append(f"challenger held-back final {bc['final_pass']} -> {cc['final_pass']} (no gain)")
    new_hard = [k for k, x in cc['per_case'].items() if x['hard'] == 'HARD-FAIL' and bc['per_case'].get(k, {}).get('hard') != 'HARD-FAIL']
    if new_hard: why.append(f'new HARD-FAIL: {new_hard}')
    if c['challenger']['wrong_arm'] or c['luna']['wrong_arm']: why.append('wrong-arm turns in the candidate run')
    if shared:
        lost = [k for k, x in b['luna']['per_case'].items() if x['final'] and not c['luna']['per_case'].get(k, {}).get('final')]
        if lost: why.append(f'Luna regression on held-back: {lost}')
    print('ACCEPT' if not why else 'REJECT: ' + '; '.join(why))
    sys.exit(0 if not why else 1)


def report(run, pairs):
    env = os.environ
    L = [f'# bpp-agent LLM compare: {os.path.basename(os.path.abspath(run))}', '',
         f"Luna = `{env.get('LUNA_PROVIDER')}`; challenger = `{env.get('CHALLENGER_PROVIDER')}` model `{env.get('CHALLENGER_MODEL')}` "
         f"({env.get('CHALLENGER_KIND')}).", '',
         '| label | arm | cases | hard pass | HARD-FAIL | final pass | % | pairwise wins | ties | wrong-arm |', '|---|---|---|---|---|---|---|---|---|---|']
    pct = {}
    for lab, out in pairs:
        s = load(f'{out}/summary.json')
        if not s: L.append(f'| {lab} | - | not scored | | | | | | | |'); continue
        for a in ARMS:
            m = s[a]; p = 100 * m['final_pass'] / max(m['cases'], 1); pct[(lab, a)] = p
            L.append(f"| {lab} | {a} | {m['cases']} | {m['hard_pass']} | {m['hard_fail']} | {m['final_pass']}{'' if m['judged'] else ' (hard only)'} "
                     f"| {p:.0f} | {m['wins']} | {m['ties']} | {len(m['wrong_arm'])} |")
    L += ['', '## Tune vs held-back (challenger)', '']
    for lab in sorted({l.rsplit('-', 1)[0] for l, _ in pairs}):
        t, h = pct.get((f'{lab}-tune', 'challenger')), pct.get((f'{lab}-heldback', 'challenger'))
        if t is not None and h is not None:
            L.append(f"- {lab}: tune {t:.0f} %, held-back {h:.0f} %, gap {t - h:+.0f} pts{' (overfitting signal: gap > 15 pts)' if t - h > 15 else ''}")
    spend = [open(f).read().strip() for f in glob.glob(f'{run}/**/.spend-usd', recursive=True)]
    L += ['', '## Notes', '',
          f"- Hosted spend estimate (agent_turn tokens x list price): {', '.join(spend) or 'n/a'} USD; the Console spend limit is the hard cap.",
          '- Judge: blind (X/Y order random per case; no model, provider, timing or token data). Self-preference risk: a judge of the same '
          'family as one arm tends to prefer that arm (a Claude judge with a Claude challenger, a Codex/GPT judge with Luna). The judge family '
          f"of this run: {env.get('JUDGE_FAMILY', 'not recorded')}.",
          '- The challenger in the llamacpp slot runs the llamacpp-only engine paths (no-think client, compact mail prompt, German retry).', '']
    os.makedirs(run, exist_ok=True)
    open(f'{run}/REPORT.md', 'w').write('\n'.join(L) + '\n')
    print(f'{run}/REPORT.md')


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'blind':
        blind(sys.argv[2], sys.argv[sys.argv.index('--seed') + 1] if '--seed' in sys.argv else 'blind')
    elif cmd == 'score':
        score(sys.argv[2])
    elif cmd == 'gate':
        gate(sys.argv[2], sys.argv[3], '--shared' in sys.argv)
    elif cmd == 'report':
        report(sys.argv[2], [tuple(x.split('=', 1)) for x in sys.argv[3:]])
    else:
        sys.exit(__doc__)
