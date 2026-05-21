#!/bin/bash
# Full grpc/1.60.1 tree (legacy-pinned versions, upstream sources) → .nupkg
#
# Same VERSION NUMBERS as the Elara Bitbucket-forks stack, but using
# canonical conan-recipes/<pkg> (sources fetched from upstream github
# via conandata.yml). Result: 7 .nupkg compatible with downstream
# consumers expecting the legacy GR113/GR120 version numbers, built
# from official upstream code (no Elara forks).
#
# Versions (exactly what grpc/conanfile.py:128 pins for the 1.60.x line):
#   grpc        1.60.1
#   protobuf    4.25.2
#   abseil      20240116.2
#   re2         20230301
#   c-ares      1.25.0
#   openssl     1.1.11    (recipe dir: openssl-1x/, name=openssl)
#   zlib        1.3.0
#
# Self-wraps in `docker run grpc-tc-mirror` exactly like
# run_legacy_versions.sh. Never runs natively on the dev-VM.
#
# Usage:
#   ./test-astra/run_grpc_1601_upstream.sh
#
# Env overrides:
#   MIRROR_IMAGE      docker image tag (default: grpc-tc-mirror)
#   PROGET_BASE       base image for Dockerfile build (default: ProGet gcc84)
#   CACHE_VOLUME      docker volume for /root/.conan2 (default: fresh)
#   OUTPUT_DIR        host-relative output dir (default: output-grpc-1601-upstream)
#   PROFILE           conan profile (default: profiles/lin-gcc84-x86_64)
#   SHARED            shared opt for all deps (default: True)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-output-grpc-1601-upstream}"
MIRROR_IMAGE="${MIRROR_IMAGE:-grpc-tc-mirror}"
PROGET_BASE="${PROGET_BASE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0}"
X64_BASE_IMAGE="${X64_BASE_IMAGE:-$PROGET_BASE}"
BASE_IMAGE="${BASE_IMAGE:-$PROGET_BASE}"
CACHE_VOLUME="${CACHE_VOLUME:-conan-cache-grpc-1601-upstream}"
SHARED="${SHARED:-True}"
# Optional version suffix appended to every emitted .nupkg + nuspec +
# CMakeLists.var _dependencies entry. Use when uploading to a ProGet feed
# that already carries the same versions from a different source
# (Bitbucket legacy forks). Example: LEGACY_NUPKG_VERSION_SUFFIX=.1
# yields abseil.lin.gcc84.shared.x86_64.20240116.2.1.nupkg.
LEGACY_NUPKG_VERSION_SUFFIX="${LEGACY_NUPKG_VERSION_SUFFIX:-}"

mkdir -p "$OUTPUT_DIR"

# ----------------------------------------------------------------------
# Docker self-wrap (same idiom as run_legacy_versions.sh /
# run_proto_4252_canonical.sh).
# ----------------------------------------------------------------------
if [ -z "${IN_MIRROR:-}" ] && [ ! -x /opt/x64-native-gcc/bin/gcc ]; then
    echo "[INFO] Host run detected. Wrapping in docker run $MIRROR_IMAGE ..."

    if ! docker image inspect "$MIRROR_IMAGE" >/dev/null 2>&1; then
        echo "[INFO] Image $MIRROR_IMAGE missing — building from Dockerfile.grpc-tc-mirror..."
        echo "[INFO] X64_BASE_IMAGE=$X64_BASE_IMAGE"
        echo "[INFO] BASE_IMAGE=$BASE_IMAGE"
        docker build \
            --build-arg X64_BASE_IMAGE="$X64_BASE_IMAGE" \
            --build-arg BASE_IMAGE="$BASE_IMAGE" \
            -f Dockerfile.grpc-tc-mirror \
            -t "$MIRROR_IMAGE" \
            .
    fi

    exec docker run --rm \
        -v "$ROOT_DIR:/work/conan-recipes" \
        -v "$CACHE_VOLUME:/root/.conan2" \
        -e IN_MIRROR=1 \
        -e OUTPUT_DIR="$OUTPUT_DIR" \
        -e PROFILE="$PROFILE" \
        -e SHARED="$SHARED" \
        -e LEGACY_NUPKG_VERSION_SUFFIX="$LEGACY_NUPKG_VERSION_SUFFIX" \
        --entrypoint bash \
        "$MIRROR_IMAGE" \
        -c "./test-astra/$(basename "${BASH_SOURCE[0]}") $*"
fi

# ----------------------------------------------------------------------
# Inside the mirror container from here.
# ----------------------------------------------------------------------
if ! command -v conan >/dev/null 2>&1; then
    if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$ROOT_DIR/venv/bin/activate"
    fi
fi
if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not on PATH inside container — check grpc-tc-mirror image"
    exit 1
fi

