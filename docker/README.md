# PingCanvas in Docker

Both apps - the CrossCanvas **editor** and the live **NOC view** - plus the poller,
in one small package. Two containers (nginx + PowerShell), one bind-mounted
`./data` folder for your boards.

## Quick start

```bash
# 1. Assemble the web assets from a CrossCanvas checkout (sibling of this repo).
#    Linux host: bash, no PowerShell needed (pwsh only runs inside the container).
./docker/build-web.sh                     # /path/to/CrossCanvas if not ../CrossCanvas
#    (Windows/authoring equivalent: pwsh docker/build-web.ps1 -CrossCanvasPath …)

# 2. Create the data folder and drop a board in.
mkdir -p data
cp /path/to/your-board.xcanvas data/board.xcanvas

# 3. Up.
docker compose up -d --build
```

The host needs only **Docker** (+ bash for step 1) - no PowerShell install. Any
box that already runs Docker can host this too; distro (Rocky, Ubuntu, …)
doesn't matter.

Setting up a fresh box? Docker means the engine **plus the Compose v2
plugin** (`docker compose`, with a space):

- **Ubuntu/Debian:** `sudo apt install docker.io docker-compose-v2`
- **Rocky/RHEL/Fedora:** the distro default is podman, not Docker - install
  `docker-ce` and `docker-compose-plugin` from
  [Docker's own repo](https://docs.docker.com/engine/install/).
- Add yourself to the `docker` group to drop `sudo` from every command:
  `sudo usermod -aG docker $USER`, then log out and back in.
- GitHub **Download ZIP** folder names (`CrossCanvas-main`) work as-is - the
  build script finds the editor either way. If your unzip tool dropped the
  execute bits: `chmod +x docker/*.sh`.

Then:
- **Editor** - `http://<host>:8080/index.html`
- **NOC view** - `http://<host>:8080/kiosk.html?board=data/board.xcanvas&status=data/status.json`
  (all the usual kiosk params work: `&bg=%23111827`, `&grid=1`, `&latency=0`, …)

## How it fits together

| Container | Image | Job |
|-----------|-------|-----|
| `web`     | nginx:alpine | serves both apps + the `./data` files (read-only) |
| `poller`  | mcr…/powershell | discovers `./data/*.xcanvas`, probes, writes `status*.json` |

- **Boards are data, not image.** Drop a `*.xcanvas` into `./data` and the poller
  picks it up next cycle (auto-discovered) - no restart, no config editing. Each
  board `X.xcanvas` gets `status-X.json`; `board.xcanvas` gets `status.json`.
- **Upgrades keep your data**: `docker compose pull && docker compose up -d`
  replaces the apps; `./data` is untouched.
- Only `./data` needs backing up. `status*.json` is regenerated every cycle.

## Config (compose `environment:`)

`POLL_INTERVAL_SEC` (30), `TIMEOUT_MS` (1000), `DEGRADED_MS` (150),
`THROTTLE` (100), `COMBINED` (1 → also write `status-all.json`).

**Every knob across all layers** - board fields, kiosk URL params, poller
config, compose, HTTPS, scripts - is tabled in
[docs/CONFIGURATION.md](../docs/CONFIGURATION.md).

## The one setting to get right: poller networking

The poller must reach the monitored segment and send ICMP:
- `cap_add: [NET_RAW]` - ping needs raw sockets (already in the compose).
- `network_mode: host` - gives the poller the host's network so it can reach your
  devices. **Linux only.** On Docker Desktop (Mac/Windows) remove that line and
  rely on bridge routing (ICMP to routable IPs still works with NET_RAW).

TCP checks (`Check=tcp` + `Port` on a device) need neither and work anywhere.

## HTTPS (optional)

Off by default - the web tier serves plain HTTP, which is fine on a trusted
segment. To turn on TLS **in the nginx container itself** (Pattern A), just give
it a cert; no flag, no rebuild:

```bash
# 1. make a self-signed cert+key in ./certs (run from your compose folder)
./docker/gen-selfsigned-cert.sh noc.lan          # Linux (needs openssl)
#   Windows, zero local tooling (runs openssl in a throwaway container):
#   .\docker\gen-selfsigned-cert.ps1 -Cn noc.lan

# 2. restart the web container - its entrypoint sees the cert and lights up :443
docker compose restart web
```

(`restart`, not `up -d`: adding files inside an already-mounted folder changes
nothing compose tracks, so `up -d` would say "Running" and skip the entrypoint.)

- **Editor**  - `https://<host>:8443/index.html`
- **NOC view** - `https://<host>:8443/kiosk.html?board=data/board.xcanvas&status=data/status.json`

How it works: `./certs` is mounted to `/etc/nginx/certs`; on start,
`docker-entrypoint.d/40-pingcanvas-tls.sh` checks for `fullchain.pem` +
`privkey.pem` and, if present, adds a `:443` server mirroring the `:80` one. No
cert → HTTP only (unchanged). Certs are gitignored - private keys never get
committed.

Options:
- Already have a real cert (internal CA, etc.)? Drop `fullchain.pem` +
  `privkey.pem` into `./certs` instead of generating one.
- Linux note: if the stack ever started before `./certs` existed, Docker
  created it **root-owned** - `gen-selfsigned-cert.sh` will tell you and the
  fix is `sudo chown $USER ./certs`.
- The `.ps1` helper pulls the tiny `alpine/openssl` image on first use - that
  one step needs registry access (the `.sh` helper uses local openssl instead).
- Want `:80` to redirect to HTTPS? Set `PINGCANVAS_TLS_REDIRECT: "1"` in the
  compose `environment:` - but only if you also publish on the standard port
  (`443:443`), or the redirect lands on the wrong port.

Self-signed means browsers warn on first visit - expected. Trust the cert once
on the kiosk machine, or, for **auto-renewing Let's Encrypt / real PKI**, don't
fight it here: front PingCanvas with a reverse proxy (Caddy is two lines and does
issuance + renewal for you) and leave the web tier on plain `:80` behind it.

## Distributing to others (no source, no build)

Recipients don't need this repo, PowerShell, or a build step - just Docker, a
compose file, and the pre-built images. Because the web image bakes its assets
in, the images are fully self-contained.

**Offline tarballs (start here).** `docker save`/`load` is single-arch, so this
produces one tarball per architecture:

```bash
# build QEMU emulation once if cross-building (e.g. arm64 on an amd64 box):
docker run --privileged --rm tonistiigi/binfmt --install all

docker/publish.sh amd64 arm64              # -> dist/pingcanvas-<arch>.tar.gz
docker/publish.sh 3.0.0 amd64 arm64        # versioned -> dist/pingcanvas-3.0.0-<arch>.tar.gz
```

The version is optional: omit it (or lead with an arch) for unversioned
`pingcanvas-<arch>.tar.gz` files tagged `:latest`; pass one to stamp
`pingcanvas-<version>-<arch>.tar.gz` and an extra `:<version>` image tag for
provenance. `publish.sh` drops everything a recipient needs into `dist/`: the
per-arch tarball(s), a `docker-compose.yml`, and `QUICKSTART.txt`. Send someone
the tarball for *their* arch plus those two files - they run:

```bash
docker load < pingcanvas-amd64.tar.gz
mkdir -p data                              # then draw a board in the editor -> ./data/board.xcanvas
docker compose up -d
```

No version to set - images are always tagged `:latest` (and `:<version>` too when
you passed one), and the compose defaults to `:latest`.

**Registry (later, for a single multi-arch artifact + `compose pull`).** Push the
buildx output to Docker Hub / GHCR and recipients pull the right arch
automatically - the natural path once the repo is public.

Licensing note: this repo contains only PingCanvas's own code - nginx, Alpine,
and PowerShell are *referenced* (pulled by Docker at build/run time) and stay
under their own licenses. The offline tarballs necessarily bundle those image
layers, license files included, as every `docker save` does.

## Notes

- Editor **Save** downloads the file to the user's browser (client-side) - to
  publish a board to the wall, drop the saved file into `./data`. A future
  "publish" button (nginx WebDAV PUT) could close that loop.
- `docker/web/` is a build artifact (gitignored); re-run `build-web.sh` (or `build-web.ps1` on Windows) after
  pulling CrossCanvas changes, then rebuild the image.

## ARM / Raspberry Pi

Everything runs on ARM (tested on a Pi 3B, 64-bit Pi OS). One wrinkle worth
knowing: the PowerShell base image the poller builds from publishes amd64
and 32-bit arm/v7 but no arm64 - on a 64-bit ARM box Docker transparently
selects the arm/v7 build, which the kernel runs natively. Nothing to
configure; the built image just reports `arm v7`.
