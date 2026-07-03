#!/bin/bash
# Полное дерево grpc/1.78.1 (новейшая линия, upstream-исходники) → .nupkg
#
# Близнец run_grpc_1601_upstream.sh, но на САМЫЙ НОВЫЙ grpc из рецептов (1.78.1)
# и его современный транзитивный стек. Канонические conan-recipes/<pkg>
# (исходники с upstream github через conandata.yml). Результат: 7 .nupkg в
# текущей схеме имён deployer'а (<pkg>.lin.gcc84.shared.x86_64.<ver>.nupkg).
#
# Версии (ветка `grpc_version > "1.69.0"` в grpc/conanfile.py::requirements
# задаёт version ranges; резолвятся ровно в этот набор, потому что Шаг 1
# экспортирует только эти версии):
#   grpc        1.78.1
#   protobuf    5.29.6
#   abseil      20250127.0   (deployer слотит как absl/0.2.0)
#   re2         20251105
#   c-ares      1.34.6       (deployer переименовывает в cares)
#   openssl     3.4.5        (recipe dir: openssl/, name=openssl)
#   zlib        1.3.1
#
# Сам оборачивается в `docker run grpc-tc-mirror-<arch>`, как
# run_grpc_1601_upstream.sh. Никогда не запускается напрямую на dev-VM.
#
# Использование:
#   ./test-astra/run_grpc_1781_upstream.sh                  # x86_64 (по умолч.)
#   ARCH=arm   ./test-astra/run_grpc_1781_upstream.sh       # кросс armv7hf
#   ARCH=arm64 ./test-astra/run_grpc_1781_upstream.sh       # кросс arm64
#   ARCH=all   ./test-astra/run_grpc_1781_upstream.sh       # три арки подряд
#
# Env-оверрайды:
#   ARCH              x86_64|arm|arm64|all (по умолч. x86_64)
#   REGISTRY          ProGet host+feed для pull станка (по умолч. proget.inc.elara.local/main)
#   MIRROR_VER        тег станка на ProGet (по умолч. 0.1.0)
#   NO_PULL=1         не тянуть станок с ProGet, собрать из Dockerfile
#   MIRROR_IMAGE      локальный тег docker-образа (по умолч. grpc-tc-mirror-<arch>)
#   GCC84_BASE        x86_64-база для build-контекста (по умолч. ProGet gcc84)
#   BASE_IMAGE        stage-2 база (по умолч. по арке из ProGet)
#   CACHE_VOLUME      docker-volume под /root/.conan2 (по умолч. свой на арку)
#   OUTPUT_DIR        выходная папка отн. репо (по умолч. output-grpc-1781-<arch>)
#   PROFILE           host-профиль (по умолч. по арке)
#   PROFILE_BUILD     build-профиль (по умолч. profiles/lin-gcc84-x86_64)
#   SHARED            shared-опция для всех deps (по умолч. False — static)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

# ARCH=x86_64|arm|arm64|all — на какой арке собирать. По умолч. x86_64 (нативно).
# arm/arm64 — кросс на linaro 7.5: host-профиль ARM, build-контекст x86_64,
# тулчейн прокидывается через CONAN_USER_TOOLCHAIN (env-fallback в рецептах
# abseil/re2/protobuf/grpc, т.к. *:user_toolchain из [conf] не доходит до
# транзитивных deps). abseil 20250127.0 несёт aarch64-патч под binutils 2.32
# (xpaclri → hint #7) — линия 1.78.1 на ARM уже валидирована run_test_grpc.sh.
ARCH="${ARCH:-x86_64}"

# all — прогнать три арки подряд (каждая сама обернётся в свой docker-образ).
if [ "$ARCH" = "all" ]; then
    rc=0
    for a in x86_64 arm arm64; do
        echo ""; echo "######## grpc/1.78.1 -> $a ########"
        ARCH="$a" bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@" || rc=1
    done
    exit $rc
