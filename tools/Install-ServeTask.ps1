<#
    Install-ServeTask.ps1 - register tools/serve.ps1 as a Scheduled Task that
    serves the PingCanvas web folder at system startup and restarts if it dies.
    The web-tier twin of poller/Install-PollerTask.ps1. Run as Administrator.

      .\Install-ServeTask.ps1 -Root C:\PingCanvas\web
      .\Install-ServeTask.ps1 -Root C:\PingCanvas\web -Port 8080 -Lan

    -Lan binds every interface (TVs / tablets / other PCs can reach the wall)
    and adds a matching inbound Windows Firewall rule for the port. Without
    -Lan the server answers on this machine only and no firewall change is
    made.

    Remove with:
      Unregister-ScheduledTask -TaskName PingCanvasWeb -Confirm:$false
      Remove-NetFirewallRule -DisplayName 'PingCanvas Web (TCP 8080)'   # -Lan installs only
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Root,
    [int]   $Port = 8080,
    [switch]$Lan,
    [string]$TaskName = 'PingCanvasWeb'
)

# Resolve against PowerShell's location, not the process cwd - the two
# differ after Set-Location, sending a relative -Root somewhere surprising.
$Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
# Strip a trailing backslash (tab completion adds one): baked into the task's
# argument string below, `"...\`" parses as an ESCAPED quote and the task dies
# on every start with -Port/-Lan swallowed into the root path.
$Root = $Root.TrimEnd('\')
if (-not (Test-Path -LiteralPath $Root)) { throw "Web root not found: $Root" }
$script = Join-Path $PSScriptRoot 'serve.ps1'
if (-not (Test-Path $script)) { throw "serve.ps1 not found next to this installer: $script" }

$psExe = (Get-Command powershell.exe).Source
$args_ = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Root `"$Root`" -Port $Port"
if ($Lan) { $args_ += ' -Lan' }

$action   = New-ScheduledTaskAction -Execute $psExe -Argument $args_
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
Write-Host "Task '$TaskName' registered (runs at startup as SYSTEM)."

if ($Lan) {
    $ruleName = "PingCanvas Web (TCP $Port)"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow -Profile Private,Domain | Out-Null
        Write-Host "Firewall rule '$ruleName' added (Private/Domain profiles)."
    } else {
        Write-Host "Firewall rule '$ruleName' already present."
    }
}

# Start it now rather than waiting for the next boot.
Start-ScheduledTask -TaskName $TaskName
Write-Host "Serving $Root at http://localhost:$Port/"
if ($Lan) {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { Write-Host "  LAN: http://$($_.IPAddress):$Port/" }
}
Write-Host "Kiosk URL: http://localhost:$Port/kiosk.html"
