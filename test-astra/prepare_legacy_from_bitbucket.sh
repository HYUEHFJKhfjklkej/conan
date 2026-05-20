#!/bin/bash
#
# prepare_legacy_from_bitbucket.sh
#
# Клонирует Elara internal форки legacy-пакетов с bitbucket.inc.elara.local,
# упаковывает каждый в tarball под legacy/<pkg>/src/, генерирует тонкий
# Conan-рецепт (conanfile.py + conandata.yml). После прогона запускаешь
# обычный pipeline:
#
#     ./test-astra/run_legacy_versions.sh
#
# и Conan собирает каждый legacy pkg под именем, совместимым с GR113/120
# (`<pkg>.lin.gcc84.shared.x86_64.<ver>.nupkg`).
#
# Использование:
#   1. Подставь URL и tag/branch в массиве PACKAGES ниже.
#   2. Прокинь креды через env (не пиши их в скрипт!):
#         export BITBUCKET_USER=your.user
#         export BITBUCKET_PASS=your_app_password_or_personal_token
#   3. ./test-astra/prepare_legacy_from_bitbucket.sh
#
# Опции:
#   PKG_FILTER="absl re2"   ./test-astra/prepare_legacy_from_bitbucket.sh
#       — обработать только указанные пакеты.
#   FORCE_REGEN=1           ./test-astra/prepare_legacy_from_bitbucket.sh
#       — перегенерировать conanfile.py / conandata.yml даже если
#         они уже существуют (по умолчанию сохраняем ручные правки).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Конфигурация. Формат каждой строки:
#   "pkg_name|version|repo_url|branch_or_tag"
#
# pkg_name      — то имя что будет в Conan (и в выходном nupkg),
#                 должно совпадать с тем что el_conf пишет в _dependencies
#                 (absl, re2, cares, upb, address_sorting, grpc и т.д.).
# version       — Elara internal version (например 0.2.0 для absl).
# repo_url      — HTTPS URL Bitbucket-репозитория.
# branch_or_tag — опционально; если пусто или placeholder — берёт HEAD.
#
# Поставь <PROJECT>, <REPO>, <TAG> на свои значения — что не подставишь
# (останется placeholder), будет пропущено с пометкой SKIP.
# ---------------------------------------------------------------------------
PACKAGES=(
    "absl|0.2.0|https://bitbucket.inc.elara.local/scm/<PROJECT>/absl.git|<TAG_OR_BRANCH>"
    "re2|0.2.0|https://bitbucket.inc.elara.local/scm/<PROJECT>/re2.git|<TAG_OR_BRANCH>"
    "cares|1.19.0|https://bitbucket.inc.elara.local/scm/<PROJECT>/c-ares.git|<TAG_OR_BRANCH>"
    "upb|0.2.0|https://bitbucket.inc.elara.local/scm/<PROJECT>/upb.git|<TAG_OR_BRANCH>"
    "address_sorting|1.0.0|https://bitbucket.inc.elara.local/scm/<PROJECT>/address_sorting.git|<TAG_OR_BRANCH>"
    "grpc|1.60.1|https://bitbucket.inc.elara.local/scm/<PROJECT>/grpc.git|<TAG_OR_BRANCH>"
    "protobuf|4.25.2|https://bitbucket.inc.elara.local/scm/<PROJECT>/protobuf.git|<TAG_OR_BRANCH>"
    "openssl|1.1.11|https://bitbucket.inc.elara.local/scm/<PROJECT>/openssl.git|<TAG_OR_BRANCH>"
    "zlib|1.3.0|https://bitbucket.inc.elara.local/scm/<PROJECT>/zlib.git|<TAG_OR_BRANCH>"
)

# ---------------------------------------------------------------------------
# Креды через env (не зашиваем в скрипт)
# ---------------------------------------------------------------------------
BITBUCKET_USER="${BITBUCKET_USER:-}"
BITBUCKET_PASS="${BITBUCKET_PASS:-}"

if [ -z "$BITBUCKET_USER" ] || [ -z "$BITBUCKET_PASS" ]; then
    cat >&2 <<'EOM'
