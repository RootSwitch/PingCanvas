# PingCanvas - Windows / IIS deployment

Copy-paste reference for the **Windows/IIS** path: kiosk URLs, the wwwroot file manifest, and the poller
config that ties them together. This is the **kiosk-only** IIS layout - the
wall without the editor; for a web root serving both apps, assemble it with
`docker\build-web.ps1` instead (see [QUICKSTART-WINDOWS.md](QUICKSTART-WINDOWS.md)).

**Deploying with Docker on Linux instead?** Start at
[docker/README.md](docker/README.md) - or let the
[canvas-suite](https://github.com/RootSwitch/canvas-suite) script do the
whole thing.

---

## Kiosk URLs

Defaults are `board.xcanvas` + `status.json`, so the main board needs no params:

```
https://<jumpbox>/kiosk.html
```

Explicit equivalent of the above:

```
https://<jumpbox>/kiosk.html?board=board.xcanvas&status=status.json
```

### Per-board status files (isolation: each file exposes only that board's devices)

```
https://<jumpbox>/kiosk.html?board=board-campusA.xcanvas&status=status-campusA.json
https://<jumpbox>/kiosk.html?board=board-campusB.xcanvas&status=status-campusB.json
```

### Combined status file (ease of use: one status URL for every board)

```
https://<jumpbox>/kiosk.html?board=board.xcanvas&status=status-all.json
https://<jumpbox>/kiosk.html?board=board-campusA.xcanvas&status=status-all.json
https://<jumpbox>/kiosk.html?board=board-campusB.xcanvas&status=status-all.json
```

### Local demo (tools/serve.ps1 or the dev server, no IIS)

```
http://localhost:8080/kiosk.html?board=board.xcanvas&status=status.json
```

### URL parameters

The common ones: `board` (which diagram), `status` (which feed), `theme`
(one look), `snmp` (SNMPCanvas overlay feed). The complete reference -
every parameter, default, and the theme/burn-in machinery - lives in
[docs/CONFIGURATION.md](docs/CONFIGURATION.md) §2, the single authoritative
table (this file used to carry a copy; it had already drifted).

Example with overrides:

```
https://<jumpbox>/kiosk.html?board=board-campusA.xcanvas&status=status-all.json&interval=15&staleMul=3
```

Dark-wall look (dark background, grid off is already the default):

```
https://<jumpbox>/kiosk.html?board=board.xcanvas&status=status.json&bg=%23111827
```

---

## wwwroot manifest

**The easy way - don't hand-pick files:**

```powershell
tools\deploy-kiosk.ps1 -Dest C:\inetpub\pingcanvas
```

That syncs the renderer from CrossCanvas and copies the complete kiosk app in one
step (boards and status*.json already in the target are left untouched; it
warns if no boards are present). The manual manifest below is for reference.

Kiosk-owned (from `kiosk\`):

```
kiosk-init.js
status-layer.js
snmp-layer.js       <- optional SNMP link overlay (only used when ?snmp= is set)
kiosk.css
kiosk-favicon.svg
starter-board.xcanvas  <- the getting-started board shown when no board exists yet
web.config          <- IIS only: serves .xcanvas as JSON (fetch 404s without it)
```

Synced from CrossCanvas (run `tools\sync-from-crosscanvas.ps1` first - these are
gitignored build artifacts, absent in a fresh clone):

```
kiosk.html          <- the GENERATED kiosk shell (CrossCanvas's index.html +
app.js                 embed flag + kiosk assets - not the editor)
devices.js
style.css
customdevices.js    <- only if your boards use team stencils (@name icon refs)
```

Content:

```
board.xcanvas            <- your saved diagram(s): board-campusA.xcanvas, ...
status.json              <- DO NOT copy: the poller writes these
status-campusA.json      <-   "
status-all.json          <-   "
```

Keep OUT of the web root: everything in `poller\` (script + config run from
anywhere; only their output lands here), `samples\`, `docs\`, `tools\`.

---

## Pairing with SNMPCanvas (live link bandwidth + host metrics)

[SNMPCanvas](https://github.com/RootSwitch/SNMPCanvas) is a separate companion
that polls SNMP interfaces and hosts and writes an `snmp-status.json`. Point the
kiosk at it with `?snmp=data/snmp-status.json` to overlay live values onto the
board. PingCanvas is display-only here; add `snmp-layer.js` to the web root (it
ships with the kiosk build) and it stays inert until `?snmp=` is set.

**Binding a link:** in CrossCanvas, add an **annotation** to the connection. The
short `code` (e.g. `{K7Q2}`, the paste-ready chip SNMPCanvas offers) is the
recommended match - unique and rename-proof. The interface `id`
(`Device:ifName`, e.g. `EdgeSw-01:GigabitEthernet0/1`) or the friendlier
`Device:alias` (`EdgeSw-01:Uplink-1`) also match. On the wall the text becomes a
`▼in ▲out` pill and the link recolors (down = red, near-cap/errors = amber,
unknown = gray).

**Host metrics on a device label:** put a `{code}` token in a device label line
and it is replaced by that metric's live value (`{H4TN}` -> `CPU 45%`). Text
around the token is kept, several per line work, and an unmatched token stays
literal so a typo stays visible. Braces are REQUIRED on device labels and
OPTIONAL on link annotations, so the braced form is always correct - paste the
same `{code}` onto either surface. Full schema, brace rules and color rules:
[docs/CONFIGURATION.md §2b](docs/CONFIGURATION.md).

**Shared data directory (the important operational bit):** the kiosk fetches the
feed same-origin, so SNMPCanvas must write `snmp-status.json` into the *same
folder the kiosk serves as `data/`*. Put that folder **outside both git
checkouts** so rebuilding or re-cloning either project can't wipe it (a data dir
that lives inside `pingcanvas/` is fragile - the classic "it vanished on
rebuild"). Create it once on the host, then bind-mount it from both stacks:

```bash
sudo mkdir -p /srv/canvas-suite && sudo chmod 2775 /srv/canvas-suite   # or a shared gid
```
```yaml
# PingCanvas: docker-compose.override.yml (leave the shipped ./data default alone)
services:
  web:    { volumes: [ "/srv/canvas-suite:/usr/share/nginx/html/data:ro,z" ] }
  poller: { volumes: [ "/srv/canvas-suite:/data:z" ] }
# SNMPCanvas: its export mount -> the same host path
  #          [ "/srv/canvas-suite:/export:z" ]
```

Have SNMPCanvas publish **atomically** (temp file + `rename()`, as this poller
already does) so the kiosk never fetches a half-written file. Avoid
`docker compose down -v` (it removes named volumes; bind mounts survive but the
habit bites).

---

## Poller config (`pingcanvas.config.json`)

```json
{
  "pollIntervalSec": 30,
  "timeoutMs": 1000,
  "degradedMs": 150,
  "throttleLimit": 100,
  "outputDir": "C:/inetpub/pingcanvas",
  "combinedStatus": "status-all.json",
  "boards": [
    { "file": "C:/inetpub/pingcanvas/board.xcanvas",         "status": "status.json" },
    { "file": "C:/inetpub/pingcanvas/board-campusA.xcanvas", "status": "status-campusA.json" },
    { "file": "C:/inetpub/pingcanvas/board-campusB.xcanvas", "status": "status-campusB.json" }
  ]
}
```

## Where the poller lives

Outside the web root (the poller writes INTO wwwroot but must not live there):

```
C:\Scripts\pingcanvas\
├─ pingcanvas-poller.ps1
├─ pingcanvas.config.json
└─ Install-PollerTask.ps1
```

Permissions for the running principal: Read/Execute on `C:\Scripts\pingcanvas`,
Modify on the `outputDir` (e.g. `C:\inetpub\pingcanvas`). An interactive admin
session already has both. Config paths resolve relative to the config file, so
use absolute paths for `boards` and `outputDir` as shown above.

Run it (interactive demo - Ctrl+C stops it; the wall goes stale ~60s later):

```powershell
& C:\Scripts\pingcanvas\pingcanvas-poller.ps1 -Config C:\Scripts\pingcanvas\pingcanvas.config.json -Verbose
```

If execution policy blocks it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\pingcanvas\pingcanvas-poller.ps1 -Config C:\Scripts\pingcanvas\pingcanvas.config.json -Verbose
```

Notes:
- **Paths in JSON must use forward slashes** (`C:/inetpub/...`) or doubled
  backslashes (`C:\\inetpub\\...`) - a bare `C:\inetpub\...` is an invalid JSON
  escape and the poller will refuse the config with a hint to this effect.
- Polling load is set by the `boards` list (union, deduped by IP - a device on
  several boards is probed once per cycle). Which status file kiosks read never
  changes what gets probed.
- `combinedStatus` is optional; remove the line and `status-all.json` isn't written.
- Per-device fields on the board (Device Details): `IP-Address` (required to be
  monitored), optional `Check` = `tcp` + `Port` for a TCP service check instead
  of ping, optional `Monitor ID` to disambiguate duplicate IPs.

---

## Production hardening (demo → standing service)

The demo (interactive session, admin account, one board) needs none of this. Fold
these in when the poller becomes an always-on service. Trust model: an internal
NOC tool on a trusted segment - the poller is the only thing that touches the
network; the kiosk only reads static files. Most "findings" against a tool like
this assume an attacker who can already write your config/board files, which
means they already own the box - so the items below are hygiene, not patches.

**Least privilege**
- Run the poller under a dedicated service account (or gMSA), not SYSTEM/admin.
- NTFS: that account needs **Read** on `C:\Scripts\pingcanvas` and **Modify** on
  the `outputDir` only. Deny interactive logon.
- IIS app-pool identity needs nothing extra - it only reads static files.

**Access control (the real security boundary)**
- The status JSON is a live map of internal IPs + up/down state. Keep the kiosk
  site on a trusted segment / internal binding; never an internet-facing one.
- Per-board status files are the isolation boundary between teams; `status-all.json`
  exposes every device, so gate who can reach it accordingly.
- **The board file is the bigger exposure than the status JSON**: a status file
  says which addresses answer, the board says what the network IS - hostnames,
  addresses, custom fields, full topology - while the rendered wall shows only
  labels. Anyone who can fetch `kiosk.html` can fetch the `.xcanvas` beside it.
- **The wall split fixes that structurally.** `"wall": true` on a board entry
  makes the poller write two extra files into `outputDir` each cycle:
  `<board>.wall.xcanvas` (every device's hidden fields stripped; monitored
  devices keep a single `Monitor ID` equal to their own opaque device id) and
  `<status>.wall.json` (same states keyed by those ids, named by drawn labels).
  The kiosk binds by `Monitor ID` natively, so no kiosk change is needed:

  ```
  data/.private/board.xcanvas      <- source of truth; dot-path = never served
  data/.private/status.json        <- full status (AlertCanvas reads via file mount)
  data/board.wall.xcanvas          <- served; carries no more than the picture
  data/status.wall.json            <- served; names are labels, keys are opaque
  ```

  Kiosk URL: `kiosk.html?board=data/board.wall.xcanvas&status=data/status.wall.json`.
  **Docker / compose: location IS the opt-in.** The poller container
  auto-discovers boards, so there is no config file to edit - any board placed
  under `/data/.private/` is walled automatically: full status written beside
  it (unserved), stripped `.wall` pair written to the served root. One private
  board also moves `status-all.json` into `.private/` (it names every device,
  so one private board makes the whole combined file private); AlertCanvas
  reads it by file mount, so update its ping-feed path setting to
  `/status/.private/status-all.json`.
  The dot-path trick rides the existing nginx rule (hidden names 404 under
  `/data/`); verify with `curl -f https://wall/data/.private/board.xcanvas`
  expecting 404. A failed strip never falls back to serving the source - the
  poller warns and leaves the previous wall copy standing.
- The SNMP overlay has the same split: the full `snmp-status.json` names every
  monitored device (sysName, host address, interface names/aliases - including
  devices on no board), so SNMPCanvas also writes an anonymized
  `snmp-status.wall.json` ({code} keys and values only). Serve the wall
  variant (`?snmp=data/snmp-status.wall.json` - a `.wall.` board derives it
  automatically) and keep the full file unserved; on the suite's setup-script
  layout that is the default. One trade: annotations keyed by
  `Device:ifName`/`Device:alias` only bind against the full file - use the
  `{code}` form, which binds against both.

**Network / monitoring friction**
- Parallel ICMP/TCP on a fixed cadence looks like a scanner. Before scaling past
  a handful of devices, give your IDS/IPS team the poller's source IP + cadence
  so it isn't flagged or auto-blocked.
- Legacy/fragile gear: prefer `icmp` over repeated TCP connects; raise
  `pollIntervalSec` for anything that dislikes being probed.

**Observability**
- Headless `Write-Verbose`/`Write-Warning` goes nowhere. Wrap the scheduled task
  to append stdout/stderr to a log file, or forward to EventLog/SIEM, so
  "falling behind" / "invalid port" warnings are actually seen.
- The kiosk's STALE banner is the primary watchdog - a dead poller is visible on
  the wall regardless of logging.

**Already handled in code (no action needed)**
- Atomic publish (temp file + retried rename + `finally` cleanup).
- Single-instance via the Scheduled Task's `MultipleInstances IgnoreNew`.
- Fail-fast on bad JSON / empty boards; numeric config fields validated (junk
  can't hang the loop); bad per-device `Port` degrades to icmp, doesn't abort.
- Stale-fail-safe: a missing/garbage `generated` timestamp reads as STALE.
- Kiosk renders feed/board values via `textContent` + color-map keys, not
  `innerHTML` - a hostile feed can't inject script (reviewed + payload-tested).
