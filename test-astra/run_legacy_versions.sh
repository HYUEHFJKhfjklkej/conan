#!/bin/bash
#
# run_legacy_versions.sh
# Сборка legacy-версий transitive deps через Conan + упаковка в legacy nupkg.
#
# Версии: zlib 1.3.0, protobuf 4.25.2, openssl 1.1.11 (= openssl 1.1.1w upstream).
# Все три — drop-in replacement для соответствующих legacy nupkg в ProGet
# (используются mosquitto, gsd_parser, sura_proto и т.д.).
#
# Использование:
#   ./test-astra/run_legacy_versions.sh                 # Release + Debug всё
#   ./test-astra/run_legacy_versions.sh zlib            # только zlib
#   ./test-astra/run_legacy_versions.sh protobuf        # только protobuf
#   ./test-astra/run_legacy_versions.sh openssl         # только openssl
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
mkdir -p "$OUTPUT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan не найден в PATH. Активируй venv:"
    echo "    source $ROOT_DIR/venv/bin/activate"
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

pack_all() {
    echo "=========================================="
    echo "Deployer: упаковка legacy nupkg в $OUTPUT_DIR"
    echo "=========================================="
    conan install \
        --requires=zlib/1.3.0 \
        --requires=protobuf/4.25.2 \
        --requires=openssl/1.1.11 \
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
    pack)
        pack_all
        ;;
    *)
        echo "Usage: $0 [all|zlib|protobuf|openssl|pack]" >&2
        exit 1
        ;;
esac

echo
echo "[DONE] $cmd"
