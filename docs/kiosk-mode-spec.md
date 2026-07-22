# PingCanvas - Kiosk Mode spec (CrossCanvas fork)

> **Historical design spec.** This is the document the kiosk was built from;
> the shipped implementation differs in places (the wall is `kiosk.html`, and
> some ideas below were never built). For current usage see
> [kiosk/README.md](../kiosk/README.md) and [CONFIGURATION.md](CONFIGURATION.md).

A read-only, full-screen mode that loads a `.xcanvas` board and a `status.json`
feed, then continuously recolors devices/zones by reachability. Designed for an
unattended wall TV. Fork-and-strip from CrossCanvas; reuse the SVG renderer, themes,
zoom-to-fit, Device Details fields, and zone traversal. **Add a status overlay
layer - never mutate the diagram model** (no undo entries, no edits, no saves).

---

## 1. Activation & config

Kiosk mode is entered by URL params so the same build can still open normally
during development:

    board.html?kiosk=1&board=board.xcanvas&status=status.json&interval=30

| Param      | Default            | Meaning                                              |
|------------|--------------------|------------------------------------------------------|
| `kiosk`    | (off)              | `1` enables kiosk mode                               |
| `board`    | `board.xcanvas`    | URL of the layout file (same-origin)                 |
| `status`   | `status.json`      | URL of the status feed (same-origin)                 |
| `interval` | file's `pollIntervalSec` | override poll seconds                          |
| `rotate`   | (none)             | comma list of board URLs to cycle (multi-board wall) |
| `staleMul` | `2`                | stale threshold = `staleMul × interval`              |

All same-origin; no cross-origin fetch, no credentials, no writes.

## 2. Load sequence

1. Parse params.
2. Fetch `board` once → existing `applyDiagramData(JSON.parse(...))` path.
3. Strip chrome (section 3), fit to viewport (section 4).
4. Build an `ip → [deviceEl]` index from Device Details **IP-Address** (an
   optional **Monitor ID** custom field overrides the key when present).
5. Start the poll loop (section 5).

**Layout vs status split:** the board is fetched **once**; only `status.json`
is polled (small, frequent). Optionally re-fetch the board on a slow timer or
when a `boardVersion` field in `status.json` changes, so layout edits published
from the editor propagate to the wall without a manual reload.

## 3. Chrome stripping

Hide/disable (CSS class `body.kiosk` + guards): sidebar, toolbar, menu bar,
properties panel, context menu, all keyboard shortcuts that mutate, drag/select
handlers, resize handles, scrollbars. Canvas fills the viewport. Cursor hidden
after N seconds idle. No dirty flag, no beforeunload prompt.

## 4. Fit & responsive

- On load and on `window.resize`, run zoom-to-fit (reuse existing fit-to-content)
  with a small margin so the whole board is always visible - no panning on a wall.
- Default to the dark theme (TVs); honor the board's saved theme otherwise.

## 5. Poll loop

- `setInterval(poll, interval*1000)`; also poll immediately on start.
- `poll()`: `fetch(status + '?t=' + Date.now())` (cache-bust) → JSON.
  - success → `renderStatus(doc)`, reset the miss counter, update the clock.
  - failure or bad JSON → keep the **last good** render, increment miss counter.
- Never throw out of the loop; a poll error must not stop future polls.

## 6. Status → visual mapping

Do **not** touch `tintColor` (themes own it). Layer a separate status indicator
per device - a **ring** around the device frame (cleanest, theme-independent),
plus an optional corner dot:

| state         | color            | notes                                  |
|---------------|------------------|----------------------------------------|
| `up`          | green            | steady                                 |
| `degraded`    | amber            | reachable, slow                        |
| `down`        | red              | optional pulse for the first ~30s      |
| `unknown`     | gray             | in feed but state unknown              |
| unmonitored   | gray, hollow     | board device with no matching feed entry |
| stale (all)   | dim gray board   | see section 7                          |

- A board device with no feed entry = **unmonitored** (hollow gray ring), counted
  separately - makes coverage gaps visible instead of falsely green. This is the
  drift signal: the device HAS an IP/Monitor ID, so it was meant to be monitored.
- A board device with no IP-Address and no Monitor ID = **opted out**: no ring,
  no legend count. The addressing field is the declaration of intent - a UPS
  drawn for its label stats or an internet cloud renders as a plain fixture.
- A feed entry with no board device = ignored for drawing, counted in a
  "N not on board" tally (helps reconcile the CSV against the diagram).

**Zone aggregation:** a zone's header/border reflects the worst state among its
descendant *monitored* devices - red if any down, amber if any degraded, else
green (or neutral if it contains none). Reuse existing zone-child enumeration.

## 7. Staleness (the safety net)

- Compute `ageSec = now - Date.parse(doc.generated)`.
- If `ageSec > staleMul × interval`: show a fixed **STALE** banner across the top
  ("Status data is N s old - poller may be down") and desaturate the whole board
  to gray so no one trusts stale colors.
- Two consecutive fetch failures also trigger stale (the file stopped updating).
- Clear immediately on the next fresh, parseable poll.

This is the whole reason for the file-based design: a dead poller becomes
visibly stale rather than silently green.

## 8. Persistent chrome (kiosk HUD)

Fixed, low-profile overlays (not part of the board):
- **Legend + counts:** up / degraded / down / unmonitored totals.
- **Clock:** "updated 8s ago" from `doc.generated`; turns red when stale.
- **Board title** (optional) and, if `rotate` set, a small board-N-of-M pill.

## 9. Optional interactions

- Click a device → popover: name, IP, state, `since` (uptime/downtime), latency.
  (Wall TVs are usually passive; gate behind a `&clickable=1` param.)
- Multi-board rotation: every `rotateSec`, swap to the next `board` URL, re-fit,
  keep the same status feed (or a per-board feed via naming convention).

## 10. Robustness / threat model

- Read-only, same-origin, no writes, no credentials. IIS serves static files
  only - no server-side code, minimal attack surface.
- Tolerate: malformed/partial `status.json` (keep last good + stale), missing
  fields (default to `unknown`), duplicate IPs on the board (all devices with
  that IP share the one status - document it; use **Monitor ID** to disambiguate),
  devices present on one side only (both counted, section 6).
- The display never scans anything; all network activity lives in the poller.

## 11. Reuse map (what CrossCanvas already gives us)

| Need                    | Existing CrossCanvas piece                          |
|-------------------------|-------------------------------------------------|
| Render board            | SVG renderer + `applyDiagramData`               |
| Fit to wall             | zoom-to-fit / fit-to-content                    |
| Theme / dark mode       | theme system (TV-friendly)                      |
| Device identity (IP)    | Device Details → IP-Address (+ Monitor ID)      |
| Zone rollups            | zone child traversal                            |
| Author the board        | editor, or CC/ISE inventory import (auto-layout)|

## 12. Build order (smallest demo first)

1. `?kiosk=1` strips chrome + fits board (no status yet).
2. Add `renderStatus` rings from a hand-written `status.json`.
3. Add the poll loop + clock.
4. Add staleness banner + desaturate.
5. Add zone aggregation.
6. Point at the live PowerShell poller - full loop.
7. (Later) board auto-refresh, rotation, click popovers.

Steps 1-4 are an afternoon and validate the whole concept end-to-end against the
already-working poller.
