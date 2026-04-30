#!/bin/bash
# ============================================
#  Build zlib (canonical conan-center recipe) in 4 variants:
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
    echo " zlib 1.3.1  linkage=$linkage  build_type=$build_type"
    echo "============================================"

    conan create "$ROOT_DIR/zlib/" \
        --version=1.3.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        --build=missing \
        --no-remote \
        -s build_type="$build_type" \
        -o "zlib/*:shared=$shared"
}

build_one static  Release
build_one static  Debug
build_one shared  Release
build_one shared  Debug

echo ""
echo "[INFO] Conan cache after builds:"
conan list "zlib/1.3.1:*" 2>/dev/null || true

echo ""
echo "[INFO] Confirming upstream sources untouched:"
SRC_TARBALL="$ROOT_DIR/zlib/src/zlib-1.3.1.tar.gz"
if [ -f "$SRC_TARBALL" ]; then
    SHA=$(sha256sum "$SRC_TARBALL" | awk '{print $1}')
    echo "  upstream:  $SHA"
    echo "  expected:  9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
    if [ "$SHA" = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23" ]; then
        echo "  [OK] upstream sha256 matches conan-center conandata.yml"
    fi
fi

echo ""
echo "============================================"
echo " ALL 4 zlib VARIANTS BUILT (canonical recipe)"
echo " test_package (consumer smoke test) ran for each variant."
echo "============================================"
