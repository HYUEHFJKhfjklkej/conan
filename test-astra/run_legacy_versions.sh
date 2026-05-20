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
# Closed-network dev-VM / Astra-агент: ни docker.io, ни pypi.org недоступны.
# Поэтому ОБЕ ARG идут на один и тот же ProGet-образ:
#   Stage 1 (x64_native_tc) — из него копируется /usr/local/gcc-8.4/
#   Stage 2 (mirror)        — он же используется как база сборочной среды
# (он одновременно содержит Debian Stretch + GCC 8.4 + cmake + protoc + Qt).
PROGET_BASE="${PROGET_BASE:-proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0}"
X64_BASE_IMAGE="${X64_BASE_IMAGE:-$PROGET_BASE}"
BASE_IMAGE="${BASE_IMAGE:-$PROGET_BASE}"
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
        echo "[INFO] X64_BASE_IMAGE=$X64_BASE_IMAGE"
        echo "[INFO] BASE_IMAGE=$BASE_IMAGE"
        docker build \
            --build-arg X64_BASE_IMAGE="$X64_BASE_IMAGE" \
            --build-arg BASE_IMAGE="$BASE_IMAGE" \
            -f Dockerfile.grpc-tc-mirror \
            -t "$MIRROR_IMAGE" \
            .
    fi

    # Передаём cmd-line обратно нашему же скрипту внутри контейнера.
    # ВАЖНО: bind-mount всего репо (не только output-legacy) — иначе
    # контейнер использует копию скриптов из образа (та что была на
    # момент docker build), и git pull на host'е не отражается внутри.
    exec docker run --rm \
        -v "$ROOT_DIR:/work/conan-recipes" \
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

export_one() {
    local recipe_dir="$1"
    local version="$2"
    echo "[EXPORT] conan export $recipe_dir --version=$version"
    conan export "$recipe_dir/" --version="$version" --no-remote
}

