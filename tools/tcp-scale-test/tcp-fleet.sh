#!/bin/bash
# Synthetic TCP fleet for PingCanvas scale testing - one dummy interface,
# three response classes by port, identical on every fleet address:
#   9101 ACCEPT - one 0.0.0.0 listener answers for every address
#   9102 RST    - nothing listens; the kernel refuses (fast, cheap "down")
#   9103 DROP   - nftables swallows the SYN (slow "down": full client timeout)
# Usage: sudo ./tcp-fleet.sh up N | sudo ./tcp-fleet.sh down
set -euo pipefail
CMD=${1:-up}; N=${2:-100}
if [ "$CMD" = up ]; then
    # Delete-and-recreate rather than flush: flushing thousands of
    # addresses can fail partway and leave a half-built fleet - link del is
    # atomic and instant.
    ip link del dummy0 2>/dev/null || true
    ip link add dummy0 type dummy
    ip link set dummy0 up
    # One ip -batch exec for N addresses: 10.99.T.H, H=1..250
    seq 0 $((N-1)) | awk '{printf "addr add 10.99.%d.%d/16 dev dummy0\n", int($1/250), ($1%250)+1}' > /tmp/fleet.batch
    ip -batch /tmp/fleet.batch   # fail LOUD: a half-built fleet reports phantom downs
    if ! nft list table inet tcptest >/dev/null 2>&1; then
        nft add table inet tcptest
        nft 'add chain inet tcptest input { type filter hook input priority 0 ; }'
        nft add rule inet tcptest input ip daddr 10.99.0.0/16 tcp dport 9103 drop
    fi
    echo "fleet up: $N addresses on dummy0, DROP armed on :9103"
elif [ "$CMD" = down ]; then
    nft delete table inet tcptest 2>/dev/null || true
    ip link del dummy0 2>/dev/null || true
    echo "fleet down"
fi
