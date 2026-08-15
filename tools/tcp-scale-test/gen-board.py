#!/usr/bin/env python3
# Board + config generator for the scale test.
#   gen-board.py N [accept,rst,drop]     default mix 90,5,5
# Class assignment is k % 100 against the mix thresholds, so every
# poller batch of 100 consecutive devices carries exactly the mix -
# uniform poisoning, which is the worst case for the batch-wait design
# and therefore the honest one to measure first.
import json, sys

n = int(sys.argv[1])
mix = sys.argv[2] if len(sys.argv) > 2 else '90,5,5'
pa, pr, pd = [int(x) for x in mix.split(',')]
assert pa + pr + pd == 100, 'mix must sum to 100'

devs = []
for k in range(n):
    ip = f"10.99.{k // 250}.{k % 250 + 1}"
    r = k % 100
    port = 9101 if r < pa else (9102 if r < pa + pr else 9103)
    devs.append({"id": f"d{k}", "label": f"t{k}",
                 "fields": {"IP-Address": ip, "Check": "tcp", "Port": str(port)}})

with open(f"board-{n}.xcanvas", "w") as f:
    json.dump({"devices": devs}, f)
cfg = {"pollIntervalSec": 30, "timeoutMs": 1000, "degradedMs": 150,
       "throttleLimit": 100, "outputDir": "./out",
       "combinedStatus": f"status-all-{n}.json",
       "boards": [{"file": f"./board-{n}.xcanvas", "status": f"status-{n}.json"}]}
with open(f"config-{n}.json", "w") as f:
    json.dump(cfg, f, indent=2)
print(f"board-{n}.xcanvas + config-{n}.json  (mix {pa}/{pr}/{pd} accept/rst/drop)")