# Auto-patch legacy/<pkg>/conanfile.py с тем что Elara legacy CMake требует.
# Идемпотентно — если patches уже на месте, не трогает.
AUTO_PATCH_DONE=0
auto_patch_legacy_recipes() {
    [ "$AUTO_PATCH_DONE" = "1" ] && return
    [ -d legacy ] || { AUTO_PATCH_DONE=1; return; }

    echo "=========================================="
    echo "Auto-patch legacy/<pkg>/conanfile.py"
    echo "=========================================="

    python3 - <<'PYAPPLY'
import re
import sys
from pathlib import Path

LEGACY = Path("legacy")
if not LEGACY.is_dir():
    sys.exit(0)

NEW_GENERATE = '''    def generate(self):
        tc = CMakeToolchain(self)
        # ---- Elara legacy CMake framework — verified from PlatformHelper.cmake source ----
        # Build-mode flags (CMakeCommon.cmake)
        tc.cache_variables["BUILD_RELEASE"] = "YES" if self.settings.build_type == "Release" else "NO"
        tc.cache_variables["PRERELEASE_SUFFIX"] = ""
        tc.cache_variables["SOURCE_REVISION"] = ""
        # PlatformHelper.cmake — exact variable names read by each helper:
        #   get_platform_prefix()  -> TARGET_PLATFORM  ("LINUX"/"WINDOWS"/"WINCE800")
        #   get_processor_prefix() -> TARGET_ARCH_CPU  ("X86_64" stays lowercase)
        #   get_library_prefix()   -> BUILD_SHARED_LIBS  (set by Conan toolchain from options.shared)
        #   get_compiler_prefix()  -> reads compiler via execute_process(g++ -dumpversion) -> "gcc84"
        tc.cache_variables["TARGET_PLATFORM"] = "LINUX"
        tc.cache_variables["TARGET_ARCH_CPU"] = "X86_64"
        tc.generate()'''

# Matches any existing generate() body so we can rewrite it idempotently
# every run (cmake-vars set evolves as we discover new Elara requirements).
OLD_GENERATE_RE = re.compile(
    r"^    def generate\(self\):\n"
    r"(?:        [^\n]*\n)*"
    r"        tc\.generate\(\)$",
    re.MULTILINE,
)

# Точный requirements() для legacy/grpc — весь Elara graph по
# internal-номенклатуре. Прочие legacy/<pkg> остаются без requirements()
# по умолчанию; если build падёт на missing dep — добавишь руками.
GRPC_REQUIREMENTS = '''    def requirements(self):
        # Whole Elara legacy graph (Bitbucket-fork internal nomenclature)
        self.requires("absl/0.2.0", transitive_headers=True, transitive_libs=True)
        self.requires("re2/0.2.0")
        self.requires("cares/1.19.0")
        self.requires("upb/0.2.0")
        self.requires("address_sorting/1.0.0")
        self.requires("protobuf/4.25.2", transitive_headers=True)
        self.requires("openssl/1.1.11")
        self.requires("zlib/1.3.0")

'''

# protobuf обычно тянет absl + zlib; openssl/zlib standalone.
EXTRA_REQS = {
    "protobuf": '''    def requirements(self):
        self.requires("absl/0.2.0", transitive_headers=True)
        self.requires("zlib/1.3.0")

''',
}

CONFIGURE_MARKER = "    def configure(self):"

changed = 0
skipped = 0
for cf in sorted(LEGACY.glob("*/conanfile.py")):
    pkg = cf.parent.name
    text = cf.read_text()
    original = text

    # 1) Patch generate() block if it's still the minimal template.
    if OLD_GENERATE_RE.search(text):
        text = OLD_GENERATE_RE.sub(NEW_GENERATE, text)

    # 2) Add requirements() if pkg needs one and it's not already there.
    extra = None
    if pkg == "grpc":
        extra = GRPC_REQUIREMENTS
    elif pkg in EXTRA_REQS:
        extra = EXTRA_REQS[pkg]
    if extra and "def requirements(self)" not in text:
        # Вставляем перед configure(), сохраняя отступ.
        if CONFIGURE_MARKER in text:
            text = text.replace(CONFIGURE_MARKER, extra + CONFIGURE_MARKER, 1)
        else:
            # Если configure() нет — вставляем перед generate()
            gen_marker = "    def generate(self):"
            text = text.replace(gen_marker, extra + gen_marker, 1)

    if text != original:
        cf.write_text(text)
        print(f"[PATCH] {cf}")
        changed += 1
    else:
        print(f"[OK]    {cf} (already patched / no template match)")
        skipped += 1

print(f"\n[INFO] auto-patch: changed={changed} skipped={skipped}")
PYAPPLY

    AUTO_PATCH_DONE=1
    echo
}

# Распаковывает первый найденный legacy/<pkg>/src/*.tar.gz и копирует
# cmake/PlatformHelper.cmake + cmake/InstallComponent.cmake + cmake/CMakeCommon.cmake
# в /work/conan-recipes/output/legacy-helpers/<pkg>/. Цель — host видит
# содержимое Elara cmake-хелперов и можно дальше править auto_patch по факту.
HELPERS_DUMPED=0
dump_legacy_helpers() {
    [ "$HELPERS_DUMPED" = "1" ] && return
    [ -d legacy ] || { HELPERS_DUMPED=1; return; }
    mkdir -p output/legacy-helpers
    echo "=========================================="
    echo "Dump cmake/ helpers from legacy/*/src/*.tar.gz to output/legacy-helpers/"
    echo "=========================================="
    for srcdir in legacy/*/src; do
        pkg=$(basename "$(dirname "$srcdir")")
        archive=$(ls -1 "$srcdir"/*.tar.gz 2>/dev/null | head -1)
        [ -n "$archive" ] || continue
        tmp=$(mktemp -d)
        tar -xzf "$archive" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; continue; }
        for f in PlatformHelper.cmake InstallComponent.cmake CMakeCommon.cmake; do
            found=$(find "$tmp" -name "$f" 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                mkdir -p "output/legacy-helpers/$pkg"
                cp "$found" "output/legacy-helpers/$pkg/$f"
                echo "  [dump] $pkg/$f"
            fi
        done
        rm -rf "$tmp"
    done
    echo "[INFO] helpers dumped to output/legacy-helpers/ — host visible via bind-mount"
    HELPERS_DUMPED=1
    echo
}

# Pre-export all legacy recipe versions into the local cache so that
# version ranges declared by upstream recipes (protobuf -> abseil range,
# grpc -> abseil/re2/c-ares ranges) can be resolved offline.
# Without this, --no-remote dies with "Package 'X/[range]' not resolved".
PREP_DONE=0
prep_recipes() {
    [ "$PREP_DONE" = "1" ] && return
    auto_patch_legacy_recipes
    dump_legacy_helpers
    echo "=========================================="
    echo "Step 0/N: Export all legacy recipes to local cache"
    echo "=========================================="
    # Все 9 рецептов из legacy/<pkg> — клоны Bitbucket-форков Elara,
    # созданы через test-astra/prepare_legacy_from_bitbucket.sh.
    # Каждый export только если директория существует — позволяет
    # запускать скрипт частично (например после прогона только
    # absl/re2/cares).
    [ -d legacy/absl ]            && export_one legacy/absl            0.2.0
    [ -d legacy/re2 ]             && export_one legacy/re2             0.2.0
    [ -d legacy/cares ]           && export_one legacy/cares           1.19.0
    [ -d legacy/upb ]             && export_one legacy/upb             0.2.0
    [ -d legacy/address_sorting ] && export_one legacy/address_sorting 1.0.0
    [ -d legacy/protobuf ]        && export_one legacy/protobuf        4.25.2
    [ -d legacy/openssl ]         && export_one legacy/openssl         1.1.11
    [ -d legacy/zlib ]            && export_one legacy/zlib            1.3.0
    [ -d legacy/grpc ]            && export_one legacy/grpc            1.60.1

    echo
    echo "[INFO] Recipes in local cache after prep:"
    conan list "*/*" --no-remote 2>/dev/null | grep -E "^[a-z]" | head -30 || true
    echo
    PREP_DONE=1
}

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
    prep_recipes
    create_one zlib 1.3.0 Release
    create_one zlib 1.3.0 Debug
}

