"""Deterministic, stratified 70/30 split of the self-test cases into a tune set and a held-back set, stored with the run.
Usage: python3 -I split.py <run-dir> --seed S [--prev <old split.json>] [--fresh <fresh.json> ...] <cases.json> [<cases.json> ...]
Writes <run-dir>/split.json, <run-dir>/tune/<suite>.json and <run-dir>/heldback/<suite>.json (the main skill's case format).

- Stratified per suite (case "suite", else the file name): per suite round(30 %) held back, at least 1 when the suite has 2+ cases.
- Deterministic: order by sha256(seed:id). With --prev every case keeps its earlier set (a held-back case never moves to tune,
  so nothing the tuning loop never saw leaks into it); only new cases are assigned, held-back first until the suite reaches 30 %.
- --fresh: new paraphrased/generated cases of this run (ids "fr-<run>-..."), always held back, marked "fresh": true.
  Earlier runs' fresh.json files go in as plain case files: --prev keeps them held back (and anything fr-... unknown to --prev too).
The tuning loop reads tune/ only. Print shows counts, never case text."""
import argparse, hashlib, json, os, sys

ap = argparse.ArgumentParser()
ap.add_argument('run'); ap.add_argument('cases', nargs='+')
ap.add_argument('--seed', required=True); ap.add_argument('--prev'); ap.add_argument('--fresh', action='append', default=[])
a = ap.parse_args()

suites, src = {}, {}
for f in a.cases:
    for c in json.load(open(f)):
        s = c.get('suite') or os.path.splitext(os.path.basename(f))[0]
        c['suite'] = s
        if c['id'] in src: sys.exit(f"duplicate case id {c['id']} in {f} and {src[c['id']]}")
        src[c['id']] = f; suites.setdefault(s, []).append(c)
prev = json.load(open(a.prev))['suites'] if a.prev else {}
h = lambda i: hashlib.sha256(f'{a.seed}:{i}'.encode()).hexdigest()
out = {'seed': a.seed, 'prev': a.prev, 'sources': sorted(set(src.values())), 'suites': {}}
for s, cs in sorted(suites.items()):
    p = prev.get(s, {})
    held = [c['id'] for c in cs if c['id'] in p.get('heldback', []) + p.get('fresh', [])]   # earlier fresh cases stay held back
    tune = [c['id'] for c in cs if c['id'] in p.get('tune', [])]
    want = max(1, round(0.3 * len(cs))) if len(cs) >= 2 else 0
    held += [c['id'] for c in cs if c['id'].startswith('fr-') and c['id'] not in held + tune]
    for c in sorted((c for c in cs if c['id'] not in held + tune), key=lambda c: h(c['id'])):
        (held if len(held) < want else tune).append(c['id'])
    out['suites'][s] = {'tune': tune, 'heldback': held, 'fresh': []}
for f in a.fresh:
    for c in json.load(open(f)):
        if not c['id'].startswith('fr-'): sys.exit(f"fresh case id must start with fr-: {c['id']}")
        if c['id'] in src: sys.exit(f"duplicate case id {c['id']}")
        c['fresh'] = True; s = c.get('suite') or 'fresh'; c['suite'] = s; src[c['id']] = f
        suites.setdefault(s, []).append(c)
        out['suites'].setdefault(s, {'tune': [], 'heldback': [], 'fresh': []})['fresh'].append(c['id'])
os.makedirs(f'{a.run}/tune', exist_ok=True); os.makedirs(f'{a.run}/heldback', exist_ok=True)
for s, cs in suites.items():
    x = out['suites'][s]; by = {c['id']: c for c in cs}
    for name, ids in (('tune', x['tune']), ('heldback', x['heldback'] + x['fresh'])):
        if ids: json.dump([by[i] for i in ids], open(f'{a.run}/{name}/{s}.json', 'w'), ensure_ascii=False, indent=1)
json.dump(out, open(f'{a.run}/split.json', 'w'), indent=1)
for s, x in sorted(out['suites'].items()):
    n = len(x['tune']) + len(x['heldback'])
    print(f"{s:12} cases {n:3}  tune {len(x['tune']):3}  held-back {len(x['heldback']):3} ({100 * len(x['heldback']) / max(n, 1):.0f} %)  fresh {len(x['fresh'])}")
