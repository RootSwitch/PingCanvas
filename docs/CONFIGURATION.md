# PingCanvas - every knob in one place

All supported customization, by layer: what you set, where, and what it does.
Defaults in **bold** work out of the box - everything here is optional.

Layers, top to bottom: the **board** describes what to monitor, the **poller**
probes it, **status files** carry the results, the **kiosk** displays them, and
**Docker/IIS** wrap it all. Each layer only reads the one above it.

---

## 1. The board (drawn in CrossCanvas - Device Details fields)

The board file is the monitoring contract. Fields are set per device in the
CrossCanvas editor under **Device Details**.

| Field | Values | Effect |
|---|---|---|
| `IP-Address` | IPv4 | **The opt-in.** Devices with an IP are monitored; without one (and without a `Monitor ID`) they get no status ring at all - they render as plain diagram fixtures (a UPS shown for its label stats, an internet cloud) and stay out of the legend counts. |
| `Check` | **`icmp`** / `tcp` | Probe type. `tcp` connects instead of pinging - works where ICMP is blocked and needs no NET_RAW/host networking. |
| `Port` | 1-65535 | Port for `Check=tcp`. Invalid values fall back to icmp with a poller warning. |
| `Monitor ID` | free text | Optional status-entry key (default: the IP). Lets two shapes share one IP but carry distinct entries/names - e.g. the same device on a logical *and* a physical diagram. |
| `Hostname` | free text | Display name in the status feed and the kiosk's Down panel. Falls back to the label's first line, then the IP. |

Board-level conventions:

| Thing | Rule |
|---|---|
| Board filename | `board.xcanvas` → `status.json` (the kiosk default pair). Any other `X.xcanvas` → `status-X.json`. Drop-in is hot: the Docker poller auto-discovers every `*.xcanvas` in the data dir each cycle - no restart. |
| Diagram title | Becomes the kiosk tab title (`PingCanvas - <title>`). Generic titles (`board`, `network-diagram`) collapse to `PingCanvas - Monitor`. |
| "board" in the title | CrossCanvas skips the `_vN` filename suffix on save (stable filename for the kiosk/poller to reference). Matches the standalone word or known compounds (whiteboard, dashboard, NOC/status/wall board). |

## 2. Kiosk URL parameters (`kiosk.html?...`)

