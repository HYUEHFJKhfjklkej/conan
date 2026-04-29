#!/bin/bash
# ============================================
#  Build gtest (canonical conan-center recipe) in 4 variants:
#    static/Release, static/Debug, shared/Release, shared/Debug
#  Each build runs test_package (consumer smoke test) automatically.
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
    source "$ROOT_DIR/venv/bin/activate"
fi

PROFILE="$ROOT_DIR/profiles/astra-gcc"
[ -f "$PROFILE" ] || PROFILE="$ROOT_DIR/profiles/linux-gcc"

echo "[INFO] Profile: $PROFILE"
echo "[INFO] Conan: $(conan --version)"
echo "[INFO] Recipe: canonical from conan-center-index"
echo ""

build_one() {
    local linkage=$1 build_type=$2
    local shared=False
    [ "$linkage" = "shared" ] && shared=True

    echo "============================================"
    echo " gtest 1.16.0  linkage=$linkage  build_type=$build_type"
    echo "============================================"

    conan create "$ROOT_DIR/gtest/" \
        --version=1.16.0 \
        --profile="$PROFILE" \
        --build=missing \
        --no-remote \
        -s build_type="$build_type" \
        -o "gtest/*:shared=$shared"
}

build_one static  Release
build_one static  Debug
build_one shared  Release
build_one shared  Debug

echo ""
echo "[INFO] Conan cache after builds:"
conan list "gtest/1.16.0:*" 2>/dev/null || true

echo ""
echo "[INFO] Confirming upstream sources untouched:"
SRC_TARBALL="$ROOT_DIR/gtest/src/v1.16.0.tar.gz"
if [ -f "$SRC_TARBALL" ]; then
    SHA=$(sha256sum "$SRC_TARBALL" | awk '{print $1}')
    echo "  upstream:  $SHA"
    echo "  expected:  78c676fc63881529bf97bf9d45948d905a66833fbfa5318ea2cd7478cb98f399"
    if [ "$SHA" = "78c676fc63881529bf97bf9d45948d905a66833fbfa5318ea2cd7478cb98f399" ]; then
        echo "  [OK] upstream sha256 matches conan-center conandata.yml"
    fi
fi

echo ""
echo "============================================"
echo " ALL 4 gtest VARIANTS BUILT (canonical recipe)"
echo " test_package (consumer smoke test) ran for each variant."
echo "============================================"