fi

GCC84_BASE="${GCC84_BASE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0}"
case "$ARCH" in
    x86_64)
        DOCKERFILE=Dockerfile.grpc-tc-mirror-x86_64
        MIRROR_IMAGE_DEF=grpc-tc-mirror-x86_64
        BASE_IMAGE_DEF="$GCC84_BASE"
        PROFILE_DEF=profiles/lin-gcc84-x86_64
        TC_PATH="" ;;
    arm)
        DOCKERFILE=Dockerfile.grpc-tc-mirror-arm
        MIRROR_IMAGE_DEF=grpc-tc-mirror-arm
        BASE_IMAGE_DEF="proget.inc.elara.local/main/library/gcc75-build-arm:0.1.0"
        PROFILE_DEF=profiles/lin-gcc75-arm-linaro
        TC_PATH=/work/conan-recipes/profiles/toolchains/linaro-arm.cmake ;;
    arm64)
        DOCKERFILE=Dockerfile.grpc-tc-mirror-arm64
        MIRROR_IMAGE_DEF=grpc-tc-mirror-arm64
        BASE_IMAGE_DEF="proget.inc.elara.local/main/library/gcc75-build-arm64:0.1.0"
        PROFILE_DEF=profiles/lin-gcc-aarch64-linaro
        TC_PATH=/work/conan-recipes/profiles/toolchains/linaro-aarch64.cmake ;;
    *) echo "[FAIL] ARCH must be x86_64|arm|arm64|all, got '$ARCH'" >&2; exit 2 ;;
esac

PROFILE="${PROFILE:-$PROFILE_DEF}"                           # host-профиль (по арке)
PROFILE_BUILD="${PROFILE_BUILD:-profiles/lin-gcc84-x86_64}"  # build-контекст всегда x86_64
OUTPUT_DIR="${OUTPUT_DIR:-output-grpc-1781-$ARCH}"
MIRROR_IMAGE="${MIRROR_IMAGE:-$MIRROR_IMAGE_DEF}"
X64_BASE_IMAGE="${X64_BASE_IMAGE:-$GCC84_BASE}"              # stage x64_native_tc (arm/arm64)
BASE_IMAGE="${BASE_IMAGE:-$BASE_IMAGE_DEF}"                  # stage 2 база (по арке)
CACHE_VOLUME="${CACHE_VOLUME:-conan-cache-grpc-1781-$ARCH}"
SHARED="${SHARED:-False}"

# Готовый станок на ProGet (его заливает prebake_push.sh). Если образа нет
# локально, драйвер сначала пытается скачать его отсюда (NO_PULL=1 — пропустить
# и собрать из Dockerfile). Так TC использует залитый образ, не пересобирая.
REGISTRY="${REGISTRY:-proget.inc.elara.local/main}"
MIRROR_VER="${MIRROR_VER:-0.1.0}"
PROGET_MIRROR="$REGISTRY/library/grpc-tc-mirror-$ARCH:$MIRROR_VER"
# Опциональный суффикс версии, добавляемый к каждому .nupkg + nuspec + записи
# _dependencies в CMakeLists.var. Нужен при заливке в ProGet-фид, где те же
# версии уже лежат из другого источника. Пример: LEGACY_NUPKG_VERSION_SUFFIX=.1
# даёт grpc.lin.gcc84.shared.x86_64.1.78.1.1.nupkg
# (slot-tag `shared` = DynamicRT — содержимое всё равно static .a).
LEGACY_NUPKG_VERSION_SUFFIX="${LEGACY_NUPKG_VERSION_SUFFIX:-}"

# Базовый URL backup-sources (HELP [16]). Прокидывается в контейнер ЯВНО:
# голый `-e VAR` при незаданной VAR на хосте заставляет docker СБРОСИТЬ
# дефолт из ENV образа вместо наследования. `-` (не `:-`): явная пустая
# строка тоже отключает backup-sources для этого прогона.
PROGET_SOURCES_URL="${PROGET_SOURCES_URL-http://proget.inc.elara.local/endpoints/conan-sources/content/}"

