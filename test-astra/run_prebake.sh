#!/bin/bash
# Verifies that the published grpc-tc-mirror image in ProGet can produce
# the seven .nupkg artefacts end-to-end (no test_arm_cross.sh scaffolding,
# just `docker run` against the pinned tag). This is the gold-standard
# acceptance test before handing the image off to TeamCity.
#
# Usage:
#   ./run_prebake.sh arm
#   ./run_prebake.sh arm64
#   ./run_prebake.sh x86_64
#
# Required env:
#   REGISTRY     ProGet hostname + main feed (e.g. proget.example/main).
#                Default: proget.inc.elara.local/main
#
# Optional env:
#   MIRROR_VER   Tag of grpc-tc-mirror-{arm,arm64,x86_64} to verify.
#                Default: 0.1.0
#   MIN_FREE_GB  Required free space in /var/lib/docker before launch.
#                Default: 30
#
# Output:
#   Seven .nupkg files in output-${ARCH}-prebake/ on success.
#
# Why this exists (and why not just `test_arm_cross.sh build`):
#   test_arm_cross.sh rebuilds the mirror image at-call-time from
#   Dockerfile.grpc-tc-mirror, so it always tests "image as it would
#   build *now*". For the TC handoff we instead want to verify "image
#   exactly as ProGet stores it" — that is, the published 0.1.0 tag,
#   pulled fresh, no local layer cache assumed.

set -uo pipefail

ARCH="${1:-}"

if [[ -z "$ARCH" ]]; then
    sed -n '2,30p' "$0"
    exit 2
fi

case "$ARCH" in
    arm)
        PROFILE="/work/conan-recipes/profiles/lin-gcc75-arm-linaro"
        USER_TC="/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"
        ;;
    arm64)
        PROFILE="/work/conan-recipes/profiles/lin-gcc-aarch64-linaro"
        USER_TC="/work/conan-recipes/profiles/toolchains/linaro-aarch64.cmake"
        ;;
    x86_64)
        # Native build — host profile = build profile, no cross toolchain.
        PROFILE="/work/conan-recipes/profiles/lin-gcc84-x86_64"
        USER_TC=""
        ;;
    *)
        echo "[FAIL] arch must be 'arm', 'arm64' or 'x86_64', got '$ARCH'" >&2
        exit 2
        ;;
esac

REGISTRY="${REGISTRY:-proget.inc.elara.local/main}"
MIRROR_VER="${MIRROR_VER:-0.1.0}"
MIN_FREE_GB="${MIN_FREE_GB:-30}"
PROFILE_BUILD="/work/conan-recipes/profiles/lin-gcc84-x86_64"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT_DIR/output-${ARCH}-prebake"
IMAGE="$REGISTRY/library/grpc-tc-mirror-${ARCH}:$MIRROR_VER"
CACHE_VOLUME="conan-cache-${ARCH}-prebake"

hdr() { printf "\n=== %s ===\n" "$1"; }
pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1" >&2; exit 1; }

# Decide how to invoke docker. dev-astra has passwordless sudo; CI build
# agents usually don't, but the build user is often in the `docker` group
# (or runs as root). Try direct, then sudo -n; fail loudly if neither works.
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
else
    cat >&2 <<EOF
[FAIL] cannot reach the Docker daemon. Options to fix on this host:
   1) Add the build user to the docker group (recommended for CI agents):
          sudo usermod -aG docker \$USER
          # log out + back in, or: newgrp docker
   2) Or grant passwordless sudo for docker:
          echo "\$USER ALL=(root) NOPASSWD: /usr/bin/docker" \\
              | sudo tee /etc/sudoers.d/\$USER-docker
   3) Or run this script as root (not advised).
EOF
    exit 1
fi
echo "docker invocation: ${DOCKER[*]}"

