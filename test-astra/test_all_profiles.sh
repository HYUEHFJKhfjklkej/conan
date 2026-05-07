#!/bin/bash
# ============================================================================
# Master test orchestrator for all conan-recipes target profiles (IN-658 / IN-353).
#
# Builds the Dockerfile.grpc-tc-mirror image for a given target architecture
# and runs the full grpc + 6 deps tree, producing 7 .nupkg in TC-compatible
# format. Supersedes the older arm-only test_arm_cross.sh — handles all
# architectures we ship CI builds for: x86_64, i686, armv7hf (arm), arm64.
#
# Usage:
#   ./test_all_profiles.sh <mode> <arch>
#       mode: smoke   — pre-flight + image diagnostics only (~2 min)
#             build   — full Conan tree + .nupkg verification (~15-90 min)
#             all     — `build` for x86_64, armv7hf, arm64 sequentially
#       arch: x86_64 | i686 | armv7hf | arm | arm64
#                 (arm = armv7hf alias, both work)
#
# Required env:
#   REGISTRY        — internal registry, e.g. proget.example/main
#                     Skipped when LOCAL_BASE is set (mac/dev mode).
#
# Optional env:
#   LOCAL_BASE             — overrides BASE_IMAGE entirely. Use for local
#                            Mac testing without internal registry. Example:
#                              LOCAL_BASE=elara-public-base:latest \
#                                ./test_all_profiles.sh build armv7hf
#   BASE_IMAGE_TAG         — default: 0.1.0 for arm/arm64, latest for x86.
#   CMAKE_BUILD_PARALLEL_LEVEL — default 4 (safe under 8GB Docker memory).
#   SHARED                 — True/False, default True (matches CI shared libs).
#   FORCE_REBUILD          — non-empty → drop output dir + conan-cache before run.
#
# Outputs:
#   ./output-<arch>/conan-cache/   — bind-mounted Conan cache (survives runs)
#   ./output-<arch>/*.nupkg        — 7 nuget packages
#   ./output-<arch>/run.log        — full conan output
#
# Why this script exists:
#   - test_arm_cross.sh did NOT propagate -e CONAN_USER_TOOLCHAIN, so the
#     env-fallback workaround for Conan 2.27.1's transitive user_toolchain
#     bug (see commits de4802b, 8278d55, NEXT_STEPS.md 4b) silently no-op'd.
#   - test_arm_cross.sh did NOT bind-mount /root/.conan2 to host, so
#     conan-cache died with each --rm container — every iteration was a
#     full rebuild.
#   This script fixes both, and adds x86_64 / i686 / arm64 cases.
# ============================================================================

set -uo pipefail

MODE="${1:-}"
ARCH="${2:-}"

usage() {
    sed -n '2,40p' "$0"
    exit 2
}

[[ -z "$MODE" || -z "$ARCH" ]] && usage
[[ "$MODE" =~ ^(smoke|build|all)$ ]] || { echo "[FAIL] mode must be smoke|build|all, got '$MODE'" >&2; exit 2; }

# 'all' mode — recurse for the three production targets.
if [[ "$MODE" == "all" ]]; then
    [[ "$ARCH" != "_" && "$ARCH" != "all" ]] && { echo "[FAIL] for mode=all, arch must be 'all' or '_'" >&2; exit 2; }
    rc=0
    for a in x86_64 armv7hf arm64; do
        echo ""
        echo "########################################"
        echo "# all → $a"
        echo "########################################"
        "$0" build "$a" || rc=1
    done
    exit $rc
fi

# Normalize arch.
case "$ARCH" in
    arm) ARCH=armv7hf ;;
esac

