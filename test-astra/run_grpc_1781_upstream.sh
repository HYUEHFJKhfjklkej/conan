#!/bin/bash
# Full grpc/1.78.1 tree (newest line, upstream sources) → .nupkg
#
# Twin of run_grpc_1601_upstream.sh, but pinned to the NEWEST grpc the
# recipes carry (1.78.1) and its modern transitive stack. Canonical
# conan-recipes/<pkg> sources (fetched from upstream github via
# conandata.yml). Result: 7 .nupkg in the current deployer naming
# scheme (<pkg>.lin.gcc84.shared.x86_64.<ver>.nupkg).
#
# Versions (exactly what grpc/conanfile.py resolves for grpc>1.69.0,
# the `grpc_version > "1.60.0"` first branch at conanfile.py:109):
#   grpc        1.78.1
#   protobuf    5.29.6
#   abseil      20250127.0   (deployer slots it as absl/0.2.0)
#   re2         20251105
#   c-ares      1.34.6       (deployer renames to cares)
#   openssl     3.4.5        (recipe dir: openssl/, name=openssl)
#   zlib        1.3.1
#
# Self-wraps in `docker run grpc-tc-mirror` exactly like
# run_grpc_1601_upstream.sh. Never runs natively on the dev-VM.
#
# Usage:
#   ./test-astra/run_grpc_1781_upstream.sh
#
# Env overrides:
#   MIRROR_IMAGE      docker image tag (default: grpc-tc-mirror)
#   PROGET_BASE       base image for Dockerfile build (default: ProGet gcc84)
#   CACHE_VOLUME      docker volume for /root/.conan2 (default: fresh)
#   OUTPUT_DIR        host-relative output dir (default: output-grpc-1781-upstream)
#   PROFILE           conan profile (default: profiles/lin-gcc84-x86_64)
#   SHARED            shared opt for all deps (default: False — static)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-output-grpc-1781-upstream}"
MIRROR_IMAGE="${MIRROR_IMAGE:-grpc-tc-mirror}"
PROGET_BASE="${PROGET_BASE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0}"
X64_BASE_IMAGE="${X64_BASE_IMAGE:-$PROGET_BASE}"
BASE_IMAGE="${BASE_IMAGE:-$PROGET_BASE}"
CACHE_VOLUME="${CACHE_VOLUME:-conan-cache-grpc-1781-upstream}"
SHARED="${SHARED:-False}"
# Optional version suffix appended to every emitted .nupkg + nuspec +
# CMakeLists.var _dependencies entry. Use when uploading to a ProGet feed
# that already carries the same versions from a different source.
# Example: LEGACY_NUPKG_VERSION_SUFFIX=.1
# (slot-tag `shared` = DynamicRT — содержимое всё равно static .a).
LEGACY_NUPKG_VERSION_SUFFIX="${LEGACY_NUPKG_VERSION_SUFFIX:-}"

# Optional 1st arg: build + deploy only ONE package instead of the whole
# grpc tree. The recipes are still all exported (cheap) so version ranges
# resolve, but build/deploy targets just the requested ref.
#   ./run_grpc_1781_upstream.sh            -> grpc/1.78.1  (full tree, 7 nupkg)
#   ./run_grpc_1781_upstream.sh abseil     -> abseil only  (1 nupkg)
declare -A TARGET_REFS=(
    [grpc]=grpc/1.78.1      [abseil]=abseil/20250127.0  [protobuf]=protobuf/5.29.6
    [re2]=re2/20251105      [c-ares]=c-ares/1.34.6      [zlib]=zlib/1.3.1
    [openssl]=openssl/3.4.5
)
TARGET_REF="${TARGET_REFS[${1:-grpc}]:-grpc/1.78.1}"

mkdir -p "$OUTPUT_DIR"

# ----------------------------------------------------------------------
# Docker self-wrap (same idiom as run_grpc_1601_upstream.sh).
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
        -c "bash ./test-astra/$(basename "${BASH_SOURCE[0]}") $*"
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
# (absl/0.2.0, cares/1.19.0, etc.) is already in cache. They would
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
# Step 1: export all 7 recipes at the exact versions grpc/1.78.1 resolves.
# These match grpc/conanfile.py:109 (the `grpc_version > "1.69.0"`
# branch) — the newest line the recipes support.
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 1] conan export — 7 recipes, grpc/1.78.1 stack"
echo "=================================================="
declare -A EXPORTS=(
    [zlib]=1.3.1
    [abseil]=20250127.0
    [c-ares]=1.34.6
    [re2]=20251105
    [protobuf]=5.29.6
    [openssl]=3.4.5
    [grpc]=1.78.1
)
# Stable export order: leaves before branches.
for pkg in zlib abseil c-ares re2 protobuf openssl grpc; do
    ver="${EXPORTS[$pkg]}"
    echo "[EXPORT] $pkg/$ver  (from ./$pkg)"
    conan export "$pkg/" --version="$ver" --no-remote
done
echo ""

# ----------------------------------------------------------------------
# Step 2: build the full tree Release + Debug (deployer needs both).
# --build=missing tells Conan to compile any binary not in cache.
# -o "*/*:shared=$SHARED" makes every dep follow the same linkage as
# requested (downstream Elara products link statically -> default static .a).
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 2] build grpc/1.78.1 tree (Release + Debug)"
echo "=================================================="
for BT in Release Debug; do
    echo ""
    echo "------ build_type=$BT  ($TARGET_REF) ------"
    # abseil static — legacy coarse 21-lib packaging only triggers on a
    # static build (abseil/conanfile.py::_aggregate_legacy_coarse). The
    # more-specific abseil/* pattern pins abseil static even if the user
    # overrides SHARED=True (rare; default SHARED=False is already static).
    conan install --requires="$TARGET_REF" \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        --build=missing --no-remote \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED" \
        -o "abseil/*:shared=False" \
        -o "protobuf/*:debug_suffix=False"
done
echo ""
echo "[STEP 2] full tree built."
echo ""

# ----------------------------------------------------------------------
# Step 3: deployer → 7 legacy-named .nupkg.
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 3] deploy $TARGET_REF -> legacy .nupkg into $OUTPUT_DIR/"
echo "=================================================="
rm -f "$OUTPUT_DIR"/{grpc,protobuf,abseil,absl,re2,c-ares,cares,openssl,zlib}.*.nupkg

# Deploy must target the SAME ref as Step 2 ($TARGET_REF) and repeat the
# EXACT options Step 2 built with. There is no --build here, so a differing
# package_id (notably a missing `abseil/*:shared=False`) makes Conan report
# the binary as missing and abort. Single-package run -> 1 .nupkg; full -> 7.
conan install --requires="$TARGET_REF" \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    -o "*/*:shared=$SHARED" \
    -o "abseil/*:shared=False" \
    -o "protobuf/*:debug_suffix=False" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/$OUTPUT_DIR"

echo ""
echo "[INFO] output listing:"
ls -lh "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | sed 's|^|  |' || echo "  (empty)"

echo ""
echo "=================================================="
echo "[DONE] grpc/1.78.1 newest-line tree built."
echo "Artifacts in $OUTPUT_DIR/ (legacy-named .nupkg)."
echo "=================================================="
