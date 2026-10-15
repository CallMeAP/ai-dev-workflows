#!/usr/bin/env python3
"""Scan a git range for tenant names and VERA credential values from creds.csv. Never prints a value.

  python3 -I leak-scan.py <repo-or-worktree> <range> [creds.csv]
  e.g. python3 -I leak-scan.py ~/Entwicklung/bpp/bpp-vera-connector.worktrees/x origin/development..HEAD

Scans the added lines of `git diff <range>` and the commit messages of `git log <range>`.
Prints only column name, file and line number. Exit 1 = at least one hit.
"""
import os
import csv
import subprocess
import sys

COLUMNS = ("tenant_name", "vera_username", "vera_password", "vera_api_key", "vera_client_secret",
           "vera_client_id", "vera_user_token", "tenant_id", "go_user_id")
MIN_LEN = 4  # shorter values match everywhere and prove nothing

repo, rng = sys.argv[1], sys.argv[2]
creds = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/Downloads/.vera-audit/creds.csv")

needles = {}  # lowercased value -> column (first column wins)
for row in csv.DictReader(open(creds, newline="")):
    for col in COLUMNS:
        v = (row.get(col) or "").strip().lower()
        if len(v) >= MIN_LEN:
            needles.setdefault(v, col)

def git(*args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout

hits = []
current, lineno = "?", 0
for line in git("diff", "-U0", rng).splitlines():
    if line.startswith("+++ "):
        current = line[6:] if line.startswith("+++ b/") else line[4:]
    elif line.startswith("@@"):
        lineno = int(line.split("+")[1].split(",")[0].split(" ")[0]) - 1
    elif line.startswith("+"):
        lineno += 1
        low = line[1:].lower()
        hits += [(col, current, lineno) for v, col in needles.items() if v in low]
log = git("log", "--format=%H%n%B", rng).lower()
hits += [(col, "commit messages", 0) for v, col in needles.items() if v in log]

for col, f, n in sorted(set(hits)):
    print(f"HIT {col}: {f}" + (f":{n}" if n else ""))
print(f"scanned {rng}: {len(needles)} distinct values, {len(set(hits))} hit(s)")
sys.exit(1 if hits else 0)
