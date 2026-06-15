#!/bin/bash
# smoke_proget_sources.sh — prove that a build inside the mirror container
# pulls a package's sources from ProGet backup-sources (not the bundled
# src/*.tar.gz baked into the image).
#
# Why a dedicated docker script: the build runs in the container and the cache
# lives on the conan-cache-* volume, BUT the bundled src/<pkg>-<ver>.tar.gz is
# baked into the IMAGE LAYER (Dockerfile COPY <pkg> ...). source() prefers that
# archive, so just wiping the volume is not enough — the bundled copy must also
# be moved aside. We do it inside a throwaway `--rm` container: the image and
# the host repo stay untouched, no restore needed.
#
# What it does, all in one `docker run --rm`:
#   1. ensure_proget.sh  -> (re)write core.sources:download_urls on the volume
#   2. conan remove "<pkg>/*" -c                 (force source() to re-run)
#   3. mv <pkg>/src <pkg>/src.off                (disable bundled fallback)
#   4. conan create <pkg> ... --no-remote        (must now hit backup-sources)
#   5. grep the log for a download from conan-sources/content -> PASS/FAIL
#
# Usage:
#   ./test-astra/smoke_proget_sources.sh                 # zlib/1.3.1, x86_64
#   PKG=re2 VERSION=20230301 ./test-astra/smoke_proget_sources.sh
#   FRESH_VOLUME=1 ./test-astra/smoke_proget_sources.sh  # wipe volume first
#
# Env:
#   PKG            recipe dir / package name   (default zlib)
#   VERSION        version to build            (default 1.3.1)
#   IMAGE          mirror image tag            (default grpc-tc-mirror-x86_64)
#   VOLUME         conan cache volume          (default conan-cache-x86_64)
#   PROFILE        host+build profile          (default profiles/lin-gcc84-x86_64)
#   PROGET_SOURCES_URL  override the image ENV default (passed through if set)
#   FRESH_VOLUME   1 = `docker volume rm $VOLUME` before the run
#   NO_SUDO        1 = drop the `sudo` prefix on docker

set -uo pipefail

PKG="${PKG:-zlib}"
VERSION="${VERSION:-1.3.1}"
IMAGE="${IMAGE:-grpc-tc-mirror-x86_64}"
VOLUME="${VOLUME:-conan-cache-x86_64}"
PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"

SUDO="sudo"
[ "${NO_SUDO:-}" = "1" ] && SUDO=""

LOG="/tmp/smoke_proget_${PKG}.log"

echo "== smoke: $PKG/$VERSION from ProGet backup-sources (image $IMAGE) =="

if ! $SUDO docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[FAIL] image '$IMAGE' missing — build it first (test_x86_64.sh build)" >&2
    exit 1
fi

if [ "${FRESH_VOLUME:-}" = "1" ]; then
    echo "[INFO] FRESH_VOLUME=1 -> removing volume '$VOLUME'"
    $SUDO docker volume rm "$VOLUME" >/dev/null 2>&1 || true
fi

# Pass PROGET_SOURCES_URL through only if the caller overrode it; otherwise the
# image ENV default applies.
URL_ARG=()
[ -n "${PROGET_SOURCES_URL:-}" ] && URL_ARG=(-e "PROGET_SOURCES_URL=$PROGET_SOURCES_URL")

INNER='
set -uo pipefail
cd /work/conan-recipes
echo "--- ensure_proget (download_urls on the volume) ---"
./test-astra/ensure_proget.sh
echo "--- download_urls in global.conf ---"
grep "core.sources:download_urls" "$(conan config home)/global.conf" \
    || { echo "[FAIL] download_urls not set — backup-sources is OFF"; exit 2; }
echo "--- conan remove '"'"'PKG_PLACEHOLDER/*'"'"' -c ---"
conan remove "PKG_PLACEHOLDER/*" -c || true
echo "--- disable bundled fallback (ephemeral, container is --rm) ---"
[ -d "PKG_PLACEHOLDER/src" ] && mv "PKG_PLACEHOLDER/src" "PKG_PLACEHOLDER/src.off"
echo "--- conan create ---"
conan create "PKG_PLACEHOLDER/" --version="VERSION_PLACEHOLDER" \
    -pr:h="PROFILE_PLACEHOLDER" -pr:b="PROFILE_PLACEHOLDER" \
    -s build_type=Release --build=missing --no-remote
'
INNER="${INNER//PKG_PLACEHOLDER/$PKG}"
INNER="${INNER//VERSION_PLACEHOLDER/$VERSION}"
INNER="${INNER//PROFILE_PLACEHOLDER/$PROFILE}"

$SUDO docker run --rm \
    "${URL_ARG[@]}" \
    -v "$VOLUME:/root/.conan2" \
    --entrypoint bash "$IMAGE" -c "$INNER" 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"

echo ""
echo "================ SMOKE VERDICT ================"
if [ "$RC" -ne 0 ]; then
    echo " docker run exited $RC — build failed (see $LOG)"
    echo "=============================================="
    exit 1
fi
if grep -Eq "conan-sources/content|backup remote|Sources downloaded from" "$LOG"; then
    echo " PASS — sources for $PKG/$VERSION came from ProGet backup-sources"
    echo "        evidence:"
    grep -Ei "conan-sources/content|backup|Sources downloaded" "$LOG" | sed 's/^/          /' | head -5
    echo "=============================================="
    exit 0
else
    echo " FAIL — no ProGet download seen in the log. Either the bundled src"
    echo "        was still present, download_urls was unset, or the feed is"
    echo "        not seeded (run HELP [16] step 1). Log: $LOG"
    echo "=============================================="
    exit 1
fi
