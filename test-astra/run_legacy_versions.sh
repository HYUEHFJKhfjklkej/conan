#!/bin/bash
#
# run_legacy_versions.sh
# Сборка полного legacy-стека grpc 1.60.1 через Conan + упаковка в legacy nupkg.
# IN-658: drop-in replacement для GR113/120 TC билдов через Conan.
#
# Версии:
#   grpc:1.60.1        — replaces legacy GR113 grpc
#   protobuf:4.25.2    — upstream v25.2 (legacy nomenclature)
#   abseil:20240116.2  — pinned to grpc 1.60.1 transitive
#   re2:20230301       — pinned to grpc 1.60.1 transitive
#   c-ares:1.25.0      — pinned to grpc 1.60.1 transitive
#   openssl:1.1.11     — Elara nomenclature = upstream OpenSSL 1.1.1w (recipe in openssl-1x/)
#   zlib:1.3.0         — upstream v1.3 (legacy nomenclature)
#
# Использование:
#   ./test-astra/run_legacy_versions.sh                 # полный стек (Release + Debug)
#   ./test-astra/run_legacy_versions.sh zlib            # только zlib
#   ./test-astra/run_legacy_versions.sh protobuf        # только protobuf
#   ./test-astra/run_legacy_versions.sh openssl         # только openssl
#   ./test-astra/run_legacy_versions.sh grpc            # только grpc (+ автоматом abseil/re2/c-ares)
#   ./test-astra/run_legacy_versions.sh pack            # только deployer (после create'ов)
#
# Перед запуском:
#   source venv/bin/activate    # должен быть Conan 2.27.1 в PATH
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE="profiles/lin-gcc84-x86_64"
OUTPUT_DIR="output-legacy"
MIRROR_IMAGE="${MIRROR_IMAGE:-grpc-tc-mirror}"
BASE_IMAGE="${BASE_IMAGE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:latest}"
CACHE_VOLUME="${CACHE_VOLUME:-conan-cache-legacy-x86_64}"

mkdir -p "$OUTPUT_DIR"

# ----------------------------------------------------------------------
# Docker self-wrapping.
#
# Профиль lin-gcc84-x86_64 жёстко зашит на /opt/x64-native-gcc/bin/gcc —
# этот путь существует только внутри Dockerfile.grpc-tc-mirror (Stage 1
# копирует gcc 8.4 из ProGet-образа gcc84-build-x86_64). На голой dev-VM
# этого пути НЕТ → cmake configure упадёт с
#   "CMAKE_C_COMPILER /opt/x64-native-gcc/bin/gcc is not a full path".
#
# Поэтому если мы НЕ внутри контейнера mirror — обернуть себя в docker run.
# Внутри контейнера флаг IN_MIRROR=1 пробрасывается через -e чтобы
# рекурсии не было.
# ----------------------------------------------------------------------
if [ -z "${IN_MIRROR:-}" ] && [ ! -x /opt/x64-native-gcc/bin/gcc ]; then
    echo "[INFO] Запуск на host. Профиль lin-gcc84-x86_64 требует Docker-зеркала."
    echo "[INFO] Оборачиваю себя в docker run $MIRROR_IMAGE ..."

    # Собираем образ-зеркало если он отсутствует.
    if ! docker image inspect "$MIRROR_IMAGE" >/dev/null 2>&1; then
        echo "[INFO] Образ $MIRROR_IMAGE отсутствует — собираю..."
        docker build \
            --build-arg BASE_IMAGE="$BASE_IMAGE" \
            -f Dockerfile.grpc-tc-mirror \
            -t "$MIRROR_IMAGE" \
            .
    fi

    # Передаём cmd-line обратно нашему же скрипту внутри контейнера.
    exec docker run --rm \
        -v "$ROOT_DIR/$OUTPUT_DIR:/work/conan-recipes/$OUTPUT_DIR" \
        -v "$CACHE_VOLUME:/root/.conan2" \
        -e IN_MIRROR=1 \
        --entrypoint bash \
        "$MIRROR_IMAGE" \
        -c "./test-astra/$(basename "${BASH_SOURCE[0]}") $*"
fi