# Опциональный 1-й аргумент: собрать + задеплоить ТОЛЬКО ОДИН пакет вместо
# всего дерева grpc. Все рецепты всё равно экспортируются (дёшево), чтобы
# резолвились version ranges, но build/deploy идёт только по запрошенному ref.
#   ./run_grpc_1781_upstream.sh            -> grpc/1.78.1  (всё дерево, 7 nupkg)
#   ./run_grpc_1781_upstream.sh abseil     -> только abseil (1 nupkg)
declare -A TARGET_REFS=(
    [grpc]=grpc/1.78.1      [abseil]=abseil/20250127.0  [protobuf]=protobuf/5.29.6
    [re2]=re2/20251105      [c-ares]=c-ares/1.34.6      [zlib]=zlib/1.3.1
    [openssl]=openssl/3.4.5
)
TARGET_REF="${TARGET_REFS[${1:-grpc}]:-grpc/1.78.1}"

mkdir -p "$OUTPUT_DIR"

# Docker self-wrap (та же идиома, что в run_grpc_1601_upstream.sh).
if [ -z "${IN_MIRROR:-}" ] && [ ! -x /opt/x64-native-gcc/bin/gcc ]; then
    echo "[INFO] Host run detected. Wrapping in docker run $MIRROR_IMAGE ..."

    if ! docker image inspect "$MIRROR_IMAGE" >/dev/null 2>&1; then
        # Нет образа локально: сначала тянем готовый станок с ProGet (заливает
        # prebake_push.sh) — TC так использует залитый образ, не пересобирая.
        # NO_PULL=1 — пропустить pull и сразу собрать из Dockerfile.
        if [ "${NO_PULL:-0}" != "1" ] && docker pull "$PROGET_MIRROR" >/dev/null 2>&1; then
            echo "[INFO] Pulled $PROGET_MIRROR from ProGet"
            docker tag "$PROGET_MIRROR" "$MIRROR_IMAGE"
        else
            echo "[INFO] $MIRROR_IMAGE нет локально и нет на ProGet — собираю из $DOCKERFILE..."
            echo "[INFO] X64_BASE_IMAGE=$X64_BASE_IMAGE"
            echo "[INFO] BASE_IMAGE=$BASE_IMAGE"
            docker build \
                --build-arg X64_BASE_IMAGE="$X64_BASE_IMAGE" \
                --build-arg BASE_IMAGE="$BASE_IMAGE" \
                -f "$DOCKERFILE" \
                -t "$MIRROR_IMAGE" \
                .
        fi
    fi

    exec docker run --rm \
        -v "$ROOT_DIR:/work/conan-recipes" \
        -v "$CACHE_VOLUME:/root/.conan2" \
        -e IN_MIRROR=1 \
        -e ARCH="$ARCH" \
        -e OUTPUT_DIR="$OUTPUT_DIR" \
        -e PROFILE="$PROFILE" \
        -e PROFILE_BUILD="$PROFILE_BUILD" \
        -e CONAN_USER_TOOLCHAIN="$TC_PATH" \
        -e SHARED="$SHARED" \
        -e LEGACY_NUPKG_VERSION_SUFFIX="$LEGACY_NUPKG_VERSION_SUFFIX" \
        -e CONAN_REMOTE -e CONAN_REMOTE_URL -e CONAN_REMOTE_INSECURE \
        -e UPLOAD_AFTER -e CONAN_LOGIN_USERNAME -e CONAN_PASSWORD \
        -e PROGET_SOURCES_URL="$PROGET_SOURCES_URL" \
        --entrypoint bash \
        "$MIRROR_IMAGE" \
        -c "bash ./test-astra/$(basename "${BASH_SOURCE[0]}") $*"
fi

