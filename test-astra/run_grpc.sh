#!/bin/bash
# ============================================
#  Build grpc 1.78.1 (canonical + offline) with full dep tree:
#    abseil, c-ares, openssl, protobuf, re2, zlib (transitively).
#  4 variants: static/Release, static/Debug, shared/Release, shared/Debug.
#  Heavy: each variant triggers ~6 package builds. Expect 30–60 min total.
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
    echo " grpc 1.78.1  linkage=$linkage  build_type=$build_type"
    echo "============================================"

    conan create "$ROOT_DIR/grpc/" \
        --version=1.78.1 \
        --profile="$PROFILE" \
        --build=missing \
        --no-remote \
        -s build_type="$build_type" \
        -o "*/*:shared=$shared"
}

build_one static  Release
build_one static  Debug
build_one shared  Release
build_one shared  Debug

echo ""
echo "[INFO] Conan cache after builds (full dep tree):"
conan list "*/*:*" 2>/dev/null | head -50

echo ""
echo "============================================"
echo " ALL 4 grpc VARIANTS BUILT (canonical recipe)"
echo " Dependency tree: abseil, c-ares, openssl, protobuf, re2, zlib"
echo "============================================"