# ARCH_SHORT below matches CI artifact naming (see ARCHITECTURE.md §3.4):
# Linux uses full arch names (x86_64, i686, arm, arm64); Linaro cross gets
# '-linaro' suffix. The deployer derives this from CONAN_USER_TOOLCHAIN env.
case "$ARCH" in
    x86_64)
        DEFAULT_BASE_TAG="latest"
        BASE_IMAGE_NAME="gcc84-build-x86_64"
        PROFILE_REL="profiles/lin-gcc84-x86_64"
        TC_PATH=""                  # native — no user_toolchain
        ARCH_SHORT="x86_64"         # CI: googletest.lin.gcc84.shared.x86_64.<ver>.nupkg
        IMAGE_TAG="grpc-tc-mirror-x86_64"
        ;;
    i686)
        DEFAULT_BASE_TAG="latest"
        BASE_IMAGE_NAME="gcc84-build-x86_64"   # multilib — i686 lives in the x86_64 image
        PROFILE_REL="profiles/lin-gcc84-i686"
        TC_PATH=""
        ARCH_SHORT="i686"           # CI: googletest.lin.gcc84.shared.i686.<ver>.nupkg
        IMAGE_TAG="grpc-tc-mirror-i686"
        ;;
    armv7hf)
        DEFAULT_BASE_TAG="0.1.0"
        BASE_IMAGE_NAME="gcc75-build-arm"
        PROFILE_REL="profiles/lin-gcc75-arm-linaro"
        TC_PATH="/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"
        ARCH_SHORT="arm-linaro"     # CI: googletest.lin.gcc75.shared.arm-linaro.<ver>.nupkg
        IMAGE_TAG="grpc-tc-mirror-armv7hf"
        ;;
    arm64)
        DEFAULT_BASE_TAG="0.1.0"
        BASE_IMAGE_NAME="gcc75-build-arm64"
        PROFILE_REL="profiles/lin-gcc-aarch64-linaro"
        TC_PATH="/work/conan-recipes/profiles/toolchains/linaro-aarch64.cmake"
        ARCH_SHORT="arm64-linaro"   # CI: googletest.lin.gcc75.shared.arm64-linaro.<ver>.nupkg
        IMAGE_TAG="grpc-tc-mirror-arm64"
        ;;
    *)
        echo "[FAIL] arch must be x86_64|i686|armv7hf|arm|arm64, got '$ARCH'" >&2
        exit 2
        ;;
esac

BASE_IMAGE_TAG="${BASE_IMAGE_TAG:-$DEFAULT_BASE_TAG}"

# Resolve BASE_IMAGE — LOCAL_BASE overrides the registry path.
if [[ -n "${LOCAL_BASE:-}" ]]; then
    BASE_IMAGE="$LOCAL_BASE"
    IMAGE_TAG="${IMAGE_TAG}-local"
else
    : "${REGISTRY:?env REGISTRY must be set (or use LOCAL_BASE for mac/dev mode)}"
    BASE_IMAGE="$REGISTRY/library/${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}"
fi

PROFILE_HOST="/work/conan-recipes/${PROFILE_REL}"
PROFILE_BUILD="/work/conan-recipes/profiles/lin-gcc84-x86_64"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT_DIR/output-${ARCH}"
CACHE_DIR="$OUTPUT_DIR/conan-cache"

# QEMU platform flag — only when host arch differs from target build platform.
# Mac M-series + LOCAL_BASE means user wants the linux/amd64 image emulated.
PLATFORM_FLAG=""
if [[ -n "${LOCAL_BASE:-}" ]] && [[ "$(uname -m)" == "arm64" ]]; then
    PLATFORM_FLAG="--platform linux/amd64"
fi

PASS=0; FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
hdr()  { echo ""; echo "== $* =="; }

hdr "Pre-flight"
echo "[INFO] arch:       $ARCH (short=$ARCH_SHORT)"
echo "[INFO] base image: $BASE_IMAGE"
echo "[INFO] profile h:  $PROFILE_REL"
echo "[INFO] profile b:  profiles/lin-gcc84-x86_64"
echo "[INFO] toolchain:  ${TC_PATH:-<none — native>}"
echo "[INFO] image tag:  $IMAGE_TAG"
echo "[INFO] output:     $OUTPUT_DIR"
echo "[INFO] platform:   ${PLATFORM_FLAG:-<host native>}"

if ! command -v docker >/dev/null; then
    fail "docker not on PATH"; exit 2
fi
# Auto-detect whether docker needs sudo (Astra: yes, Mac: usually no).
if docker info >/dev/null 2>&1; then
    DOCKER="docker"
elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
else
    fail "docker daemon not reachable as user nor via passwordless sudo"
    fail "  → on Astra: run with sudo, or configure passwordless sudo for docker"
    fail "  → on Mac: ensure Docker Desktop is running and user can call docker"
    exit 2
fi
pass "docker daemon reachable (via: $DOCKER)"

# Pull base image (skip silently when LOCAL_BASE is a local image).
hdr "1. Base image $BASE_IMAGE"
if [[ -n "${LOCAL_BASE:-}" ]]; then
    if $DOCKER image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        pass "local base image present"
    else
        fail "LOCAL_BASE='$LOCAL_BASE' not found locally"; exit 1
    fi
