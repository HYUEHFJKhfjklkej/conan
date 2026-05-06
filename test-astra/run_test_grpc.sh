#!/bin/bash
# ============================================
#  Полный тест Conan для grpc на Linux/Astra
#  1. Собирает grpc + 6 транзитивных deps Release+Debug (static)
#  2. Упаковывает все 7 пакетов в legacy .nupkg через Conan-deployer
#  Артефакты: output/{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg
#  Heavy: ~15-25 минут на 8 ядрах (×2 build_type).
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
    source "$ROOT_DIR/venv/bin/activate"
fi

PROFILE="${PROFILE:-$ROOT_DIR/profiles/astra-gcc}"
[ -f "$PROFILE" ] || PROFILE="$ROOT_DIR/profiles/linux-gcc"

echo "[INFO] Profile: $PROFILE"
echo "[INFO] Conan: $(conan --version)"
echo ""

# Step 1: export all recipes so --no-remote can find them
echo "============================================"
echo " Step 1/3: Export all recipes to local cache"
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

# Step 2: build full dep tree Release + Debug (deployer needs both in cache)
echo "============================================"
echo " Step 2/3: Build grpc tree Release + Debug"
echo "============================================"
SHARED="${SHARED:-True}"
for BT in Release Debug; do
    echo "[INFO] Building grpc/1.78.1 + 6 deps build_type=$BT shared=$SHARED"
    conan install --requires=grpc/1.78.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        --build=missing --no-remote \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED"
done
echo "[OK] grpc tree built (Release+Debug, shared=$SHARED)"
echo ""

# Step 3: deployer → 7 legacy .nupkg
echo "============================================"
echo " Step 3/3: Package full tree via deployer"
echo "============================================"
mkdir -p "$ROOT_DIR/output"
rm -f "$ROOT_DIR/output"/{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg

conan install \
    --requires=grpc/1.78.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    -o "*/*:shared=$SHARED" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/output"

echo ""
echo "[INFO] Generated .nupkg files:"
ls -1 "$ROOT_DIR/output"/*.nupkg | sed 's|^|  |'

echo ""
echo "============================================"
echo " ALL grpc TREE PACKAGES BUILT"
echo "============================================"
echo " Артефакты: output/*.nupkg (7 файлов)"
echo " Структура совпадает с TeamCity-форматом."
echo "============================================"