build_protobuf() {
    prep_recipes
    create_one protobuf 4.25.2 Release
    create_one protobuf 4.25.2 Debug
}

build_openssl() {
    prep_recipes
    create_one openssl-1x 1.1.11 Release
    create_one openssl-1x 1.1.11 Debug
}

build_grpc() {
    prep_recipes
    # Pulls abseil/20240116.2 + re2/20230301 + c-ares/1.25.0
    # automatically via grpc/conanfile.py's "elif >= 1.60.0" branch.
    create_one grpc 1.60.1 Release
    create_one grpc 1.60.1 Debug
}

# Build legacy Elara forks (cloned via prepare_legacy_from_bitbucket.sh).
# Each builds in Release + Debug.
build_legacy_absl()            { prep_recipes; create_one legacy/absl            0.2.0  Release; create_one legacy/absl            0.2.0  Debug; }
build_legacy_re2()             { prep_recipes; create_one legacy/re2             0.2.0  Release; create_one legacy/re2             0.2.0  Debug; }
build_legacy_cares()           { prep_recipes; create_one legacy/cares           1.19.0 Release; create_one legacy/cares           1.19.0 Debug; }
build_legacy_upb()             { prep_recipes; create_one legacy/upb             0.2.0  Release; create_one legacy/upb             0.2.0  Debug; }
build_legacy_address_sorting() { prep_recipes; create_one legacy/address_sorting 1.0.0  Release; create_one legacy/address_sorting 1.0.0  Debug; }
build_legacy_protobuf()        { prep_recipes; create_one legacy/protobuf        4.25.2 Release; create_one legacy/protobuf        4.25.2 Debug; }
build_legacy_openssl()         { prep_recipes; create_one legacy/openssl         1.1.11 Release; create_one legacy/openssl         1.1.11 Debug; }
build_legacy_zlib()            { prep_recipes; create_one legacy/zlib            1.3.0  Release; create_one legacy/zlib            1.3.0  Debug; }
build_legacy_grpc()            { prep_recipes; create_one legacy/grpc            1.60.1 Release; create_one legacy/grpc            1.60.1 Debug; }

