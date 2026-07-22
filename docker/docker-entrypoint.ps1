<#
    docker/docker-entrypoint.ps1 - poller container entrypoint.

    Auto-discovers every *.xcanvas (and legacy *.netdraw) in the data dir (so users just drop boards in,
    no config to edit), generates the poller config from env vars, and drives the
    poll cadence itself by calling the poller -Once each cycle. Because it
    re-discovers every cycle, ADDING or REPLACING a board is hot - no restart.

    Env (all optional): DATA_DIR (/data), POLL_INTERVAL_SEC (30), TIMEOUT_MS (1000),
    DEGRADED_MS (150), THROTTLE (100), COMBINED (1 -> also write status-all.json).
#>
$ErrorActionPreference = 'Stop'

$dataDir  = if ($env:DATA_DIR) { $env:DATA_DIR } else { '/data' }
$poller   = Join-Path $PSScriptRoot 'pingcanvas-poller.ps1'
$cfgPath  = '/tmp/pingcanvas.config.json'

$num = { param($v, $d) $n = 0; if ([int]::TryParse("$v", [ref]$n) -and $n -ge 0) { $n } else { $d } }
# TryParse like every other env var - a raw [int] cast of e.g. "30s" throws and
# crash-loops the container before the resilient poll loop is even entered.
$interval = & $num $env:POLL_INTERVAL_SEC 30; if ($interval -lt 1) { $interval = 30 }
$timeoutMs  = & $num $env:TIMEOUT_MS 1000
$degradedMs = & $num $env:DEGRADED_MS 150
$throttle   = & $num $env:THROTTLE 100
$combined   = ($env:COMBINED -ne '0')

Write-Host "PingCanvas poller: dataDir=$dataDir interval=${interval}s"

while ($true) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $boards = @(Get-ChildItem -LiteralPath $dataDir -File -ErrorAction Stop |
                Where-Object { $_.Extension -in '.xcanvas', '.netdraw' })   # .netdraw = legacy, read forever
        if (-not $boards.Count) {
            Write-Warning "No .xcanvas (or .netdraw) boards in $dataDir yet - drop one in; waiting."
        } else {
            $entries = foreach ($b in $boards) {
                $base   = [System.IO.Path]::GetFileNameWithoutExtension($b.Name)
                # board.xcanvas (or legacy board.netdraw) -> status.json (kiosk
                # default); others -> status-<base>.json
                $status = if ($base -ieq 'board') { 'status.json' } else { "status-$base.json" }
                [ordered]@{ file = $b.FullName; status = $status }
            }
            $cfg = [ordered]@{
                pollIntervalSec = $interval
                timeoutMs       = $timeoutMs
                degradedMs      = $degradedMs
                throttleLimit   = $throttle
                outputDir       = $dataDir
                boards          = @($entries)
            }
            if ($combined) { $cfg.combinedStatus = 'status-all.json' }
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 6), $utf8)
            & $poller -Config $cfgPath -Once
        }
    } catch {
        Write-Warning "Poll cycle failed: $($_.Exception.Message)"   # keep looping -> board ages to STALE
    }
    $sw.Stop()
    # Liveness heartbeat: touched every cycle, boards or not, so the container
    # HEALTHCHECK can tell "poll loop is running" from "output is present" - an
    # idle poller with no boards yet is healthy. /tmp is container-local, never served.
    try { [System.IO.File]::WriteAllText('/tmp/poller-heartbeat', (Get-Date -Format o)) } catch { }
    Start-Sleep -Seconds ([Math]::Max(1, $interval - [int]$sw.Elapsed.TotalSeconds))
}
