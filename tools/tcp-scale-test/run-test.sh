#!/bin/bash
# One measurement run: bring the fleet to N, run the real poller for a fixed
# window, print each status write (cycle boundary) with the fleet TIME_WAIT
# count beside it, then check class correctness.
#   ./run-test.sh N [mix] [seconds]
set -euo pipefail
N=${1:?usage: run-test.sh N [mix] [seconds]}
MIX=${2:-90,5,5}
SECS=${3:-150}
cd "$(dirname "$0")"

sudo ./tcp-fleet.sh up "$N"
pkill -f 'listener.py' 2>/dev/null || true
nohup python3 listener.py >/dev/null 2>&1 &
sleep 0.5
python3 gen-board.py "$N" "$MIX"
mkdir -p out
rm -f "out/status-$N.json"

echo "== N=$N mix=$MIX window=${SECS}s =="
pwsh -NoProfile -File pingcanvas-poller.ps1 -Config "config-$N.json" > "poller-$N.log" 2>&1 &
POLLER=$!

last=""
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$SECS" ]; do
    sleep 1
    tw=$(ss -Htan state time-wait 2>/dev/null | grep -c '10\.99\.' || true)
    if [ -f "out/status-$N.json" ]; then
        m=$(stat -c %Y "out/status-$N.json")
        if [ "$m" != "$last" ]; then
            [ -n "$last" ] && echo "  cycle write at +$(( m - start ))s  (delta $(( m - ${lastm:-m} ))s)  fleet TIME_WAIT=$tw"
            [ -z "$last" ] && echo "  first write at +$(( m - start ))s  fleet TIME_WAIT=$tw"
            lastm=$m; last=$m
        fi
    fi
done
kill "$POLLER" 2>/dev/null || true
wait "$POLLER" 2>/dev/null || true
pkill -f 'listener.py' 2>/dev/null || true

echo "-- correctness --"
python3 check-status.py "$N" && echo "-- classes all correct --"
echo "-- poller log tail --"
tail -3 "poller-$N.log"
