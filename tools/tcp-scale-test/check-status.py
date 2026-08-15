#!/usr/bin/env python3
# Correctness check: join the board (ip -> port class) with the status file
# (ip -> state) and report per-class outcomes plus any misclassification.
#   check-status.py N
import json, sys, collections

n = sys.argv[1]
board = json.load(open(f"board-{n}.xcanvas"))
status = json.load(open(f"out/status-{n}.json"))

cls = {}
for d in board["devices"]:
    f = d["fields"]
    cls[f["IP-Address"]] = {"9101": "accept", "9102": "rst", "9103": "drop"}[f["Port"]]

devmap = status.get("devices") or {}
per = collections.defaultdict(collections.Counter)
missing = 0
for ip, c in cls.items():
    entry = devmap.get(ip)
    if entry is None:
        missing += 1
        continue
    per[c][entry.get("state", "?")] += 1

bad = []
for c, states in sorted(per.items()):
    want = "up" if c == "accept" else "down"
    wrong = sum(v for s, v in states.items() if s != want and not (c == "accept" and s == "degraded"))
    print(f"  {c:7s} {dict(states)}  expected={want}" + (f"  WRONG={wrong}" if wrong else ""))
    if wrong:
        bad.append(c)
print(f"  missing from status: {missing}")
sys.exit(1 if bad or missing else 0)
