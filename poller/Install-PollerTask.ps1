<#
    Install-PollerTask.ps1 - register the poller as a Scheduled Task that runs in
    loop mode at system startup and restarts if it dies. Run as Administrator.

      .\Install-PollerTask.ps1 -Config C:\pingcanvas\poller\pingcanvas.config.json

    Remove with:  Unregister-ScheduledTask -TaskName PingCanvasPoller -Confirm:$false
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$TaskName = 'PingCanvasPoller'
)

# (Defaults resolved here, not in param(): under 'powershell -File <relative
# path>' Windows PowerShell 5.1 evaluates param() defaults with an EMPTY
# $PSScriptRoot; in the body it is reliable.)
if (-not $Config) { $Config = Join-Path $PSScriptRoot 'pingcanvas.config.json' }

# The task runs from System32 at boot, so the config path baked into its
# arguments must be absolute (resolved against PowerShell's location).
$Config = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Config)
# A trailing backslash baked into the quoted -Config argument below would
# parse as an escaped quote and corrupt the task's command line.
$Config = $Config.TrimEnd('\')
$psExe  = (Get-Command powershell.exe).Source
$script = Join-Path $PSScriptRoot 'pingcanvas-poller.ps1'
if (-not (Test-Path $script)) { throw "Poller not found: $script" }
if (-not (Test-Path $Config)) { throw "Config not found: $Config" }

$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Config `"$Config`""

$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
Write-Host "Task '$TaskName' registered (runs at startup as SYSTEM)."

# Start it now rather than waiting for the next boot (same as Install-ServeTask).
Start-ScheduledTask -TaskName $TaskName
Write-Host "Poller started - status file(s) will appear in the config's outputDir within one poll interval."