hdr "config"
echo "ARCH          = $ARCH"
echo "REGISTRY      = $REGISTRY"
echo "MIRROR_VER    = $MIRROR_VER"
echo "IMAGE         = $IMAGE"
echo "PROFILE       = $PROFILE"
echo "PROFILE_BUILD = $PROFILE_BUILD"
echo "USER_TC       = $USER_TC"
echo "OUTPUT_DIR    = $OUTPUT_DIR"
echo "CACHE_VOLUME  = $CACHE_VOLUME"
echo "MIN_FREE_GB   = $MIN_FREE_GB"

hdr "1. disk-space pre-flight"
# The mirror writes ~5 GB of conan-cache + ~2 GB of compiler temporaries
# into the docker storage partition. Bail out early if there isn't room.
DOCKER_DIR="$("${DOCKER[@]}" info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
FREE_KB=$(df --output=avail -k "$DOCKER_DIR" 2>/dev/null | tail -1 | tr -d ' ')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
echo "free on $DOCKER_DIR: ${FREE_GB} GB"
if (( FREE_GB < MIN_FREE_GB )); then
    cat <<EOF >&2
[FAIL] less than ${MIN_FREE_GB} GB free in $DOCKER_DIR.
       Free up space before re-running:
           sudo docker image prune -f
           sudo docker builder prune -f
       And, if still tight, drop stale :latest mirror tags from
       earlier test_arm_cross.sh runs (no longer needed once
       ${MIRROR_VER} is pinned in ProGet):
           sudo docker image rm \\
               grpc-tc-mirror grpc-tc-mirror-arm \\
               grpc-tc-mirror-arm64 grpc-tc-mirror-armv7hf 2>/dev/null
       Override the threshold with MIN_FREE_GB=<n> $0 $ARCH.
EOF
    exit 1
fi
pass "${FREE_GB} GB free (>= ${MIN_FREE_GB} GB)"

hdr "2. fresh pull from ProGet"
# Drop any local copy first — we want to exercise the actual ProGet
# round-trip, not a stale layer cache.
"${DOCKER[@]}" image rm "$IMAGE" >/dev/null 2>&1 || true
if ! "${DOCKER[@]}" pull "$IMAGE"; then
    fail "docker pull $IMAGE — did the push complete, and is this host logged in to ProGet? Try: ${DOCKER[*]} login ${REGISTRY%%/*}"
fi
pass "pulled $IMAGE"

hdr "3. end-to-end build"
mkdir -p "$OUTPUT_DIR"
echo "log → $OUTPUT_DIR/build.log"
echo "starting at $(date +%H:%M:%S), expect 15-25 min"

if "${DOCKER[@]}" run --rm \
        -v "$ROOT_DIR":/work/conan-recipes \
        -v "$OUTPUT_DIR":/work/conan-recipes/output \
        -v "$CACHE_VOLUME":/root/.conan2 \
        -e PROFILE="$PROFILE" \
        -e PROFILE_BUILD="$PROFILE_BUILD" \
        -e CONAN_USER_TOOLCHAIN="$USER_TC" \
        "$IMAGE" \
        bash /work/conan-recipes/test-astra/run_test_grpc.sh \
        2>&1 | tee "$OUTPUT_DIR/build.log"; then
    pass "docker run completed"
else
    fail "docker run failed — tail $OUTPUT_DIR/build.log and check HELP [10]"
fi

hdr "4. verify .nupkg artefacts"
COUNT=$(ls -1 "$OUTPUT_DIR"/*.nupkg 2>/dev/null | wc -l)
if (( COUNT != 7 )); then
    ls -lh "$OUTPUT_DIR"/*.nupkg 2>/dev/null || true
    fail "expected 7 .nupkg in $OUTPUT_DIR, got $COUNT"
fi
ls -lh "$OUTPUT_DIR"/*.nupkg
pass "7 .nupkg in $OUTPUT_DIR"

hdr "done — image $IMAGE is production-ready for TC handoff"