# Дальше — внутри контейнера-зеркала.
if ! command -v conan >/dev/null 2>&1; then
    if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$ROOT_DIR/venv/bin/activate"
    fi
fi
if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not on PATH inside container — check grpc-tc-mirror image"
    exit 1
fi

# Настройка ProGet (no-op без env): строка backup-sources в global.conf +
# опциональная регистрация remote. См. HELP [16]/[17].
bash "$ROOT_DIR/test-astra/ensure_proget.sh" || true

# CONAN_REMOTE=<name> переключает install с --no-remote на -r <name>
# (бинарники переиспользуются из / заливаются в ProGet). По умолч. offline.
CONAN_REMOTE="${CONAN_REMOTE:-}"
REMOTE_ARGS=(--no-remote)
[ -n "$CONAN_REMOTE" ] && REMOTE_ARGS=(-r "$CONAN_REMOTE")

echo "[INFO] conan:           $(conan --version 2>&1 | head -1)"
echo "[INFO] arch:            ${ARCH:-x86_64}"
echo "[INFO] profile (host):  $PROFILE"
echo "[INFO] profile (build): ${PROFILE_BUILD:-$PROFILE}"
echo "[INFO] toolchain:       ${CONAN_USER_TOOLCHAIN:-<none — native>}"
echo "[INFO] output:          $OUTPUT_DIR"
echo "[INFO] shared:          $SHARED"
echo "[INFO] cache:           $(conan config home 2>/dev/null)"
echo "[INFO] version_suffix:  '${LEGACY_NUPKG_VERSION_SUFFIX}'  (empty = no suffix)"
echo ""

# Шаг 0: pre-flight — отказаться, если в кэше уже есть Elara-форк legacy/*
# (absl/0.2.0, cares/1.19.0 и т.д.). Они резолвятся раньше наших upstream-версий
# и возвращают inline-namespace mismatch, который этот скрипт призван избегать.
echo "=================================================="
echo "[STEP 0] pre-flight: no legacy/* in cache"
echo "=================================================="
STALE=""
for pat in 'absl/0.2.0' 'cares/1.19.0' 'upb/0.2.0' 'address_sorting/1.0.0'; do
    if conan list "$pat" 2>/dev/null | grep -qE "^\s+$pat"; then
        STALE="$STALE $pat"
    fi
done
if [ -n "$STALE" ]; then
    echo "[ERROR] cache contains Elara-fork packages:$STALE"
    echo "        These resolve ahead of canonical recipes — abort."
    echo "        Either use a fresh CACHE_VOLUME (default) or:"
    echo "            conan remove 'absl/*' 'cares/1.19.0' 'upb/*' 'address_sorting/*' -c"
    exit 1
fi
echo "[STEP 0] clean."
echo ""

# Шаг 0.5: чистим кэш, чтобы каждая сборка была с нуля. Опция `debug_suffix`
# в рецепте protobuf не всегда форсит новый package_id — Conan может молча
# переиспользовать бинарник с дефолтными опциями. Очистка кэша гарантирует
# свежую сборку. Можно пропустить через SKIP_CACHE_CLEAN=1 (например, когда
# правишь только deployer).
if [ -z "${SKIP_CACHE_CLEAN:-}" ]; then
    echo "=================================================="
    echo "[STEP 0.5] wipe Conan cache (set SKIP_CACHE_CLEAN=1 to skip)"
    echo "=================================================="
    conan remove '*' -c
    echo ""
fi

