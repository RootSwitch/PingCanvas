#!/bin/sh
# PingCanvas TLS bootstrap - Pattern A: HTTPS terminated in the web tier itself.
#
# Presence-based, no flag to remember: if a cert AND key are mounted at
# /etc/nginx/certs, generate a :443 server that mirrors the :80 locations. No
# cert -> HTTP only (the image's default). nginx:alpine runs every executable
# /docker-entrypoint.d/*.sh before starting nginx, so this lands the config in
# time with no entrypoint override.
#
# This script OWNS both conf.d files and rewrites them from scratch on every
# boot. That determinism matters on `docker restart` (same container fs as the
# previous boot): a stale default-ssl.conf pointing at a since-removed cert
# would crash-loop nginx, and a stale :80 redirect would point clients at a
# dead :443. Rebuilding both from current mounts/env makes restart safe.
#
# Get a cert the easy way with docker/gen-selfsigned-cert.{sh,ps1}, or drop in
# your own PEM pair. For real PKI / auto-renewing Let's Encrypt, front PingCanvas
# with a proxy (Caddy/Traefik) instead - see docker/README.md.
set -e

CERT=/etc/nginx/certs/fullchain.pem
KEY=/etc/nginx/certs/privkey.pem
SSL_CONF=/etc/nginx/conf.d/default-ssl.conf
HTTP_CONF=/etc/nginx/conf.d/default.conf
PRISTINE=/etc/nginx/pingcanvas-http.conf.pristine   # baked by Dockerfile.web

# Start from a known state every boot: pristine :80 server, no :443 server.
[ -f "$PRISTINE" ] && cp "$PRISTINE" "$HTTP_CONF"
rm -f "$SSL_CONF"

if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    if [ -f "$CERT" ] || [ -f "$KEY" ]; then
        echo "pingcanvas-tls: found only one of fullchain.pem/privkey.pem in /etc/nginx/certs - need BOTH. Serving HTTP only."
    else
        echo "pingcanvas-tls: no cert at $CERT - serving HTTP only."
    fi
    exit 0
fi

echo "pingcanvas-tls: cert found - enabling HTTPS on 443."
cat > "$SSL_CONF" <<EOF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:1m;
    ssl_session_timeout 10m;

    include /etc/nginx/snippets/pingcanvas-locations.conf;
}
EOF

# Optional: turn the plaintext :80 server into a redirect to HTTPS. Only sane
# when 443 is published on the standard port (443:443) - with a non-standard
# mapping like 8443:443 a redirect would point at the wrong port. Off by default
# so :80 keeps serving; opt in with PINGCANVAS_TLS_REDIRECT=1 in the compose
# (the pre-rename NETSTATUS_TLS_REDIRECT is honored too).
# (Reaching here means the cert exists, so the redirect never targets a dead
# :443; and the pristine copy above already undid any previous boot's redirect.)
if [ "${PINGCANVAS_TLS_REDIRECT:-${NETSTATUS_TLS_REDIRECT:-0}}" = "1" ]; then
    echo "pingcanvas-tls: TLS redirect enabled - :80 now 301-redirects to https."
    cat > "$HTTP_CONF" <<'REDIR'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
REDIR
fi
