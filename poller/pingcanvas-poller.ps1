<#
    pingcanvas-poller.ps1  -  parallel up/down poller for the PingCanvas dashboard.

    Reads one or more CrossCanvas ".xcanvas" boards DIRECTLY (the board is the single
    source of truth - no CSV, no drift), checks every device CONCURRENTLY, and
    writes a status.json per board ATOMICALLY into the web root the kiosk fetches.
    No modules; Windows PowerShell 5.1+ or 7+.

    Model: POLL ONCE, PUBLISH MANY. All boards are unioned and DEDUPED BY IP, so a
    device that appears on several boards is probed only once. Each board then gets
    its own status file containing just that board's IPs (per-team isolation); an
    optional combined file carries every device for a NOC overview board.

    Why parallel: sequential checks take the SUM of every timeout, so a handful of
    dead devices at a 1s timeout can push a big cycle past the refresh interval -
    the file ages and the kiosk (correctly) shows STALE. Here each cycle is bounded
    by ~one timeout per throttle batch, not the sum.

    Contract: this script is the ONLY thing that touches the network. If it dies or
    falls behind, it stops refreshing the status files; their "generated" timestamp
    ages and the kiosk flips to STALE on its own.

    Usage
      .\pingcanvas-poller.ps1 -Config .\pingcanvas.config.json           # loop
      .\pingcanvas-poller.ps1 -Config .\pingcanvas.config.json -Once     # single pass
#>
[CmdletBinding()]
param(
    [string]$Config,
    [switch]$Once
)

# (Defaults resolved here, not in param(): under 'powershell -File <relative
# path>' Windows PowerShell 5.1 evaluates param() defaults with an EMPTY
# $PSScriptRoot; in the body it is reliable.)
if (-not $Config) { $Config = Join-Path $PSScriptRoot 'pingcanvas.config.json' }
# Resolve against PowerShell's location, not the process cwd - the two
# differ after Set-Location.
$Config = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Config)

# --- config ----------------------------------------------------------------
function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }
    # Fail FAST and loudly on a bad config - ConvertFrom-Json's error is
    # non-terminating, so without the try/catch a typo'd config yields a null
    # $cfg and the poller would loop forever polling zero boards. The classic
    # typo is Windows backslashes in JSON strings ("C:\Scripts\..."): \S is an
    # invalid escape. Use forward slashes or doubled backslashes.
    try { $cfg = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop }
    catch {
        throw ("Config is not valid JSON ($Path): $($_.Exception.Message)`n" +
               "Hint: JSON paths need forward slashes (C:/Scripts/...) or doubled backslashes (C:\\Scripts\\...).")
    }
    if (-not $cfg.boards -or @($cfg.boards).Count -eq 0) {
        throw "Config has no boards ($Path) - add at least one { file, status } entry."
    }
    # Numeric fields: coerce and floor, falling back to the default on anything
    # non-parseable or out of range. A negative throttleLimit makes the chunk
    # step negative (infinite loop); a non-numeric one throws mid-cycle -> the
    # board never refreshes -> permanent STALE. Validate here so config junk
    # degrades to sane defaults instead of hanging the poller.
    $asNum = {
        param($value, $default, $min)
        $n = 0
        if ([int]::TryParse("$value", [ref]$n) -and $n -ge $min) { $n } else { $default }
    }
    $cfg | Add-Member pollIntervalSec (& $asNum $cfg.pollIntervalSec 30 1)   -Force
    $cfg | Add-Member timeoutMs       (& $asNum $cfg.timeoutMs 1000 1)       -Force
    $cfg | Add-Member degradedMs      (& $asNum $cfg.degradedMs 150 0)       -Force
    $cfg | Add-Member throttleLimit   (& $asNum $cfg.throttleLimit 100 1)    -Force
    return $cfg
}

