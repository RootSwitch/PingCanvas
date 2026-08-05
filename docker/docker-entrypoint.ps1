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
        # .netdraw = legacy, read forever. *.wall.* files are the POLLER'S OWN
        # OUTPUT - without the exclusion it discovers its generated wall copy
        # as a new board named 'board.wall', polls its zero IPs, and litters
        # the served root with an empty status-board.wall.json every cycle.
        $boards = @(Get-ChildItem -LiteralPath $dataDir -File -ErrorAction Stop |
                Where-Object { $_.Extension -in '.xcanvas', '.netdraw' -and
                               $_.Name -notmatch '\.wall\.(xcanvas|netdraw)$' })
        # Wall-split layout (DEPLOY.md): boards under /data/.private are
        # SOURCES the web tier never serves (nginx 404s dot-paths). Location
        # IS the opt-in - a board placed there gets `wall = true`
        # automatically, its full status written beside it in .private, and
        # only the stripped .wall pair lands in the served root. No env var
        # to remember: putting a board somewhere unservable already states
        # the intent completely.
        $privDir = Join-Path $dataDir '.private'
        $privBoards = @()
        if (Test-Path -LiteralPath $privDir) {
            $privBoards = @(Get-ChildItem -LiteralPath $privDir -File -ErrorAction Stop |
                    Where-Object { $_.Extension -in '.xcanvas', '.netdraw' -and
                                   $_.Name -notmatch '\.wall\.(xcanvas|netdraw)$' })
        }
        if (-not $boards.Count -and -not $privBoards.Count) {
            Write-Warning "No .xcanvas (or .netdraw) boards in $dataDir (or its .private) yet - drop one in; waiting."
        } else {
            # board.xcanvas (or legacy board.netdraw) -> status.json (kiosk
            # default); others -> status-<base>.json
            $statusNameFor = { param($base)
                if ($base -ieq 'board') { 'status.json' } else { "status-$base.json" }
            }
            $entries = @()
            $entries += foreach ($b in $boards) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($b.Name)
                [ordered]@{ file = $b.FullName; status = (& $statusNameFor $base) }
            }
            $entries += foreach ($b in $privBoards) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($b.Name)
                # Full status stays unserved beside its board; the poller
                # derives the served .wall pair's names from these basenames.
                [ordered]@{ file = $b.FullName
                            status = ('.private/' + (& $statusNameFor $base))
                            wall = $true }
            }
            $cfg = [ordered]@{
                pollIntervalSec = $interval
                timeoutMs       = $timeoutMs
                degradedMs      = $degradedMs
                throttleLimit   = $throttle
                outputDir       = $dataDir
                boards          = @($entries)
            }
            # The combined file names every device across every board, so one
            # private board makes the WHOLE combined file private - hostnames
            # from .private must not resurface at the served root through the
            # side door. AlertCanvas reads it by file mount, so it follows the
            # move via its ping-feed path setting.
            if ($combined) {
                $cfg.combinedStatus = if ($privBoards.Count) { '.private/status-all.json' } else { 'status-all.json' }
                if ($privBoards.Count) {
                    Write-Host "Private boards present: combined status -> .private/status-all.json (point AlertCanvas's ping feed there)"
                }
            }
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
