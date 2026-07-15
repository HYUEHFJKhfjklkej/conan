#!/bin/bash
# build_libxml2_nodocker.sh — собрать пакет libxml2/2.13.8 БЕЗ docker-self-wrap.
#
# export -> build Release+Debug -> deployer -> libxml2.<...>.nupkg. Никакого
# docker build/pull/run — контейнер-станок поднимает сам TeamCity
# ("Run step within Docker container"), как у grpc-драйвера build_1781_nodocker.sh.
# libxml2 — одиночный пакет вне grpc-дерева (без транзитивных deps).
#
# Запуск (TC build-step, внутри docker-контейнера от TC):
#   ARCH=x86_64 ./test-astra/build_libxml2_nodocker.sh      # x86_64 (по умолч.)
#   ARCH=arm    ./test-astra/build_libxml2_nodocker.sh      # кросс armv7hf
#   ARCH=arm64  ./test-astra/build_libxml2_nodocker.sh      # кросс arm64
#
# Env:
#   ARCH          x86_64|x86|arm|arm64 (по умолч. x86_64) — выбирает профиль/тулчейн
#   LIBXML2_VERSION   версия libxml2 (по умолч. 2.13.8)
#   PKG_VERSION   generic-фолбэк версии (если LIBXML2_VERSION не задан) — единая
#                 человекочитаемая переменная TC-шаблона для всех single-пакетов
#   PROFILE       host-профиль (по умолч. по арке)
#   PROFILE_BUILD build-профиль (по умолч. profiles/lin-gcc84-x86_64)
#   OUTPUT_DIR    выход отн. репо (по умолч. output-libxml2-<arch>)
#   SHARED        False — static .a содержимое (по умолч.)
#   LEGACY_NUPKG_VERSION_SUFFIX  суффикс версии .nupkg (по умолч. пусто)
#   PROGET_SOURCES_URL           backup-sources (по умолч. ProGet conan-sources)
#   SKIP_CACHE_CLEAN=1           не чистить conan-кэш на старте
#   CONAN_REMOTE / CONAN_REMOTE_URL / UPLOAD_AFTER  — как в grpc-драйвере
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

LIBXML2_VERSION="${LIBXML2_VERSION:-${PKG_VERSION:-2.13.8}}"
ARCH="${ARCH:-x86_64}"
case "$ARCH" in
    x86_64) PROFILE_DEF=profiles/lin-gcc84-x86_64;       TC_PATH="" ;;
    x86)    PROFILE_DEF=profiles/lin-gcc84-i686;         TC_PATH="" ;;  # 32-bit: -m32 в станке x86_64
    arm)    PROFILE_DEF=profiles/lin-gcc75-arm-linaro;   TC_PATH="$ROOT_DIR/profiles/toolchains/linaro-arm.cmake" ;;
    arm64)  PROFILE_DEF=profiles/lin-gcc-aarch64-linaro; TC_PATH="$ROOT_DIR/profiles/toolchains/linaro-aarch64.cmake" ;;
    *) echo "[FAIL] ARCH must be x86_64|x86|arm|arm64, got '$ARCH'" >&2; exit 2 ;;
esac
PROFILE="${PROFILE:-$PROFILE_DEF}"
PROFILE_BUILD="${PROFILE_BUILD:-profiles/lin-gcc84-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-output-libxml2-$ARCH}"
SHARED="${SHARED:-False}"
export LEGACY_NUPKG_VERSION_SUFFIX="${LEGACY_NUPKG_VERSION_SUFFIX:-}"
export PROGET_SOURCES_URL="${PROGET_SOURCES_URL-http://proget.inc.elara.local/endpoints/conan-sources/content/}"

# Кросс-тулчейн прокидывается через env (баг непропагации *:user_toolchain).
# Self-wrap'а тут нет, экспортируем сами. Рецепт libxml2 читает CONAN_USER_TOOLCHAIN
# в generate() с арк-гейтом (armv7/aarch64).
[ -n "$TC_PATH" ] && export CONAN_USER_TOOLCHAIN="$TC_PATH"

# conan на PATH (в станке стоит; на голом агенте — из venv).
if ! command -v conan >/dev/null 2>&1; then
    [ -f venv/bin/activate ] && source venv/bin/activate
fi
command -v conan >/dev/null 2>&1 || { echo "[FAIL] conan не найден (нет станка/venv)" >&2; exit 1; }

REF="libxml2/$LIBXML2_VERSION"
mkdir -p "$OUTPUT_DIR"
echo "[INFO] ref=$REF  arch=$ARCH  profile=$PROFILE  build=$PROFILE_BUILD"
echo "[INFO] toolchain=${CONAN_USER_TOOLCHAIN:-<none — native>}"
echo "[INFO] output=$OUTPUT_DIR  shared=$SHARED"
echo "[INFO] conan: $(conan --version 2>&1 | head -1)"

# ProGet backup-sources (no-op без env).
bash "$SCRIPT_DIR/ensure_proget.sh" || true

CONAN_REMOTE="${CONAN_REMOTE:-}"
REMOTE_ARGS=(--no-remote)
[ -n "$CONAN_REMOTE" ] && REMOTE_ARGS=(-r "$CONAN_REMOTE")

# Чистый кэш = честная сборка с нуля (SKIP_CACHE_CLEAN=1 чтобы пропустить).
[ -z "${SKIP_CACHE_CLEAN:-}" ] && conan remove '*' -c

# Экспорт рецепта libxml2.
conan export zlib/ --version=1.3.1 --no-remote   # dep
conan export libxml2/ --version="$LIBXML2_VERSION" --no-remote

# Сборка Release + Debug (deployer'у нужны оба).
for BT in Release Debug; do
    echo "------ build_type=$BT ($REF) ------"
    conan install --requires="$REF" \
        -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
        --build=missing "${REMOTE_ARGS[@]}" \
        -s build_type="$BT" \
        -o "libxml2/*:iconv=False" \
        -o "libxml2/*:lzma=False" \
        -o "*/*:shared=$SHARED"
done

# Deployer → legacy .nupkg (те же опции, что в build, иначе package_id разойдётся).
rm -f "$OUTPUT_DIR"/libxml2.*.nupkg
conan install --requires="$REF" \
    -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
    "${REMOTE_ARGS[@]}" \
    -o "libxml2/*:iconv=False" \
    -o "libxml2/*:lzma=False" \
    -o "*/*:shared=$SHARED" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/$OUTPUT_DIR"

echo ""
ls -lh "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | sed 's|^|  |' || echo "  (пусто)"
echo "[DONE] $REF ($ARCH) -> $OUTPUT_DIR/"

# Опционально: upload conan-пакетов в remote (CONAN_REMOTE + UPLOAD_AFTER=1).
if [ -n "$CONAN_REMOTE" ] && [ "${UPLOAD_AFTER:-0}" = "1" ]; then
    conan upload "*" -r "$CONAN_REMOTE" --confirm
fi
