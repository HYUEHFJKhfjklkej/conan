#!/bin/bash
# Manual minimal-build diagnostic for armv7hf cross when test_arm_cross.sh
# build keeps hitting policy_checks.h "GCC 7 or higher".
#
# Bypasses test_arm_cross.sh entirely — runs a single docker container,
# explicit -e CONAN_USER_TOOLCHAIN, builds top-level abseil only.
# 5-7 minutes on a native ARM CI runner.
#
# Usage:  ./test-astra/diag_arm.sh
# Reads:  IMAGE_TAG   (default grpc-tc-mirror-arm)
#         VOL_NAME    (default conan-cache-arm-diag — kept SEPARATE from
#                      the conan-cache-arm volume that test_arm_cross.sh
#                      writes to, so this run does not interfere)

set -uo pipefail

IMAGE_TAG="${IMAGE_TAG:-grpc-tc-mirror-arm}"
VOL_NAME="${VOL_NAME:-conan-cache-arm-diag}"
USER_TC="/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"
PROFILE="profiles/lin-gcc75-arm-linaro"
PROFILE_BUILD="profiles/lin-gcc84-x86_64"

echo "== preflight =="
sudo docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 \
    && echo "[ok] image $IMAGE_TAG present" \
    || { echo "[fail] image $IMAGE_TAG missing — run smoke first"; exit 1; }

echo ""
echo "== run abseil install in fresh volume =="
sudo docker run --rm \
    -v "${VOL_NAME}:/root/.conan2" \
    -e CONAN_USER_TOOLCHAIN="$USER_TC" \
    "$IMAGE_TAG" bash -c '
        set -e
        echo "------ env-check inside container ------"
        echo "CONAN_USER_TOOLCHAIN=[$CONAN_USER_TOOLCHAIN]"
        if [ -z "$CONAN_USER_TOOLCHAIN" ]; then
            echo "[fail] env-var did NOT propagate; docker -e is broken"
            exit 1
        fi
        echo ""
        echo "------ verify patch is in image ------"
        grep -n CONAN_USER_TOOLCHAIN /work/conan-recipes/abseil/conanfile.py \
            && echo "[ok] env-fallback patch is present" \
            || { echo "[fail] patch missing in abseil/conanfile.py"; exit 1; }
        echo ""
        echo "------ conan export ------"
        cd /work/conan-recipes
        conan export abseil/ --version=20250127.0 2>&1 | tail -3
        echo ""
        echo "------ conan install (full output) ------"
        conan install --requires=abseil/20250127.0 \
            -pr:h='"$PROFILE"' -pr:b='"$PROFILE_BUILD"' \
            --build=missing --no-remote \
            -o "*/*:shared=True" 2>&1
    ' 2>&1 | tee /tmp/diag_arm.log

RC=${PIPESTATUS[0]}
echo ""
echo "== verdict =="
if [ "$RC" -eq 0 ]; then
    echo "[OK] minimal abseil build succeeded under armv7hf cross."
    echo "     This means the image and recipe are correct."
    echo "     If test_arm_cross.sh build arm still fails — it is the"
    echo "     test_arm_cross.sh harness, not the build."
else
    echo "[FAIL] minimal abseil build failed (exit $RC)."
    echo "     Inspect /tmp/diag_arm.log; the first compiler error is"
    echo "     usually within 200 lines after 'Building from source'."
    echo "     grep -m 3 -B 1 -A 4 'error:' /tmp/diag_arm.log | head -40"
fi
echo ""
echo "Cleanup the diagnostic volume when done:"
echo "  sudo docker volume rm $VOL_NAME"
