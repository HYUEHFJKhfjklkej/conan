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
#   4. HTTP-probe the exact blob URL (<base>/<sha256>) -> definitive code+size,
#      and it leaves an entry in the conan-sources feed request log on ProGet
#   5. conan create <pkg> ... --no-remote -vvv     (prints the source download
#      URL; must now hit backup-sources, not the bundled archive)
#   6. verdict from BOTH signals (HTTP 200 probe + conan -vvv fetch) -> PASS/FAIL
#
# Auth for the probe (the conan download itself is anonymous backup-sources):
#   PROGET_API_KEY  -> X-ApiKey header     | PROGET_USER/PROGET_PASS -> basic
#   PROGET_INSECURE=1 -> curl -k (self-signed TLS)
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
# image ENV default applies. Pass smoke params + optional ProGet auth through
# as env vars (cleaner than string substitution into the INNER script).
PASS_ENV=(
    -e "SMOKE_PKG=$PKG"
    -e "SMOKE_VER=$VERSION"
    -e "SMOKE_PROFILE=$PROFILE"
    # passthrough-if-set from the host env (no '=' -> inherit):
    -e PROGET_API_KEY -e PROGET_USER -e PROGET_PASS -e PROGET_INSECURE
)
[ -n "${PROGET_SOURCES_URL:-}" ] && PASS_ENV+=(-e "PROGET_SOURCES_URL=$PROGET_SOURCES_URL")

# Single-quoted: nothing expands on the host. All vars resolve inside the
# container at runtime from the -e passthrough above.
INNER='
set -uo pipefail
cd /work/conan-recipes
PKG="$SMOKE_PKG"; VER="$SMOKE_VER"; PROF="$SMOKE_PROFILE"

echo "--- ensure_proget (download_urls on the volume) ---"
./test-astra/ensure_proget.sh
CONF="$(conan config home)/global.conf"
echo "--- download_urls in global.conf ---"
DLU=$(grep "core.sources:download_urls" "$CONF") \
    || { echo "[FAIL] download_urls not set — backup-sources is OFF"; exit 2; }
echo "$DLU"

# Backup-sources base = first URL in the list. The blob ProGet serves is named
# by the tarball sha256 (== the sha256 conandata declares), so we can probe the
# exact object URL directly.
BASE=$(printf "%s" "$DLU" | sed -E "s/.*\[\"([^\"]+)\".*/\1/")
TARBALL=$(ls "$PKG"/src/*"$VER"*.tar.gz 2>/dev/null | head -1)
[ -z "$TARBALL" ] && TARBALL=$(ls "$PKG"/src/*.tar.gz 2>/dev/null | head -1)
SHA=""
[ -n "$TARBALL" ] && SHA=$(sha256sum "$TARBALL" | awk "{print \$1}")
echo "--- backup-sources base: $BASE"
echo "--- tarball: ${TARBALL:-<none>}  sha256: ${SHA:-<none>}"

# Explicit HTTP probe — definitive code + size, AND it shows up in the
# conan-sources feed request log on ProGet.
if [ -n "$SHA" ] && command -v curl >/dev/null 2>&1; then
    URL="${BASE%/}/$SHA"
    AUTH=()
    if [ -n "${PROGET_API_KEY:-}" ]; then AUTH=(-H "X-ApiKey: ${PROGET_API_KEY}")
    elif [ -n "${PROGET_USER:-}" ]; then AUTH=(-u "${PROGET_USER}:${PROGET_PASS:-}"); fi
    INS=(); [ "${PROGET_INSECURE:-}" = "1" ] && INS=(-k)
    echo "PROGET_PROBE_URL: $URL"
    PROBE=$(curl -sS -o /dev/null "${INS[@]}" "${AUTH[@]}" \
        -w "HTTP %{http_code}  %{size_download}B  time=%{time_total}s" "$URL" 2>&1) \
        || PROBE="curl failed: $PROBE"
    echo "PROGET_PROBE: $PROBE"
else
    echo "PROGET_PROBE: skipped (no curl or no sha256)"
fi

echo "--- conan remove \"$PKG/*\" -c ---"
conan remove "$PKG/*" -c || true
echo "--- disable bundled fallback (ephemeral, container is --rm) ---"
[ -d "$PKG/src" ] && mv "$PKG/src" "$PKG/src.off"
echo "--- conan create -vvv (verbose: prints the source download URL) ---"
conan create "$PKG/" --version="$VER" \
    -pr:h="$PROF" -pr:b="$PROF" \
    -s build_type=Release --build=missing --no-remote -vvv
'

$SUDO docker run --rm \
    "${PASS_ENV[@]}" \
    -v "$VOLUME:/root/.conan2" \
    --entrypoint bash "$IMAGE" -c "$INNER" 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"

echo ""
echo "================ SMOKE VERDICT ================"

# 1. Direct HTTP probe of the blob URL.
PROBE_LINE=$(grep "^PROGET_PROBE:" "$LOG" | tail -1)
PROBE_URL=$(grep "^PROGET_PROBE_URL:" "$LOG" | tail -1 | sed 's/^PROGET_PROBE_URL: //')
[ -n "$PROBE_LINE" ] && echo " probe: ${PROBE_LINE#PROGET_PROBE: }  ($PROBE_URL)"
probe_ok=0
echo "$PROBE_LINE" | grep -q "HTTP 200" && probe_ok=1

# 2. conan -vvv actually fetched the source over the backup-sources URL.
conan_ok=0
grep -Eq "conan-sources/content|backup remote|Sources downloaded|Source.*[Dd]ownload" "$LOG" && conan_ok=1

if [ "$RC" -ne 0 ]; then
    echo " docker run exited $RC — build failed (see $LOG)"
    [ "$probe_ok" = 1 ] && echo " (but the HTTP probe got 200 — feed is reachable & seeded)"
    echo "=============================================="
    exit 1
fi
if [ "$conan_ok" = 1 ] || [ "$probe_ok" = 1 ]; then
    echo " PASS — $PKG/$VERSION sources served by ProGet backup-sources"
    echo "        HTTP probe 200: $([ "$probe_ok" = 1 ] && echo yes || echo 'no — check feed read perms')"
    echo "        conan fetched : $([ "$conan_ok" = 1 ] && echo yes || echo 'not seen in -vvv log')"
    echo "        conan evidence:"
    grep -Ei "conan-sources/content|backup|Sources downloaded|Source.*download" "$LOG" \
        | sed 's/^/          /' | head -5
    echo "=============================================="
    exit 0
else
    echo " FAIL — no ProGet download seen. Either the bundled src was still"
    echo "        present, download_urls was unset, the feed is not seeded"
    echo "        (HELP [16] step 1), or read perms block anonymous GET."
    echo "        probe=$PROBE_LINE  log=$LOG"
    echo "=============================================="
    exit 1
fi
