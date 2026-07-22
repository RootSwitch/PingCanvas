# PingCanvas on a Windows desktop - no Docker, no IIS

The whole loop runs natively on Windows 10/11 with nothing installed: the
poller is PowerShell (Windows ICMP needs no special privileges - no raw-socket
or host-networking setup like the Linux container), and a bundled PowerShell
static server handles the web tier. Two scheduled tasks and a browser shortcut
turn the PC you already have into the monitoring wall.

Start to finish, from the two downloads - about ten minutes end to end:

## 1. Download both projects

PingCanvas displays boards; its sister project
[CrossCanvas](https://github.com/RootSwitch/CrossCanvas) is the editor they're
drawn in, and the build step in step 2 needs both. Grab each repo's ZIP
(**Code → Download ZIP**) - or `git clone` them - and extract both into one
folder, e.g. `C:\PingCanvas`:

```
C:\PingCanvas\
├── CrossCanvas-main\      (the editor - from the CrossCanvas ZIP)
└── PingCanvas-main\       (this project)
```

`C:\PingCanvas` is just the example path - any folder you can write to works
(say, `Documents\PingCanvas`); adjust the paths in the steps below to match.
The GitHub `-main` folder names are fine as-is; the scripts find the editor
next to them either way. Two Windows notes:

- **Explorer's Extract All doubles the folders.** Its suggested destination
  adds a folder named after the ZIP, and the ZIP already contains one - so
  accepting the default gives `C:\PingCanvas\CrossCanvas-main\CrossCanvas-main\…`.
  Trim the suggested path back to `C:\PingCanvas` when extracting - or don't
  bother: the build script finds the editor in the doubled layout too, just
  `cd` one folder deeper in step 2.
- **PowerShell refuses scripts on a stock machine, twice.** Fresh Windows
  ships with execution policy `Restricted` (no `.ps1` runs at all), and files
  extracted from a downloaded ZIP are additionally "blocked"
  (Mark-of-the-Web). Fix both once, from any PowerShell window:

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # let local scripts run (answer Y)
  Get-ChildItem C:\PingCanvas -Recurse | Unblock-File   # clear the downloaded-file block
  ```

  After that, every command in this guide runs as written. Prefer not to
  change a setting? Prefix each script call instead:
  `powershell -ExecutionPolicy Bypass -File .\docker\build-web.ps1 …`

## 2. Assemble the web folder

Neither ZIP contains a runnable web root - this step builds it, copying the
CrossCanvas editor and the kiosk into one folder:

```powershell
cd C:\PingCanvas\PingCanvas-main
.\docker\build-web.ps1 -Out C:\PingCanvas\web
```

If PowerShell says the script doesn't exist, you have Explorer's doubled
layout from step 1 - run `cd PingCanvas-main` once more and retry.

(It lives under `docker\` but needs no Docker - it just assembles files.)
Afterwards `C:\PingCanvas\web` holds `index.html` (the editor) and
`kiosk.html` (the wall).

## 3. Draw your board

Open `C:\PingCanvas\web\index.html` in a browser and draw your network - or
import a diagram or inventory export you already have. Give each device you want
monitored an **IP-Address** in Device Details, then use the editor's
**File → Save** (not the browser's save menu) to save the file as:

```
C:\PingCanvas\web\board.xcanvas
```

(If your browser saves to Downloads, just move it there and rename it.) Until
a board exists, the kiosk shows a built-in getting-started view instead of an
error.

## 4. Copy the poller into place

From `C:\PingCanvas\PingCanvas-main` (the same window as step 2):

```powershell
Copy-Item .\poller C:\PingCanvas\poller -Recurse
```

Open `C:\PingCanvas\poller\pingcanvas.config.json` and check it - with the
folders laid out as above, the shipped defaults are already correct (paths
resolve relative to the config file, and `../web` is your web folder):

```json
{
  "pollIntervalSec": 30,
  "timeoutMs": 1000,
  "degradedMs": 150,
  "throttleLimit": 100,
  "outputDir": "../web",
  "boards": [
    { "file": "../web/board.xcanvas", "status": "status.json" }
  ]
}
```

## 5. Install the poller task

From an **Administrator** PowerShell:

```powershell
C:\PingCanvas\poller\Install-PollerTask.ps1 -Config C:\PingCanvas\poller\pingcanvas.config.json
```

That registers a scheduled task that starts at boot and restarts if it dies -
and starts it right away: within one poll interval (30 s by default) you
should see `status.json` appear next to your board in `C:\PingCanvas\web`.
No reboot needed; if the file doesn't show up, run the poller once in the
open window to see why:

```powershell
C:\PingCanvas\poller\pingcanvas-poller.ps1 -Config C:\PingCanvas\poller\pingcanvas.config.json -Once -Verbose
```

## 6. Install the web server task

Still as Administrator, from `C:\PingCanvas\PingCanvas-main`:

```powershell
.\tools\Install-ServeTask.ps1 -Root C:\PingCanvas\web            # this PC only
.\tools\Install-ServeTask.ps1 -Root C:\PingCanvas\web -Lan       # + TVs/tablets on your network
```

`-Lan` binds every interface and adds the matching inbound firewall rule
(Private/Domain profiles). The task starts immediately and at every boot.

Everything is now in place - your folders should match the "What goes where"
map in the [README](README.md#what-goes-where).

## 7. Put the wall on a screen

Open `http://localhost:8080/kiosk.html` - devices ring green/amber/red live.
To make it appear full-screen at logon: press `Win+R`, run `shell:startup`,
and create a shortcut with target

```
msedge --kiosk http://localhost:8080/kiosk.html --edge-kiosk-type=fullscreen
```

The editor lives at `http://localhost:8080/index.html` on the same origin, so
"edit the board, save over `board.xcanvas`, reload the wall" is the whole
update workflow.

## Removing it

```powershell
Unregister-ScheduledTask -TaskName PingCanvasPoller -Confirm:$false
Unregister-ScheduledTask -TaskName PingCanvasWeb    -Confirm:$false
Remove-NetFirewallRule -DisplayName 'PingCanvas Web (TCP 8080)'   # only if you used -Lan

# Optional full wipe. Careful: your board lives in C:\PingCanvas\web -
# copy board.xcanvas somewhere safe first if you want to keep it.
Remove-Item -Recurse -Force C:\PingCanvas
```

## Alternatives on a desktop

- **IIS - yes, on desktop Windows.** Windows 10/11 Pro *and* Home can enable
  IIS under *Turn Windows features on or off*; the standard IIS deployment in
  [DEPLOY.md](DEPLOY.md) then applies unchanged. Client IIS caps at ~10
  simultaneous connections - irrelevant for a status wall (one small JSON
  fetch per screen per interval).
- **Docker Desktop (WSL2), hybrid.** If you already run Docker Desktop, use
  the compose stack for the **web tier only** and keep the poller native:
  `network_mode: host` is Linux-only, so a containerized poller pings from
  behind WSL2's NAT, while the native PowerShell poller pings from your real
  adapter. Point its `outputDir` at the compose `./data` bind mount and both
  halves meet in the middle.
- **Windows pings, your NAS serves.** Everything between the poller and the
  kiosk is plain files, so `outputDir` can be a UNC path
  (`\\\\nas\\web\\pingcanvas`): the desktop runs only the poller task, and
  whatever already serves HTTP in the house (Synology Web Station, a Pi)
  hosts the wall. No always-on Windows session needed for viewing.
- **A full Linux VM (bridged) running Docker** works too and mirrors the
  reference Linux deployment - but it's the heaviest option here; prefer it
  only if you already run VMs.