# ----------------------------------------------------------------------
# Дальше — мы внутри Docker-зеркала (либо рукотворного хоста с GCC 8.4 в
# нужном пути). В образе grpc-tc-mirror Conan уже установлен в /opt/python,
# симлинк в /usr/local/bin, venv не нужен. На host'е (если кто-то очень
# хочет) — попробуем venv.
# ----------------------------------------------------------------------
if ! command -v conan >/dev/null 2>&1; then
    if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
        echo "[INFO] conan не в PATH — активирую venv автоматически"
        # shellcheck disable=SC1091
        source "$ROOT_DIR/venv/bin/activate"
    fi
fi
if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan не найден ни в PATH, ни в $ROOT_DIR/venv/."
    echo "       На host: ./test-astra/setup.sh"
    echo "       В Docker: образ grpc-tc-mirror должен иметь Conan в /opt/python — проверь Dockerfile"
    exit 1
fi
echo "[INFO] Conan: $(conan --version)"
echo "[INFO] Profile: $PROFILE"
echo "[INFO] Output dir: $ROOT_DIR/$OUTPUT_DIR"
echo

create_one() {
    local recipe_dir="$1"
    local version="$2"
    local build_type="$3"
    echo "=========================================="
    echo "conan create $recipe_dir --version=$version build_type=$build_type"
    echo "=========================================="
    conan create "$recipe_dir/" --version="$version" \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        -s build_type="$build_type" \
        --build=missing --no-remote
    echo
}

build_zlib() {
    create_one zlib 1.3.0 Release
    create_one zlib 1.3.0 Debug
}

build_protobuf() {
    create_one protobuf 4.25.2 Release
    create_one protobuf 4.25.2 Debug
}

build_openssl() {
    create_one openssl-1x 1.1.11 Release
    create_one openssl-1x 1.1.11 Debug
}

build_grpc() {
    # Pulls abseil/20240116.2 + re2/20230301 + c-ares/1.25.0
    # automatically via grpc/conanfile.py's "elif >= 1.60.0" branch.
    create_one grpc 1.60.1 Release
    create_one grpc 1.60.1 Debug
}

pack_all() {
    echo "=========================================="
    echo "Deployer: упаковка legacy nupkg в $OUTPUT_DIR"
    echo "=========================================="
    # Pulling grpc/1.60.1 brings the entire legacy graph through
    # transitive requires (abseil/protobuf/openssl/re2/c-ares/zlib),
    # the deployer then packs each as its own legacy .nupkg.
    conan install \
        --requires=grpc/1.60.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE" --no-remote \
        --deployer=extensions/deployers/legacy_nupkg.py \
        --deployer-folder="$OUTPUT_DIR/"

    echo
    echo "=========================================="
    echo "Результат в $OUTPUT_DIR/"
    echo "=========================================="
    ls -lh "$OUTPUT_DIR/"*.nupkg 2>/dev/null || echo "    (пусто)"

    # Sanity-check: .nuspec в корне zip?
    echo
    echo "=== Sanity-check: .nuspec в корне у каждого pkg ==="
    for n in "$OUTPUT_DIR"/*.nupkg; do
        [ -f "$n" ] || continue
        local fname
        fname="$(basename "$n")"
        local nuspec_at_root
        nuspec_at_root=$(unzip -l "$n" 2>/dev/null | awk '{print $NF}' | grep -E '^[^/]+\.nuspec$' | head -1)
        if [ -n "$nuspec_at_root" ]; then
            echo "  OK    $fname (root nuspec: $nuspec_at_root)"
        else
            echo "  FAIL  $fname — .nuspec не в корне"
        fi
    done
}

cmd="${1:-all}"
case "$cmd" in
    all)
        build_zlib
        build_protobuf
        build_openssl
        build_grpc
        pack_all
        ;;
    zlib)
        build_zlib
        ;;
    protobuf)
        build_protobuf
        ;;
    openssl)
        build_openssl
        ;;
    grpc)
        build_grpc
        ;;
    pack)
        pack_all
        ;;
    *)
        echo "Usage: $0 [all|zlib|protobuf|openssl|grpc|pack]" >&2
        exit 1
        ;;
esac

echo
echo "[DONE] $cmd"
