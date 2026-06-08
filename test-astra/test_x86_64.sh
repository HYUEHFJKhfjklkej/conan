#!/bin/bash
# Tests the native Linux x86_64 build path of grpc-tc-mirror.
#
# Native sibling of test_arm_cross.sh: same Dockerfile.grpc-tc-mirror,
# but host == build (gcc 8.4, no linaro cross-toolchain). This is the
# driver the TeamCity "Build Conan x86_64" stage runs, mirroring the
# existing "Build Conan ARM / ARM64" stages.
#
# Usage:
#   ./test_x86_64.sh smoke    # ~1-2 min: pre-flight + image build, no Conan run
#   ./test_x86_64.sh build    # ~15-25 min: full Conan tree + verify 7 .nupkg
#
# Required env:
#   REGISTRY        ProGet hostname + main feed (e.g. proget.inc.elara.local/main).
#                   Only used to derive BASE_IMAGE; set BASE_IMAGE directly to skip.
#
# Optional env:
#   BASE_IMAGE      Override the gcc 8.4 x86_64 base image outright.
#                   Default: $REGISTRY/library/gcc84-build-x86_64:${BASE_IMAGE_TAG:-0.1.0}
#   BASE_IMAGE_TAG  Tag for the default base image. Default: 0.1.0
#   FRESH_CACHE     If "1", `docker volume rm conan-cache-x86_64` before the run.
#                   Use this on the Conan 2.27.1 -> 2.29.0 migration so the
#                   build does NOT reuse packages compiled by the old Conan.
#   EXPECT_CONAN    Conan version the image must report (migration guard).
#                   Default: 2.29.0 . Set empty to disable the check.
#
# Output:
#   Seven .nupkg in output-x86_64/ : <pkg>.lin.gcc84.shared.x86_64.<ver>.nupkg

set -uo pipefail

MODE="${1:-}"

if [[ -z "$MODE" ]]; then
    sed -n '2,30p' "$0"
    exit 2
fi
if [[ "$MODE" != "smoke" && "$MODE" != "build" ]]; then
    echo "[FAIL] mode must be 'smoke' or 'build', got '$MODE'" >&2
    exit 2
fi

BASE_IMAGE_TAG="${BASE_IMAGE_TAG:-0.1.0}"
# Resolve BASE_IMAGE from REGISTRY only if not given explicitly. Guard here
# (before the pass/fail helpers exist) so an unset REGISTRY fails loudly
# instead of building a malformed "/library/..." reference.
if [[ -z "${BASE_IMAGE:-}" ]]; then
    if [[ -z "${REGISTRY:-}" ]]; then
        echo "[FAIL] set REGISTRY=... (or BASE_IMAGE=...) so the gcc84 base image resolves" >&2
        exit 2
    fi
    BASE_IMAGE="$REGISTRY/library/gcc84-build-x86_64:$BASE_IMAGE_TAG"
fi
EXPECT_CONAN="${EXPECT_CONAN-2.29.0}"

PROFILE="/work/conan-recipes/profiles/lin-gcc84-x86_64"
PROFILE_BUILD="/work/conan-recipes/profiles/lin-gcc84-x86_64"   # host == build
ARCH_SHORT="x86_64"
IMAGE_TAG="grpc-tc-mirror-x86_64"
OUTPUT_DIR="output-x86_64"
CACHE_VOL="conan-cache-x86_64"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ----- helpers -----------------------------------------------------------
PASS=0
FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
hdr()  { echo ""; echo "== $* =="; }

# ----- pre-flight --------------------------------------------------------
hdr "Pre-flight"
pass "BASE_IMAGE=$BASE_IMAGE"

if ! command -v docker >/dev/null; then
    fail "docker not on PATH"
    exit 2
fi
pass "docker on PATH"

if ! sudo docker info >/dev/null 2>&1; then
    fail "sudo docker info failed; daemon down or no permission"
    exit 2
fi
pass "docker daemon reachable"

# ----- 1. base image is pullable ----------------------------------------
hdr "1. Base image $BASE_IMAGE"
if sudo docker pull "$BASE_IMAGE" >/tmp/pull_x64.log 2>&1; then
    pass "pulled"
else
    fail "pull failed; see /tmp/pull_x64.log"
    tail -20 /tmp/pull_x64.log
    exit 1
fi

# ----- 2. base image diagnostics (native, not cross) --------------------
hdr "2. Base image probe"
sudo docker run --rm "$BASE_IMAGE" bash -c '
    echo "--- uname"; uname -m
    echo "--- os-release"; grep -E "^(PRETTY_NAME|VERSION_ID)=" /etc/os-release | head -2
    echo "--- native gcc 8.4"
    for g in /usr/local/gcc-8.4/bin/gcc /opt/x64-native-gcc/bin/gcc gcc; do
        command -v "$g" >/dev/null 2>&1 && { echo "GCC:$g: $($g --version | head -1)"; break; }
    done
    echo "--- cmake"; command -v cmake && cmake --version | head -1
' | tee /tmp/probe_x64.log

if grep -q "x86_64" /tmp/probe_x64.log; then
    pass "image runs as x86_64"
