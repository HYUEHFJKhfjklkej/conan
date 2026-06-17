#!/bin/bash
# ============================================
#  Полный тест Conan для grpc на Linux/Astra
#  1. Сборка grpc + 6 транзитивных deps Release+Debug (static)
#  2. Упаковка всех 7 пакетов в legacy .nupkg через Conan-deployer
#  Артефакты: output/{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg
#  ~15-25 минут на 8 ядрах (×2 build_type).
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
    source "$ROOT_DIR/venv/bin/activate"
fi

PROFILE="${PROFILE:-$ROOT_DIR/profiles/astra-gcc}"
[ -f "$PROFILE" ] || PROFILE="$ROOT_DIR/profiles/linux-gcc"

# Для кросс-сборки (arm/arm64 на x86_64-хосте) можно задать PROFILE_BUILD как
# нативный профиль — тогда Conan берёт правильный тулчейн для build-context. По
# умолчанию = PROFILE (нативная сборка, host == build).
PROFILE_BUILD="${PROFILE_BUILD:-$PROFILE}"

echo "[INFO] Profile (host):  $PROFILE"
echo "[INFO] Profile (build): $PROFILE_BUILD"
echo "[INFO] Conan: $(conan --version)"
echo ""

# Настройка ProGet (без env — no-op): строка backup-sources в global.conf +
# опциональная регистрация remote. См. HELP [16]/[17].
bash "$SCRIPT_DIR/ensure_proget.sh" || true

# CONAN_REMOTE=<name> переключает установку с --no-remote на -r <name>.
# По умолчанию — offline.
CONAN_REMOTE="${CONAN_REMOTE:-}"
REMOTE_ARGS=(--no-remote)
[ -n "$CONAN_REMOTE" ] && REMOTE_ARGS=(-r "$CONAN_REMOTE")

# Шаг 1: экспортировать все рецепты, чтобы --no-remote их нашёл
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

# Шаг 2: собрать всё дерево зависимостей Release + Debug (deployer'у нужны оба в кэше)
echo "============================================"
echo " Step 2/3: Build grpc tree Release + Debug"
echo "============================================"
SHARED="${SHARED:-False}"
for BT in Release Debug; do
    echo "[INFO] Building grpc/1.78.1 + 6 deps build_type=$BT shared=$SHARED"
    conan install --requires=grpc/1.78.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
        --build=missing "${REMOTE_ARGS[@]}" \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED"
done
echo "[OK] grpc tree built (Release+Debug, shared=$SHARED)"
echo ""

# Шаг 3: deployer → 7 legacy .nupkg
echo "============================================"
echo " Step 3/3: Package full tree via deployer"
echo "============================================"
mkdir -p "$ROOT_DIR/output"
rm -f "$ROOT_DIR/output"/{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg

conan install \
    --requires=grpc/1.78.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
    "${REMOTE_ARGS[@]}" \
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

# Опционально: выложить собранные пакеты на remote (HELP [17]).
if [ -n "$CONAN_REMOTE" ] && [ "${UPLOAD_AFTER:-0}" = "1" ]; then
    echo "[INFO] conan upload '*' -> remote '$CONAN_REMOTE'"
    conan upload "*" -r "$CONAN_REMOTE" --confirm
fi