ERROR: BITBUCKET_USER и BITBUCKET_PASS должны быть установлены.

    export BITBUCKET_USER=your.user
    export BITBUCKET_PASS=your_app_password_or_personal_token
    ./test-astra/prepare_legacy_from_bitbucket.sh

Bitbucket обычно требует App Password (Server) или Personal Access Token
(Cloud) — обычный логин-пароль может не подойти. Спроси админа если нет.
EOM
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY_DIR="$ROOT_DIR/legacy"
CLONE_TMP="${CLONE_TMP:-/tmp/legacy-clone}"
PKG_FILTER="${PKG_FILTER:-}"
FORCE_REGEN="${FORCE_REGEN:-0}"

mkdir -p "$LEGACY_DIR" "$CLONE_TMP"

# URL-encode credentials so $ / @ / etc в пароле не ломают URL.
url_encode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}
encoded_user=$(url_encode "$BITBUCKET_USER")
encoded_pass=$(url_encode "$BITBUCKET_PASS")

# Сгенерировать имя класса PascalCase из snake_case имени.
class_name_for() {
    python3 -c "import sys; print(''.join(s.capitalize() for s in sys.argv[1].replace('-','_').split('_')))" "$1"
}

# ---------------------------------------------------------------------------
# Шаблон conanfile.py: тонкая обёртка над Elara CMakeLists.
# Если у конкретного pkg у Elara нестандартный build (autotools, custom
# install layout) — после прогона скрипта откорректируй вручную.
# ---------------------------------------------------------------------------
write_conanfile() {
    local pkg="$1"
    local dst_file="$2"
    local class_name
    class_name=$(class_name_for "$pkg")

    cat > "$dst_file" <<EOF
"""Thin Conan wrapper for the Elara legacy '$pkg' package.

Source comes from a bundled tarball under src/, populated by
test-astra/prepare_legacy_from_bitbucket.sh from the Elara Bitbucket
fork. The recipe just lets Conan drive the existing CMakeLists and
produce a package whose name/version match the legacy GR113/120
nupkg scheme — so el_conf and other consumers see a drop-in
replacement in their _dependencies.

If Elara's build is not pure CMake (autotools, custom Makefile, etc.)
adjust build() / package() below accordingly.
"""
import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get, unzip


class ${class_name}Conan(ConanFile):
    name = "$pkg"
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
    }

    # Bundled tarball ships inside the recipe so closed-network agents
    # never need internet at conan create time.
    exports_sources = "src/*.tar.gz"

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")
        # If Elara legacy is pure C — keep these. For C++ pkgs comment out.
        self.settings.rm_safe("compiler.libcxx")
        self.settings.rm_safe("compiler.cppstd")

    def layout(self):
        cmake_layout(self, src_folder="src")

    def source(self):
        local = os.path.join(
            self.export_sources_folder, "src",
            f"{self.name}-{self.version}.tar.gz",
        )
        if os.path.exists(local):
            unzip(self, local, destination=self.source_folder, strip_root=True)
            return
        sources = self.conan_data.get("sources", {}).get(str(self.version), {})
        if sources and sources.get("url"):
            get(self, **sources, strip_root=True)
            return
        raise RuntimeError(
            f"No bundled src/{self.name}-{self.version}.tar.gz and no "
            "URL in conandata.yml. Run "
            "./test-astra/prepare_legacy_from_bitbucket.sh first."
        )

    def generate(self):
        tc = CMakeToolchain(self)
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        # Default: один target с тем же именем что и pkg.
        # Если у Elara CMakeLists экспортирует несколько компонентов
        # (libabsl_strings, libabsl_log и т.д.) — раскрой здесь явно.
        self.cpp_info.libs = ["$pkg"]
EOF
}

# Простой conandata.yml — версия бандлится локально, URL/sha256 пустые
# (на случай если кто-то захочет fallback к скачиванию).
write_conandata() {
    local ver="$1"
    local dst_file="$2"

    cat > "$dst_file" <<EOF
# Auto-generated by prepare_legacy_from_bitbucket.sh.
# Source bundled offline as src/<pkg>-<ver>.tar.gz; conanfile.py prefers
# the local file. URL kept as documentation of upstream origin.
sources:
  "$ver":
    url: ""
    sha256: ""
EOF
}

