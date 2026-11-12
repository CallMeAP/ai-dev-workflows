#!/usr/bin/env python3
"""Estimate the API-price cost of all Claude Code usage (what /usage -> Stats counts).

All-time tokens per model come from ~/.claude/stats-cache.json (the Stats tab's source; it covers days up
to its lastComputedDate, and old transcripts get cleaned up, so they cannot be used for history). Usage after
that date is added from the transcripts under ~/.claude/projects (deduplicated by message id). The cache keeps no
TTL split for writes, so stats-cache writes are priced at the 1-hour rate (what Claude Code writes today);
transcript writes use their recorded split. Result: ~/.claude/state/cost-total.json. Transcript files are
cached by (mtime, size, cutoff), so a refresh only re-reads changed ones.
"""
import json, os, sys, time

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".claude", "projects")
STATE = os.path.join(HOME, ".claude", "state")
OUT = os.path.join(STATE, "cost-total.json")
CACHE = os.path.join(STATE, "cost-total-cache.json")

# USD per million tokens: input, output, cache write 5m, cache write 1h, cache read.
# Source: claude-api skill model table (cached 2026-11-03). Older models only matter for old transcripts.
PRICES = {
    "claude-fable-5-2": (8, 40, 10, 16, 0.20),
    "claude-mythos-5-2": (8, 40, 10, 16, 0.20),
    "claude-fable-5-1": (10, 50, 12.5, 20, 0.25),
    "claude-fable-5": (10, 50, 12.5, 20, 1.00),
    "claude-opus-5-5": (4, 20, 5, 8, 0.20),
    "claude-opus-5": (5, 25, 6.25, 10, 0.50),
    "claude-opus-4": (5, 25, 6.25, 10, 0.50),
    "claude-sonnet-5-5": (2, 10, 2.5, 4, 0.10),
    "claude-sonnet-5": (2, 10, 2.5, 4, 0.20),
    "claude-sonnet-4": (3, 15, 3.75, 6, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.125, 0.20, 0.01),
    "claude-haiku-4": (1, 5, 1.25, 2, 0.10),
}


def price_for(model):
    best = None
    for key in PRICES:  # longest matching prefix wins (claude-opus-5-5 before claude-opus-5)
        if model.startswith(key) and (best is None or len(key) > len(best)):
            best = key
    return PRICES.get(best)


def file_cost(path, since):
    seen, cost, unknown = set(), 0.0, set()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"usage"' not in line or '"assistant"' not in line:
                continue
            try:
                msg = json.loads(line).get("message") or {}
            except ValueError:
                continue
            if (json.loads(line).get("timestamp") or "") < since:
                continue
            u, mid, model = msg.get("usage"), msg.get("id"), msg.get("model") or ""
            if not u or not mid or mid in seen or model == "<synthetic>":
                continue
            seen.add(mid)
            p = price_for(model)
            if not p:
                unknown.add(model)
                continue
            cc = u.get("cache_creation") or {}
            w5 = cc.get("ephemeral_5m_input_tokens")
            w1 = cc.get("ephemeral_1h_input_tokens")
            if w5 is None and w1 is None:
                w5, w1 = u.get("cache_creation_input_tokens", 0), 0
            cost += (u.get("input_tokens", 0) * p[0] + u.get("output_tokens", 0) * p[1]
                     + (w5 or 0) * p[2] + (w1 or 0) * p[3] + u.get("cache_read_input_tokens", 0) * p[4]) / 1e6
    return cost, sorted(unknown)


def main():
    os.makedirs(STATE, exist_ok=True)
    try:
        with open(CACHE) as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        cache = {}
    stats = {}
    try:
        with open(os.path.join(HOME, ".claude", "stats-cache.json")) as fh:
            stats = json.load(fh)
    except (OSError, ValueError):
        pass
    last = stats.get("lastComputedDate") or "0000-00-00"
    since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.mktime(time.strptime(last, "%Y-%m-%d")) + 86400)) if last[0] != "0" else ""
    total, unknown = 0.0, set()
    for model, u in (stats.get("modelUsage") or {}).items():
        p = price_for(model)
        if not p:
            unknown.add(model)
            continue
        total += (u.get("inputTokens", 0) * p[0] + u.get("outputTokens", 0) * p[1]
                  + u.get("cacheCreationInputTokens", 0) * p[3] + u.get("cacheReadInputTokens", 0) * p[4]) / 1e6
    stats_total = total
    new = {}
    for d, _, files in os.walk(ROOT):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(d, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime < time.mktime(time.strptime(last, "%Y-%m-%d")) + 86400 - 86400 * 2 and last[0] != "0":
                continue  # untouched since before the cutoff: nothing after it
            key = f"{st.st_mtime_ns}:{st.st_size}:{since}"
            hit = cache.get(path)
            if hit and hit["k"] == key:
                c, unk = hit["c"], hit.get("u", [])
            else:
                c, unk = file_cost(path, since)
            new[path] = {"k": key, "c": c, "u": unk}
            total += c
            unknown.update(unk)
    for path, data in ((CACHE, new), (OUT, {"computed_at": int(time.time()), "total_usd": round(total, 2),
                                           "stats_through": last, "stats_usd": round(stats_total, 2),
                                           "since_usd": round(total - stats_total, 2), "files": len(new), "unpriced_models": sorted(unknown)})):
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)


if __name__ == "__main__":
    sys.exit(main())
