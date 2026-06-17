#!/bin/bash
# smoke_build_pkg.sh <arch> [pkg] [ver] — быстрый sanity-check образа:
# собрать ОДИН пакет (по умолчанию zlib/1.3.1) в готовом grpc-tc-mirror-<arch>.
# Проверяет, что образ рабочий: conan стартует, профиль валиден, для arm/arm64
# linaro-cross реально компилит. ~1 мин вместо полного дерева (~25 мин).
#
# Запуск на dev-VM (docker под sudo, переменные внутри bash -c):
#   sudo bash -c 'cd /home/user/conan-master && ./test-astra/smoke_build_pkg.sh x86_64'
#   ... arm | arm64 | all
# Другой пакет/версия — 2-й и 3-й аргументы: ./smoke_build_pkg.sh arm openssl 3.4.5
#
# Env:
#   REGISTRY     по умолч. proget.inc.elara.local/main (для имени образа)
#   MIRROR_VER   тег образа, по умолч. 0.1.0
#   IMAGE        переопределить ссылку на образ целиком
set -uo pipefail

ARCH="${1:-}"; PKG="${2:-zlib}"; VER="${3:-1.3.1}"
[ -z "$ARCH" ] && { echo "usage: $0 <x86_64|arm|arm64|all> [pkg] [ver]"; exit 2; }

REGISTRY="${REGISTRY:-proget.inc.elara.local/main}"
MIRROR_VER="${MIRROR_VER:-0.1.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# all — прогнать по трём аркам подряд
if [ "$ARCH" = "all" ]; then
    rc=0
    for a in x86_64 arm arm64; do
        echo; echo "######## $a ########"
        "$0" "$a" "$PKG" "$VER" || rc=1
    done
    exit $rc
fi

# Профиль host по арке. Build-профиль всегда нативный x86_64. Linaro-тулчейн
# arm/arm64 берётся из [conf] *:user_toolchain самого профиля (zlib собирается
# напрямую, поэтому env-fallback из рецептов grpc-дерева не нужен).
case "$ARCH" in
    x86_64) PROFILE=profiles/lin-gcc84-x86_64 ;;
    arm)    PROFILE=profiles/lin-gcc75-arm-linaro ;;
    arm64)  PROFILE=profiles/lin-gcc-aarch64-linaro ;;
    *) echo "[FAIL] arch must be x86_64|arm|arm64|all, got '$ARCH'" >&2; exit 2 ;;
esac
PROFILE_BUILD=profiles/lin-gcc84-x86_64

# docker напрямую, иначе passwordless sudo
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -n docker)
else DOCKER=(docker); fi

# Имя образа от prebake_push (registry-путь). Если такого нет, но есть bare-тег
# от test_all_profiles.sh — взять его.
IMAGE="${IMAGE:-$REGISTRY/library/grpc-tc-mirror-$ARCH:$MIRROR_VER}"
if ! "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1; then
    if "${DOCKER[@]}" image inspect "grpc-tc-mirror-$ARCH" >/dev/null 2>&1; then
        IMAGE="grpc-tc-mirror-$ARCH"
    fi
fi

echo "[INFO] $ARCH: $IMAGE -> conan create $PKG/$VER -pr:h=$PROFILE -pr:b=$PROFILE_BUILD"
"${DOCKER[@]}" run --rm \
    -v "$ROOT_DIR":/work/conan-recipes \
    "$IMAGE" \
    bash -lc "cd /work/conan-recipes \
        && bash test-astra/ensure_proget.sh || true \
        && conan create $PKG --version=$VER -pr:h=$PROFILE -pr:b=$PROFILE_BUILD --build=missing --no-remote" \
    && echo "[PASS] $PKG/$VER собран в $IMAGE ($ARCH)" \
    || { echo "[FAIL] $PKG/$VER не собрался в $IMAGE ($ARCH)" >&2; exit 1; }
