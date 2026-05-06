#!/bin/bash
# Tests the arm / arm64 cross-build path of grpc-tc-mirror.
#
# Usage:
#   ./test_arm_cross.sh smoke arm
#   ./test_arm_cross.sh smoke arm64
#   ./test_arm_cross.sh build arm
#   ./test_arm_cross.sh build arm64
#
# `smoke` (~1-2 min) runs pre-flight + image diagnostics only.
# `build` (~15-25 min) does the full Conan tree build and verifies
# the seven .nupkg files and their TC-style names.
#
# Required env: REGISTRY (e.g. proget.example/main)

set -uo pipefail

MODE="${1:-}"
ARCH="${2:-}"

if [[ -z "$MODE" || -z "$ARCH" ]]; then
    sed -n '2,15p' "$0"
    exit 2
fi

if [[ "$MODE" != "smoke" && "$MODE" != "build" ]]; then
    echo "[FAIL] mode must be 'smoke' or 'build', got '$MODE'" >&2
    exit 2
fi

case "$ARCH" in
    arm)
        BASE_IMAGE="$REGISTRY/library/gcc75-build-arm:${BASE_IMAGE_TAG:-0.1.0}"
        PROFILE="/work/conan-recipes/profiles/lin-gcc75-arm-linaro"
        ARCH_SHORT="arm"
        IMAGE_TAG="grpc-tc-mirror-arm"
        OUTPUT_DIR="output-arm"
        ;;
    arm64)
        BASE_IMAGE="$REGISTRY/library/gcc75-build-arm64:${BASE_IMAGE_TAG:-0.1.0}"
        PROFILE="/work/conan-recipes/profiles/lin-gcc-aarch64-linaro"
        ARCH_SHORT="arm64"
        IMAGE_TAG="grpc-tc-mirror-arm64"
        OUTPUT_DIR="output-arm64"
        ;;
    *)
        echo "[FAIL] arch must be 'arm' or 'arm64', got '$ARCH'" >&2
        exit 2
        ;;
esac

PROFILE_BUILD="/work/conan-recipes/profiles/lin-gcc84-x86_64"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ----- helpers -----------------------------------------------------------
PASS=0
FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
hdr()  { echo ""; echo "== $* =="; }

require_env() {
    if [[ -z "${!1:-}" ]]; then
        fail "env $1 is not set (export $1=...)"
        exit 2
    fi
}

# ----- pre-flight --------------------------------------------------------
hdr "Pre-flight"
require_env REGISTRY
pass "REGISTRY=$REGISTRY"

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
if sudo docker pull "$BASE_IMAGE" >/tmp/pull.log 2>&1; then
    pass "pulled"
else
    fail "pull failed; see /tmp/pull.log"
    tail -20 /tmp/pull.log
    exit 1
fi

# ----- 2. base image diagnostics ----------------------------------------
hdr "2. Base image probe"
sudo docker run --rm "$BASE_IMAGE" bash -c '
    echo "--- uname"
    uname -m
    echo "--- os-release"
    grep -E "^(PRETTY_NAME|VERSION_ID)=" /etc/os-release | head -3
    echo "--- /opt"
    ls /opt 2>/dev/null
    echo "--- cross gcc"
    for g in arm-linux-gnueabihf-gcc arm-linaro-linux-gnueabihf-gcc \
             aarch64-linux-gnu-gcc aarch64-linaro-linux-gnu-gcc \
             arm-none-linux-gnueabihf-gcc; do
        if command -v $g >/dev/null; then
            echo "$g: $($g --version | head -1)"
        fi
    done
    echo "--- toolchain.cmake locations"
    find /opt -maxdepth 4 -name "*toolchain*.cmake" 2>/dev/null | head -10
    echo "--- cmake"
    command -v cmake && cmake --version | head -1
' | tee /tmp/probe.log

if grep -q "x86_64" /tmp/probe.log; then
    pass "image runs as x86_64 (cross-compiler inside)"
else
    fail "image is NOT x86_64 — bundled python tarball won't run"
fi

if grep -qE "(arm|aarch64).*-gcc" /tmp/probe.log; then
    pass "cross-gcc detected"
else
    fail "no cross-gcc found in image"
fi

if grep -qE "toolchain.cmake" /tmp/probe.log; then
    pass "toolchain.cmake present in /opt"
else
    fail "no toolchain.cmake under /opt — profile [conf] path may not exist"
fi

# ----- 3. mirror docker build --------------------------------------------
hdr "3. docker build grpc-tc-mirror for $ARCH"
cd "$ROOT_DIR"
if sudo docker build \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        -f Dockerfile.grpc-tc-mirror \
        -t "$IMAGE_TAG" \
        . 2>&1 | tee /tmp/build.log | tail -20
then
    if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        fail "docker build failed; full log /tmp/build.log"
        exit 1
    fi
fi
if sudo docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    pass "image $IMAGE_TAG built"
else
    fail "image not present after build"
    exit 1
fi

# ----- smoke ends here ---------------------------------------------------
if [[ "$MODE" == "smoke" ]]; then
    echo ""
    echo "================ SMOKE SUMMARY ================"
    echo " arch=$ARCH  pass=$PASS  fail=$FAIL"
    echo "==============================================="
    [[ "$FAIL" -eq 0 ]] || exit 1
    echo "Smoke OK. To run the full build:"
    echo "  $0 build $ARCH"
    exit 0
fi

# ----- 4. full build (long) ---------------------------------------------
hdr "4. Full Conan build (15-25 min)"
mkdir -p "$ROOT_DIR/$OUTPUT_DIR"
rm -f "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg

if sudo docker run --rm \
        -e PROFILE="$PROFILE" \
        -e PROFILE_BUILD="$PROFILE_BUILD" \
        -v "$ROOT_DIR/$OUTPUT_DIR:/work/conan-recipes/output" \
        "$IMAGE_TAG" 2>&1 | tee /tmp/run.log | tail -30
then
    if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        fail "container exited non-zero; full log /tmp/run.log"
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

# Each name must contain '.lin.gcc.shared.<ARCH_SHORT>.'
for pkg in grpc protobuf abseil openssl re2 c-ares zlib; do
    f=$(ls -1 "$ROOT_DIR/$OUTPUT_DIR/$pkg".lin.gcc.shared."$ARCH_SHORT".*.nupkg 2>/dev/null | head -1)
    if [[ -n "$f" ]]; then
        size=$(du -h "$f" | cut -f1)
        pass "$(basename "$f") ($size)"
    else
        fail "$pkg.lin.gcc.shared.$ARCH_SHORT.*.nupkg missing"
    fi
done

# ----- summary -----------------------------------------------------------
echo ""
echo "================ BUILD SUMMARY ================"
echo " arch=$ARCH  pass=$PASS  fail=$FAIL"
echo " output: $ROOT_DIR/$OUTPUT_DIR/"
ls -la "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | awk '{print "   " $9 " (" $5 " bytes)"}'
echo "==============================================="

[[ "$FAIL" -eq 0 ]] || exit 1