# Resolve a config path relative to the config file's own directory (unless absolute).
function Resolve-ConfigPath {
    param([string]$Base, [string]$P)
    if ([System.IO.Path]::IsPathRooted($P)) { return $P }
    return [System.IO.Path]::GetFullPath((Join-Path $Base $P))
}

# --- board parsing (native .xcanvas) ---------------------------------------
function Read-BoardDevices {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Board not found: $Path" }
    # -ErrorAction Stop so a truncated/corrupt board raises a catchable error
    # instead of ConvertFrom-Json's non-terminating warning yielding $null - the
    # loop would then iterate nothing and publish an all-gray "unmonitored"
    # board, i.e. a healthy-looking wall hiding a broken feed. Same reasoning as
    # Read-Config.
    $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
    $out = New-Object System.Collections.ArrayList
    foreach ($d in $doc.devices) {
        $f  = $d.fields
        $ip = if ($f) { $f.'IP-Address' } else { $null }
        if (-not $ip -or -not "$ip".Trim()) { continue }        # only devices with an IP are monitored
        $name = if ($f -and $f.Hostname) { "$($f.Hostname)" }
                elseif ($d.label)        { ("$($d.label)" -split "`n")[0] }
                else                     { "$ip" }
        $check = if ($f -and $f.Check) { "$($f.Check)".Trim().ToLower() } else { 'icmp' }
        $port  = $null
        if ($check -eq 'tcp') {
            # A bad Port (typo like "443/tcp", or >65535) would otherwise throw
            # when cast/connected and abort the WHOLE poll for every board. Parse
            # and range-check here; on failure, degrade this one device to icmp.
            $parsed = 0
            if ([int]::TryParse("$($f.Port)".Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
                $port = $parsed
            } else {
                Write-Warning ("Device {0} ({1}): invalid tcp Port '{2}' - falling back to icmp." -f $name, $ip, $f.Port)
                $check = 'icmp'
            }
        }
        # Optional Monitor ID: the status-file key when set (else the IP). Lets
        # two shapes share one IP yet carry distinct entries/names - e.g. the
        # same device drawn on both a logical and a physical diagram.
        $monId = if ($f -and $f.'Monitor ID' -and "$($f.'Monitor ID')".Trim()) { "$($f.'Monitor ID')".Trim() } else { $null }
        [void]$out.Add([pscustomobject]@{
            IP = "$ip".Trim(); Key = $(if ($monId) { $monId } else { "$ip".Trim() })
            Name = "$name".Trim(); Check = $check; Port = $port
        })
    }
    return $out
}

# --- one concurrent batch (fired together, one bounded wait) ----------------
function Invoke-CheckBatch {
    param([object[]]$Batch, [int]$TimeoutMs, [int]$DegradedMs)
    $jobs = New-Object System.Collections.ArrayList
    $dead = New-Object System.Collections.ArrayList     # devices that threw at setup -> down, not a whole-batch abort
    foreach ($d in $Batch) {
        try {
            if ($d.Check -eq 'tcp' -and $d.Port) {
                $client = New-Object System.Net.Sockets.TcpClient
                $task   = $client.ConnectAsync($d.IP, [int]$d.Port)
                [void]$jobs.Add([pscustomobject]@{ dev=$d; kind='tcp'; task=$task; res=$client })
            } else {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $task = $ping.SendPingAsync($d.IP, $TimeoutMs)
                [void]$jobs.Add([pscustomobject]@{ dev=$d; kind='icmp'; task=$task; res=$ping })
            }
        } catch {
            Write-Warning ("Check setup failed for {0}: {1}" -f $d.IP, $_.Exception.Message)
            [void]$dead.Add([pscustomobject]@{ ip=$d.IP; state='down'; latencyMs=$null })
        }
    }
    $tasks = [System.Threading.Tasks.Task[]]@($jobs | ForEach-Object { $_.task })
    if ($tasks.Count) { try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, [int]($TimeoutMs + 750)) } catch { } }

    $results = New-Object System.Collections.ArrayList
    foreach ($x in $dead) { [void]$results.Add($x) }
    foreach ($j in $jobs) {
        $up = $false; $lat = $null
        if ($j.kind -eq 'icmp') {
            if ($j.task.Status -eq 'RanToCompletion' -and $j.task.Result.Status -eq 'Success') {
                $up = $true; $lat = [int]$j.task.Result.RoundtripTime
            }
            $j.res.Dispose()
        } else {
            $up = ($j.task.Status -eq 'RanToCompletion' -and $j.res.Connected)
            if ($j.task.IsFaulted) { $null = $j.task.Exception }   # observe faulted task
            $j.res.Close()
        }
        $state = if (-not $up) { 'down' }
                 elseif ($lat -ne $null -and $lat -ge $DegradedMs) { 'degraded' }
                 else { 'up' }
        [void]$results.Add([pscustomobject]@{ ip=$j.dev.IP; state=$state; latencyMs=$lat })
    }
    return $results
}

