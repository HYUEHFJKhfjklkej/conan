#!/bin/bash
# build_qwt_nodocker.sh — собрать пакет qwt/6.2.0 БЕЗ docker-self-wrap.
#
# ТОЛЬКО x86_64: Qt 5.15.2 живёт в базовом CI-образе gcc84-build-x86_64
# (deb qt5-devel-elara -> /opt/Qt/5.15.2, ENV QT5_ROOT_DIR) — станок
# grpc-tc-mirror-x86_64 строится FROM него и несёт Qt as-is; arm/arm64-образы
# Qt не несут, потребитель qwt (el_conf, десктопный конфигуратор) — x86_64.
# Qt НЕ conan-деп: рецепт берёт qmake из $QT5_ROOT_DIR/gcc_64/bin (фолбэк —
# qmake с PATH), ровно как Qt5Configure.cmake легаси-фреймворка.
#
# Версия 6.2.0 = легаси-пин el_conf (qwt:6.2.0 в CMakeLists.var), НЕ 6.3.0.
#
# export -> build Release+Debug -> deployer -> qwt.<...>.nupkg.
#
# Запуск (TC build-step, внутри docker-контейнера от TC):
#   ./test-astra/build_qwt_nodocker.sh              # x86_64 (единственный)
#
# Env:
#   QWT_VERSION   версия qwt (по умолч. 6.2.0)
#   PKG_VERSION   generic-фолбэк версии — единая переменная TC-шаблона
#   PROFILE       host-профиль (по умолч. lin-gcc84-x86_64)
#   PROFILE_BUILD build-профиль (по умолч. = PROFILE)
#   OUTPUT_DIR    выход отн. репо (по умолч. output-qwt-x86_64)
#   SHARED        False — static .a содержимое (по умолч.)
#   LEGACY_NUPKG_VERSION_SUFFIX / PROGET_SOURCES_URL / SKIP_CACHE_CLEAN=1
#   CONAN_REMOTE / UPLOAD_AFTER  — как в остальных драйверах
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

QWT_VERSION="${QWT_VERSION:-${PKG_VERSION:-6.2.0}}"
ARCH="${ARCH:-x86_64}"
if [ "$ARCH" != "x86_64" ]; then
    echo "[FAIL] qwt собирается только на x86_64 (Qt 5.15.2 есть лишь в образе gcc84-build-x86_64; arm/arm64-образы Qt не несут)" >&2
    exit 2
fi
PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"
PROFILE_BUILD="${PROFILE_BUILD:-$PROFILE}"
OUTPUT_DIR="${OUTPUT_DIR:-output-qwt-x86_64}"
SHARED="${SHARED:-False}"
export LEGACY_NUPKG_VERSION_SUFFIX="${LEGACY_NUPKG_VERSION_SUFFIX:-}"
export PROGET_SOURCES_URL="${PROGET_SOURCES_URL-http://proget.inc.elara.local/endpoints/conan-sources/content/}"

# conan на PATH (в станке стоит; на голом агенте — из venv).
if ! command -v conan >/dev/null 2>&1; then
    [ -f venv/bin/activate ] && source venv/bin/activate
fi
command -v conan >/dev/null 2>&1 || { echo "[FAIL] conan не найден (нет станка/venv)" >&2; exit 1; }

# Pre-flight: qmake из QT5_ROOT_DIR (рецепт ищет так же).
QMAKE="${QT5_ROOT_DIR:-}/gcc_64/bin/qmake"
if [ ! -x "$QMAKE" ] && ! command -v qmake >/dev/null 2>&1; then
    echo "[FAIL] qmake не найден: нет \$QT5_ROOT_DIR/gcc_64/bin/qmake и qmake не на PATH." >&2
    echo "       Станок должен нести Qt 5.15.2 (базовый образ gcc84-build-x86_64) — HELP [32]" >&2
    exit 1
fi
echo "[INFO] qmake: $([ -x "$QMAKE" ] && echo "$QMAKE" || command -v qmake)"

REF="qwt/$QWT_VERSION"
mkdir -p "$OUTPUT_DIR"
echo "[INFO] ref=$REF  profile=$PROFILE  output=$OUTPUT_DIR  shared=$SHARED"
echo "[INFO] conan: $(conan --version 2>&1 | head -1)"

# ProGet backup-sources (no-op без env).
bash "$SCRIPT_DIR/ensure_proget.sh" || true

CONAN_REMOTE="${CONAN_REMOTE:-}"
REMOTE_ARGS=(--no-remote)
[ -n "$CONAN_REMOTE" ] && REMOTE_ARGS=(-r "$CONAN_REMOTE")

# Чистый кэш = честная сборка с нуля (SKIP_CACHE_CLEAN=1 чтобы пропустить).
[ -z "${SKIP_CACHE_CLEAN:-}" ] && conan remove '*' -c

conan export qwt/ --version="$QWT_VERSION" --no-remote

for BT in Release Debug; do
    echo "------ build_type=$BT ($REF) ------"
    conan install --requires="$REF" \
        -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
        --build=missing "${REMOTE_ARGS[@]}" \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED"
done

# Deployer → legacy .nupkg.
rm -f "$OUTPUT_DIR"/qwt.*.nupkg
conan install --requires="$REF" \
    -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
    "${REMOTE_ARGS[@]}" \
    -o "*/*:shared=$SHARED" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/$OUTPUT_DIR"

echo ""
ls -lh "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | sed 's|^|  |' || echo "  (пусто)"
echo "[DONE] $REF (x86_64) -> $OUTPUT_DIR/"

if [ -n "$CONAN_REMOTE" ] && [ "${UPLOAD_AFTER:-0}" = "1" ]; then
    conan upload "*" -r "$CONAN_REMOTE" --confirm
fi
