"""
Conan deployer: упаковка зависимостей в legacy NuGet-формат TeamCity.

Использование:
    conan install --requires=gtest/1.15.2 \
        --profile=astra-gcc \
        --deployer=legacy_nupkg \
        --deployer-folder=output/

Для каждого dependency из install-графа находит в кеше Release- и Debug-варианты
(по settings.build_type), генерит .targets/.nuspec/CMakeLists.var, кладёт бинари и
заголовки, упаковывает в .nupkg.
"""
import glob
import json
import os
import shutil
import subprocess
import zipfile


# Маппинг имён Conan → legacy
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    # Подменяем наш upstream-сборку `abseil` на legacy Elara-слот `absl`, чтобы
    # downstream (exceptions/googletest, завязанные на `absl:0.2.0`) брал upstream-
    # бинари — в них есть недостающие `cord`-компоненты.
    "abseil": "absl",
    # Conan-рецепт зовётся `c-ares` (имя conan-center), но legacy Elara-слот —
    # `cares`, без дефиса. Важно: downstream ResolveDependencies.cmake генерит
    # `add_definitions(-D${_name}_..._DEFINE)` БЕЗ sanitize имени пакета (на `_`
    # меняется только имя компонента). Дефис здесь даёт битый флаг
    # `-Dc-ares_..._DEFINE` -> `<command-line>: expected ',' or '...' before '-' token`.
    "c-ares": "cares",
}

# Имя dep для записей `${project_name}_dependencies` в чужом CMakeLists.var:
# сначала этот map, иначе LEGACY_NAME_MAP, иначе Conan-имя.
LEGACY_DEP_NAME_MAP = {
}

# Переопределяет версию в имени .nupkg, в .nuspec <version> и в каждой записи
# _dependencies, ссылающейся на пакет. Conan-кеш по-прежнему ключуется реальной
# upstream-версией (`20240116.2`); меняется только то, что объявляет артефакт.
LEGACY_DEP_VERSION_MAP = {
    # Выдаём наш abseil/20240116.2 за absl/0.2.0, чтобы он встал как более высокая
    # версия (с суффиксом .1), чем legacy `absl/0.2.0` уже в ProGet, и победил в
    # downstream ResolveDependencies.
    "abseil": "0.2.0",
}

# Суффикс версии для каждого .nupkg + nuspec + записи _dependencies, из env
# LEGACY_NUPKG_VERSION_SUFFIX. Нужен при заливке upstream-mirror артефактов в
# ProGet-feed, где те же версии уже есть из другого источника (Bitbucket-форки):
# суффикс разводит их без переименования пакетов. Примеры: ".1", "-elara1".
# По умолчанию пусто → поведение не меняется.
VERSION_SUFFIX = os.environ.get("LEGACY_NUPKG_VERSION_SUFFIX", "")

# Маппинг ОС: Conan settings.os → legacy os-короткое
OS_SHORT = {"Linux": "lin", "Windows": "win", "Macos": "mac"}

# Короткое имя arch зависит от ОС — выведено из реальных имён CI-артефактов в
# TeamCity (см. photo_index.md, photo_2026-04-27_17-31-50.jpg):
#   googletest.lin.gcc84.shared.x86_64.1.15.2.nupkg          (Linux: полный arch)
#   googletest.lin.gcc84.shared.i686.1.15.2.nupkg            (Linux: x86 → i686)
#   googletest.lin.gcc75.shared.arm-linaro.1.15.2.nupkg      (Linux: armv7hf → arm)
#   googletest.lin.gcc75.shared.arm64-linaro.1.15.2.nupkg    (Linux: armv8   → arm64)
#   googletest.win.v142.shared.x64.1.15.2.nupkg              (Windows: x86_64 → x64)
#   googletest.win.v142.shared.x86.1.15.2.nupkg              (Windows: x86)
ARCH_SHORT_LINUX   = {"x86_64": "x86_64", "x86": "i686", "armv7hf": "arm", "armv8": "arm64"}
ARCH_SHORT_WINDOWS = {"x86_64": "x64",    "x86": "x86"}


def _arch_short(arch, os_name):
    arch = str(arch)
    if os_name == "Windows":
        return ARCH_SHORT_WINDOWS.get(arch, arch)
    return ARCH_SHORT_LINUX.get(arch, arch)

KEEPDIR_CONTENT = (
    "#\n"
    "# *** IMPORTANT NOTE ***\n"
    "#\n"
    "# Please, do not delete this file. This file is used for keeping empty directories.\n"
    "#\n"
)


def _short_compiler(compiler, version):
    """(compiler, version) → короткая CI-форма.

    Реальные имена CI-артефактов из TeamCity (см. photo_index.md):
      gcc 8   → 'gcc8'    (abseil.lin.gcc8.static.x86_64.20250127.0.nupkg)
      gcc 8.4 → 'gcc84'   (googletest.lin.gcc84.shared.x86_64.1.15.2.nupkg)
      gcc 7.5 → 'gcc75'   (googletest.lin.gcc75.shared.arm-linaro.1.15.2.nupkg)
      gcc 9.3 → 'gcc93'   (googletest.lin.gcc93.shared.x64-e3300.1.15.2.nupkg)
      msvc 142 → 'v142'   (googletest.win.v142.shared.x64.1.15.2.nupkg)

    Astra обрабатывается отдельно — см. _resolve_os_short(): её артефакт
    (googletest.astra.gcc.static.x86_64) вообще без версии gcc. Включается
    через env LEGACY_OS_SHORT=astra.
    """
    if compiler == "msvc":
        # Conan msvc compiler.version — версия КОМПИЛЯТОРА (192/193/194...),
        # а легаси-слот в имени .nupkg — VS TOOLSET (v142/v143), см. эталон
        # googletest.win.v142.shared.x64 выше. Без маппинга уезжает 'v194',
        # которого ни один легаси-резолвер не найдёт.
        _MSVC_TOOLSET = {
            "190": "v140", "191": "v141", "192": "v142",
            "193": "v143", "194": "v143",
        }
        return _MSVC_TOOLSET.get(str(version), f"v{version}")
    ver = str(version).replace(".", "").replace("_", "")
    if compiler == "gcc":
        return f"gcc{ver}" if ver else "gcc"
    return f"{compiler}{ver}"


