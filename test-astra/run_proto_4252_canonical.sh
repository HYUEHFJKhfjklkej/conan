#!/bin/bash
# Сборка канонических protobuf 4.25.2 + abseil 20230802.1 через Docker-зеркало.
#
# Назначение: проверить, что канонические рецепты (protobuf/, abseil/) дают
# рабочий protoc + .nupkg в образе grpc-tc-mirror, без legacy/-форков. Это ответ
# на класс ошибок `undefined reference to absl::lts_20230802::*`, которые ловит
# legacy/protobuf 4.25.2 при подтягивании absl/0.2.0 (там inline namespace
# lts_20240116).
#
# Сам себя оборачивает в `docker run grpc-tc-mirror` (как run_legacy_versions.sh).
# Никогда не запускается на голой dev-VM: Astra 1.8 несёт gcc 12 — не тот ABI
# против gcc 8.4 в зеркале.
#
# Запуск:
#   ./test-astra/run_proto_4252_canonical.sh
#
# Переопределение через env:
#   MIRROR_IMAGE      тег docker-образа (default: grpc-tc-mirror)
#   PROGET_BASE       базовый образ для сборки Dockerfile (default: ProGet)
#   CACHE_VOLUME      docker volume под /root/.conan2 (default: свежий)
#   OUTPUT_DIR        каталог под .nupkg (default: output-proto-4252-canonical)
#   PROFILE           conan-профиль (default: profiles/lin-gcc84-x86_64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-output-proto-4252-canonical}"
MIRROR_IMAGE="${MIRROR_IMAGE:-grpc-tc-mirror}"
PROGET_BASE="${PROGET_BASE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0}"
X64_BASE_IMAGE="${X64_BASE_IMAGE:-$PROGET_BASE}"
BASE_IMAGE="${BASE_IMAGE:-$PROGET_BASE}"
# По умолчанию свежий cache volume: иначе старый absl/0.2.0 или abseil из legacy-
# прогона может попасть на линковку и воспроизвести ту самую ошибку.
CACHE_VOLUME="${CACHE_VOLUME:-conan-cache-proto-4252-canonical}"

mkdir -p "$OUTPUT_DIR"

# Самооборачивание в Docker (тот же приём, что в run_legacy_versions.sh).
if [ -z "${IN_MIRROR:-}" ] && [ ! -x /opt/x64-native-gcc/bin/gcc ]; then
    echo "[INFO] Host run detected. Wrapping in docker run $MIRROR_IMAGE ..."

    if ! docker image inspect "$MIRROR_IMAGE" >/dev/null 2>&1; then
        echo "[INFO] Image $MIRROR_IMAGE missing — building from Dockerfile.grpc-tc-mirror..."
        echo "[INFO] X64_BASE_IMAGE=$X64_BASE_IMAGE"
        echo "[INFO] BASE_IMAGE=$BASE_IMAGE"
        docker build \
            --build-arg X64_BASE_IMAGE="$X64_BASE_IMAGE" \
            --build-arg BASE_IMAGE="$BASE_IMAGE" \
            -f Dockerfile.grpc-tc-mirror-x86_64 \
            -t "$MIRROR_IMAGE" \
            .
    fi

    exec docker run --rm \
        -v "$ROOT_DIR:/work/conan-recipes" \
        -v "$CACHE_VOLUME:/root/.conan2" \
        -e IN_MIRROR=1 \
        -e OUTPUT_DIR="$OUTPUT_DIR" \
        -e PROFILE="$PROFILE" \
        --entrypoint bash \
        "$MIRROR_IMAGE" \
        -c "./test-astra/$(basename "${BASH_SOURCE[0]}") $*"
fi

# Дальше — внутри контейнера зеркала (или на хосте с /opt/x64-native-gcc/bin/gcc).
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

echo "[INFO] conan:    $(conan --version 2>&1 | head -1)"
echo "[INFO] profile:  $PROFILE"
echo "[INFO] output:   $OUTPUT_DIR"
echo "[INFO] cache:    $(conan config home 2>/dev/null)"
echo ""

# Pre-flight: убедиться, что в кэше нет залежавшегося absl/0.2.0 или abseil от
# прошлых legacy-прогонов. На свежем CACHE_VOLUME это no-op; на общем — прерывает
# прогон, а не молча линкуется с не тем abseil.
echo "[STEP 0] pre-flight: check no stale absl/0.2.0 in cache"
STALE=$(conan list 'absl/*' 2>/dev/null | grep -E '^\s+absl/0\.2\.0' || true)
if [ -n "$STALE" ]; then
    echo "[ERROR] cache contains legacy absl/0.2.0 — would conflict with abseil/20230802.1"
    echo "$STALE"
    echo ""
    echo "Either use a fresh CACHE_VOLUME (default), or run:"
    echo "    conan remove 'absl/*' -c"
    echo "    conan remove 'protobuf/*' -c"
    exit 1
fi
echo "[STEP 0] clean."
echo ""

# Шаг 1 — abseil 20230802.1 (Release + Debug)
echo "=================================================="
echo "[STEP 1] conan create abseil/20230802.1  (Release)"
echo "=================================================="
conan create abseil/ --version=20230802.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Release --build=missing --no-remote

echo ""
echo "=================================================="
echo "[STEP 1] conan create abseil/20230802.1  (Debug)"
echo "=================================================="
conan create abseil/ --version=20230802.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Debug --build=missing --no-remote

# Шаг 1b — zlib 1.3.1 (Release + Debug)
# protobuf 4.25.2 транзитивно тянет zlib/[>=1.2.11 <2] при options.with_zlib=True
# (default рецепта). В --no-remote диапазон версий из conan-center не резолвится —
# нужно сначала засеять кэш подходящей сборкой zlib.
echo ""
echo "=================================================="
echo "[STEP 1b] conan create zlib/1.3.1  (Release)"
echo "=================================================="
conan create zlib/ --version=1.3.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Release --build=missing --no-remote

echo ""
echo "=================================================="
echo "[STEP 1b] conan create zlib/1.3.1  (Debug)"
echo "=================================================="
conan create zlib/ --version=1.3.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Debug --build=missing --no-remote

# Шаг 2 — protobuf 4.25.2 (Release + Debug)
echo ""
echo "=================================================="
echo "[STEP 2] conan create protobuf/4.25.2  (Release)"
echo "=================================================="
conan create protobuf/ --version=4.25.2 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Release --build=missing --no-remote

echo ""
echo "=================================================="
echo "[STEP 2] conan create protobuf/4.25.2  (Debug)"
echo "=================================================="
conan create protobuf/ --version=4.25.2 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    -s build_type=Debug --build=missing --no-remote

# Шаг 3 — выкладка .nupkg через legacy_nupkg.py
echo ""
echo "=================================================="
echo "[STEP 3] deploy legacy .nupkg into $OUTPUT_DIR/"
echo "=================================================="
conan install --requires=protobuf/4.25.2 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder="$OUTPUT_DIR/"

echo ""
echo "[INFO] output listing:"
ls -la "$OUTPUT_DIR/" || true
echo ""
echo "[DONE] canonical protobuf 4.25.2 + abseil 20230802.1 built via Docker mirror."