# Шаг 1: экспорт всех 7 рецептов в версиях, которые резолвит grpc/1.78.1.
# Ranges из grpc/conanfile.py (ветка `grpc_version > "1.69.0"`) резолвятся
# ровно в этот набор — новейшая линия, поддерживаемая рецептами.
echo "=================================================="
echo "[STEP 1] conan export — 7 recipes, grpc/1.78.1 stack"
echo "=================================================="
declare -A EXPORTS=(
    [zlib]=1.3.1
    [abseil]=20250127.0
    [c-ares]=1.34.6
    [re2]=20251105
    [protobuf]=5.29.6
    [openssl]=3.4.5
    [grpc]=1.78.1
)
# Стабильный порядок экспорта: листья раньше веток.
for pkg in zlib abseil c-ares re2 protobuf openssl grpc; do
    ver="${EXPORTS[$pkg]}"
    echo "[EXPORT] $pkg/$ver  (from ./$pkg)"
    conan export "$pkg/" --version="$ver" --no-remote
done
echo ""

# Шаг 2: сборка всего дерева Release + Debug (deployer'у нужны оба).
# --build=missing — Conan компилирует любой бинарник, которого нет в кэше.
# -o "*/*:shared=$SHARED" — все deps в одной linkage (downstream Elara
# линкуется статически -> по умолчанию static .a).
echo "=================================================="
echo "[STEP 2] build grpc/1.78.1 tree (Release + Debug)"
echo "=================================================="
for BT in Release Debug; do
    echo ""
    echo "------ build_type=$BT  ($TARGET_REF) ------"
    # abseil static — legacy-упаковка из 21 крупной .a срабатывает только на
    # static-сборке (abseil/conanfile.py::_aggregate_legacy_coarse). Отдельный
    # паттерн abseil/* пинит abseil static, даже если задать SHARED=True
    # (редко; дефолт SHARED=False и так static).
    conan install --requires="$TARGET_REF" \
        -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
        --build=missing "${REMOTE_ARGS[@]}" \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED" \
        -o "abseil/*:shared=False" \
        -o "protobuf/*:debug_suffix=False"
done
echo ""
echo "[STEP 2] full tree built."
echo ""

# Шаг 3: deployer → 7 .nupkg с legacy-именами.
echo "=================================================="
echo "[STEP 3] deploy $TARGET_REF -> legacy .nupkg into $OUTPUT_DIR/"
echo "=================================================="
rm -f "$OUTPUT_DIR"/{grpc,protobuf,abseil,absl,re2,c-ares,cares,openssl,zlib}.*.nupkg

# Deploy должен указывать на ТОТ ЖЕ ref, что Шаг 2 ($TARGET_REF), и повторять
# ТЕ ЖЕ опции. Здесь нет --build, поэтому при ином package_id (особенно без
# `abseil/*:shared=False`) Conan сочтёт бинарник отсутствующим и упадёт.
# Один пакет -> 1 .nupkg; всё дерево -> 7.
conan install --requires="$TARGET_REF" \
    -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
    "${REMOTE_ARGS[@]}" \
    -o "*/*:shared=$SHARED" \
    -o "abseil/*:shared=False" \
    -o "protobuf/*:debug_suffix=False" \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/$OUTPUT_DIR"

echo ""
echo "[INFO] output listing:"
ls -lh "$ROOT_DIR/$OUTPUT_DIR"/*.nupkg 2>/dev/null | sed 's|^|  |' || echo "  (empty)"

echo ""
echo "=================================================="
echo "[DONE] grpc/1.78.1 newest-line tree built."
echo "Artifacts in $OUTPUT_DIR/ (legacy-named .nupkg)."
echo "=================================================="

# Шаг 4 (opt-in): публикация собранных conan-пакетов в remote. Нужны
# CONAN_REMOTE=<name> UPLOAD_AFTER=1 и аутентификация (conan remote login
# один раз на cache volume, либо CONAN_LOGIN_USERNAME + CONAN_PASSWORD в env).
# См. HELP [17].
if [ -n "$CONAN_REMOTE" ] && [ "${UPLOAD_AFTER:-0}" = "1" ]; then
    echo ""
    echo "=================================================="
    echo "[STEP 4] conan upload '*' -> remote '$CONAN_REMOTE'"
    echo "=================================================="
    conan upload "*" -r "$CONAN_REMOTE" --confirm
fi
