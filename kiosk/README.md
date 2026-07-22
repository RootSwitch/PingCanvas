# PingCanvas kiosk (fork of CrossCanvas)

The kiosk is a **read-only fork of CrossCanvas** that loads a `.xcanvas` board and a
`status.json` feed, then continuously recolors devices by reachability for an
unattended wall display. This folder holds the *net-new* pieces; the renderer
itself comes from CrossCanvas.

## What's here

| File              | Status | Purpose                                                          |
|-------------------|--------|------------------------------------------------------------------|
| `kiosk-init.js`   | ready  | Boot: URL params → load board → fit → rings → wire `StatusFeed`  |
| `status-layer.js` | ready  | Renderer-agnostic poll loop + staleness + status→color mapping   |
| `snmp-layer.js`   | ready  | Optional SNMP link overlay (bandwidth + up/down on connections)  |
| `kiosk.css`       | ready  | Status ring, stale banner, HUD, chrome-hiding, inert canvas      |
| `web.config`      | ready  | IIS static hosting (`.xcanvas` MIME map)                          |
| `app.js` `devices.js` `style.css` `kiosk.html` | synced | **Build artifacts** from `tools/sync-from-crosscanvas.ps1` - gitignored, never edited here |

## How it stays in sync with CrossCanvas

Run `..\tools\sync-from-crosscanvas.ps1` after any CrossCanvas change. It copies
`app.js` / `devices.js` / `style.css` verbatim and generates `kiosk.html` from
CrossCanvas's `index.html` by injecting three lines at stable anchors (the embed
flag before `app.js`, `kiosk.css` after `style.css`, the kiosk scripts after
`app.js`).
Theme, color, markup and logic changes in CrossCanvas all flow through with no
hand-porting. The only upstream dependency is CrossCanvas's tiny embed hook
(`window.CROSSCANVAS_EMBED` + `window.CrossCanvas = { load, fitToView, contentBounds,
devices, zones, zoom, svg, theme, themes, recolor }`). `theme`/`themes`/`recolor`
are optional - the kiosk feature-detects them, so an older synced `app.js` simply
skips theme rotation instead of breaking. Note `recolor` re-renders the board
layers, so any overlay that patched the DOM in place must re-bind afterwards
(`SnmpLayer.rescan()`).

## URL parameters

`kiosk.html?board=board.xcanvas&status=status.json&interval=30&staleMul=2&margin=60`

All optional - the defaults are the values shown. Devices are matched to the
feed by Device Details **IP-Address** (a **Monitor ID** field overrides when
two devices share an IP). Zones get an attention ring colored by their worst
monitored child (shown only for down/degraded).

## Burn-in mitigation (optional)

Two independent knobs, best used together:

`?themes=night&themeInterval=600` rotates the theme every 10 minutes, repainting
the canvas background and chrome so a permanently-on panel isn't holding one
image for months. `?theme=blueprint` applies a single theme instead.

`?themeRecolor=1` goes further and restyles the **board itself** each time the
theme changes - device tints, zone fills, connection ink, label colors - using
the editor's Recolor to Theme on the in-memory copy only (your `.xcanvas` on
disk is never written). Off by default because it isn't right for every
diagram: it erases colors that carry meaning, only SVG icons retint, and
imported Gliffy/Visio boards keep their source styling. Live monitoring state
(rings, SNMP link colors, `{code}` values) is re-applied immediately after each
recolor.

Name kinds to protect a legend: `?themeRecolor=devices,zones` recolors those
and leaves connection/text-box colors alone, so a key built from colored links
and labels keeps meaning what it says. Kinds are `devices`, `zones`,
`connections`, `textBoxes`. Caveat table in
[../docs/CONFIGURATION.md](../docs/CONFIGURATION.md) §2c.

`?shift=8` adds a **pixel orbit**: the whole diagram steps around a small ring
(default every 300s, `?shiftInterval=`). Theme rotation recolors what's under
your zone and device edges but never moves them, and burn-in tracks static
high-contrast edges - so this is the half that protects the geometry. The
offset moves the viewBox with the background re-anchored to it, so nothing
gaps at the screen edge, and it's one attribute write per step (no animation,
which matters on a Pi).

Each theme supplies its own canvas color, so you never have to pick a
background hex - and whenever the applied background is dark (from a theme or a
plain `?bg=`), board label text is recolored to stay legible. That decision is
made per label against the surface actually under it (zone fills composited
over the canvas), so a light zone on a dark canvas keeps its dark text rather
than going light-on-light. Device, zone and
link colors deliberately do NOT rotate: on a monitoring wall they encode status.
Details and the full parameter list are in
[../docs/CONFIGURATION.md](../docs/CONFIGURATION.md) §2c.

## SNMP overlay (optional)

Add `&snmp=snmp-status.json` (and optionally `&snmpInterval=<sec>`) to overlay
live SNMP values onto the board. The feed is produced by the separate
**SNMPCanvas** project (which can write its `snmp-status.json` into the same
`./data` folder the poller uses); PingCanvas only displays it. Without `?snmp=`
the layer is completely inert - existing walls are unaffected.

There are two surfaces: **link bandwidth/up-down on connections** and **host
metrics on device labels**.

**Host metrics in a device label:** put a `{code}` token in a device label line
(in CrossCanvas: edit the label, add lines). On the wall each `{code}` is
replaced by that metric's live value, so a label

```
DNS-2                     DNS-2
{H4TN}          ->        CPU 45%
{D8YK}                    Disk 78%
```

You can put text around a token (`Rx: {K7Q2}`) or several on a line
(`{M2LP} / {G6QB}`); only the token is swapped. A `{code}` that matches nothing is
left literal, so a typo stays visible. A `cpu` metric with a `warn`/`crit`
status also tints its device's frame amber/red.

**Binding a link to an interface:** in CrossCanvas, add an **annotation** to the
connection (select the link, add an annotation). The **short `code`** is the
best match - unique, rename-proof, and offered as a paste-ready `{P9WT}` chip in
SNMPCanvas. The annotation can also use the interface `id` (`Device:ifName`, the
raw SNMP name like `EdgeSw-01:GigabitEthernet0/1`) or the friendlier
`Device:alias` (`EdgeSw-01:Uplink-1`) when the feed carries one. Braces work on
any of these, so a single `{code}` string pastes onto a link OR a device label
without editing it. On the
wall that text is replaced by a live `▼in ▲out` bandwidth pill; the link
recolors: **red (pulsing)** when the interface is down, **amber** when it is
near line rate (≥80%) or reporting errors/discards, **gray/dim** when its status
or counters are unknown, otherwise it keeps its own color. An annotation whose
text matches no interface keeps showing its text, so a typo stays visible.
(Only the link's stroke recolors - arrowheads keep the connection's own color.)

The feed schema is documented in [../docs/CONFIGURATION.md](../docs/CONFIGURATION.md);
`samples/snmp-status.json` + `samples/board-snmp.xcanvas` are a ready demo pair.

## Deploying

Copy this folder's contents plus your `board.xcanvas` to the IIS site the
poller writes `status.json` into (one origin - no CORS). That's the deploy.

## Testing at home (no IIS)

```
..\tools\sync-from-crosscanvas.ps1                     # refresh renderer copies
..\poller\pingcanvas-poller.ps1 -Config <cfg>       # writes status.json
..\tools\serve.ps1 -Root <webroot> -Port 8080      # or python -m http.server
```

Open `http://localhost:8080/kiosk.html?board=board.xcanvas&status=status.json`.
