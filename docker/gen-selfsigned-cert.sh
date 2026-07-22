#!/usr/bin/env bash
# gen-selfsigned-cert.sh - one self-signed cert+key for PingCanvas Pattern A HTTPS.
#
#   ./gen-selfsigned-cert.sh [hostname] [days]
#   ./gen-selfsigned-cert.sh noc.lan 825
#
# Writes {fullchain.pem,privkey.pem} into ./certs by default - run it from the
# same directory as your docker-compose.yml (where ./data lives). The compose
# mounts ./certs into the web container, and the entrypoint turns on HTTPS the
# next time you `docker compose up -d`. Set CERT_DIR to write somewhere else
# (e.g. a shared data folder the override mounts), matching the Node apps'
# gen-cert.sh so the whole suite honors the same variable:
#
#   CERT_DIR=/srv/noc-data/certs ./gen-selfsigned-cert.sh noc.lan
#
# Browsers WILL warn on a self-signed cert - that's expected. Trust it once on
# the kiosk machine, or front PingCanvas with a proxy (Caddy) for real PKI.
set -euo pipefail

CN="${1:-pingcanvas.local}"
DAYS="${2:-825}"          # keep <825d: modern clients reject longer-lived leaf certs
DIR="${CERT_DIR:-./certs}"

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl not found. On Windows run gen-selfsigned-cert.ps1 (uses Docker," >&2
    echo "no local openssl needed), or install openssl and re-run." >&2
    exit 1
fi

mkdir -p "$DIR" 2>/dev/null || true
# If the stack started before ./certs existed, Docker created it root-owned -
# fail with the fix instead of a bare openssl EACCES.
if [ ! -w "$DIR" ]; then
    echo "$DIR is not writable (docker likely created it as root)." >&2
    echo "Fix:  sudo chown $(id -un) $DIR   then re-run." >&2
    exit 1
fi
# Basic CN hygiene: it lands inside the SAN list, so commas/spaces would inject
# bogus SAN tokens rather than fail loudly.
case "$CN" in *[!A-Za-z0-9.-]*)
    echo "CN '$CN' contains characters outside [A-Za-z0-9.-] - pick a plain hostname." >&2
    exit 1
esac
# The two MSYS_* vars stop Git Bash (Windows) from rewriting the leading-slash
# "-subj /CN=..." into a C:\ path. They're unused no-ops on real Linux/macOS.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$DIR/privkey.pem" -out "$DIR/fullchain.pem" \
    -days "$DAYS" -subj "/CN=$CN" \
    -addext "subjectAltName=DNS:$CN,DNS:localhost,IP:127.0.0.1"
chmod 600 "$DIR/privkey.pem" 2>/dev/null || true

echo "Wrote $DIR/fullchain.pem + $DIR/privkey.pem  (CN=$CN, ${DAYS}d)"
echo "Next: docker compose restart web   ->   https://<host>:8443/index.html"
echo "      (restart, not 'up -d' - up -d won't recreate a running container to"
echo "       re-run the entrypoint that enables HTTPS.)"
