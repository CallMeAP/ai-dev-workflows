#!/usr/bin/env python3
"""Emit one line per finished workflow phase segment (for away-mode status mails).

usage: python3 -I phasewatch.py <state_dir> <workflows_dir> [--mark-existing]
  state_dir      holds watch.txt (one run id per line, re-read every loop) and emitted.txt
  workflows_dir  <session transcript dir>/subagents/workflows
  --mark-existing  record segments that are already finished, print them once, exit
journal.jsonl: 'started' carries agentId+phase; 'result' or 'failed' carries only agentId.
A segment is a run of phase starts; re-entering a phase after another one started opens a new
segment (Fix -> Verify -> Fix gives Fix, Verify, Fix#2) only when the earlier segment had finished;
pipelined phases that interleave stay one segment each. A segment is finished when a later
segment has started and each of its agents has a result or failed line. The last segment is
reported by the workflow's completion notification, not here. A segment whose agents never all
report (killed/crashed agents write no line) is emitted with noresult=N after STALL seconds without
progress (loop mode only; --mark-existing leaves it for the loop).
"""
import json, os, sys, time

state, wfdir = sys.argv[1], sys.argv[2]
once = '--mark-existing' in sys.argv
said = set()  # distinct warnings already printed
STALL = 3600  # s without progress before a moved-past segment with silent agents is reported anyway
progress = {}  # key -> ((ok, failed), since)

def warn(msg):
    if msg not in said:
        said.add(msg)
        print(f'WATCH_ERROR {msg}', flush=True)

def scan():
    emitted = set(open(f'{state}/emitted.txt').read().split('\n')) if os.path.exists(f'{state}/emitted.txt') else set()
    watch = [l.strip() for l in open(f'{state}/watch.txt') if l.strip()] if os.path.exists(f'{state}/watch.txt') else []
    for wf in watch:
        j = f'{wfdir}/{wf}/journal.jsonl'
        if not os.path.exists(j):
            warn(f'{wf} no journal at {j}')
            continue
        segs, seg_of = [], {}  # segs: [phase, n, started, ok, failed]
        for line in open(j):
            try:
                e = json.loads(line)
            except Exception:
                continue
            aid = e.get('agentId')
            if not aid:
                continue
            if e.get('type') == 'started':
                p = e.get('phase') or '?'
                prev = [s for s in segs if s[0] == p]
                last = prev[-1] if prev else None
                # join the phase's latest segment unless it had already finished and another
                # phase started since (a real loop: Fix -> Verify -> Fix); pipelines interleave
                # starts of unfinished phases and must not count as re-entry
                if last is None or (segs[-1] is not last and last[3] + last[4] >= last[2]):
                    last = [p, len(prev) + 1, 0, 0, 0]
                    segs.append(last)
                last[2] += 1
                seg_of[aid] = last
            elif e.get('type') in ('result', 'failed') and aid in seg_of:
                seg_of[aid][3 if e['type'] == 'result' else 4] += 1
        for i, (p, n, st, ok, fl) in enumerate(segs[:-1]):
            key = f'{wf}|{p}|{n}'
            if key in emitted:
                continue
            pr = progress.get(key)
            if pr is None or pr[0] != (ok, fl):
                progress[key] = pr = ((ok, fl), time.time())
            lost = st - ok - fl  # agents with no result/failed line (killed, crashed)
            if lost > 0 and (once or time.time() - pr[1] < STALL):
                continue
            tag = p if n == 1 else f'{p}#{n}'
            extra = f' noresult={lost}' if lost > 0 else ''
            print(f'PHASE_DONE {wf} phase={tag} agents={ok}/{st} failed={fl}{extra} next={segs[i + 1][0]}', flush=True)
            with open(f'{state}/emitted.txt', 'a') as f:
                f.write(key + '\n')
            emitted.add(key)

if once:
    scan()
    sys.exit(0)
while True:
    try:
        scan()
    except Exception as ex:
        warn(str(ex))
    time.sleep(60)
