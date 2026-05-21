#!/bin/bash
# Canonical protobuf 4.25.2 + abseil 20230802.1 build via Docker mirror.
#
# Purpose
# -------
# Sanity check that the upstream-canonical recipes in this repo
# (protobuf/, abseil/) produce a working protoc + .nupkg under the
# grpc-tc-mirror image — without touching the legacy/ forks at all.
# This is the answer to the `undefined reference to absl::lts_20230802::*`
# class of errors that hit legacy/protobuf 4.25.2 when it pulls
# absl/0.2.0 (which carries inline namespace lts_20240116).
#
# Self-wraps in `docker run grpc-tc-mirror` exactly like
# run_legacy_versions.sh. Never runs natively on the dev-VM (Astra 1.8
# ships gcc 12 — wrong ABI vs CI's gcc 8.4 in the mirror).
#
# Usage
# -----
#   ./test-astra/run_proto_4252_canonical.sh
#
# Override via env:
#   MIRROR_IMAGE      docker image tag (default: grpc-tc-mirror)
#   PROGET_BASE       base image for Dockerfile build (default: ProGet)
#   CACHE_VOLUME      docker volume for /root/.conan2 (default: fresh)
#   OUTPUT_DIR        host-relative output dir for .nupkg (default: output-proto-4252-canonical)
#   PROFILE           conan profile (default: profiles/lin-gcc84-x86_64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-output-proto-4252-canonical}"
MIRROR_IMAGE="${MIRROR_IMAGE:-grpc-tc-mirror}"
PROGET_BASE="${PROGET_BASE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0}"
X64_BASE_IMAGE="${X64_BASE_IMAGE:-$PROGET_BASE}"
BASE_IMAGE="${BASE_IMAGE:-$PROGET_BASE}"
# Use a FRESH cache volume by default — otherwise an old absl/0.2.0 or
# abseil cached from a legacy run can sneak onto the link line and
# reproduce the very error this build is trying to disprove.
CACHE_VOLUME="${CACHE_VOLUME:-conan-cache-proto-4252-canonical}"

mkdir -p "$OUTPUT_DIR"

# ----------------------------------------------------------------------
# Docker self-wrap (same idiom as run_legacy_versions.sh).
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
        --entrypoint bash \
        "$MIRROR_IMAGE" \
        -c "./test-astra/$(basename "${BASH_SOURCE[0]}") $*"
fi

# ----------------------------------------------------------------------
# From here we are inside the mirror container (or, in theory, on a host
# that has /opt/x64-native-gcc/bin/gcc — same effect).
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

echo "[INFO] conan:    $(conan --version 2>&1 | head -1)"
echo "[INFO] profile:  $PROFILE"
echo "[INFO] output:   $OUTPUT_DIR"
echo "[INFO] cache:    $(conan config home 2>/dev/null)"
echo ""

# ----------------------------------------------------------------------
# Pre-flight: prove the cache does NOT contain any stale absl/0.2.0
# or abseil from prior legacy runs. If a fresh CACHE_VOLUME was used
# this is a no-op. If a shared volume was passed via CACHE_VOLUME env,
# this aborts the run rather than silently linking against the wrong
# abseil (the original failure mode this script exists to avoid).
# ----------------------------------------------------------------------
echo "[STEP 0] pre-flight: check no stale absl/0.2.0 in cache"
STALE=$(conan list 'absl/*' 2>/dev/null | grep -E '^\s+absl/0\.2\.0' || true)
if [ -n "$STALE" ]; then
    echo "[ERROR] cache contains legacy absl/0.2.0 — would conflict with abseil/20230802.1"
    echo "$STALE"
    echo ""
    echo "Either use a fresh CACHE_VOLUME (default), or run:"
    echo "    conan remove 'absl/*' -c"
    echo "    conan remove 'protobuf/*' -c"
    exit 1
fi
echo "[STEP 0] clean."
echo ""

# ----------------------------------------------------------------------
# Step 1 — abseil 20230802.1 (Release + Debug)
# ----------------------------------------------------------------------
echo "=================================================="
echo "[STEP 1] conan create abseil/20230802.1  (Release)"
echo "=================================================="
conan create abseil/ --version=20230802.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Release --build=missing --no-remote

echo ""
echo "=================================================="
echo "[STEP 1] conan create abseil/20230802.1  (Debug)"
echo "=================================================="
conan create abseil/ --version=20230802.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Debug --build=missing --no-remote

# ----------------------------------------------------------------------
# Step 1b — zlib 1.3.1 (Release + Debug)
# protobuf 4.25.2 transitively requires zlib/[>=1.2.11 <2] when
# options.with_zlib=True (the recipe default). In --no-remote mode the
# version range cannot be resolved from conan-center; we must seed the
# cache with a matching zlib build first.
# ----------------------------------------------------------------------
echo ""
echo "=================================================="
echo "[STEP 1b] conan create zlib/1.3.1  (Release)"
echo "=================================================="
conan create zlib/ --version=1.3.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Release --build=missing --no-remote

echo ""
echo "=================================================="
echo "[STEP 1b] conan create zlib/1.3.1  (Debug)"
echo "=================================================="
conan create zlib/ --version=1.3.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Debug --build=missing --no-remote

# ----------------------------------------------------------------------
# Step 2 — protobuf 4.25.2 (Release + Debug)
# ----------------------------------------------------------------------
echo ""
echo "=================================================="
echo "[STEP 2] conan create protobuf/4.25.2  (Release)"
echo "=================================================="
conan create protobuf/ --version=4.25.2 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Release --build=missing --no-remote

echo ""
echo "=================================================="
echo "[STEP 2] conan create protobuf/4.25.2  (Debug)"
echo "=================================================="
conan create protobuf/ --version=4.25.2 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Debug --build=missing --no-remote

# ----------------------------------------------------------------------
# Step 3 — deploy .nupkg via legacy_nupkg.py
# ----------------------------------------------------------------------
echo ""
echo "=================================================="
echo "[STEP 3] deploy legacy .nupkg into $OUTPUT_DIR/"
echo "=================================================="
conan install --requires=protobuf/4.25.2 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder="$OUTPUT_DIR/"

echo ""
echo "[INFO] output listing:"
ls -la "$OUTPUT_DIR/" || true
echo ""
echo "[DONE] canonical protobuf 4.25.2 + abseil 20230802.1 built via Docker mirror."