| Param | Default | Effect |
|---|---|---|
| `board=` | **`board.xcanvas`** | Which board file to render. |
| `status=` | **`status.json`** | Which status feed to poll. |
| `interval=` | feed's `pollIntervalSec` | Per-display fetch cadence override, seconds (min 1). Normally unneeded - the kiosk adopts whatever the feed advertises. |
| `staleMul=` | **`2`** | Stale threshold = `staleMul × interval`. Data older than that (or 2 straight fetch failures) → STALE banner + grayscale board. |
| `margin=` | **`60`** | Fit-to-view padding in px around the board. |
| `grid=1` | **off** | Show the editor's grid on the wall. |
| `bg=` | board default | Solid canvas background - `%23112233` (# is URL-encoded) or a CSS color name. Handy for dark walls. On a dark background the board's labels are auto-recolored to stay legible. |
| `theme=` | board default | Apply one CrossCanvas theme (`blueprint`, `ink`, `synthwave`, ...). Also sets the canvas to that theme's own background, so you never pick a hex. See §2c. |
| `themes=` | **off** | Rotate themes to spare the panel: a group (`night`, `paper`, `warm`, `cool`, `screen`), a comma list (`ink,blueprint`), or `all`. |
| `themeInterval=` | **900** | Seconds between theme changes (min 5). |
| `themeBg=0` | **on** | Keep the board's own background; rotate only the chrome. |
| `themeRecolor=` | **off** | Also restyle the board's own objects to each theme. `1`/`all` for everything, or name the kinds to restyle - `devices,zones` leaves connection and text-box colors alone. Read the caveats in §2c first. |
| `shift=` | **off** | Pixel orbit: nudge the whole diagram this many px around a small ring, so no edge sits on one line of pixels. `8` is a good wall value. |
| `shiftInterval=` | **300** | Seconds between orbit steps (min 30). |
| `latency=0` | **on** | Hide the per-device response-time labels. |
| `snmp=` | **off** | Path to an `snmp-status.json` (SNMPCanvas) to overlay live link bandwidth/health onto connections. Absent = the SNMP layer is inert. See §2b. |
| `snmpInterval=` | feed's cadence / `30` | Fetch-cadence override for the SNMP feed, seconds (min 1). |
| `annstyle=native` | **chip** | Link readouts patch the annotation's own text in place (keeping its font, colors, and theme background) instead of the high-contrast overlay chip. |

Example dark wall: `kiosk.html?board=data/board.xcanvas&status=data/status.json&bg=%23111827&latency=0`

### 2b. SNMP overlay (optional)

The `?snmp=` layer displays live SNMP values on the board, produced by the
separate **SNMPCanvas** project (which may write into the same `./data` folder).
PingCanvas is display-only here. Two surfaces:

**Links** - add a CrossCanvas **annotation** to a connection. **The short
`code` is the recommended match** (`P9WT`, or the paste-ready `{P9WT}` chip
SNMPCanvas offers) - it is globally unique and immune to interface renames. An
annotation can also match the interface `id`, which is `Device:ifName` (the raw
SNMP name, e.g. `EdgeSw-01:GigabitEthernet0/1`), or the friendlier
`Device:alias` (the interface's ifAlias, e.g. `EdgeSw-01:Uplink-1`) when the
export carries one. Braces work on any of these (`{P9WT}`, `Rx {P9WT}`), so a
single `{code}` string pastes onto a link OR a device label unchanged. On the
wall that text becomes a live `▼in ▲out` readout and the link recolors. The
readout is a high-contrast overlay chip by default (legible on any backdrop);
`?annstyle=native` instead swaps the values into the annotation's own text -
keeping the font, colors, and background you styled in CrossCanvas - for walls
where the chips feel too loud:

| Interface condition | Link |
|---|---|
| `operStatus` down | red, pulsing |
| up, `max(in,out)/speedBps ≥ 0.8`, or any error/discard > 0 | amber |
| `operStatus` unknown, or bandwidth null | gray, dimmed |
| up, normal | keeps its own color |
| feed stale / unreachable | readout grayed, link dimmed |
| annotation matches no interface | unchanged (id text stays visible) |

Braces are REQUIRED on device labels (below) and OPTIONAL on annotations, so
`{code}` everywhere is always correct. A bare code on a device label does
nothing - that rule is what stops a device whose name happens to match a code
from being silently replaced by a reading.

**Device labels** - put a `{code}` token in a device label line; on the wall each
`{code}` is replaced by that metric's `display` string (`{H4TN}` -> `CPU 45%`).
Text around a token is kept (`Rx: {K7Q2}`), several per line work (`{M2LP} / {G6QB}`),
and an unmatched `{code}` stays literal (typo stays visible). A `cpu` metric with
a `warn`/`crit` `status` also tints its device's frame amber/red; every other
metric is display-only (no color) - deliberately, since mem/temp/disk readings
are noisy and should be seen, not alerted on.

**Feed schema** (`snmp-status.json`, schemaVersion 2):
```
{ schemaVersion, generator, generatedAt, pollIntervalSec,
  interfaces: [ { id, code?, alias?, operStatus, speedBps, inBps, outBps (bits/s, may be null),
                  in/outErrorsPerSec, in/outDiscardsPerSec, ... } ],
  metrics:    [ { code, kind, host, display, value?, unit?, status? } ] }
```
`pollIntervalSec` is the feed's own cadence; the kiosk adopts it for staleness
(overridable with `?snmpInterval=`). A metric may carry `status`
(`ok`/`warn`/`crit`/`unknown`) - the kiosk currently colors a device frame from
it only on `kind:"cpu"`, but the feed may set it on other kinds (e.g. battery)
for forward compatibility.
All interface ids + interface codes + metric codes share ONE match namespace, so
every code must be globally unique. `samples/snmp-status.json` +
`samples/board-snmp.xcanvas` are a ready demo pair.

### 2c. Themes and burn-in (optional)

A wall display holds one image for months, and even an IPS panel can retain it.
`?themes=` repaints the largest constant areas - the canvas background and the
chrome - on a timer, which spreads the load per pixel for free:

```
kiosk.html?board=data/board.xcanvas&status=data/status.json&themes=night&themeInterval=600
```

- **Picking a background is automatic.** Every theme carries its own canvas
  color, so `?theme=`/`?themes=` sets one for you. An explicit `?bg=` always
  wins; `?themeBg=0` keeps the board's own background and rotates chrome only.
- **Labels stay legible, per surface.** Boards are authored against a white
  canvas (dark text), so a dark background - from a theme *or* a plain
  `?bg=%23111827` - would hide them. The kiosk recolors label text to the
  theme's own light color, but decides **per label**, compositing any zone
  underneath: a light zone on a dark canvas keeps its dark text, so only the
  labels that actually sit on a dark surface flip. No re-render, so SNMP
  overlays are unaffected.
- **Device, zone and link colors don't rotate by default.** On a monitoring wall
  those often encode status; only the backdrop and chrome change unless you opt
  in with `?themeRecolor=1` (below).
- Group names for `?themes=`: `paper`, `warm`, `cool`, `night`, `screen`. An
  unknown theme name is ignored rather than fatal.

**Pixel orbit (`?shift=`) is the other half.** Theme rotation changes the colors
under your zone borders and device outlines, but never moves them - and burn-in
tracks static high-contrast *edges* (the reason a taskbar or snapped-window
border ghosts long before the middle of a screen does). `?shift=8` walks the
whole diagram around a 9-point ring, one step every `shiftInterval` seconds, so
no edge holds the same pixels for longer than one step:

```
kiosk.html?board=data/board.xcanvas&status=data/status.json&themes=night&shift=8
```

The offset moves the SVG viewBox, and the background and grid are re-anchored
to it, so the canvas stays full-bleed with no gap opening at an edge. The HUD
and down-panel ride along; the full-width stale banner stays put. It is one
attribute write per step and is deliberately not animated - a smooth tween
would burn real CPU on a Raspberry Pi for something meant to be barely
noticeable. Use both together: `?themes=` spreads the color load, `?shift=`
spreads the geometry.

Neither is a substitute for letting the OS blank the panel overnight.

#### `?themeRecolor=` - restyle the board itself (know the caveats)

By default a rotating theme repaints only the backdrop. `?themeRecolor=1` also
runs the editor's **Recolor to Theme** on the board each time it changes, so
device tints, zone fills, connection ink and label colors follow along - the
whole wall becomes Sakura, then Ember, then Blueprint. It operates on the
in-memory copy only: **your `.xcanvas` file on disk is never written.**

**Protecting a key/legend.** Name the kinds instead of `1` and the others keep
their authored colors. If your legend encodes meaning in link and label colors -
a common way to build one - recolor only the rest:

```
kiosk.html?board=data/board.xcanvas&themes=night&themeRecolor=devices,zones
```

Kinds are `devices`, `zones`, `connections`, `textBoxes`; an unrecognised value
is treated as off rather than as "everything". This matters because a recolored
legend doesn't look broken, it looks *wrong* - the swatches quietly stop
matching what they label, which is worse than an obvious failure.

It is off by default because it genuinely is not right for every diagram:

| Board trait | What happens |
|---|---|
| Colors carry MEANING (role, site, VLAN, owner) | That meaning is erased - every device becomes one theme tint. Exclude that kind (above) |
| A key/legend built from colored links or text | Its swatches stop matching what they label. Use `themeRecolor=devices,zones` |
| Raster or pasted icons | Keep their original look; only SVG icons retint, so a mixed board recolors unevenly |
| Imported Gliffy/Visio/draw.io diagrams | Keep their source styling by design, so results are inconsistent |
| Deliberate per-object colors | Overwritten wholesale |
| Nested zones | Parent/child shading is re-derived from geometry, not from your authored fills |

Live monitoring state always wins: status rings, down washes and any SNMP link
colors or `{code}` label values are re-applied immediately after each recolor,
so nothing monitoring-related is lost. Try a theme's recolor in the editor
first - if the board looks good there, it will look the same on the wall.

## 3. Poller (config JSON ↔ Docker env)

One set of knobs, two spellings: `pingcanvas.config.json` for IIS/Windows
deploys, `environment:` vars for the Docker poller (the container generates the
JSON from them each cycle).

| Config JSON | Docker env | Default | Effect |
|---|---|---|---|
| `pollIntervalSec` | `POLL_INTERVAL_SEC` | **30** | Poll cadence, seconds (min 1). The kiosk follows automatically via the feed. ~5s is comfortable; below that, lower `timeoutMs` too. The poller warns if a cycle overruns the interval. |
| `timeoutMs` | `TIMEOUT_MS` | **1000** | Per-probe timeout. Down devices cost the full timeout, so this bounds cycle time. |
| `degradedMs` | `DEGRADED_MS` | **150** | Latency above this = amber "degraded" instead of green. |
| `throttleLimit` | `THROTTLE` | **100** | Probes fired concurrently per batch. |
| `outputDir` | `DATA_DIR` (**/data**) | config dir | Where status files are written (Docker: also where boards are discovered). |
| `boards[]` `{file, status}` | *(auto-discovered)* | - | IIS/manual only: explicit board→status pairs. Docker builds this list from `*.xcanvas` in the data dir. |
| `combinedStatus` | `COMBINED` (**1**) | off (JSON) / on (Docker) | Also write one merged `status-all.json` across all boards - for a NOC overview board. |

Windows service wrapper: `poller\Install-PollerTask.ps1 [-Config path] [-TaskName PingCanvasPoller]`
(registers an at-startup SYSTEM task; cadence comes from the config, not the task).

## 4. Docker compose

| Setting | Where | Default | Effect |
|---|---|---|---|
| `ports: 8080:80` | web | **8080** | Editor + kiosk over HTTP. Change the left side if 8080 is taken. |
| `ports: 8443:443` | web | **8443** | HTTPS - only live once a cert is mounted (below). Use `443:443` for redirect setups. |
| `./data` mount | both | - | Boards in, status files out. The web tier mounts it read-only. Back this folder up; containers are disposable. |
| `./certs` mount | web | - | TLS cert pair (see §5). |
| `PINGCANVAS_TLS_REDIRECT: "1"` | web env | **off** | `:80` 301-redirects to HTTPS. Only sane with `443:443` published. |
| `PINGCANVAS_VERSION` | dist compose | **latest** | Image tag to run (offline-tarball deploys). |
| `network_mode: host` | poller | on | Poller reaches the monitored LAN for ICMP. **Linux only** - remove on Docker Desktop. |
| `cap_add: NET_RAW` | poller | on | Raw sockets for ping. TCP checks need neither this nor host networking. |
| `x-logging` anchor | both | 10 MB × 5 | Container log rotation cap (~50 MB/service). |

## 5. HTTPS (Pattern A - TLS in the web container)

Presence-based: a cert pair in `./certs` turns HTTPS on; no cert, no flag, no rebuild.

| Step | Command |
|---|---|
| Self-signed cert (Linux) | `./docker/gen-selfsigned-cert.sh [hostname] [days]` (**pingcanvas.local, 825**) |
| Self-signed cert (Windows) | `.\docker\gen-selfsigned-cert.ps1 -Cn <name> [-Days 825]` (runs openssl via Docker - pulls `alpine/openssl` once) |
| Own cert (internal CA…) | drop `fullchain.pem` + `privkey.pem` into `./certs` |
| Apply | `docker compose restart web` - **not** `up -d` (nothing compose tracks changed, so `up -d` won't re-run the entrypoint) |
| Verify | `docker compose logs web \| grep pingcanvas-tls` → "cert found - enabling HTTPS on 443" |

Self-signed → browsers warn once; trust the cert on the kiosk machine. For real
PKI / auto-renewing Let's Encrypt, front PingCanvas with a reverse proxy (Caddy)
instead and leave the web tier on plain :80 behind it.
Linux gotcha: if the stack started before `./certs` existed, Docker created it
root-owned - `sudo chown $USER ./certs` (the gen script detects and says so).

## 6. Build, deploy & packaging scripts

| Script | Args (defaults) | Job |
|---|---|---|
| `docker/build-web.sh` | `[crosscanvas-path]` (**../../crosscanvas**) | Assemble `docker/web/` (editor + kiosk + shared renderer) on a Linux host. |
| `docker/build-web.ps1` | `-CrossCanvasPath`, `-Out` | Same, Windows authoring box. |
| `docker/publish.sh` | `[version] [arch ...]` (**unversioned; amd64 arm64**) | Build images + offline tarballs into `dist/` with compose + QUICKSTART. Version optional: omit → `pingcanvas-<arch>.tar.gz` tagged `:latest`. |
| `tools/sync-from-crosscanvas.ps1` | `-CrossCanvasPath`, `-Dest` | Refresh the kiosk's copy of the CrossCanvas renderer (build artifacts, gitignored; the generated wall page is `kiosk.html`). |
| `tools/deploy-kiosk.ps1` | `-Dest` (required), `-CrossCanvasPath` | One-command standalone (kiosk-only) deploy to any web root (IIS, local demo). |

## 7. What lives in the data folder

| File | Written by | Notes |
|---|---|---|
| `*.xcanvas` | you (Save in the editor, then copy in) | The boards. Replacing one is hot. |
| `status.json`, `status-<name>.json` | poller, every cycle | Regenerated constantly - never edit, never back up. |
| `status-all.json` | poller (when combined output is on) | Merged view across all boards. |

---

*Editor-side customization (themes, default colors/fonts, stencils, import
formats) is CrossCanvas's own and documented in its `USER_GUIDE.md` / in-app Help -
this doc covers the monitoring/deployment surface.*
