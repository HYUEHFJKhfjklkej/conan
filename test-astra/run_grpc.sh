#!/bin/bash
# ============================================
#  Build grpc 1.78.1 (canonical + offline) with full dep tree:
#    abseil, c-ares, openssl, protobuf, re2, zlib (transitively).
#  Heavy: each variant triggers ~6 package builds.
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

# Step 1: export every recipe so Conan can find them in --no-remote mode
echo "============================================"
echo " Step 1: Export all recipes to local cache"
echo "============================================"
for pkg in zlib abseil c-ares re2 protobuf openssl grpc; do
    case "$pkg" in
        zlib)     ver=1.3.1 ;;
        abseil)   ver=20250127.0 ;;
        c-ares)   ver=1.34.6 ;;
        re2)      ver=20251105 ;;
        protobuf) ver=5.29.6 ;;
        openssl)  ver=3.4.5 ;;
        grpc)     ver=1.78.1 ;;
    esac
    echo "[INFO] conan export $pkg ($ver)"
    conan export "$ROOT_DIR/$pkg/" --version="$ver"
done
echo ""

build_one() {
    local linkage=$1 build_type=$2
    local shared=False
    [ "$linkage" = "shared" ] && shared=True

    echo "============================================"
    echo " grpc 1.78.1  linkage=$linkage  build_type=$build_type"
    echo "============================================"

    conan install --requires=grpc/1.78.1 \
        -pr:h="$PROFILE" \
        -pr:b="$PROFILE" \
        --build=missing \
        --no-remote \
        -s build_type="$build_type" \
        -o "*/*:shared=$shared"
}

build_one static  Release

echo ""
echo "[INFO] Conan cache after build:"
conan list "*/*:*" 2>/dev/null | head -50

echo ""
echo "============================================"
echo " grpc Release/static built (with full dep tree)"
echo "============================================"