# --- poll a deduped target set -> hashtable ip -> {state, latencyMs} --------
function Invoke-Checks {
    param([object[]]$Targets, [int]$TimeoutMs, [int]$DegradedMs, [int]$ThrottleLimit)
    $map = @{}
    for ($i = 0; $i -lt $Targets.Count; $i += $ThrottleLimit) {
        $end   = [Math]::Min($i + $ThrottleLimit - 1, $Targets.Count - 1)
        $batch = $Targets[$i..$end]
        foreach ($r in (Invoke-CheckBatch -Batch $batch -TimeoutMs $TimeoutMs -DegradedMs $DegradedMs)) {
            $map[$r.ip] = $r
        }
    }
    return $map
}

# --- prior state (so "since" survives across runs) --------------------------
function Get-PriorDevices {
    param([string]$Path)
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $prev = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
            foreach ($p in $prev.devices.PSObject.Properties) { $map[$p.Name] = $p.Value }
        } catch { }
    }
    return $map
}

# --- atomic write ----------------------------------------------------------
function Write-Atomic {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp  = "$Path.$PID.tmp"
    $utf8 = New-Object System.Text.UTF8Encoding($false)          # UTF-8, no BOM
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, $utf8)
        # Move-Item -Force can transiently fail if a reader (e.g. IIS) holds the
        # target open without share-delete; a couple of retries ride out the
        # momentary lock instead of skipping the cycle (which would read as STALE).
        for ($i = 0; ; $i++) {
            try { Move-Item -LiteralPath $tmp -Destination $Path -Force; break }
            catch { if ($i -ge 2) { throw }; Start-Sleep -Milliseconds 100 }
        }
    } finally {
        # never leave an orphaned temp file behind
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# --- build one status file from master results + that board's IP list -------
function Write-StatusFile {
    param([string]$Path, [string[]]$Keys, [hashtable]$KeyToIp, [hashtable]$Results,
          [hashtable]$Names, [string]$NowS, [int]$IntervalSec)
    $prior = Get-PriorDevices -Path $Path
    $out = [ordered]@{}
    foreach ($k in $Keys) {
        $r = $Results[$KeyToIp[$k]]       # probe results are per-IP; entries per-key
        $state = if ($r) { $r.state } else { 'unknown' }
        $lat   = if ($r) { $r.latencyMs } else { $null }
        $since = $NowS
        if ($prior.ContainsKey($k) -and $prior[$k].state -eq $state -and $prior[$k].since) {
            $since = $prior[$k].since
        }
        $entry = [ordered]@{ state = $state; latencyMs = $lat; since = $since }
        if ($Names[$k]) { $entry.name = $Names[$k] }
        $out[$k] = $entry                 # keyed by Monitor ID when the device sets one, else by IP
    }
    $doc = [ordered]@{ generated = $NowS; pollIntervalSec = $IntervalSec; devices = $out }
    Write-Atomic -Path $Path -Content ($doc | ConvertTo-Json -Depth 6)
}

# --- one full poll (all boards) --------------------------------------------
function Invoke-Poll {
    param($Cfg, [string]$BaseDir)

    $nowS    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $outDir  = if ($Cfg.outputDir) { Resolve-ConfigPath -Base $BaseDir -P $Cfg.outputDir } else { $BaseDir }

    # 1) gather each board's status keys + a master IP-deduped target set.
    # Polling dedupes by IP (one probe per host); status entries are keyed by
    # Monitor ID when a device sets one (else by IP), so shapes sharing an IP
    # can still have distinct entries/names.
    $master  = [ordered]@{}   # ip  -> target (first definition wins)
    $names   = @{}            # key -> display name
    $keyToIp = @{}            # key -> ip (entry key back to the probed result)
    $boards  = @()            # {statusPath, keys[]}
    foreach ($b in $Cfg.boards) {
        $boardPath = Resolve-ConfigPath -Base $BaseDir -P $b.file
        # Isolate each board: a missing or corrupt one must not abort the whole
        # cycle (Read-BoardDevices throws on both). Skip it with a warning and
        # leave its status file untouched - going stale is the honest signal;
        # the other boards keep polling.
        try {
            $devs = @(Read-BoardDevices -Path $boardPath)
        } catch {
            Write-Warning ("Skipping board '{0}': {1}" -f $b.file, $_.Exception.Message)
            continue
        }
        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($d in $devs) {
            if (-not $master.Contains($d.IP)) { $master[$d.IP] = $d }
            if (-not $keyToIp.ContainsKey($d.Key)) { $keyToIp[$d.Key] = $d.IP; $names[$d.Key] = $d.Name }
            if (-not $keys.Contains($d.Key)) { $keys.Add($d.Key) }
        }
        $boards += [pscustomobject]@{ statusPath = (Join-Path $outDir $b.status); keys = $keys.ToArray() }
    }

    $targets = @($master.Values)
    Write-Verbose ("Polling {0} unique targets across {1} board(s)" -f $targets.Count, $Cfg.boards.Count)

    # 2) poll the deduped set once
    $results = Invoke-Checks -Targets $targets -TimeoutMs $Cfg.timeoutMs `
                             -DegradedMs $Cfg.degradedMs -ThrottleLimit $Cfg.throttleLimit

    # 3) publish per-board files (projection of master results)
    foreach ($bd in $boards) {
        Write-StatusFile -Path $bd.statusPath -Keys $bd.keys -KeyToIp $keyToIp -Results $results `
                         -Names $names -NowS $nowS -IntervalSec $Cfg.pollIntervalSec
    }

    # 4) optional combined file for a NOC overview board
    if ($Cfg.combinedStatus) {
        Write-StatusFile -Path (Join-Path $outDir $Cfg.combinedStatus) -Keys @($keyToIp.Keys) `
                         -KeyToIp $keyToIp -Results $results -Names $names -NowS $nowS -IntervalSec $Cfg.pollIntervalSec
    }

    Write-Verbose ("Wrote {0} board file(s){1} at {2}" -f `
        $boards.Count, $(if ($Cfg.combinedStatus) { " + combined" } else { "" }), $nowS)
}

# --- main loop -------------------------------------------------------------
$cfg     = Read-Config -Path $Config
$baseDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Config))

do {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { Invoke-Poll -Cfg $cfg -BaseDir $baseDir }
    catch { Write-Warning "Poll failed: $($_.Exception.Message)" }   # don't rewrite -> ages to STALE
    $sw.Stop()
    $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($elapsed -gt $cfg.pollIntervalSec) {
        Write-Warning ("Poll cycle took {0}s, over the {1}s interval - raise throttleLimit, lower timeoutMs, or raise pollIntervalSec." -f $elapsed, $cfg.pollIntervalSec)
    }
    if (-not $Once) { Start-Sleep -Seconds ([Math]::Max(0, $cfg.pollIntervalSec - $elapsed)) }
} while (-not $Once)