def _resolve_os_short(os_name):
    """Короткое имя ОС с возможностью env-override для Astra (и подобных).

    Conan не отличает AstraLinux от обычного Linux, поэтому orchestrator-скрипт
    (test_all_profiles.sh) ставит LEGACY_OS_SHORT=astra при сборке профилем
    astra-gcc. Без override — обычный маппинг Linux/Windows/Macos.
    """
    override = os.environ.get("LEGACY_OS_SHORT", "").strip().lower()
    if override:
        return override
    return OS_SHORT.get(os_name, os_name.lower())


def _resolve_arch_with_toolchain(arch, os_name):
    """Добавляет суффикс '-linaro', когда user_toolchain указывает на Linaro
    cmake-файл — как в CI-именах cross-сборок:
      googletest.lin.gcc75.shared.arm-linaro.1.15.2.nupkg
      googletest.lin.gcc75.shared.arm64-linaro.1.15.2.nupkg
    Определяется по env CONAN_USER_TOOLCHAIN (ставит orchestrator-скрипт
    под каждую arch), так что нативные x86_64/i686 не затрагиваются.
    """
    base = _arch_short(arch, os_name)
    user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "")
    if user_tc and "linaro" in user_tc.lower():
        return f"{base}-linaro"
    return base


def _find_debug_package_path(name, version):
    """Найти Debug-вариант пакета в локальном кеше."""
    result = subprocess.run(
        ["conan", "list", f"{name}/{version}:*", "--format=json"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return None
    data = json.loads(result.stdout)
    for cache_name, refs in data.items():
        for ref, ref_data in refs.items():
            for rev_id, rev_data in ref_data.get("revisions", {}).items():
                for pkg_id, pkg_data in rev_data.get("packages", {}).items():
                    if pkg_data.get("info", {}).get("settings", {}).get("build_type") == "Debug":
                        path_result = subprocess.run(
                            ["conan", "cache", "path", f"{name}/{version}:{pkg_id}"],
                            capture_output=True, text=True
                        )
                        if path_result.returncode == 0:
                            return path_result.stdout.strip()
    return None


def _generate_targets(legacy_name, os_short, compiler_short, linkage, arch, libs):
    lib_suffix = f"{os_short}-{compiler_short}-{linkage}-{arch}"
    lib_deps = ";".join(f"{lib}.lib" for lib in libs) + ";%(AdditionalDependencies)"
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<Project ToolsVersion="14.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003" >',
        '    <ItemDefinitionGroup>',
        '        <ClCompile>',
        '            <AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)..\\..\\include\\;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>',
        '        </ClCompile>',
        '        <Link>',
        f'            <AdditionalDependencies>{lib_deps}</AdditionalDependencies>',
        '        </Link>',
        '    </ItemDefinitionGroup>',
        '',
    ]
    for cfg in ("Debug", "Release"):
        suffix = "-d" if cfg == "Debug" else ""
        lines += [
            f'    <ItemDefinitionGroup Condition="\'$(Configuration)\' == \'{cfg}\' And \'$(Platform)\' == \'\'">',
            '        <Link>',
            f'            <AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)..\\..\\lib\\native\\{lib_suffix}{suffix}\\;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>',
            '        </Link>',
            '    </ItemDefinitionGroup>',
            f'    <ItemGroup Condition="\'$(Configuration)\' == \'{cfg}\' And \'$(Platform)\' == \'\'">',
            f'        <Content Include="$(MSBuildThisFileDirectory)..\\..\\lib\\native\\{lib_suffix}{suffix}\\*.dll">',
            '            <CopyToOutputDirectory>Always</CopyToOutputDirectory>',
            '        </Content>',
            '    </ItemGroup>',
            '',
        ]
    lines.append('</Project>')
    return "\n".join(lines)


def _generate_nuspec(legacy_name, version, os_short, compiler_short, linkage, arch, deps):
    pkg_id = f"{legacy_name}.{os_short}.{compiler_short}.{linkage}.{arch}"
    lines = [
        '<?xml version="1.0"?>',
        '<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">',
        '    <metadata>',
        f'        <id>{pkg_id}</id>',
        f'        <version>{version}</version>',
        '        <copyright>Copyright (c) 2018</copyright>',
        '        <summary>Insert summary here!</summary>',
        '        <description>Insert description here!</description>',
        '        <owners>Insert owners here!</owners>',
        '        <authors>Insert authors here!</authors>',
        '        <dependencies>',
        '            <group>',
    ]
    for dep_name, dep_ver in deps:
        dep_id = f"{dep_name}.{os_short}.{compiler_short}.{linkage}.{arch}"
        lines.append(f'                <dependency id="{dep_id}" version="{dep_ver}" />')
    lines += [
        '            </group>',
        '        </dependencies>',
        '    </metadata>',
        '    <files>',
        '        <file src="lib\\**" target="lib"/>',
        '        <file src="include\\**" target="include" />',
        '        <file src="build\\**" target="build" />',
        '        <file src="proto\\**" target="proto" />',
        '        <file src="CMakeLists.var" target=""/>',
        '        <file src="LICENSE.txt" target=""/>',
        '    </files>',
        '</package>',
    ]
    return "\n".join(lines)


def _generate_cmakelists_var(legacy_name, version, components, platforms, deps=None):
    deps = deps or []
    parts = version.split(".")
    major, minor, patch = (parts + ["0", "0", "0"])[:3]
    lines = ["#" * 67, "#", "# Project Name (Unique project name)", "#",
             f"set(project_name {legacy_name})", ""]
    lines += ["#", "# Project Version", "#",
              f"set(${{project_name}}_major {major})",
              f"set(${{project_name}}_minor {minor})",
              f"set(${{project_name}}_patch {patch})",
              'set(${project_name}_prerelease_suffix "-alpha")', ""]
    lines += ["#", "# List of components included in the project.", "#",
              "set(components"]
    for c in components:
        lines.append(f"    {c}")
    lines += ["    )", ""]
    lines += ["#", "# List of platforms supported by each component.", "#"]
    for c in components:
        lines.append(f"set({c}")
        for p in platforms:
            lines.append(f"    {p}")
        lines += ["    )", ""]
    lines += ["#", "# List of test components included in the project.", "#",
              "set(test_components", "    )", ""]
    lines += ["#", "# Definitions for all components in project.", "#",
              "set(${project_name}_definitions", "    )", ""]
    lines += ["#", "# List of dependencies on other projects.", "#",
              "set(${project_name}_dependencies"]
    for d in deps:
        lines.append(f"    {d}")
    lines += ["    )", ""]
    return "\n".join(lines)


def _is_lib_file(fname):
    """Распознаёт static/shared/import-библиотеки, включая версионированные .so
    (libfoo.so.0.1.2). Простая проверка расширения их теряет, т.к.
    `'libfoo.so.0.1.2'.split('.')[-1]` == '2'."""
    # Static + Windows-import + macOS dylib + голые .so / .dll.
    if fname.endswith((".a", ".lib", ".dll", ".dylib", ".so")):
        return True
    # Версионированный ELF .so: libfoo.so.0, libfoo.so.0.1.2 и т.п.
    if ".so." in fname:
        return True
    return False


# Алиасы для библиотек, чьё upstream-имя ('libz.so') не совпадает с legacy-именем
# пакета ('zlib'). Downstream Elara CMake-фреймворк генерит `-l<pkg_name>` в
# линковке, поэтому либа должна существовать и под этим именем. Делаются как
# доп. симлинки рядом с оригиналами (оригиналы остаются, чтобы `-lz` тоже работал).
LIB_FILENAME_ALIASES = {
    "zlib": {"z": "zlib"},     # libz.so       -> libzlib.so       (симлинк)
                                # libz.so.1.3.0 -> libzlib.so.1.3.0
    # Elara-форк protobuf выделяет upstream `libprotoc.so` (compiler-либа с
    # CommandLineInterface, парсерами, кодогенераторами) в отдельную
    # `libprotolib.a`. Downstream (profibus_dp_ui_plugin и др.) линкуют
    # `-lprotolib` напрямую. Мы поставляем тот же код как `libprotoc.so`; алиас
    # создаёт симлинк `libprotolib.so` -> `libprotoc.so`, чтобы legacy-имя
    # резолвилось без правки кода потребителей. Проверено на IN-658 el_conf 2026-05-26.
    "protobuf": {"protoc": "protolib"},
}

# Пакеты, чьи либы имеют префикс в имени, который downstream Elara CMake-фреймворк
# НЕ использует — срезаем префикс алиас-симлинком. Пример: upstream abseil даёт
# `libabsl_strings.so`, а legacy-слот `absl/0.2.0` — `libstrings.so`; downstream-
# резолвер генерит `-lstrings`, поэтому делаем такой симлинк рядом с оригиналом.
LIB_FILENAME_PREFIX_STRIP = {
    "abseil": "absl_",          # libabsl_<X>.so -> lib<X>.so
}

# abseil деплоится иначе остальных — см. abseil/conanfile.py. Elara CMake-фреймворк
# ждёт abseil как 21 крупный component-либ (`-lstrings`, `-lrandom`, ... — по одному
# на absl/<subdir>/), как в legacy-слоте `absl/0.2.0`. abseil/conanfile.py
# агрегирует их в `lib/legacy-coarse/`; нативные ~150 мелких либ остаются в `lib/`
# для Conan-потребителей. Для abseil deployer упаковывает именно крупный набор.
LEGACY_LIBDIR_OVERRIDE = {"abseil": "legacy-coarse"}

# Все legacy-артефакты Elara несут slot-тег `.shared.<arch>.` — это DynamicRT-слот
# рантайма в legacy CI-именовании (на TeamCity в паре с GR113). Содержимое всегда
# статические `.a`; тег лишь выбирает, какой runtime-CRT слот читает downstream-
# резолвер (ResolveDependencies.cmake / FindInstalledPackage.cmake в el_conf,
# grpc_sdk, sura). Override через env `LEGACY_NUPKG_LINKAGE=static` для StaticRT-
# слота (аналог GR121 — IN-658 его сейчас не использует).
#
# Per-package оверрайды лежат в LEGACY_LINKAGE_OVERRIDE для исторических исключений;
# сегодня все пакеты → "shared", поэтому словарь пуст.
LEGACY_LINKAGE_OVERRIDE = {}


def _add_lib_aliases(dst, pkg_name):
    """Создаёт алиас-симлинки рядом с реальными библиотеками. Два механизма:
    1. LIB_FILENAME_ALIASES — явное переименование base→alias на пакет.
    2. LIB_FILENAME_PREFIX_STRIP — срезать известный префикс из имени каждой либы.
    Оригиналы не трогаются, чтобы оба варианта именования работали."""
    if not os.path.isdir(dst):
        return
    aliases = LIB_FILENAME_ALIASES.get(pkg_name)
    if aliases:
        for fname in list(os.listdir(dst)):
            if not fname.startswith("lib"):
                continue
            stem_and_ext = fname[3:]  # срезаем 'lib'
            for base, alias in aliases.items():
                if stem_and_ext == base or stem_and_ext.startswith(base + "."):
                    new_fname = "lib" + alias + stem_and_ext[len(base):]
                    if new_fname == fname:
                        continue
                    new_path = os.path.join(dst, new_fname)
                    if os.path.islink(new_path) or os.path.exists(new_path):
                        os.unlink(new_path)
                    os.symlink(fname, new_path)
                    break
    prefix = LIB_FILENAME_PREFIX_STRIP.get(pkg_name)
    if prefix:
        marker = "lib" + prefix
        for fname in list(os.listdir(dst)):
            if not fname.startswith(marker):
                continue
            new_fname = "lib" + fname[len(marker):]
            if new_fname == fname:
                continue
            new_path = os.path.join(dst, new_fname)
            if os.path.islink(new_path) or os.path.exists(new_path):
                os.unlink(new_path)
            os.symlink(fname, new_path)


def _copy_libs(src_lib, dst, pkg_name=None):
    if not os.path.isdir(src_lib):
        # Всё равно создаём dst, чтобы пустую `-d/` сохранила downstream-логика
        # `.keepdir` — legacy CMake-фреймворк ждёт существования каталога даже
        # если Debug-либ нет.
        os.makedirs(dst, exist_ok=True)
        return 0
    n = 0
    os.makedirs(dst, exist_ok=True)
    for f in os.listdir(src_lib):
        sf = os.path.join(src_lib, f)
        # Сохраняем симлинки, не разыменовывая: libfoo.so -> libfoo.so.X.Y.Z
        # должен остаться ссылкой внутри .nupkg.
        if os.path.islink(sf) and _is_lib_file(f):
            link_target = os.readlink(sf)
            link_path = os.path.join(dst, f)
            if os.path.islink(link_path) or os.path.exists(link_path):
                os.unlink(link_path)
            os.symlink(link_target, link_path)
            n += 1
        elif os.path.isfile(sf) and _is_lib_file(f):
            shutil.copy2(sf, os.path.join(dst, f))
            n += 1
    if pkg_name:
        _add_lib_aliases(dst, pkg_name)
    return n


def _list_libs(src_lib):
    """Получить «голые» имена библиотек: libgtest.a → gtest."""
    if not os.path.isdir(src_lib):
        return []
    names = set()
    for f in os.listdir(src_lib):
        ext = f.rsplit(".", 1)[-1] if "." in f else ""
        if ext not in ("a", "lib", "so", "dll", "dylib"):
            continue
        base = f.rsplit(".", 1)[0]
        if base.startswith("lib"):
            base = base[3:]
        names.add(base)
    return sorted(names)


def _legacy_component_names(libs, pkg_name):
    """Преобразует сырые basename'ы либ (из _list_libs, напр. 'z', 'absl_strings')
    в имена, которые downstream Elara-фреймворк ждёт в списке `components`
    CMakeLists.var.

    Должно зеркалить переименование ФАЙЛОВ из _add_lib_aliases — иначе
    ResolveDependencies.cmake (foreach по `components`, ~строка 306) создаст
    IMPORTED-таргет под UPSTREAM-именем ('z'), а потребители линкуют LEGACY-имя
    ('zlib'). CMake тогда сводит неизвестное имя к голому флагу -> `ld: cannot
    find -lzlib`.
    """
    aliases = LIB_FILENAME_ALIASES.get(pkg_name, {})
    prefix = LIB_FILENAME_PREFIX_STRIP.get(pkg_name)
    out = []
    for lib in libs:
        if lib in aliases:
            # Эмитим И алиас, И оригинал — потребители могут пинить любое имя
            # (напр. для protobuf одни пинят `protoc`, другие `protolib`; оба
            # должны резолвиться). Файл-алиас — симлинк на оригинал (см.
            # _add_lib_aliases), так что оба find_library() сработают.
            out.append(aliases[lib])
            out.append(lib)
        elif prefix and lib.startswith(prefix):
            out.append(lib[len(prefix):])
        else:
            out.append(lib)
    # Dedup с сохранением порядка вставки (фреймворк идёт по `components` по
    # порядку; на корректность не влияет, но CMakeLists.var чище).
    seen = set()
    return [x for x in out if not (x in seen or seen.add(x))]


# Build-tool исполняемые, которые пакет кладёт в lib/native/<variant>/ (как legacy
# TeamCity-пакеты). Лежат в bin/ Conan-пакета; deployer копирует их рядом с либами
# И перечисляет как components, чтобы find_program Elara-фреймворка
# (GenerateGrpcCpp.cmake) нашёл версионно-совпадающие protoc / grpc_cpp_plugin, а не
# свалился на системные другой версии (системный protoc ->
# `google/protobuf/runtime_version.h` not found; системный grpc_cpp_plugin ->
# неверный gRPC ABI). Проверено end-to-end на el_conf, 2026-06-02.
LEGACY_BIN_TOOLS = {
    "grpc": ("grpc_cpp_plugin",),
    "protobuf": ("protoc",),
}


def _target_binutils_prefix(arch, user_toolchain):
    """Binutils-префикс для линкера *цели*. Пусто для нативных x86_64/i686.

    Для Linaro ARM cross-сборок deployer обязан использовать cross `ld`, чтобы
    слить ARM relocatable-объекты (хостовый `ld` отвергает чужой EM_ARM/EM_AARCH64).
    Определяется как в _resolve_arch_with_toolchain: Linaro user_toolchain в conf
    означает ARM cross-прогон.
    """
    a = str(arch)
    if "linaro" in (user_toolchain or "").lower():
        if a in ("armv7", "armv7hf", "armv7s"):
            return "arm-linux-gnueabihf-"
        if a in ("armv8", "armv8_32", "armv8.3", "arm64ec"):
            return "aarch64-linux-gnu-"
    return ""


def _resolve_cross_ld(ld_name):
    """Абсолютный путь к (cross-)ld. На deploy-шаге `[buildenv]` профиля не
    активен, поэтому голое `arm-linux-gnueabihf-ld` не находится на PATH —
    ищем явно: уже абсолютный → PATH → установка Linaro в /opt. Если не нашли,
    возвращаем имя как есть (subprocess даст понятный FileNotFoundError)."""
    if os.path.sep in ld_name and os.path.isfile(ld_name):
        return ld_name
    found = shutil.which(ld_name)
    if found:
        return found
    for cand in sorted(glob.glob(f"/opt/linaro-*/*/bin/{ld_name}")):
        if os.path.isfile(cand):
            return cand
    return ld_name


def _fold_upb_into_libgrpc(lib_dir, ld_cmd, output=None):
    """Сливает отдельные архивы grpc `libupb*.a` в `libgrpc.a`, затем заменяет их
    одной ПУСТОЙ заглушкой `libupb.a` — так пакет несёт САМОДОСТАТОЧНУЮ `libgrpc.a`
    ПЛЮС no-op компонент `upb`, байт-структурно как legacy TeamCity grpc-пакет
    (он вшивал upb внутрь и выставлял лишь крошечную заглушку upb).

    Зачем fold (доказано end-to-end на dev-astra18-13, 2026-06-02): legacy Elara-
    фреймворк (`ResolveDependencies.cmake`) flat-линкует каждый компонент-`.a` без
    графа зависимостей / порядка линковки. Upstream grpc дробит upb на
    пересекающиеся per-feature архивы (`libupb_json_lib.a`, ...), и пакет также
    несёт ~8KB заглушку `libupb.a`. Flat-потребитель тогда:
      - линкует заглушку libupb.a -> `undefined reference to upb_Encode/...`, либо
      - линкует реальные upb-либы  -> `multiple definition of google_protobuf_*`
        (`descriptor.upb_minitable.c.o` дублируется в upb и libgrpc.a).
    Partial-линк (`ld -r ... -z muldefs`) сплющивает grpc + upb в один relocatable-
    объект, дедуплицируя пересекающиеся descriptor minitables (идентичные объекты,
    первый побеждает), и даёт чисто линкующуюся libgrpc.a.

    Зачем ПУСТАЯ заглушка (2026-06-03): downstream-потребители (grpc_sdk, цепочка
    el_conf и многие др.) несут исторический link-компонент `upb` в СВОЁМ
    CMakeLists.var — остаток от времён, когда grpc поставлял отдельный upb. Удаление
    всех libupb*.a (как делает fold) оставляет эту ссылку висящей -> `ld: cannot find
    -lupb` при линковке. Пустая заглушка держит `upb` резолвимым как безвредный
    компонент (`find_library` находит, `_list_libs` снова эмитит `upb`, ld линкует
    как no-op), а реальные upb-символы остаются внутри libgrpc.a. Пустая => ноль
    дублей символов, нет multiple-def — фикс целиком на нашей стороне, потребителей
    не трогаем.
    """
    if not os.path.isdir(lib_dir):
        return
    libgrpc = os.path.join(lib_dir, "libgrpc.a")
    upb_libs = sorted(
        os.path.join(lib_dir, f) for f in os.listdir(lib_dir)
        if f.startswith("libupb") and f.endswith(".a")
    )
    if not os.path.isfile(libgrpc) or not upb_libs:
        return
    combined = os.path.join(lib_dir, "_grpc_upb_combined.o")
    subprocess.run(
        [ld_cmd, "-r", "--whole-archive", libgrpc] + upb_libs
        + ["--no-whole-archive", "-z", "muldefs", "-o", combined],
        check=True)
    os.remove(libgrpc)
    subprocess.run(["ar", "qcs", libgrpc, combined], check=True)
    os.remove(combined)
    for ulib in upb_libs:
        os.remove(ulib)
    # Оставляем ПУСТУЮ заглушку libupb.a, чтобы link-компонент `upb`, на который
    # ссылаются downstream-потребители, по-прежнему резолвился (см. docstring).
    # `!<arch>\n` — валидный пустой GNU `ar`-архив: ld линкует как no-op,
    # find_library() находит по имени, _list_libs() снова эмитит `upb`.
    stub = os.path.join(lib_dir, "libupb.a")
    with open(stub, "wb") as _stub_f:
        _stub_f.write(b"!<arch>\n")
    if output is not None:
        output.info(
            f"legacy_nupkg: folded {len(upb_libs)} upb archive(s) into "
            f"libgrpc.a + left empty upb stub ({os.path.basename(lib_dir)})")


def _make_keepdirs(*dirs):
    """Гарантирует, что каждый каталог есть в staged-дереве, и кладёт маркер
    .keepdir ТОЛЬКО если каталог иначе пуст. Маркер нужен лишь чтобы ZipFile
    сохранил каталог (пустые он выкидывает); если в каталоге уже есть реальное
    содержимое, маркер — мёртвый груз и хуже того: downstream-тулинг, который
    глобит каталог (напр. Elara-фреймворк собирает все файлы под `proto/` для
    protoc), принимает .keepdir за обычный файл и ломается. Проверено на IN-658
    el_conf: sura_connector_client cmake-конфиг падал с
    `google/protobuf/timestamp.proto: File not found`, пока .keepdir не убрали
    из `proto/` (2026-05-25)."""
    for d in dirs:
        os.makedirs(d, exist_ok=True)
        contents = [f for f in os.listdir(d) if f != ".keepdir"]
        if contents:
            # В каталоге уже есть реальное содержимое — удаляем устаревший
            # .keepdir, если он создан раньше в этом же деплое, и пропускаем.
            stale = os.path.join(d, ".keepdir")
            if os.path.isfile(stale):
                os.remove(stale)
            continue
        with open(os.path.join(d, ".keepdir"), "w", encoding="utf-8") as f:
            f.write(KEEPDIR_CONTENT)


def deploy(graph, output_folder, **kwargs):
    """Точка входа Conan-deployer'а."""
    conanfile = graph.root.conanfile
    deps = list(conanfile.dependencies.host.items())
    if not deps:
        conanfile.output.warning("legacy_nupkg: no dependencies in graph")
        return

    for require, dep in deps:
        name = dep.ref.name
        # `version_real` — то, что в Conan-кеше (для cache-lookup'ов через
        # `_find_debug_package_path` и т.п.). `version` — то, что мы ЭМИТИМ (имя
        # файла, nuspec, _dependencies): override LEGACY_DEP_VERSION_MAP (если
        # есть) + VERSION_SUFFIX для разводки ProGet-конфликтов.
        version_real = str(dep.ref.version)
        version = LEGACY_DEP_VERSION_MAP.get(name, version_real) + VERSION_SUFFIX
        legacy_name = LEGACY_NAME_MAP.get(name, name)

        s = dep.settings
        os_name = str(s.os)
        compiler = str(s.compiler)
        compiler_version = str(s.compiler.version)
        arch = _resolve_arch_with_toolchain(s.arch, os_name)
        build_type = str(s.build_type)

        # В legacy CI-именовании linkage — slot-тег RUNTIME-CRT (shared =
        # DynamicRT / GR113; static = StaticRT / GR121), а НЕ описание содержимого
        # либы (оно всегда `.a` после IN-658). По умолчанию "shared" (DynamicRT-
        # слот, который читают el_conf, grpc_sdk, sura). Override через env
        # LEGACY_NUPKG_LINKAGE=static для слота GR121. Per-package оверрайды имеют
        # приоритет (сегодня их нет — см. коммент к LEGACY_LINKAGE_OVERRIDE выше).
        linkage = os.environ.get("LEGACY_NUPKG_LINKAGE", "shared").strip() or "shared"
        if linkage not in ("shared", "static"):
            linkage = "shared"
        linkage = LEGACY_LINKAGE_OVERRIDE.get(name, linkage)

        os_short = _resolve_os_short(os_name)
        # Соглашение Astra CI: версию gcc опускаем (astra.gcc.static.x86_64).
        if os_short == "astra" and compiler == "gcc":
            compiler_short = "gcc"
        else:
            compiler_short = _short_compiler(compiler, compiler_version)
        lib_suffix = f"{os_short}-{compiler_short}-{linkage}-{arch}"
        variant_dir = f"{os_short}.{compiler_short}.{linkage}.{arch}"
        targets_name = f"{legacy_name}.{os_short}.{compiler_short}.{linkage}.{arch}"
        pkg_id = f"{legacy_name}.{os_short}.{compiler_short}.{linkage}.{arch}"

        if build_type != "Release":
            conanfile.output.info(
                f"legacy_nupkg: skipping {name}/{version} build_type={build_type}"
                f" (deployer expects Release as primary; Debug is auto-detected from cache)"
            )
            continue

        release_pkg = dep.package_folder
        debug_pkg = _find_debug_package_path(name, version_real)
        if not debug_pkg:
            conanfile.output.warning(
                f"legacy_nupkg: Debug build of {name}/{version_real} not in cache; "
                "debug folder will mirror Release"
            )
            debug_pkg = release_pkg

        # Staging — уникален на pkg_id; финальный архив пакуется из этого каталога,
        # чтобы корневые записи (.nuspec, CMakeLists.var, ...) легли в корень zip.
        staging = os.path.join(output_folder, "staging", pkg_id)
        if os.path.isdir(staging):
            shutil.rmtree(staging)
        os.makedirs(staging, exist_ok=True)

        # 1. include/
        src_include = os.path.join(release_pkg, "include")
        dst_include = os.path.join(staging, "include")
        if os.path.exists(src_include):
            shutil.copytree(src_include, dst_include)

        # 1b. proto/ — legacy-layout кладёт `.proto`-файлы (protobuf well-known'ы:
        # timestamp.proto, duration.proto, ...; protos grpc-плагина) в отдельное
        # top-level дерево `proto/` с той же относительной структурой, что и
        # `include/`. Upstream protobuf ставит их в
        # `<prefix>/include/google/protobuf/*.proto`, поэтому зеркалим все
        # скопированные выше `*.proto` в `proto/` под то, что потребляет
        # `protobuf_generate_grpc_cpp()` legacy Elara-фреймворка
        # (`--proto_path=<pkg>/proto`). Без этого downstream `.proto`, которые
        # `import "google/protobuf/timestamp.proto";`, падают `File not found`
        # при вызове protoc в el_conf-сборках.
        #
        # ИСКЛЮЧАЕМ upstream-only лишнее, которое legacy-форк Elara срезает:
        #   - `**/compiler/plugin.proto` — protoc plugin API; нет в legacy .nupkg,
        #     и его наличие ломает downstream protoc при резолве транзитивных
        #     import'ов (проверено IN-658 el_conf, 2026-05-25 —
        #     см. test-astra/diff_two_dirs.sh).
        #   - `**/java/...` — Java-специфичные well-known'ы вроде
        #     `java_features.proto` (синтаксис edition-2023, который старый protoc
        #     не парсит); legacy их не поставляет, для C++-потребителей не нужны.
        # Legacy protobuf 4.25.2 nupkg несёт ровно 12 well-known .proto под
        # `proto/google/protobuf/`; совпадаем.
        dst_proto = os.path.join(staging, "proto")
        _PROTO_EXCLUDE_DIRS = {"compiler", "java"}
        if os.path.isdir(src_include):
            for root, dirs, files in os.walk(src_include):
                # Срезаем исключённые подкаталоги на месте (os.walk это учитывает).
                dirs[:] = [d for d in dirs if d not in _PROTO_EXCLUDE_DIRS]
                for fname in files:
                    if not fname.endswith(".proto"):
                        continue
                    rel = os.path.relpath(os.path.join(root, fname), src_include)
                    target = os.path.join(dst_proto, rel)
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copy2(os.path.join(root, fname), target)

        # 2. lib/native/{,-d}/
        # abseil кладёт legacy-крупные либы в подпапку lib/
        # (LEGACY_LIBDIR_OVERRIDE); остальные используют lib/ напрямую.
        _lib_sub = LEGACY_LIBDIR_OVERRIDE.get(name)

        def _libdir(pkg_root):
            base = os.path.join(pkg_root, "lib")
            return os.path.join(base, _lib_sub) if _lib_sub else base

        _staging_rel_libdir = os.path.join(staging, "lib", "native", lib_suffix)
        _staging_dbg_libdir = os.path.join(staging, "lib", "native", f"{lib_suffix}-d")
        n_rel = _copy_libs(_libdir(release_pkg), _staging_rel_libdir, pkg_name=name)
        n_dbg = _copy_libs(_libdir(debug_pkg), _staging_dbg_libdir, pkg_name=name)

        # grpc: вшиваем отдельные статические архивы upb в libgrpc.a, чтобы
        # legacy flat-линкующий фреймворк видел самодостаточную libgrpc.a, как в
        # legacy TeamCity-пакете. Работаем только над staged-копией; upstream
        # Conan-пакет не трогаем. Полное «зачем» — в _fold_upb_into_libgrpc.
        if name == "grpc":
            _ld = _resolve_cross_ld(_target_binutils_prefix(
                s.arch, os.environ.get("CONAN_USER_TOOLCHAIN", "")) + "ld")
            # Release-fold обязателен. _fold_upb_into_libgrpc меняет каталог только
            # ПОСЛЕ успешного `ld -r`, так что падение оставляет каталог целым.
            _fold_upb_into_libgrpc(_staging_rel_libdir, _ld, conanfile.output)
            # Debug libgrpc.a огромна (~1.4 GB static+debug); `ld -r` по ней может
            # исчерпать RAM на CI-агенте. Делаем не-фатальным: при падении грузим
            # debug-вариант без fold (в Release-сборках потребители линкуют
            # release). Debug-потребители тогда упрутся в upb-ссылки — приемлемо,
            # пока fold не разбит или не стримится.
            try:
                _fold_upb_into_libgrpc(_staging_dbg_libdir, _ld, conanfile.output)
            except Exception as _fold_err:
                conanfile.output.warning(
                    f"legacy_nupkg: debug libgrpc.a upb-fold skipped ({_fold_err}); "
                    "release variant is folded, debug shipped as-is")

        # Кладём build-tool исполняемые (grpc -> grpc_cpp_plugin, protobuf ->
        # protoc) в lib/native/<suffix>/, как legacy-пакеты. GenerateGrpcCpp.cmake
        # Elara-фреймворка находит версионно-совпадающие protoc + grpc_cpp_plugin;
        # без них кодоген сваливается на системные инструменты другой версии.
        # Источник — bin/ Conan-пакета (нужна сборка, реально сохранившая бинарь —
        # protobuf должен собираться с protobuf_BUILD_PROTOC_BINARIES=ON, что
        # рецепт и ставит).
        # ВНИМАНИЕ для ARM cross: кладёт бинарь HOST-arch; x86_64 cross-потребителю
        # нужен бинарь build-context — пересмотреть для ARM-ветки.
        for _tool in LEGACY_BIN_TOOLS.get(name, ()):
            for _src_pkg, _dst in ((release_pkg, _staging_rel_libdir),
                                   (debug_pkg, _staging_dbg_libdir)):
                _src_tool = os.path.join(_src_pkg, "bin", _tool)
                if os.path.isfile(_src_tool):
                    os.makedirs(_dst, exist_ok=True)
                    _dst_tool = os.path.join(_dst, _tool)
                    shutil.copy2(_src_tool, _dst_tool)
                    os.chmod(_dst_tool, 0o755)

        # Имена компонентов — LEGACY (zlib, не z), см. _legacy_component_names.
        # Сами .so алиасятся в _add_lib_aliases внутри _copy_libs выше. Читаем из
        # STAGING-каталога (после fold): feature-либы upb (libupb_json_lib, ...)
        # вшиты в libgrpc.a, остаётся единственная пустая заглушка `libupb.a` ->
        # `upb` эмитится одним безвредным компонентом, чтобы потребители его
        # резолвили (см. _fold_upb_into_libgrpc).
        libs = _legacy_component_names(_list_libs(_staging_rel_libdir), name)

        # 3. .targets
        os.makedirs(os.path.join(staging, "build", "native"), exist_ok=True)
        with open(os.path.join(staging, "build", "native", f"{targets_name}.targets"),
                  "w", encoding="utf-8") as f:
            f.write(_generate_targets(legacy_name, os_short, compiler_short, linkage, arch, libs))

        # 4. .nuspec — NuGet/ProGet требуют его в корне архива, не в nuget/.
        # Применяем тот же remap имени+версии, что и _dependencies, чтобы .nuspec
        # объявлял слоты, которые реально отдаёт downstream-feed.
        nuspec_deps = []
        for _, d in dep.dependencies.host.items():
            dep_n = LEGACY_DEP_NAME_MAP.get(
                d.ref.name, LEGACY_NAME_MAP.get(d.ref.name, d.ref.name))
            dep_v = (LEGACY_DEP_VERSION_MAP.get(d.ref.name, str(d.ref.version))
                     + VERSION_SUFFIX)
            nuspec_deps.append((dep_n, dep_v))
        with open(os.path.join(staging, f"{legacy_name}.nuspec"),
                  "w", encoding="utf-8") as f:
            f.write(_generate_nuspec(legacy_name, version, os_short, compiler_short,
                                     linkage, arch, nuspec_deps))

        # 5. .keepdir-маркеры
        # `lib/native/<lib_suffix>{,-d}` должны пережить ZIP-архивацию даже
        # пустыми (ZipFile выкидывает пустые каталоги). Иначе downstream
        # ResolveDependencies.cmake проверяет наличие пути и падает
        # ("Unable to find debug version of <pkg>").
        _make_keepdirs(
            os.path.join(staging, "lib", "net461"),
            os.path.join(staging, "lib", "native", lib_suffix),
            os.path.join(staging, "lib", "native", f"{lib_suffix}-d"),
            os.path.join(staging, "proto"),
            os.path.join(dst_include, "gmock", "internal", "custom") if os.path.isdir(dst_include) else os.path.join(staging, "_skip"),
            os.path.join(dst_include, "gtest", "internal", "custom") if os.path.isdir(dst_include) else os.path.join(staging, "_skip"),
        )
        skip = os.path.join(staging, "_skip")
        if os.path.isdir(skip):
            shutil.rmtree(skip)

        # 6. CMakeLists.var
        components = list(libs) if libs else [name]
        # grpc_cpp_plugin / protoc — ИСПОЛНЯЕМЫЕ (нет .a/.so), поэтому _list_libs
        # их пропускает; но legacy CMakeLists.var перечисляет их как components,
        # чтобы Elara-фреймворк (find_program в GenerateGrpcCpp.cmake) нашёл
        # версионно-совпадающий инструмент в lib/native/<variant>. Без component-
        # записи просто положить файл недостаточно — его не видно. Добавляем
        # только в CMakeLists.var, НЕ в lib-список Windows .targets (это не link-либы).
        for _tool in LEGACY_BIN_TOOLS.get(name, ()):
            if os.path.isfile(os.path.join(_staging_rel_libdir, _tool)) \
                    and _tool not in components:
                components.append(_tool)
        platforms = ["WINDOWS", "LINUX", "LINUX_ARM_NXP", "LINUX_ARM_LINARO",
                     "LINUX_ARM64_ROCKCHIP", "LINUX_ARM64_LINARO", "LINUX_ATOM", "WINCE800"]
        # Только прямые deps ЭТОГО пакета (не весь транзитивный замыкатель):
        # downstream Elara-фреймворк (ResolveDependencies.cmake в grpc_sdk и др.)
        # резолвит транзитивы, обходя _dependencies каждого потреблённого пакета.
        # Формат, который ждёт фреймворк: `<legacy_name>:<version>` на строку,
        # совпадает с legacy_name + version соответствующего .nupkg в feed.
        var_deps = []
        for _, d in dep.dependencies.host.items():
            dep_legacy_name = LEGACY_DEP_NAME_MAP.get(
                d.ref.name, LEGACY_NAME_MAP.get(d.ref.name, d.ref.name))
            dep_version = (LEGACY_DEP_VERSION_MAP.get(d.ref.name, str(d.ref.version))
                           + VERSION_SUFFIX)
            var_deps.append(f"{dep_legacy_name}:{dep_version}")
        # Доп. псевдо-deps, которых ждёт downstream ResolveDependencies.cmake
        # (legacy Elara-форк grpc/1.60.1 поставлял их отдельными пакетами), а
        # upstream grpc/protobuf 1.60.1/4.25.2 вендорят внутри. Эмитим только для
        # grpc 1.60.x. Это пакеты из legacy Bitbucket-feed в ProGet (этой сборкой
        # не производятся), поэтому VERSION_SUFFIX НЕ применяется.
        if name == "grpc" and version.startswith("1.60."):
            # address_sorting остаётся отдельным legacy-пакетом (чисто линкуется
            # своей .a). upb как dependency НЕ эмитим: он вшит в libgrpc.a через
            # _fold_upb_into_libgrpc, который оставляет пустую заглушку libupb.a,
            # так что `upb` идёт самодостаточным no-op КОМПОНЕНТОМ grpc —
            # потребители, ссылающиеся на `upb`, резолвят его из самого grpc.
            # Возврат `upb:0.2.0` в deps подтянул бы legacy standalone libupb.a
            # (реальные символы) и снова продублировал бы google_protobuf
            # descriptor minitables, уже лежащие в свёрнутой libgrpc.a ->
            # multiple-definition при линковке.
            var_deps.append("address_sorting:1.0.0")
        with open(os.path.join(staging, "CMakeLists.var"), "w", encoding="utf-8") as f:
            f.write(_generate_cmakelists_var(legacy_name, version, components, platforms, var_deps))

        # 7. LICENSE.txt — некоторые рецепты (openssl) кладут в licenses/ не только
        # файлы, но и подпапки (licenses/external/...). Берём только plain-файлы;
        # побеждает последний (одного файла достаточно для legacy-формата).
        src_lic = os.path.join(release_pkg, "licenses")
        dst_lic = os.path.join(staging, "LICENSE.txt")
        copied = False
        if os.path.isdir(src_lic):
            for lf in os.listdir(src_lic):
                src_path = os.path.join(src_lic, lf)
                if os.path.isfile(src_path):
                    shutil.copy2(src_path, dst_lic)
                    copied = True
        if not copied:
            open(dst_lic, "w").close()

        # 8. .nupkg — пакуем из `staging`, чтобы .nuspec лёг в корень архива
        # (раньше паковали из родительского `staging/`, оставляя лишний слой-
        # обёртку <variant_dir>/, ломавший заливку в ProGet и резолв CMakeLists.var).
        nupkg = os.path.join(output_folder, f"{pkg_id}.{version}.nupkg")
        with zipfile.ZipFile(nupkg, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, _, files in os.walk(staging):
                for fname in files:
                    fp = os.path.join(root, fname)
                    arcname = os.path.relpath(fp, staging)
                    zf.write(fp, arcname)
        shutil.rmtree(os.path.join(output_folder, "staging"))

        size_mb = os.path.getsize(nupkg) / (1024 * 1024)
        conanfile.output.success(
            f"legacy_nupkg: {os.path.basename(nupkg)} ({size_mb:.1f} MB) — "
            f"Release={n_rel} libs, Debug={n_dbg} libs"
        )