echo "[INFO] conan:           $(conan --version 2>&1 | head -1)"
echo "[INFO] profile:         $PROFILE"
echo "[INFO] output:          $OUTPUT_DIR"
echo "[INFO] shared:          $SHARED"
echo "[INFO] cache:           $(conan config home 2>/dev/null)"
echo "[INFO] version_suffix:  '${LEGACY_NUPKG_VERSION_SUFFIX}'  (empty = no suffix)"
echo ""

# ----------------------------------------------------------------------
# Step 0: pre-flight — refuse to run if any Elara-fork legacy/* package
# (absl/0.2.0, re2/0.2.0, etc.) is already in cache. They would
# resolve ahead of our upstream-pinned versions and reintroduce the
# inline-namespace mismatch this script is designed to avoid.
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 0] pre-flight: no legacy/* in cache"
echo "=================================================="
STALE=""
for pat in 'absl/0.2.0' 'cares/1.19.0' 'upb/0.2.0' 'address_sorting/1.0.0'; do
    if conan list "$pat" 2>/dev/null | grep -qE "^\s+$pat"; then
        STALE="$STALE $pat"
    fi
done
if [ -n "$STALE" ]; then
    echo "[ERROR] cache contains Elara-fork packages:$STALE"
    echo "        These resolve ahead of canonical recipes — abort."
    echo "        Either use a fresh CACHE_VOLUME (default) or:"
    echo "            conan remove 'absl/*' 'cares/1.19.0' 'upb/*' 'address_sorting/*' -c"
    exit 1
fi
echo "[STEP 0] clean."
echo ""

# ----------------------------------------------------------------------
# Step 0.5: nuke the cache so every build is from scratch. The recipe
# `debug_suffix` option does not always force a new package_id in the
# protobuf recipe — Conan can silently reuse a binary built with the
# default options. Wiping the cache guarantees a fresh build each run.
# Skippable via SKIP_CACHE_CLEAN=1 if you want to iterate faster (e.g.
# tweaking the deployer only).
# ----------------------------------------------------------------------
if [ -z "${SKIP_CACHE_CLEAN:-}" ]; then
    echo "=================================================="
    echo "[STEP 0.5] wipe Conan cache (set SKIP_CACHE_CLEAN=1 to skip)"
    echo "=================================================="
    conan remove '*' -c
    echo ""
fi

# ----------------------------------------------------------------------
# Step 1: export all 7 recipes at the exact versions grpc/1.60.1 pins.
# These match grpc/conanfile.py:128 (the `elif _grpc_release == "1.60"`
# branch), which is precisely the version-tuple downstream products
# expect from the legacy Bitbucket stack.
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 1] conan export — 7 recipes, legacy-pinned versions"
echo "=================================================="
declare -A EXPORTS=(
    [zlib]=1.3.0
    [abseil]=20240116.2
    [c-ares]=1.25.0
    [re2]=20230301
    [protobuf]=4.25.2
    [openssl-1x]=1.1.11
    [grpc]=1.60.1
)
# Stable export order: leaves before branches.
for pkg in zlib abseil c-ares re2 protobuf openssl-1x grpc; do
    ver="${EXPORTS[$pkg]}"
    echo "[EXPORT] $pkg/$ver  (from ./$pkg)"
    conan export "$pkg/" --version="$ver" --no-remote
done
echo ""

# ----------------------------------------------------------------------
# Step 2: build the full tree Release + Debug (deployer needs both).
# --build=missing tells Conan to compile any binary not in cache.
# -o "*/*:shared=$SHARED" makes every dep follow the same linkage as
# requested (downstream needs shared .so for the .nupkg).
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 2] build grpc/1.60.1 tree (Release + Debug)"
echo "=================================================="
for BT in Release Debug; do
    echo ""
    echo "------ build_type=$BT ------"
    conan install --requires=grpc/1.60.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        --build=missing --no-remote \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED" \
        -o "protobuf/*:debug_suffix=False"
done
echo ""
echo "[STEP 2] full tree built."
echo ""

# ----------------------------------------------------------------------
# Step 3: deployer → 7 legacy-named .nupkg.
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 3] deploy 7 legacy .nupkg into $OUTPUT_DIR/"
echo "=================================================="
rm -f "$OUTPUT_DIR"/{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg

conan install --requires=grpc/1.60.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    -o "*/*:shared=$SHARED" \
    -o "protobuf/*:debug_suffix=False" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/$OUTPUT_DIR"

echo ""
echo "[INFO] output listing:"
ls -lh "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | sed 's|^|  |' || echo "  (empty)"

echo ""
echo "=================================================="
echo "[DONE] grpc/1.60.1 upstream-mirror-of-bitbucket tree built."
echo "Artifacts in $OUTPUT_DIR/ (legacy-named .nupkg)."
echo "=================================================="