# ---------------------------------------------------------------------------
# Основной цикл
# ---------------------------------------------------------------------------
success=()
skipped=()
failed=()

for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg ver url ref <<< "$entry"

    # Фильтр через env
    if [ -n "$PKG_FILTER" ]; then
        case " $PKG_FILTER " in
            *" $pkg "*) ;;
            *) continue ;;
        esac
    fi

    if [[ "$url" == *"<PROJECT>"* ]] || [ -z "$url" ]; then
        echo "[SKIP] $pkg:$ver — placeholder URL не заполнен"
        skipped+=("$pkg")
        continue
    fi

    echo
    echo "============================================="
    echo "Processing $pkg:$ver"
    echo "URL: $url"
    echo "Ref: ${ref:-<HEAD>}"
    echo "============================================="

    pkg_dir="$LEGACY_DIR/$pkg"
    src_dir="$pkg_dir/src"
    mkdir -p "$src_dir"

    clone_dir="$CLONE_TMP/$pkg"
    rm -rf "$clone_dir"

    auth_url="${url/https:\/\//https://${encoded_user}:${encoded_pass}@}"

    branch_args=()
    if [ -n "$ref" ] && [[ "$ref" != *"<"*">"* ]]; then
        branch_args=(--branch "$ref")
    fi

    if ! git clone --depth=1 "${branch_args[@]}" "$auth_url" "$clone_dir" 2>&1 \
            | sed "s|${encoded_pass}|***|g; s|${encoded_user}|<user>|g"; then
        echo "[FAIL] git clone failed for $pkg"
        failed+=("$pkg")
        continue
    fi

    archive="$src_dir/$pkg-$ver.tar.gz"
    # Упаковываем содержимое clone_dir (без .git) с префиксом <pkg>-<ver>/
    (cd "$clone_dir" && tar czf "$archive" \
         --exclude='./.git' \
         --transform "s,^\.,$pkg-$ver," \
         .)
    archive_size=$(du -h "$archive" | cut -f1)
    echo "[OK] archive: $archive ($archive_size)"

    # conanfile.py — генерируем только если нет (либо FORCE_REGEN=1)
    if [ ! -f "$pkg_dir/conanfile.py" ] || [ "$FORCE_REGEN" = "1" ]; then
        write_conanfile "$pkg" "$pkg_dir/conanfile.py"
        echo "[OK] generated $pkg_dir/conanfile.py"
    else
        echo "[KEEP] $pkg_dir/conanfile.py существует (FORCE_REGEN=1 чтобы пересоздать)"
    fi

    # conandata.yml — тоже
    if [ ! -f "$pkg_dir/conandata.yml" ] || [ "$FORCE_REGEN" = "1" ]; then
        write_conandata "$ver" "$pkg_dir/conandata.yml"
    fi

    rm -rf "$clone_dir"
    success+=("$pkg:$ver")
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "============================================="
echo "Summary"
echo "============================================="
[ ${#success[@]} -gt 0 ] && printf "  OK:      %s\n" "${success[@]}"
[ ${#skipped[@]} -gt 0 ] && printf "  SKIP:    %s\n" "${skipped[@]}"
[ ${#failed[@]} -gt 0 ] && printf "  FAIL:    %s\n" "${failed[@]}"
echo

if [ ${#success[@]} -gt 0 ]; then
    cat <<EOM
Next steps:
  1. Проверь сгенерированные рецепты:
     ls -la $LEGACY_DIR/*/
  2. Если у какого-то пакета Elara CMakeLists нестандартный (autotools,
     custom layout) — поправь legacy/<pkg>/conanfile.py вручную.
  3. Добавь в test-astra/run_legacy_versions.sh export_one / create_one
     для каждого нового pkg (legacy/<pkg> recipe directory).
  4. ./test-astra/run_legacy_versions.sh
EOM
fi

[ ${#failed[@]} -gt 0 ] && exit 1
exit 0
