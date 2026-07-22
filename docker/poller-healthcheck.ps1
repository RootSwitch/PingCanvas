# PingCanvas poller liveness check (Docker HEALTHCHECK: exit 0 = healthy, 1 = not).
# The entrypoint touches /tmp/poller-heartbeat every poll cycle - boards or not -
# so a stale heartbeat means the loop wedged (a dead poller otherwise just leaves
# status.json ageing to STALE with no container-level signal). Tolerate up to 3x
# the poll interval (floor 90s) before reporting unhealthy; the first heartbeat
# lands after the first cycle, which the Dockerfile's --start-period covers.
$hb = '/tmp/poller-heartbeat'
if (-not (Test-Path -LiteralPath $hb)) { exit 1 }
$interval = 30
if ($env:POLL_INTERVAL_SEC) { [void][int]::TryParse($env:POLL_INTERVAL_SEC, [ref]$interval) }
if ($interval -lt 1) { $interval = 30 }
$ageSec = ((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalSeconds
if ($ageSec -gt [Math]::Max(90, $interval * 3)) { exit 1 } else { exit 0 }
