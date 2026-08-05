# PingCanvas

PingCanvas is a lightweight, locally hostable monitoring dashboard that turns
a network diagram into a live status wall: every device on the board recolors
by reachability - **green** up, **amber** slow, **red** down, **gray**
unmonitored. It is designed to ride on hardware you already have, with no
agents, no database, and no cloud account: a PowerShell poller checks your
devices and writes a small JSON file, and a read-only kiosk page in any
browser displays it. Boards are authored in its sister application,
[**CrossCanvas**](https://github.com/RootSwitch/CrossCanvas) - any diagram
whose devices carry an IP address becomes a dashboard as-is. A third companion,
[**SNMPCanvas**](https://github.com/RootSwitch/SNMPCanvas), is optional: point
the kiosk at its export with `?snmp=` and the same board also carries live link
bandwidth and host metrics (see [DEPLOY.md](DEPLOY.md)).
[**AlertCanvas**](https://github.com/RootSwitch/AlertCanvas) reads that same
export and sends raise/clear notifications - the wall shows it, the email
tells you. A fifth sibling,
[**SyslogCanvas**](https://github.com/RootSwitch/SyslogCanvas), collects syslog
and SNMP traps from the same devices - no board integration, just the same
self-hosted deployment shape. And
[**LaunchCanvas**](https://github.com/RootSwitch/LaunchCanvas), the suite's
front door, uploads boards to this wall straight from the browser - the
`scp` step is gone.

**Install the whole suite in one command:** the [canvas-suite](https://github.com/RootSwitch/canvas-suite) repo is the family's landing page, with one-shot install scripts for the full six-app stack or a Pi-class PingCanvas + AlertCanvas pair.

![The PingCanvas kiosk wall: a corporate network with green rings and latency
readouts on healthy devices, the directory server down - red-washed, with both
the server VLAN it sits in and the building around it ringed red - and the live
HUD counting 33 up, 1 down](docs/hero-kiosk.png)

## Boards come from CrossCanvas

PingCanvas has no editor of its own - it is the *display half* of a pair, and
[CrossCanvas](https://github.com/RootSwitch/CrossCanvas) is the authoring
half. Before there is anything to monitor, you draw (or import) a diagram
there:

1. In CrossCanvas, lay out your network - draw it, import a Visio / Gliffy /
   draw.io diagram, or import a device inventory (CSV, DHCP leases, arp/nmap).
2. Give each device you want monitored an **IP-Address** in its Device
   Details. (Devices without one show gray - PingCanvas never pings anything
   your board doesn't list.)
3. **File → Save** the board as `board.xcanvas` and drop it in the web folder
   (see the map below).

You don't need to install anything extra for this - but you do need **both
projects downloaded side by side**: this repo contains none of the editor's
files, and the build step (`docker\build-web.ps1`) copies the full CrossCanvas
editor into the web folder it assembles. After that, `index.html` is the
editor and `kiosk.html` is the wall - edit, save over `board.xcanvas`, reload
the wall. That's the whole update workflow.

## How it works

A browser can't ping, so PingCanvas splits the job in two, meeting in the
middle at plain files:

```
board.xcanvas ──► Poller (PowerShell) ──► status.json ──► Kiosk (browser/TV)
     │   reachability probes (ICMP/TCP)        │   HTTP poll every N s
     └───────────── same web folder / origin ──┘
```

- The **poller** (`poller/pingcanvas-poller.ps1`) reads the device IPs out of
  your `.xcanvas` board directly, checks them all in parallel, and writes
  `status.json`. It is the only component that touches the network, and it
  runs as a scheduled task on any Windows box - or as the PowerShell
  container in the Docker deployment.
- The **kiosk** (`kiosk.html`) loads the board once, fetches `status.json` on
  an interval, and recolors. It's a static page - point a TV at it.

The `.xcanvas` file is the single source of truth: the poller reads its
device IPs and the kiosk reads its layout, so the two can never disagree.

## What goes where

Everything lives in one served folder plus one poller folder. Using the paths
from the Windows quick start:

```
C:\PingCanvas\
├── web\                        ← the folder your browser sees (the "web root")
│   ├── index.html                 the CrossCanvas editor (copied in by build-web)
│   ├── kiosk.html                 the wall - this is what the TV shows
│   ├── board.xcanvas              YOUR diagram - you save this here
│   ├── status.json                written by the poller every interval
│   └── app.js / kiosk.css / …     app files, assembled by build-web.ps1
└── poller\
    ├── pingcanvas-poller.ps1      the poller
    └── pingcanvas.config.json     which boards to poll, how often, where to
                                   write status (paths resolve relative to
                                   this file - "outputDir": "../web")
```

The one rule: **the kiosk page, the board, and the status file must be served
from the same folder/origin**, so the browser's fetches are same-origin. The
poller can live anywhere that can read the board and write into that folder -
same PC, a NAS path, a container bind mount.

## Quick start

> **Installed via the [canvas-suite](https://github.com/RootSwitch/canvas-suite)
> script?** The wall is already built and serving on 8080/8443 with the
> board at `data/board.xcanvas` - upload new boards from LaunchCanvas
> rather than repeating the steps below.

**Windows desktop (no Docker, no IIS)** - the recommended first run:
**[QUICKSTART-WINDOWS.md](QUICKSTART-WINDOWS.md)** takes you from the two
GitHub ZIP downloads to a live wall: extract both projects into
`C:\PingCanvas`, assemble `C:\PingCanvas\web` with `docker\build-web.ps1`
(despite the folder name it needs no Docker), draw and save your board there,
install the poller and web-server scheduled tasks, and point a browser (or an
Edge kiosk shortcut on a TV) at `http://localhost:8080/kiosk.html`.

**See the poller work in ten seconds** - straight from a checkout, no setup:

```powershell
# Probe the sample boards (public resolver IPs) once and write their status
poller\pingcanvas-poller.ps1 -Config samples\pingcanvas.config.json -Once -Verbose
# → samples\out\status.json, status-teamA.json, status-all.json
```

**Docker / Linux** - the two-container stack (nginx web tier + PowerShell
poller, one bind-mounted board folder) is covered in
**[docker/README.md](docker/README.md)**. **IIS** users get a copy-paste
cheat sheet (URLs, wwwroot manifest, config) in **[DEPLOY.md](DEPLOY.md)**.
Same folder layout everywhere - only the host serving it changes.

Before you've placed a board, the kiosk shows a bundled **starter view** with
getting-started steps instead of an error. It monitors nothing (its one
example device has no IP), and it appears only when no board file exists - a
board that exists but fails to load still fails loudly with its own name.

## Configuration (`pingcanvas.config.json`)

```json
{
  "pollIntervalSec": 30,        // cadence; also drives the kiosk's stale threshold
  "timeoutMs": 1000,            // per-device check timeout
  "degradedMs": 150,            // ICMP round-trip over this => amber "degraded"
  "throttleLimit": 100,         // max checks in flight at once
  "outputDir": "../web",        // where status files land (your web root)
  "combinedStatus": "status-all.json",   // optional all-devices overview file
  "boards": [
    { "file": "../web/board.xcanvas",  "status": "status.json" },
    { "file": "../web/team-a.xcanvas", "status": "status-teamA.json" }
  ]
}
```

The `//` comments above are annotation for this README only - JSON doesn't
allow them, and the poller will reject a config that has them. Don't copy
this block; start from the shipped
[poller/pingcanvas.config.json](poller/pingcanvas.config.json), which is
comment-free. Paths resolve relative to the config file. Devices default to
ICMP; add `Check` (`icmp`|`tcp`) and `Port` as Device Details fields in
CrossCanvas to get TCP service checks instead. Full reference:
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

**Multi-board:** list several boards and the poller unions their devices,
deduped by IP - a device on three boards is probed once - then writes one
status file per board containing only that board's IPs (per-team isolation),
plus the optional combined file.

## Staleness - the safety net

The kiosk trusts the `generated` timestamp in `status.json`. If it's older
than `2 × pollIntervalSec` (or two fetches fail), the board desaturates and a
STALE banner appears - a **dead poller shows as stale, not falsely
all-green**. This is the whole reason for the file-based design.

## Security posture

The editor stays zero-network (CrossCanvas is file-distributable and never
phones home). PingCanvas is openly a networked app with an honest, different
threat model: all network activity lives in the poller on a segment you
trust; the kiosk only reads a static file and never scans anything; the web
tier serves static files with no server-side code. And nothing is monitored
by default - the poller probes exactly the IPs your own board defines.

**The board file is the sensitive part, and the wall hides that.** The kiosk
renders role labels ("Core Switch"), but it works by fetching the whole
`.xcanvas`, which carries everything the labels do not show: hostnames,
management IPs, serials, and any custom fields an inventory import brought
along, plus the full topology. Anyone who can reach the kiosk port can skip
the wall and take the file:

```
curl http://wall:8080/data/board.xcanvas
```

The status feeds beside it carry hostnames and reachability too. So treat the
kiosk port with the sensitivity of the board's data, not of the picture it
draws: keep it on the management network or behind a VPN, and never
port-forward it to the internet. Screenshots of the wall are safe to share;
the URL is not. (Details and per-board isolation options in DEPLOY.md.)

Or serve a board that matches the picture: `"wall": true` on a board in the
poller config writes a **sanitized wall copy** - the same diagram with every
hidden field stripped (monitored devices keep one opaque binding id), plus a
status file named by drawn labels instead of hostnames. Point the kiosk at
`board.wall.xcanvas` / `status.wall.json` and keep the source board in an
unserved path (`data/.private/` works - the web tier 404s every dot-path).
Then the URL carries no more than the wall displays. See DEPLOY.md.

## Repo layout

| Path | Contents |
|------|----------|
| `poller/` | `pingcanvas-poller.ps1` (parallel poller: reads `.xcanvas`, multi-board), the config template, `Install-PollerTask.ps1` (register as a startup Scheduled Task) |
| `kiosk/` | `kiosk-init.js` (boot: URL params, board load, rings), `status-layer.js` (poll loop + staleness + color mapping), `snmp-layer.js` (optional SNMP overlay), `kiosk.css` (ring / banner / HUD styles), `starter-board.xcanvas` (shown until a board exists), `web.config` (IIS static hosting) |
| `docker/` | `build-web.ps1` / `.sh` (assemble the web folder: editor + kiosk), compose + Dockerfiles for the Linux/container deployment |
| `tools/` | `serve.ps1` (zero-install static server), `Install-ServeTask.ps1`, `sync-from-crosscanvas.ps1` and `deploy-kiosk.ps1` (refresh / stand up a kiosk-only web root) |
| `samples/` | `board.xcanvas`, `board-teamA.xcanvas`, `board-snmp.xcanvas` + `snmp-status.json` (SNMP demo pair), `pingcanvas.config.json` |
| `docs/` | `CONFIGURATION.md`, `kiosk-mode-spec.md` |

## Contributing

Bug reports and small fixes are welcome via Issues and pull requests - host
compatibility (a Windows update or PowerShell version that breaks the poller),
static-page rendering quirks, and documentation fixes are all genuinely useful.

PingCanvas is intentionally small: a file-based poller and a read-only kiosk,
nothing more. For larger monitoring features - API polling, alerting, history
and the like - I'd rather you fork than open a big PR. (SNMP is the exception
that proves the rule: rather than grow it here, it lives in a separate
companion, SNMPCanvas, and the kiosk just displays its export.) Keeping the
moving parts few is a design choice, not an oversight, and forking is easy:
it's a small PowerShell poller plus a static page, under The Unlicense. Build
the monitor you want.

## License

[The Unlicense](LICENSE) - public domain, same as CrossCanvas, SNMPCanvas,
SyslogCanvas, AlertCanvas, and LaunchCanvas. (nginx, Alpine, and PowerShell are pulled by Docker at build/run
time and remain under their own licenses - none of their code lives in this
repo.)
