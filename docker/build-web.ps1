<#
    docker/build-web.ps1 - assemble the web root the container image bakes in.

    Produces docker/web/ holding BOTH apps (the proven Option A layout):
      index.html   = CrossCanvas editor (verbatim)
      kiosk.html    = the NOC view (CrossCanvas's index.html + embed flag + kiosk assets)
      app.js / devices.js / style.css  = shared renderer (one copy)
      kiosk-init.js / status-layer.js / kiosk.css = the kiosk layer
    Run before `docker build` (the Dockerfile just COPYs docker/web/). Gitignored
    build artifact - same source-of-truth story as sync-from-crosscanvas.ps1.
#>
[CmdletBinding()]
param(
    [string]$CrossCanvasPath,
    [string]$Out
)

# (Defaults resolved here, not in param(): under 'powershell -File <relative
# path>' Windows PowerShell 5.1 evaluates param() defaults with an EMPTY
# $PSScriptRoot; in the body it is reliable.)
if (-not $CrossCanvasPath) { $CrossCanvasPath = Join-Path $PSScriptRoot '..\..\crosscanvas' }
if (-not $Out)         { $Out = Join-Path $PSScriptRoot 'web' }

# Resolve user-supplied paths against PowerShell's location, not the process
# cwd ([IO.Path]::GetFullPath) - the two differ after Set-Location.
$CrossCanvasPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CrossCanvasPath)
$Out         = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
# Tolerant sibling discovery (default path only; an explicit -CrossCanvasPath
# still fails loudly): GitHub ZIP downloads extract as 'CrossCanvas-main' /
# '-master', a checkout from before the rename is a 'netdraw' sibling, and
# Explorer's Extract All nests everything one level deeper (ZIP.zip ->
# ZIP\ZIP\...) - so search the folder above this checkout AND one above that,
# and accept app.js either directly in a crosscanvas*/netdraw* folder or in a
# same-named folder nested inside it.
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
$kiosk       = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\kiosk'))
if (-not (Test-Path -LiteralPath (Join-Path $CrossCanvasPath 'app.js'))) {
    throw "CrossCanvas not found: $CrossCanvasPath (need a sibling folder containing app.js, e.g. 'crosscanvas' or a 'CrossCanvas-main' ZIP extract; or pass -CrossCanvasPath)"
}

# Rebuild the artifacts but PRESERVE user data. The Windows quickstart has the
# operator save board.xcanvas into this folder and the poller writes status.json
# here too, so a blanket wipe on the next build would delete a hand-drawn board
# with no warning. Everything else is our own output and is safe to replace.
if (Test-Path -LiteralPath $Out) {
    Get-ChildItem -LiteralPath $Out -Force | Where-Object {
        $_.Name -notlike '*.xcanvas' -and $_.Name -notlike 'status*.json'
    } | Remove-Item -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $Out -Force | Out-Null
}

# 1. shared renderer + the editor's own index.html (verbatim). favicon.svg is
#    the EDITOR's icon (the html references it; omitting it 404'd silently).
foreach ($f in 'app.js', 'devices.js', 'style.css', 'index.html', 'favicon.svg') {
    Copy-Item -LiteralPath (Join-Path $CrossCanvasPath $f) -Destination (Join-Path $Out $f) -Force
}
$custom = Join-Path $CrossCanvasPath 'customdevices.js'
if (Test-Path -LiteralPath $custom) { Copy-Item $custom (Join-Path $Out 'customdevices.js') -Force }

# 2. kiosk layer. The kiosk's own favicon ships under a distinct name so the
#    NOC tab (green status ring) is tellable from the editor tab (blue diamond).
foreach ($f in 'kiosk-init.js', 'status-layer.js', 'snmp-layer.js', 'kiosk.css', 'starter-board.xcanvas') {
    Copy-Item -LiteralPath (Join-Path $kiosk $f) -Destination (Join-Path $Out $f) -Force
}
Copy-Item -LiteralPath (Join-Path $kiosk 'favicon.svg') -Destination (Join-Path $Out 'kiosk-favicon.svg') -Force

# 3. kiosk.html = CrossCanvas's index.html with the embed flag + kiosk assets injected
#    at stable anchors (fail loudly if CrossCanvas ever moves them).
$html    = Get-Content -Raw -LiteralPath (Join-Path $CrossCanvasPath 'index.html')
$anchCss = '<link rel="stylesheet" href="style.css">'
$anchApp = '<script src="app.js"></script>'
if ($html.IndexOf($anchCss) -lt 0) { throw "Anchor not found in CrossCanvas index.html: $anchCss" }
if ($html.IndexOf($anchApp) -lt 0) { throw "Anchor not found in CrossCanvas index.html: $anchApp" }
$html = $html.Replace($anchCss, $anchCss + "`n    <link rel=`"stylesheet`" href=`"kiosk.css`">")
# The inline embed flag is hash-allowlisted in CrossCanvas's web.config CSP -
# changing this exact string requires recomputing that sha256 hash.
$html = $html.Replace($anchApp,
    "<script>window.CROSSCANVAS_EMBED = true;</script>`n    " + $anchApp +
    "`n    <script src=`"status-layer.js`"></script>" +
    "`n    <script src=`"snmp-layer.js`"></script>" +
    "`n    <script src=`"kiosk-init.js`"></script>")
# Kiosk tab gets its own icon (best-effort - cosmetic, so no hard anchor check:
# if CrossCanvas reshapes its favicon link, the kiosk just shares the editor icon).
$html = $html.Replace('href="favicon.svg"', 'href="kiosk-favicon.svg"')
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $Out 'kiosk.html'), $html, $utf8)

Write-Host "Built web root -> $Out"
Get-ChildItem $Out | ForEach-Object { "  {0,-18} {1,8:N0}" -f $_.Name, $_.Length }
