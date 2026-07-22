#!/usr/bin/env bash
# docker/publish.sh - build the images and export OFFLINE tarballs (one per arch).
#
# docker save/load is single-architecture, so we emit one tarball per arch; a
# recipient loads the one matching their box and runs docker-compose.dist.yml.
# (A registry is the path for a single multi-arch artifact - see README.)
#
#   ./publish.sh [version] [arch ...]        # version optional; default arches amd64 arm64
#   ./publish.sh                             # unversioned -> pingcanvas-<arch>.tar.gz, :latest
#   ./publish.sh amd64 arm64                 # unversioned, explicit arches
#   ./publish.sh 3.0.0                        # versioned -> pingcanvas-3.0.0-<arch>.tar.gz
#   ./publish.sh 3.0.0 amd64                  # versioned, just amd64
#
# Cross-arch builds need QEMU binfmt on the host (one time):
#   docker run --privileged --rm tonistiigi/binfmt --install all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# First arg is an OPTIONAL version tag. Omit it (or lead with an arch) to build
# unversioned: pingcanvas-<arch>.tar.gz, images tagged :latest only. A leading
# token that isn't a known Docker arch is treated as the version - but informal
# arch spellings (armv7l, aarch64, x86_64 - uname -m muscle memory) are caught
# rather than silently becoming a bogus version tag.
VERSION=""
if [ "${1:-}" ] && ! printf '%s' "$1" | grep -Eq '^(amd64|arm64|arm/v[0-9]+|386|ppc64le|s390x|riscv64|mips64le)$'; then
    if printf '%s' "$1" | grep -Eiq '^(arm|armv[0-9]+l?|aarch64|x86[_-]64|i[36]86)$'; then
        echo "'$1' looks like an architecture, but Docker platforms use amd64/arm64/arm/v7/..." >&2
        echo "(did you mean one of those? A version tag must not look like an arch.)" >&2
        exit 1
    fi
    VERSION="$1"; shift
fi
if [ "$#" -gt 0 ]; then ARCHES=("$@"); else ARCHES=(amd64 arm64); fi

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx required (Docker 19.03+)" >&2; exit 1; }

# 1. assemble the web assets baked into the web image
"$SCRIPT_DIR/build-web.sh"

# 2. a buildx builder that supports cross-arch --load
docker buildx inspect pingcanvas-builder >/dev/null 2>&1 || docker buildx create --name pingcanvas-builder >/dev/null
docker buildx use pingcanvas-builder

OUT="$REPO_ROOT/dist"; mkdir -p "$OUT"
for arch in "${ARCHES[@]}"; do
    platform="linux/$arch"
    echo ">> building $platform${VERSION:+ (v$VERSION)}"
    # Always tag :latest (so the dist compose's default just works - recipients
    # never need to set a version). Add :VERSION too when one was given, for
    # provenance/rollback. Same set gets saved into the tarball.
    webTags=(-t "pingcanvas-web:latest"); pollTags=(-t "pingcanvas-poller:latest")
    saveImgs=("pingcanvas-web:latest" "pingcanvas-poller:latest")
    if [ -n "$VERSION" ]; then
        webTags+=(-t "pingcanvas-web:$VERSION"); pollTags+=(-t "pingcanvas-poller:$VERSION")
        saveImgs=("pingcanvas-web:$VERSION" "pingcanvas-web:latest" \
                  "pingcanvas-poller:$VERSION" "pingcanvas-poller:latest")
    fi
    docker buildx build --platform "$platform" -f "$SCRIPT_DIR/Dockerfile.web" \
        "${webTags[@]}" --load "$REPO_ROOT"
    docker buildx build --platform "$platform" -f "$SCRIPT_DIR/Dockerfile.poller" \
        "${pollTags[@]}" --load "$REPO_ROOT"
    archSafe="${arch//\//-}"                    # arm/v7 -> arm-v7 (no slash in the filename)
    tarball="$OUT/pingcanvas${VERSION:+-$VERSION}-$archSafe.tar.gz"
    docker save "${saveImgs[@]}" | gzip > "$tarball"
    echo ">> wrote $tarball ($(du -h "$tarball" | cut -f1))"
done

# bundle the recipient-facing quickstart + the dist compose next to the tarballs
cp "$SCRIPT_DIR/docker-compose.dist.yml" "$OUT/docker-compose.yml"
[ -f "$SCRIPT_DIR/QUICKSTART.txt" ] && cp "$SCRIPT_DIR/QUICKSTART.txt" "$OUT/QUICKSTART.txt"
# optional-HTTPS helpers travel with the offline bundle so recipients can enable
# self-signed TLS without this repo (Pattern A - see QUICKSTART/README).
cp "$SCRIPT_DIR/gen-selfsigned-cert.sh" "$SCRIPT_DIR/gen-selfsigned-cert.ps1" "$OUT/" 2>/dev/null || true

echo ""
echo "Done. dist/ now holds, ready to hand over:"
echo "  - pingcanvas${VERSION:+-$VERSION}-<arch>.tar.gz   (send the recipient's arch)"
echo "  - docker-compose.yml + QUICKSTART.txt"
echo "Recipient runs:  docker load < pingcanvas${VERSION:+-$VERSION}-<arch>.tar.gz && docker compose up -d"
echo "(no version to set - images are also tagged :latest)"