else
    fail "image is NOT x86_64"
fi
if grep -qE "^GCC:.*8\.4" /tmp/probe_x64.log; then
    pass "native gcc 8.4 present"
else
    fail "gcc 8.4 not found in base image"
fi

# ----- 3. mirror docker build -------------------------------------------
hdr "3. docker build $IMAGE_TAG (native x86_64)"
cd "$ROOT_DIR"
# Native build: both Dockerfile stages resolve to the same gcc84 image
# (X64_BASE_IMAGE is the build-context native toolchain; for x86_64 it
# equals BASE_IMAGE). Conan is installed from packages-linux/ by glob,
# so the image picks up whatever tarball is there (now conan-2.29.0).
if sudo docker build \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg X64_BASE_IMAGE="$BASE_IMAGE" \
        -f Dockerfile.grpc-tc-mirror \
        -t "$IMAGE_TAG" \
        . 2>&1 | tee /tmp/build_x64.log | tail -20
then
    if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        fail "docker build failed; full log /tmp/build_x64.log"
        exit 1
    fi
fi
if sudo docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    pass "image $IMAGE_TAG built"
else
    fail "image not present after build"
    exit 1
fi

# ----- 3b. Conan version guard (the "moved to new Conan" check) ----------
if [[ -n "$EXPECT_CONAN" ]]; then
    hdr "3b. Conan version in image (expect $EXPECT_CONAN)"
    cver=$(sudo docker run --rm "$IMAGE_TAG" conan --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ "$cver" == "$EXPECT_CONAN" ]]; then
        pass "Conan $cver"
    else
        fail "image reports Conan '$cver', expected '$EXPECT_CONAN' (stale packages-linux/ tarball?)"
    fi
fi

# ----- smoke ends here ---------------------------------------------------
if [[ "$MODE" == "smoke" ]]; then
    echo ""
    echo "================ SMOKE SUMMARY ================"
    echo " arch=x86_64  pass=$PASS  fail=$FAIL"
    echo "==============================================="
    [[ "$FAIL" -eq 0 ]] || exit 1
    echo "Smoke OK. To run the full build:  $0 build"
    exit 0
fi

# ----- 4. full build (long) ---------------------------------------------
hdr "4. Full Conan build (15-25 min)"
if [[ "${FRESH_CACHE:-}" == "1" ]]; then
    echo "[INFO] FRESH_CACHE=1 -> wiping $CACHE_VOL (Conan migration: no 2.27.1 reuse)"
    sudo docker volume rm "$CACHE_VOL" >/dev/null 2>&1 || true
fi
mkdir -p "$ROOT_DIR/$OUTPUT_DIR"
rm -f "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg

if sudo docker run --rm \
        -e PROFILE="$PROFILE" \
        -e PROFILE_BUILD="$PROFILE_BUILD" \
        -v "$ROOT_DIR/$OUTPUT_DIR:/work/conan-recipes/output" \
        -v "$CACHE_VOL:/root/.conan2" \
        "$IMAGE_TAG" 2>&1 | tee /tmp/run_x64.log | tail -30
then
    if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        fail "container exited non-zero; full log /tmp/run_x64.log"
        exit 1
    fi
fi

# ----- 5. verify .nupkg artefacts ---------------------------------------
hdr "5. Verify $OUTPUT_DIR/*.nupkg"
expected_count=7
actual_count=$(ls -1 "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | wc -l)
if [[ "$actual_count" -eq "$expected_count" ]]; then
    pass "$actual_count .nupkg files"
else
    fail "expected $expected_count files, got $actual_count"
fi

# Native names: '<pkg>.lin.gcc84.<linkage>.x86_64.<ver>.nupkg' — must NOT
# carry the '-linaro' cross suffix (that would mean a cross profile leaked).
for pkg in grpc protobuf abseil openssl re2 c-ares zlib; do
    f=$(ls -1 "$ROOT_DIR/$OUTPUT_DIR/$pkg".lin.gcc*.{static,shared}."$ARCH_SHORT".*.nupkg 2>/dev/null | grep -v -- '-linaro' | head -1)
    if [[ -n "$f" ]]; then
        size=$(du -h "$f" | cut -f1)
        pass "$(basename "$f") ($size)"
    else
        fail "$pkg.lin.gcc*.{static,shared}.$ARCH_SHORT.*.nupkg missing (in $OUTPUT_DIR/)"
    fi
done
if ls -1 "$ROOT_DIR/$OUTPUT_DIR"/*-linaro*.nupkg >/dev/null 2>&1; then
    fail "found -linaro artefact in a native x86_64 build (cross profile leaked)"
fi

# ----- summary -----------------------------------------------------------
echo ""
echo "================ BUILD SUMMARY ================"
echo " arch=x86_64  pass=$PASS  fail=$FAIL"
echo " output: $ROOT_DIR/$OUTPUT_DIR/"
ls -la "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | awk '{print "   " $9 " (" $5 " bytes)"}'
echo "==============================================="

[[ "$FAIL" -eq 0 ]] || exit 1
