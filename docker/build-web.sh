#!/usr/bin/env bash
# docker/build-web.sh - bash port of build-web.ps1 for Linux hosts (no pwsh
# needed on the host; PowerShell only runs inside the poller container).
# Assembles docker/web/ with BOTH apps: index.html (editor, verbatim) and
# kiosk.html (editor + embed flag + kiosk assets injected), plus shared renderer.
#
#   ./build-web.sh [/path/to/CrossCanvas]        # defaults to ../../crosscanvas
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tolerant sibling discovery (default path only - an explicit arg still fails
# loudly): GitHub ZIP downloads extract as 'CrossCanvas-main' / '-master', a
# checkout from before the rename is a 'netdraw' sibling, and Windows
# Explorer's Extract All nests everything one level deeper (ZIP.zip ->
# ZIP/ZIP/...) - so search the folder above this checkout AND one above that,
# and accept app.js either directly in a crosscanvas*/netdraw* folder
# (case-insensitive) or in a same-named folder nested inside it.
DEFAULT_CC="$SCRIPT_DIR/../../crosscanvas"
if [ ! -f "$DEFAULT_CC/app.js" ]; then
    for root in "$SCRIPT_DIR"/../.. "$SCRIPT_DIR"/../../..; do
        for d in "$root"/*/; do
            name="$(basename "$d" | tr '[:upper:]' '[:lower:]')"
            case "$name" in crosscanvas*|netdraw*) ;; *) continue ;; esac
            if [ -f "$d/app.js" ]; then DEFAULT_CC="$d"; break 2; fi
            for n in "$d"*/; do
                nname="$(basename "$n" | tr '[:upper:]' '[:lower:]')"
                case "$nname" in
                    crosscanvas*|netdraw*) [ -f "$n/app.js" ] && DEFAULT_CC="$n" && break 3 ;;
                esac
            done
        done
    done
fi
[ -f "${1:-$DEFAULT_CC}/app.js" ] || { echo "CrossCanvas not found: ${1:-$DEFAULT_CC} (need a sibling folder containing app.js - e.g. 'crosscanvas' or a 'CrossCanvas-main' ZIP extract - or pass the path as an argument)" >&2; exit 1; }
CROSSCANVAS="$(cd "${1:-$DEFAULT_CC}" && pwd)"
KIOSK="$(cd "$SCRIPT_DIR/../kiosk" && pwd)"
OUT="$SCRIPT_DIR/web"

# Rebuild the artifacts but PRESERVE user data: a board.xcanvas or status.json
# left in this folder (the Windows quickstart and manual deploys both do this)
# must survive a rebuild. Everything else is our own output.
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -maxdepth 1 ! -name '*.xcanvas' ! -name 'status*.json' -exec rm -rf {} +

# 1. shared renderer + the editor's own index.html (verbatim). favicon.svg is
#    the EDITOR's icon (the html references it; omitting it 404'd silently).
for f in app.js devices.js style.css index.html favicon.svg; do cp "$CROSSCANVAS/$f" "$OUT/$f"; done
[ -f "$CROSSCANVAS/customdevices.js" ] && cp "$CROSSCANVAS/customdevices.js" "$OUT/"

# 2. kiosk layer + the kiosk's own favicon under a distinct name, so the NOC tab
#    (green status ring) is tellable from the editor tab (blue diamond).
for f in kiosk-init.js status-layer.js snmp-layer.js kiosk.css starter-board.xcanvas; do cp "$KIOSK/$f" "$OUT/$f"; done
cp "$KIOSK/favicon.svg" "$OUT/kiosk-favicon.svg"

# 3. kiosk.html = CrossCanvas index.html + injections at stable anchors (fail loudly)
cp "$CROSSCANVAS/index.html" "$OUT/kiosk.html"
grep -qF '<link rel="stylesheet" href="style.css">' "$OUT/kiosk.html" || { echo "Anchor (css) not found in CrossCanvas index.html" >&2; exit 1; }
grep -qF '<script src="app.js"></script>'          "$OUT/kiosk.html" || { echo "Anchor (app) not found in CrossCanvas index.html" >&2; exit 1; }
sed -i 's|<link rel="stylesheet" href="style.css">|&\n    <link rel="stylesheet" href="kiosk.css">|' "$OUT/kiosk.html"
# The inline embed flag is hash-allowlisted in CrossCanvas's web.config CSP -
# changing this exact string requires recomputing that sha256 hash.
sed -i 's|<script src="app.js"></script>|<script>window.CROSSCANVAS_EMBED = true;</script>\n    <script src="app.js"></script>\n    <script src="status-layer.js"></script>\n    <script src="snmp-layer.js"></script>\n    <script src="kiosk-init.js"></script>|' "$OUT/kiosk.html"
# kiosk tab gets its own icon (best-effort - cosmetic, no hard anchor check)
sed -i 's|href="favicon.svg"|href="kiosk-favicon.svg"|' "$OUT/kiosk.html"
# kiosk tab title: the source is the editor's "CrossCanvas Diagram Editor"; the
# wall is PingCanvas (kiosk-init refines it to "PingCanvas - <board>" once a
# board loads). Best-effort like the favicon - a no-match just keeps the editor title.
sed -i 's|<title>CrossCanvas Diagram Editor</title>|<title>PingCanvas</title>|' "$OUT/kiosk.html"

echo "Built web root -> $OUT"
ls -la "$OUT"
