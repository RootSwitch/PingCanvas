# Changelog

Forward-only from 2026-07: PingCanvas evolved continuously (and pre-dates
the rest of the suite's versioning habit), so history before this point
lives in `git log` rather than reconstructed entries. Entries below record
what changed and when, newest first.

## Unreleased

- **Kiosk fetches twice per produced status file.** The kiosk polled the
  status feed at exactly the rate the poller wrote it, so a fetch landing
  just before a fresh write left the board showing data that aged a further
  whole interval before the next fetch. "updated Ns ago" peaked near 2x the
  poll interval - 60s+ on the default 30s poller, right at the staleness
  threshold - on a wall that was entirely healthy. Fetching at half the
  advertised interval bounds the displayed age at 1.5x instead, keeping it
  clearly below the stale threshold. The threshold itself still uses the
  full interval; halving that would have fired the stale banner every cycle
  on a healthy poller. Covered by `kiosk/status-layer.test.js`.

## 2026-07 - current state

The wall as it stands: CrossCanvas boards render as a live kiosk with ping
status (green/amber/red/gray), latency labels, zone attention rings, theme
rotation and pixel-orbit burn-in care, and an optional SNMPCanvas overlay
(link bandwidth pills, `{code}` metrics in labels, warn/crit frame tints).
A PowerShell poller does the pinging (ICMP or TCP per device, Monitor ID
aliasing, per-board + combined status files, atomic writes); nginx or IIS
serves the result, with the CrossCanvas editor co-hosted on the same web
tier in the Docker layout. Part of the six-app
[Canvas Suite](https://github.com/RootSwitch/canvas-suite): AlertCanvas
alerts on the poller's combined feed, LaunchCanvas uploads boards to the
wall, and the suite setup script (or `canvas-wall-setup.sh` for the
PingCanvas + AlertCanvas pair) stands it all up in one shot. Tested down
to a Raspberry Pi 3B.
