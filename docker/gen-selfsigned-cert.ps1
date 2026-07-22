<#
    gen-selfsigned-cert.ps1 - self-signed cert+key for PingCanvas Pattern A HTTPS,
    with ZERO local tooling: it runs openssl inside a throwaway container, so you
    don't need OpenSSL installed on Windows (Docker is already here for PingCanvas).

      .\gen-selfsigned-cert.ps1                        # CN=pingcanvas.local, 825 days
      .\gen-selfsigned-cert.ps1 -Cn noc.lan -Days 825

    Writes .\certs\{fullchain.pem,privkey.pem} in the current folder - run it from
    the same directory as your docker-compose.yml (where .\data lives). The compose
    mounts .\certs into the web container; `docker compose up -d` then serves HTTPS.

    Browsers WILL warn on a self-signed cert - expected. Trust it once on the kiosk
    machine, or front PingCanvas with a proxy (Caddy) for real PKI.
#>
[CmdletBinding()]
param(
    [string]$Cn   = 'pingcanvas.local',
    [int]   $Days = 825                # keep <825d: modern clients reject longer leaf certs
)
$ErrorActionPreference = 'Stop'

$certDir = Join-Path (Get-Location) 'certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

# CN lands inside the SAN list - commas/spaces would inject bogus SAN tokens.
if ($Cn -notmatch '^[A-Za-z0-9.-]+$') {
    throw "CN '$Cn' contains characters outside [A-Za-z0-9.-] - pick a plain hostname."
}

$subj = "/CN=$Cn"
$san  = "subjectAltName=DNS:$Cn,DNS:localhost,IP:127.0.0.1"

# alpine/openssl is a tiny official image; --rm throws the container away after.
docker run --rm -v "${certDir}:/certs" alpine/openssl req -x509 -newkey rsa:2048 -nodes `
    -keyout /certs/privkey.pem -out /certs/fullchain.pem `
    -days $Days -subj $subj -addext $san
if ($LASTEXITCODE -ne 0) { throw "openssl container failed (is Docker running?)" }

Write-Host "Wrote $certDir\fullchain.pem + privkey.pem  (CN=$Cn, ${Days}d)"
Write-Host "Next: docker compose restart web   ->   https://<host>:8443/index.html"
Write-Host "      (restart, not 'up -d' - up -d won't recreate a running container to"
Write-Host "       re-run the entrypoint that enables HTTPS.)"