pack_deps() {
    prep_recipes
    echo "=========================================="
    echo "Deployer: упаковка legacy nupkg (6 deps без grpc) в $OUTPUT_DIR"
    echo "=========================================="
    # Без grpc/1.60.1 — он требует opencensus-proto skачать с интернета
    # (CMake `download_archive` срабатывает на gRPC <1.62, флаг
    # gRPC_DOWNLOAD_ARCHIVES не поддерживается). На offline-агенте
    # упрётся в timeout. См. отдельную задачу.
    # Эти 6 nupkg сами по себе разблокируют el_conf VersionChecker:
    # protobuf 4.25.2 + openssl 1.1.11 + zlib 1.3.0 закрывают конфликты,
    # abseil/re2/c-ares идут как транзитивы protobuf'a.
    conan install \
        --requires=protobuf/4.25.2 \
        --requires=openssl/1.1.11 \
        --requires=zlib/1.3.0 \
        --requires=abseil/20240116.2 \
        --requires=re2/20230301 \
        --requires=c-ares/1.25.0 \
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

pack_legacy_full() {
    prep_recipes
    echo "=========================================="
    echo "Deployer: full Elara-legacy pack via grpc/1.60.1 (Bitbucket fork)"
    echo "=========================================="
    # legacy/grpc 1.60.1 (с Bitbucket) объявляет в requirements()
    # весь Elara-стек: absl/0.2.0, re2/0.2.0, cares/1.19.0, upb/0.2.0,
    # address_sorting/1.0.0, protobuf/4.25.2, openssl/1.1.11, zlib/1.3.0.
    # Conan пройдёт по графу, deployer положит каждый в output-legacy/
    # под legacy-именем.
    conan install \
        --requires=grpc/1.60.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE" --no-remote \
        --deployer=extensions/deployers/legacy_nupkg.py \
        --deployer-folder="$OUTPUT_DIR/"

    echo
    echo "Output:"
    ls -lh "$OUTPUT_DIR/"*.nupkg 2>/dev/null || echo "    (пусто)"
}

cmd="${1:-all}"
case "$cmd" in
    all)
        # Default — собираем 3 upstream deps + pack без grpc 1.60.1.
        prep_recipes
        build_zlib
        build_protobuf
        build_openssl
        pack_deps
        ;;
    legacy-all)
        # Полный Elara-legacy стек (после prepare_legacy_from_bitbucket.sh):
        # все 9 пакетов из Bitbucket-форков + pack через grpc/1.60.1.
        prep_recipes
        build_legacy_zlib
        build_legacy_absl
        build_legacy_re2
        build_legacy_cares
        build_legacy_upb
        build_legacy_address_sorting
        build_legacy_openssl
        build_legacy_protobuf
        build_legacy_grpc
        pack_legacy_full
        ;;
    prep)
        prep_recipes
        ;;
    zlib)               build_zlib ;;
    protobuf)           build_protobuf ;;
    openssl)            build_openssl ;;
    grpc)               build_grpc ;;
    legacy-absl)        build_legacy_absl ;;
    legacy-re2)         build_legacy_re2 ;;
    legacy-cares)       build_legacy_cares ;;
    legacy-upb)         build_legacy_upb ;;
    legacy-address-sorting) build_legacy_address_sorting ;;
    legacy-zlib)        build_legacy_zlib ;;
    legacy-protobuf)    build_legacy_protobuf ;;
    legacy-openssl)     build_legacy_openssl ;;
    legacy-grpc)        build_legacy_grpc ;;
    pack|pack-deps)     pack_deps ;;
    pack-legacy-full)   pack_legacy_full ;;
    *)
        cat >&2 <<'USAGE'
Usage: $0 [command]

Commands:
  all                   3 upstream deps (zlib/protobuf/openssl) + pack 6 nupkg
  legacy-all            full Elara legacy stack (требует prepare_legacy_from_bitbucket.sh):
                          все 9 Bitbucket-форков + pack via legacy/grpc/1.60.1
  prep                  conan export всех recipes без сборки
  zlib | protobuf | openssl | grpc
                        собрать один upstream pkg (наши conan-recipes/)
  legacy-zlib | legacy-protobuf | legacy-openssl | legacy-grpc |
  legacy-absl | legacy-re2 | legacy-cares | legacy-upb |
  legacy-address-sorting
                        собрать один Elara Bitbucket-форк
  pack-deps             pack 6 nupkg без grpc
  pack-legacy-full      pack via legacy grpc/1.60.1 (все 9 nupkg)
USAGE
        exit 1
        ;;
esac

echo
echo "[DONE] $cmd"