else
    if $DOCKER pull $PLATFORM_FLAG "$BASE_IMAGE" >/tmp/pull-$ARCH.log 2>&1; then
        pass "pulled"
    else
        fail "pull failed; see /tmp/pull-$ARCH.log"
        tail -10 /tmp/pull-$ARCH.log
        exit 1
    fi
fi

# Build the grpc-tc-mirror image on top of the base.
hdr "2. docker build $IMAGE_TAG"
cd "$ROOT_DIR"
if $DOCKER build $PLATFORM_FLAG \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        -f Dockerfile.grpc-tc-mirror \
        -t "$IMAGE_TAG" \
        . >/tmp/build-$ARCH.log 2>&1; then
    pass "built $IMAGE_TAG"
else
    fail "build failed; tail of /tmp/build-$ARCH.log:"
    tail -20 /tmp/build-$ARCH.log
    exit 1
fi

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

# Full build.
hdr "3. Full Conan build (15-90 min depending on arch + emulation)"
mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"

if [[ -n "${FORCE_REBUILD:-}" ]]; then
    echo "[INFO] FORCE_REBUILD set — wiping cache + nupkg"
    sudo rm -rf "$CACHE_DIR"/* "$OUTPUT_DIR"/*.nupkg 2>/dev/null
    mkdir -p "$CACHE_DIR"
fi

DOCKER_ARGS=(
    --rm $PLATFORM_FLAG
    --memory=6g --memory-swap=10g
    -v "$CACHE_DIR:/root/.conan2"
    -v "$OUTPUT_DIR:/work/conan-recipes/output"
    -v "$OUTPUT_DIR:/host"
    -e PROFILE="$PROFILE_HOST"
    -e PROFILE_BUILD="$PROFILE_BUILD"
    -e SHARED="${SHARED:-True}"
    -e CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
)

# Pass CONAN_USER_TOOLCHAIN only for cross-compiled archs. Empty for native
# x86_64/i686 — env-fallback in recipes is gated on arch (commit 8278d55),
# so passing it for native would be a no-op anyway, but be explicit.
if [[ -n "$TC_PATH" ]]; then
    DOCKER_ARGS+=(-e "CONAN_USER_TOOLCHAIN=$TC_PATH")
fi

if $DOCKER run "${DOCKER_ARGS[@]}" "$IMAGE_TAG" bash -c '
        ./test-astra/run_test_grpc.sh 2>&1 | tee /host/run.log
        rc=$?
        echo ""
        echo "=== EXIT $rc ==="
        echo "=== LINARO-ARM-TC count ==="
        grep -c "==LINARO-ARM-TC==" /host/run.log
        echo "=== LINARO-ARM64-TC count ==="
        grep -c "==LINARO-ARM64-TC==" /host/run.log
        exit $rc
    '; then
    pass "container exited 0"
else
    fail "container exited non-zero"
    echo "[INFO] tail of run.log:"
    tail -30 "$OUTPUT_DIR/run.log"
fi

# Verify .nupkg artefacts.
hdr "4. Verify $OUTPUT_DIR/*.nupkg"
expected_count=7
actual_count=$(ls -1 "$OUTPUT_DIR"/*.nupkg 2>/dev/null | wc -l)
if [[ "$actual_count" -eq "$expected_count" ]]; then
    pass "$actual_count .nupkg files"
else
    fail "expected $expected_count files, got $actual_count"
fi

# Each name must contain '.lin.gcc.shared.<ARCH_SHORT>.'
for pkg in grpc protobuf abseil openssl re2 c-ares zlib; do
    f=$(ls -1 "$OUTPUT_DIR/$pkg".lin.gcc.shared."$ARCH_SHORT".*.nupkg 2>/dev/null | head -1)
    if [[ -n "$f" ]]; then
        size=$(du -h "$f" | cut -f1)
        pass "$(basename "$f") ($size)"
    else
        fail "$pkg.lin.gcc.shared.$ARCH_SHORT.*.nupkg missing"
    fi
done

echo ""
echo "================ BUILD SUMMARY ================"
echo " arch=$ARCH  pass=$PASS  fail=$FAIL"
echo " output: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR"/*.nupkg 2>/dev/null | awk '{print "   " $NF " (" $5 " bytes)"}'
echo "==============================================="

[[ "$FAIL" -eq 0 ]]
