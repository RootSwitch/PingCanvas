# Changelog

Forward-only from 2026-07: PingCanvas evolved continuously (and pre-dates
the rest of the suite's versioning habit), so history before this point
lives in `git log` rather than reconstructed entries. Entries below record
what changed and when, newest first.

## Unreleased

- **`tools/test-snmp-schema.js`**: proves a kiosk indexes an SNMPCanvas v3 feed
  and a v4 feed identically. Version skew between siblings is normal - separate
  repos mean somebody updates SNMPCanvas on Tuesday and the kiosk Pi in March -
  and v4 flattened `device` to a string and moved `sampledAt` to epoch seconds.
  The failure it guards against is quiet: a board whose annotations stop binding
  still renders perfectly, just with no numbers on it. It lifts the real
  `buildIndex` out of `kiosk/snmp-layer.js` rather than copying it, so an edit
  to the shipped function is an edit to what the test covers.

- **A degraded link hatches its bandwidth pill.** Link state was carried by
  colour alone - amber for degraded - so it was invisible to anyone who cannot
  separate amber from green, the same gap the device rings had. The pill now
  fills with a diagonal hatch instead. Deliberately a fill swap rather than an
  extra "Degraded" line of text: identical geometry, so nothing new can cover
  the label beneath it. On a board dense enough to be worth watching there is
  no spare room, and an indicator that obscures the diagram is one operators
  turn off. Down links are unchanged (they pulse and read `--`).
- **A bare `kiosk.html` now finds the board on a suite install.** The default
  was `board.xcanvas` beside `kiosk.html`, but the suite setup script and the
  LaunchCanvas tile put boards in the shared data root, which nginx serves at
  `/data/` - so typing the URL by hand showed the starter board's "place a
  board here" guidance while a real board sat one directory away. Accurate from
  the file's point of view; baffling from the operator's. The default search is
  now `board.xcanvas` -> `data/board.xcanvas` -> `board.netdraw`, and the
  status/SNMP feeds default to **whichever directory the board was found in**
  rather than always the web root - otherwise a suite install rendered a live
  board with every device permanently gray. An explicit `?board=` is still
  never second-guessed, only a 404 advances the search (a board that exists but
  is broken still fails loudly by name), and a root-level board still wins for
  standalone deployments.
- **Kiosk reads snmp-status.json schema v4 as well as v3.** v4 sends `device`
  as the device NAME instead of a `{name, host, status}` object and drops `id`
  (which was always `device + ":" + name`), cutting the file roughly in half.
  The kiosk now derives the `Device:ifName` binding key when `id` is absent and
  reads the device name from either shape, so board annotations keep binding
  either way. Both schemas are accepted deliberately: suite apps are updated
  independently, and an operator who updates SNMPCanvas on Tuesday and
  PingCanvas on Friday should not get a blank wall in between. Covered by
  `kiosk/snmp-layer.schema.test.js`, which extracts the real `buildIndex` from
  the shipped file rather than re-implementing it.
- **Status no longer depends on telling colours apart.** Each state's ring now
  carries a dash pattern saying what its colour says: `up` solid, `degraded`
  dashed, `unknown`/`unmonitored` dotted, `down` unchanged (it already had a
  translucent body wash and a pulse, so it never needed colour). This closes a
  real gap rather than adding decoration - `up` (#2e9b57) and `degraded`
  (#d9a406) are the classic red-green confusion pair and collapse to nearly the
  same olive for the ~8% of men with deuteranopia, so a **degrading device read
  as healthy**, the worst direction for that to fail. The HUD legend swatches
  are now outlines carrying the same patterns, since a key that varies only by
  colour is unusable by the people the patterns are for. Zone rings take the
  pattern but not the body wash. Dashes are static, so unlike the pulse they
  also survive monochrome displays and printouts.
- **The editor no longer flashes on screen before the kiosk takes over.**
  `kiosk.css` scopes every chrome-hiding rule to `body.kiosk`, but that class
  was only added once `kiosk-init.js` ran - after ~800KB of `app.js` had been
  parsed and executed. Since the editor chrome is static markup, the browser
  painted the whole editor first and hid it afterwards, which on a Raspberry Pi
  is slow enough to sit and watch. The build now writes `class="kiosk"` into
  the markup, so the rules apply from the first byte and the chrome never
  paints. Verified by loading the built page with every script stripped: the
  chrome is hidden with no JavaScript at all.
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
