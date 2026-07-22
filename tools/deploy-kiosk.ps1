<#
    tools/deploy-kiosk.ps1 - one-command kiosk deploy.

    Answers "which folder do I pull from?" by making the answer: none - run this.
    It (1) refreshes the synced renderer copies from CrossCanvas, then (2) copies the
    complete kiosk app into the target web root. Your boards and the poller's
    status*.json in the target are left untouched.

    Usage
      .\deploy-kiosk.ps1 -Dest C:\inetpub\pingcanvas                  # IIS
      .\deploy-kiosk.ps1 -Dest ..\web                                # local demo (the poller's default outputDir)
      .\deploy-kiosk.ps1 -Dest C:\inetpub\pingcanvas -CrossCanvasPath D:\src\CrossCanvas
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dest,
    [string]$CrossCanvasPath
)

# (Defaults resolved here, not in param(): under 'powershell -File <relative
# path>' Windows PowerShell 5.1 evaluates param() defaults with an EMPTY
# $PSScriptRoot; in the body it is reliable.)
if (-not $CrossCanvasPath) { $CrossCanvasPath = Join-Path $PSScriptRoot '..\..\crosscanvas' }

$kiosk = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\kiosk'))
# Resolve against PowerShell's location, not the process cwd - the two
# differ after Set-Location, sending a relative -Dest somewhere surprising.
$Dest  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dest)
# Tolerant sibling discovery - same rules as sync-from-crosscanvas.ps1 (ZIP
# extract names, pre-rename 'netdraw' checkouts, Explorer's doubled folders).
if (-not $PSBoundParameters.ContainsKey('CrossCanvasPath') -and
    -not (Test-Path -LiteralPath (Join-Path $CrossCanvasPath 'app.js'))) {
    :search foreach ($up in '..\..', '..\..\..') {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $up))
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match '^(crosscanvas|netdraw)' })) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'app.js')) {
                $CrossCanvasPath = $d.FullName; break search
            }
            $nested = Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(crosscanvas|netdraw)' -and
                               (Test-Path -LiteralPath (Join-Path $_.FullName 'app.js')) } |
                Select-Object -First 1
            if ($nested) { $CrossCanvasPath = $nested.FullName; break search }
        }
    }
}

# 1) sync renderer + generated kiosk.html from CrossCanvas (fails loudly on drift)
& (Join-Path $PSScriptRoot 'sync-from-crosscanvas.ps1') -CrossCanvasPath $CrossCanvasPath

# 2) copy the kiosk app (docs stay behind; boards/status in Dest untouched).
#    This is a KIOSK-ONLY web root - the wall lives at kiosk.html and the
#    CrossCanvas editor is not included (use docker/build-web.ps1 for a root
#    that serves both). favicon.svg here is the PingCanvas mark
#    (kiosk/favicon.svg), which is what a kiosk-only site should show.
if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
$files = 'kiosk.html', 'app.js', 'devices.js', 'style.css',
         'kiosk-init.js', 'status-layer.js', 'snmp-layer.js', 'kiosk.css', 'web.config', 'favicon.svg',
         'starter-board.xcanvas'
foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $kiosk $f) -Destination (Join-Path $Dest $f) -Force
}
# Pre-4.0 deploys shipped the kiosk shell AS index.html into $Dest; left in
# place it keeps old bookmarks and the IIS default document pointed at a shell
# whose markup can't host the freshly copied app.js (dead wall, "embed hook
# missing"). Same content-gated rule as sync-from-crosscanvas.ps1: remove it
# only if it is OUR generated artifact, never a file someone placed (a dual
# editor+kiosk root has a legitimate index.html - the editor - with no flag).
$staleShell = Join-Path $Dest 'index.html'
if ((Test-Path -LiteralPath $staleShell) -and
    ((Get-Content -Raw -LiteralPath $staleShell) -match 'window\.(CROSSCANVAS|NETDRAW)_EMBED = true')) {
    Remove-Item -LiteralPath $staleShell -Force
    Write-Host "Removed stale pre-4.0 kiosk shell from target: index.html (the wall is kiosk.html now)"
}

# team stencil layer rides along when CrossCanvas has one (boards may carry @name refs)
$custom = Join-Path $CrossCanvasPath 'customdevices.js'
if (Test-Path -LiteralPath $custom) {
    Copy-Item -LiteralPath $custom -Destination (Join-Path $Dest 'customdevices.js') -Force
    Write-Host "customdevices.js included (team stencil layer)"
}

Write-Host "Kiosk deployed to $Dest"
$boards = @(Get-ChildItem -LiteralPath $Dest -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.xcanvas', '.netdraw' -and          # .netdraw = legacy, still served
                   $_.Name -ne 'starter-board.xcanvas' })                # ships with the app, not a user board
if ($boards.Count) {
    Write-Host ("Boards present: " + (($boards | ForEach-Object Name) -join ', '))
} else {
    Write-Warning "No .xcanvas (or .netdraw) boards in $Dest yet - copy your board(s) in and point the poller's outputDir here."
}
