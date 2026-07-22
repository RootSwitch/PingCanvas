<#
    tools/serve.ps1 - dead-simple static file server (no IIS, nothing installed).

    Serves a folder over HTTP with correct MIME types and no-cache on the status
    feed, so the whole PingCanvas loop runs on a plain Windows desktop. Point
    -Root at a folder that holds the kiosk app files, board.xcanvas, and the
    poller's status output together (one origin). Ctrl+C stops.

    Usage
      .\serve.ps1 -Root C:\PingCanvas\web -Port 8080          # this machine only
      .\serve.ps1 -Root C:\PingCanvas\web -Port 8080 -Lan     # reachable from the LAN
                                                              # (TVs, tablets, other PCs)

    Run at startup instead: tools\Install-ServeTask.ps1 registers this script as
    a Scheduled Task (and opens the firewall port when -Lan). See
    QUICKSTART-WINDOWS.md for the whole desktop setup.

    If an interactive (non-admin) run fails with "Access is denied" on Start(),
    either run the shell as Administrator, or grant the URL once (admin prompt):
      netsh http add urlacl url=http://+:8080/ sddl=D:(A;;GX;;;WD)
#>
param(
    [string]$Root,
    [int]   $Port = 8080,
    [switch]$Lan
)

# (Defaults resolved here, not in param(): under 'powershell -File <relative
# path>' Windows PowerShell 5.1 evaluates param() defaults with an EMPTY
# $PSScriptRoot; in the body it is reliable.)
if (-not $Root) { $Root = Join-Path $PSScriptRoot '..\samples\out' }

$mime = @{
    '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'
    '.css'='text/css; charset=utf-8';   '.json'='application/json; charset=utf-8'
    '.xcanvas'='application/json; charset=utf-8'; '.svg'='image/svg+xml'
    '.png'='image/png'; '.jpg'='image/jpeg'; '.ico'='image/x-icon'; '.woff2'='font/woff2'
}

# Resolve against PowerShell's location, not the process cwd - the two
# differ after Set-Location, serving a relative -Root from somewhere surprising.
$Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
if (-not (Test-Path -LiteralPath $Root)) { throw "Root not found: $Root" }

$listener = New-Object System.Net.HttpListener
# -Lan binds every interface ('+') so other devices on the network can view
# the wall; the default binds loopback only.
$prefix = if ($Lan) { "http://+:$Port/" } else { "http://localhost:$Port/" }
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Serving $Root at http://localhost:$Port/  (Ctrl+C to stop)"
if ($Lan) {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { Write-Host "  LAN: http://$($_.IPAddress):$Port/" }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request; $res = $ctx.Response
        try {
            $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
            $path = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
            # Boundary match, not a prefix match: compare against root + separator
            # so a sibling dir sharing the root's name (C:\web vs C:\web-secret)
            # can't slip past. UnescapeDataString runs before this, so percent-
            # encoded ..%2f is covered too.
            $rootWithSep = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if ($path -ne $Root -and -not $path.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
                $res.StatusCode = 403                                  # path-traversal guard
            } elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $res.StatusCode = 404
            } else {
                $ext = [System.IO.Path]::GetExtension($path).ToLower()
                $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
                if ($ext -eq '.json' -or $ext -eq '.xcanvas') {
                    $res.Headers.Add('Cache-Control','no-cache, no-store, must-revalidate')
                }
                $bytes = [System.IO.File]::ReadAllBytes($path)
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        } catch {
            try { $res.StatusCode = 500 } catch { }
        } finally {
            $res.OutputStream.Close()
        }
    }
} finally {
    $listener.Stop()
}
