#!/bin/bash
# build_1601_nodocker.sh — собрать дерево grpc/1.60.1 БЕЗ docker-self-wrap.
#
# Для TeamCity, где контейнер-станок поднимает САМ TC ("Run step within Docker
# container", образ в параметрах билдера). Скрипт запускается УЖЕ ВНУТРИ станка
# и только гоняет conan: export → build Release+Debug → deployer → 7 .nupkg.
# Никакого docker build/pull/run внутри — этим управляет TeamCity.
#
# Запуск (TC build-step, внутри docker-контейнера от TC):
#   ARCH=x86_64 ./test-astra/build_1601_nodocker.sh      # x86_64 (по умолч.)
#   ARCH=arm    ./test-astra/build_1601_nodocker.sh      # кросс armv7hf
#   ARCH=arm64  ./test-astra/build_1601_nodocker.sh      # кросс arm64
#   ./test-astra/build_1601_nodocker.sh abseil           # один пакет вместо дерева
#
# Env:
#   ARCH          x86_64|arm|arm64 (по умолч. x86_64) — выбирает профиль/тулчейн
#   PROFILE       host-профиль (по умолч. по арке)
#   PROFILE_BUILD build-профиль (по умолч. profiles/lin-gcc84-x86_64)
#   OUTPUT_DIR    выход отн. репо (по умолч. output-grpc-1601-<arch>)
#   SHARED        False — static .a содержимое (по умолч.)
#   LEGACY_NUPKG_VERSION_SUFFIX  суффикс версии .nupkg (по умолч. пусто)
#   PROGET_SOURCES_URL           backup-sources (по умолч. ProGet conan-sources)
#   SKIP_CACHE_CLEAN=1           не чистить conan-кэш на старте
#   CONAN_REMOTE / CONAN_REMOTE_URL / UPLOAD_AFTER  — как в основном драйвере
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

ARCH="${ARCH:-x86_64}"
case "$ARCH" in
    x86_64) PROFILE_DEF=profiles/lin-gcc84-x86_64;       TC_PATH="" ;;
    arm)    PROFILE_DEF=profiles/lin-gcc75-arm-linaro;   TC_PATH="$ROOT_DIR/profiles/toolchains/linaro-arm.cmake" ;;
    arm64)  PROFILE_DEF=profiles/lin-gcc-aarch64-linaro; TC_PATH="$ROOT_DIR/profiles/toolchains/linaro-aarch64.cmake" ;;
    *) echo "[FAIL] ARCH must be x86_64|arm|arm64, got '$ARCH'" >&2; exit 2 ;;
esac
PROFILE="${PROFILE:-$PROFILE_DEF}"
PROFILE_BUILD="${PROFILE_BUILD:-profiles/lin-gcc84-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-output-grpc-1601-$ARCH}"
SHARED="${SHARED:-False}"
export LEGACY_NUPKG_VERSION_SUFFIX="${LEGACY_NUPKG_VERSION_SUFFIX:-}"
export PROGET_SOURCES_URL="${PROGET_SOURCES_URL-http://proget.inc.elara.local/endpoints/conan-sources/content/}"

# Кросс-тулчейн транзитивным deps дерева прокидывается через env (баг
# непропагации *:user_toolchain). Self-wrap'а тут нет, экспортируем сами.
[ -n "$TC_PATH" ] && export CONAN_USER_TOOLCHAIN="$TC_PATH"

# conan на PATH (в станке стоит; на голом агенте — из venv).
if ! command -v conan >/dev/null 2>&1; then
    [ -f venv/bin/activate ] && source venv/bin/activate
fi
command -v conan >/dev/null 2>&1 || { echo "[FAIL] conan не найден (нет станка/venv)" >&2; exit 1; }

# Опциональный 1-й арг: собрать+задеплоить ОДИН пакет вместо всего дерева.
declare -A TARGET_REFS=(
    [grpc]=grpc/1.60.1      [abseil]=abseil/20230802.1  [protobuf]=protobuf/4.25.2
    [re2]=re2/20230301      [c-ares]=c-ares/1.25.0      [zlib]=zlib/1.3.0
    [openssl]=openssl/1.1.11
)
TARGET_REF="${TARGET_REFS[${1:-grpc}]:-grpc/1.60.1}"

mkdir -p "$OUTPUT_DIR"
echo "[INFO] arch=$ARCH  profile=$PROFILE  build=$PROFILE_BUILD"
echo "[INFO] toolchain=${CONAN_USER_TOOLCHAIN:-<none — native>}"
echo "[INFO] conan: $(conan --version 2>&1 | head -1)"

# ProGet backup-sources (no-op без env).
bash "$SCRIPT_DIR/ensure_proget.sh" || true

CONAN_REMOTE="${CONAN_REMOTE:-}"
REMOTE_ARGS=(--no-remote)
[ -n "$CONAN_REMOTE" ] && REMOTE_ARGS=(-r "$CONAN_REMOTE")

# Чистый кэш = честная сборка с нуля (SKIP_CACHE_CLEAN=1 чтобы пропустить).
[ -z "${SKIP_CACHE_CLEAN:-}" ] && conan remove '*' -c

# Экспорт 7 рецептов в версиях линии 1.60.1.
declare -A EXPORTS=(
    [zlib]=1.3.0     [abseil]=20230802.1  [c-ares]=1.25.0  [re2]=20230301
    [protobuf]=4.25.2 [openssl-1x]=1.1.11 [grpc]=1.60.1
)
for pkg in zlib abseil c-ares re2 protobuf openssl-1x grpc; do
    conan export "$pkg/" --version="${EXPORTS[$pkg]}" --no-remote
done

# Сборка дерева Release + Debug (deployer'у нужны оба).
for BT in Release Debug; do
    echo "------ build_type=$BT ($TARGET_REF) ------"
    conan install --requires="$TARGET_REF" \
        -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
        --build=missing "${REMOTE_ARGS[@]}" \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED" \
        -o "abseil/*:shared=False" \
        -o "protobuf/*:debug_suffix=False"
done

# Deployer → legacy .nupkg (те же опции, что в build, иначе package_id разойдётся).
rm -f "$OUTPUT_DIR"/{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg
conan install --requires="$TARGET_REF" \
    -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
    "${REMOTE_ARGS[@]}" \
    -o "*/*:shared=$SHARED" \
    -o "abseil/*:shared=False" \
    -o "protobuf/*:debug_suffix=False" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/$OUTPUT_DIR"

echo ""
ls -lh "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | sed 's|^|  |' || echo "  (пусто)"
echo "[DONE] grpc/1.60.1 ($ARCH) -> $OUTPUT_DIR/"

# Опционально: upload conan-пакетов в remote (CONAN_REMOTE + UPLOAD_AFTER=1).
if [ -n "$CONAN_REMOTE" ] && [ "${UPLOAD_AFTER:-0}" = "1" ]; then
    conan upload "*" -r "$CONAN_REMOTE" --confirm
fi
