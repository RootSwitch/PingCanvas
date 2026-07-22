<#
    tools/sync-from-crosscanvas.ps1 - refresh the kiosk's copy of the CrossCanvas renderer.

    The kiosk REUSES CrossCanvas's renderer rather than forking it:
      * app.js / devices.js / style.css are copied in UNMODIFIED,
      * kiosk.html is generated from CrossCanvas's index.html with three small
        injections (embed flag before app.js, kiosk.css after style.css, kiosk
        scripts after app.js) - same convention as docker/build-web.ps1: the
        wall is always kiosk.html.
    All four synced files are gitignored in this repo - they are build artifacts,
    never edited here. Everything kiosk-specific lives in the additive layer
    (kiosk.css, status-layer.js, kiosk-init.js), so a theme, color or markup
    change in CrossCanvas flows here by re-running this script. Nothing to hand-port.

    Usage
      .\sync-from-crosscanvas.ps1                       # assumes ..\..\CrossCanvas
      .\sync-from-crosscanvas.ps1 -CrossCanvasPath C:\path\to\CrossCanvas
#>
[CmdletBinding()]
param(
    [string]$CrossCanvasPath,
    [string]$Dest
)

# (Defaults resolved here, not in param(): under 'powershell -File <relative
# path>' Windows PowerShell 5.1 evaluates param() defaults with an EMPTY
# $PSScriptRoot; in the body it is reliable.)
if (-not $CrossCanvasPath) { $CrossCanvasPath = Join-Path $PSScriptRoot '..\..\crosscanvas' }
if (-not $Dest)        { $Dest = Join-Path $PSScriptRoot '..\kiosk' }

# Resolve user-supplied paths against PowerShell's location, not the process
# cwd ([IO.Path]::GetFullPath) - the two differ after Set-Location.
$CrossCanvasPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CrossCanvasPath)
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
$Dest        = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dest)
if (-not (Test-Path -LiteralPath (Join-Path $CrossCanvasPath 'app.js'))) {
    throw "CrossCanvas not found: $CrossCanvasPath (need a sibling folder containing app.js, e.g. 'crosscanvas' or a 'CrossCanvas-main' ZIP extract; or pass -CrossCanvasPath)"
}

# 1) verbatim copies. customdevices.js (a team/site @name stencil layer) is
#    copied WHEN PRESENT - without it, boards that reference those stencils show
#    placeholder icons on the kiosk. It's optional, so a missing file is silent.
$files = 'app.js', 'devices.js', 'style.css', 'customdevices.js'
foreach ($f in $files) {
    $src = Join-Path $CrossCanvasPath $f
    if (-not (Test-Path -LiteralPath $src)) {
        if ($f -ne 'customdevices.js') { Write-Warning "skip (missing): $f" }
        continue
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $Dest $f) -Force
    "{0,-16} {1,8:N0} bytes" -f $f, (Get-Item (Join-Path $Dest $f)).Length
}

# 2) kiosk.html = CrossCanvas's index.html with kiosk injections at stable
#    anchors. If CrossCanvas ever moves these anchors the replaces miss and we
#    fail loudly rather than emit a half-wired kiosk page.
$htmlSrc = Join-Path $CrossCanvasPath 'index.html'
$html    = Get-Content -Raw -LiteralPath $htmlSrc

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
# kiosk tab title: the wall is PingCanvas, not the editor (kiosk-init refines it
# to "PingCanvas - <board>" once a board loads). Best-effort - a no-match keeps
# the editor title.
$html = $html.Replace('<title>CrossCanvas Diagram Editor</title>', '<title>PingCanvas</title>')

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $Dest 'kiosk.html'), $html, $utf8)
"{0,-16} {1,8:N0} bytes  (embed flag + kiosk assets injected)" -f 'kiosk.html', (Get-Item (Join-Path $Dest 'kiosk.html')).Length

# Pre-4.0 syncs generated the kiosk shell AS index.html; a stale copy would
# shadow the kiosk.html convention. Remove it only if it is that artifact
# (identified by the injected embed flag - the oldest, pre-rename syncs
# injected NETDRAW_EMBED), never a file someone placed.
$oldShell = Join-Path $Dest 'index.html'
if ((Test-Path -LiteralPath $oldShell) -and
    ((Get-Content -Raw -LiteralPath $oldShell) -match 'window\.(CROSSCANVAS|NETDRAW)_EMBED = true')) {
    Remove-Item -LiteralPath $oldShell -Force
    Write-Host "Removed stale pre-4.0 kiosk shell: index.html (the wall is kiosk.html now)"
}

Write-Host "Synced from $CrossCanvasPath -> $Dest"
