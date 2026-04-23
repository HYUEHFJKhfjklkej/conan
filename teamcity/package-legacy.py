#!/usr/bin/env python3
"""
Упаковка Conan-пакета в legacy-формат артефактов TeamCity.

Conan собирает пакет из оригинальных исходников (без модификации),
а этот скрипт пакует результат в тот же формат, что и текущая система:

    googletest.zip
    └── lin.gcc.shared.x64/
        ├── build/native/
        │   └── googletest.lin.gcc84.shared.x86_64.targets
        ├── include/
        ├── lib/
        ├── nuget/
        │   └── googletest.nuspec
        ├── proto/
        ├── CMakeLists.var
        └── LICENSE.txt

Использование:
    python package-legacy.py --name gtest --version 1.14.0 --profile lin-gcc84-x86_64 --shared True
"""

import argparse
import json
import os
import shutil
import subprocess
import zipfile


# Маппинг Conan-профилей на legacy-именование
PROFILE_MAP = {
    "lin-gcc84-x86_64":       {"os": "lin", "compiler": "gcc84",  "arch": "x86_64", "arch_short": "x64"},
    "lin-gcc84-i686":         {"os": "lin", "compiler": "gcc84",  "arch": "i686",   "arch_short": "x86"},
    "lin-gcc75-arm-linaro":   {"os": "lin", "compiler": "gcc75",  "arch": "arm-linaro", "arch_short": "arm-linaro"},
    "lin-gcc-aarch64-linaro": {"os": "lin", "compiler": "gcc75",  "arch": "aarch64-linaro", "arch_short": "aarch64-linaro"},
    "win-v142-x64":           {"os": "win", "compiler": "v142",   "arch": "x86_64", "arch_short": "x64"},
    "win-v142-x86":           {"os": "win", "compiler": "v142",   "arch": "i686",   "arch_short": "x86"},
    "linux-gcc":              {"os": "lin", "compiler": "gcc",     "arch": "x86_64", "arch_short": "x64"},
    "linux-gcc-debug":        {"os": "lin", "compiler": "gcc",     "arch": "x86_64", "arch_short": "x64"},
    "windows-msvc":           {"os": "win", "compiler": "v142",   "arch": "x86_64", "arch_short": "x64"},
    "windows-msvc-debug":     {"os": "win", "compiler": "v142",   "arch": "x86_64", "arch_short": "x64"},
}

# Маппинг имён пакетов Conan → legacy
PACKAGE_NAME_MAP = {
    "gtest": "googletest",
}


def get_conan_package_path(name, version):
    """Получить путь к собранному пакету (с include/, lib/) в Conan-кэше."""
    # Сначала найти package_id через conan list
    result = subprocess.run(
        ["conan", "list", f"{name}/{version}:*", "--format=json"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"Package {name}/{version} not found in cache: {result.stderr}")

    data = json.loads(result.stdout)
    # Структура: {"Local Cache": {"name/version": {"revisions": {"rev": {"packages": {"pkg_id": ...}}}}}}
    for cache_name, refs in data.items():
        for ref, ref_data in refs.items():
            for rev_id, rev_data in ref_data.get("revisions", {}).items():
                packages = rev_data.get("packages", {})
                if packages:
                    # Берём первый (или последний) package_id
                    pkg_id = list(packages.keys())[-1]
                    # Получить путь к package folder
                    path_result = subprocess.run(
                        ["conan", "cache", "path",
                         f"{name}/{version}:{pkg_id}"],
                        capture_output=True, text=True
                    )
                    if path_result.returncode == 0:
                        pkg_path = path_result.stdout.strip()
                        print(f"  Found package {pkg_id[:12]}... at {pkg_path}")
                        return pkg_path

    raise RuntimeError(f"No binary packages found for {name}/{version}. Run 'conan create' first.")


def get_package_libs(package_path):
    """Найти все .lib/.a/.so файлы в пакете."""
    libs = []
    lib_dir = os.path.join(package_path, "lib")
    if os.path.exists(lib_dir):
        for f in os.listdir(lib_dir):
            if f.endswith((".lib", ".a", ".so", ".dll")):
                name = f.replace(".lib", "").replace("lib", "", 1).replace(".a", "").replace(".so", "")
                if name not in libs:
                    libs.append(f.replace(".lib", "").replace(".a", ""))
    return libs


def generate_cmakelists_var(name, version, components, platforms, definitions, dependencies):
    """Генерация CMakeLists.var в legacy-формате."""
    legacy_name = PACKAGE_NAME_MAP.get(name, name)
    parts = version.split(".")
    major = parts[0] if len(parts) > 0 else "0"
    minor = parts[1] if len(parts) > 1 else "0"
    patch = parts[2] if len(parts) > 2 else "0"

    lines = []
    lines.append("#")
    lines.append("# Project Name (unique project name)")
    lines.append(f"set(project_name {legacy_name})")
    lines.append("")
    lines.append("#")
    lines.append("# Project Version")
    lines.append(f'set(${{{legacy_name}}}_major {major})')
    lines.append(f'set(${{{legacy_name}}}_minor {minor})')
    lines.append(f'set(${{{legacy_name}}}_patch {patch})')
    lines.append(f'set(${{{legacy_name}}}_prerelease_suffix "-alpha")')
    lines.append("")
    lines.append("#")
    lines.append("# List of components included in the project.")
    lines.append("set(components")
    for comp in components:
        lines.append(f"    {comp}")
    lines.append(")")
    lines.append("")

    lines.append("#")
    lines.append("# List of platforms supported by each component.")
    for comp in components:
        lines.append(f"set({comp}")
        for plat in platforms:
            lines.append(f"    {plat}")
        lines.append(")")
        lines.append("")

    lines.append("#")
    lines.append("# List of test components included in the project.")
    lines.append("set(test_components")
    lines.append(")")
    lines.append("")

    lines.append("#")
    lines.append("# Definitions for all components in project.")
    lines.append(f"set(${{{legacy_name}}}_definitions")
    for d in definitions:
        lines.append(f"    {d}")
    lines.append(")")
    lines.append("")

    lines.append("#")
    lines.append("# List of dependencies on other projects.")
    lines.append(f"set(${{{legacy_name}}}_dependencies")
    for dep in dependencies:
        lines.append(f"    {dep}")
    lines.append(")")
    lines.append("")

    return "\n".join(lines)


def generate_targets(legacy_name, profile_info, shared, libs):
    """Генерация .targets файла для NuGet/MSBuild."""
    os_name = profile_info["os"]
    compiler = profile_info["compiler"]
    linkage = "shared" if shared else "static"
    arch = profile_info["arch_short"]

    lib_suffix = f"{os_name}-{compiler}-{linkage}-{arch}"
    lib_deps = ";".join([f"{lib}.lib" for lib in libs]) + ";%(AdditionalDependencies)"

    lines = []
    lines.append('<?xml version="1.0" encoding="utf-8"?>')
    lines.append(f'<Project ToolsVersion="14.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003" >')
    lines.append('  <ItemDefinitionGroup>')
    lines.append('    <ClCompile>')
    lines.append(f'      <AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)..\\..\\include\\;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>')
    lines.append('    </ClCompile>')
    lines.append('    <Link>')
    lines.append(f'      <AdditionalDependencies>{lib_deps}</AdditionalDependencies>')
    lines.append('    </Link>')
    lines.append('  </ItemDefinitionGroup>')
    lines.append('')

    for config in ["Debug", "Release"]:
        suffix = "-d" if config == "Debug" else ""
        lines.append(f'  <ItemDefinitionGroup Condition="\'$(Configuration)\' == \'{config}\' And \'$(Platform)\' == \'\'">')
        lines.append('    <Link>')
        lines.append(f'      <AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)..\\..\\lib\\native\\{lib_suffix}{suffix}\\;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>')
        lines.append('    </Link>')
        lines.append('  </ItemDefinitionGroup>')
        if shared:
            lines.append(f'  <ItemGroup Condition="\'$(Configuration)\' == \'{config}\' And \'$(Platform)\' == \'\'">')
            lines.append(f'    <Content Include="$(MSBuildThisFileDirectory)..\\..\\lib\\native\\{lib_suffix}{suffix}\\*.dll">')
            lines.append('      <CopyToOutputDirectory>Always</CopyToOutputDirectory>')
            lines.append('    </Content>')
            lines.append('  </ItemGroup>')
        lines.append('')

    lines.append('</Project>')
    return "\n".join(lines)


def generate_nuspec(legacy_name, version, profile_info, shared, dependencies):
    """Генерация .nuspec файла."""
    os_name = profile_info["os"]
    compiler = profile_info["compiler"]
    linkage = "shared" if shared else "static"
    arch = profile_info["arch_short"]
    pkg_id = f"{legacy_name}.{os_name}.{compiler}.{linkage}.{arch}"

    lines = []
    lines.append('<?xml version="1.0"?>')
    lines.append('<package>')
    lines.append('  <metadata>')
    lines.append(f'    <id>{pkg_id}</id>')
    lines.append(f'    <version>{version}</version>')
    lines.append(f'    <description>{legacy_name} package</description>')
    lines.append('    <authors>Elara</authors>')

    if dependencies:
        lines.append('    <dependencies>')
        for dep in dependencies:
            parts = dep.rsplit("-", 1)
            dep_name = parts[0]
            dep_ver = parts[1] if len(parts) > 1 else "0.0.0"
            dep_id = f"{dep_name}.{os_name}.{compiler}.{linkage}.{arch}"
            lines.append(f'      <dependency id="{dep_id}" version="{dep_ver}" />')
        lines.append('    </dependencies>')

    lines.append('  </metadata>')
    lines.append('</package>')
    return "\n".join(lines)


def package_legacy(name, version, profile_name, shared, output_dir,
                   components=None, platforms=None, definitions=None, dependencies=None):
    """Упаковать Conan-пакет в legacy zip-формат."""

    legacy_name = PACKAGE_NAME_MAP.get(name, name)
    profile_info = PROFILE_MAP.get(profile_name)
    if not profile_info:
        raise ValueError(f"Unknown profile: {profile_name}. Known: {list(PROFILE_MAP.keys())}")

    # Получить путь к пакету в Conan-кэше
    pkg_path = get_conan_package_path(name, version)
    print(f"Conan package path: {pkg_path}")

    # Определить имя поддиректории (lin.gcc.shared.x64)
    os_name = profile_info["os"]
    compiler = profile_info["compiler"]
    linkage = "shared" if shared else "static"
    arch = profile_info["arch_short"]
    variant_dir = f"{os_name}.{compiler}.{linkage}.{arch}"

    # Targets-имя файла
    targets_name = f"{legacy_name}.{os_name}.{compiler}.{linkage}.{profile_info['arch']}"

    # Найти библиотеки
    libs = get_package_libs(pkg_path)
    if not libs and components:
        libs = components

    # Defaults
    if platforms is None:
        platforms = ["WINDOWS", "LINUX", "LINUX_ARM_NXP", "LINUX_ARM_LINARO",
                     "LINUX_ARM64_ROCKCHIP", "LINUX_ARM64_LINARO", "LINUX_ATOM", "WINCE800"]
    if definitions is None:
        definitions = []
    if dependencies is None:
        dependencies = []
    if components is None:
        components = libs if libs else [name]

    # Создать структуру
    staging = os.path.join(output_dir, "staging", variant_dir)
    os.makedirs(staging, exist_ok=True)

    # 1. include/
    src_include = os.path.join(pkg_path, "include")
    dst_include = os.path.join(staging, "include")
    if os.path.exists(src_include):
        shutil.copytree(src_include, dst_include, dirs_exist_ok=True)
        print(f"  Copied include/ ({len(os.listdir(dst_include))} items)")
    else:
        os.makedirs(dst_include, exist_ok=True)
        print(f"  WARNING: no include/ in Conan package at {pkg_path}")

    # 2. lib/ → lib/native/{variant}/ (legacy structure)
    src_lib = os.path.join(pkg_path, "lib")
    lib_suffix = f"{os_name}-{compiler}-{linkage}-{arch}"
    dst_lib_native = os.path.join(staging, "lib", "native", lib_suffix)
    dst_lib_native_d = os.path.join(staging, "lib", "native", f"{lib_suffix}-d")
    dst_lib_net461 = os.path.join(staging, "lib", "native", "net461")
    os.makedirs(dst_lib_native, exist_ok=True)
    os.makedirs(dst_lib_native_d, exist_ok=True)
    os.makedirs(dst_lib_net461, exist_ok=True)

    if os.path.exists(src_lib):
        # Копировать все .lib/.a/.so/.dll в lib/native/{variant}/
        for f in os.listdir(src_lib):
            src_file = os.path.join(src_lib, f)
            if os.path.isfile(src_file):
                shutil.copy2(src_file, os.path.join(dst_lib_native, f))
        # Дублировать в debug-папку (в реальности debug собирается отдельно)
        for f in os.listdir(src_lib):
            src_file = os.path.join(src_lib, f)
            if os.path.isfile(src_file):
                shutil.copy2(src_file, os.path.join(dst_lib_native_d, f))
        print(f"  Copied lib/ → lib/native/{lib_suffix}/")
    else:
        print(f"  WARNING: no lib/ in Conan package at {pkg_path}")

    # 3. build/native/ (.targets)
    build_native = os.path.join(staging, "build", "native")
    os.makedirs(build_native, exist_ok=True)
    targets_content = generate_targets(legacy_name, profile_info, shared, libs)
    targets_file = os.path.join(build_native, f"{targets_name}.targets")
    with open(targets_file, "w", encoding="utf-8") as f:
        f.write(targets_content)
    print(f"  Generated {targets_name}.targets")

    # 4. nuget/ (.nuspec)
    nuget_dir = os.path.join(staging, "nuget")
    os.makedirs(nuget_dir, exist_ok=True)
    nuspec_content = generate_nuspec(legacy_name, version, profile_info, shared, dependencies)
    nuspec_file = os.path.join(nuget_dir, f"{legacy_name}.nuspec")
    with open(nuspec_file, "w", encoding="utf-8") as f:
        f.write(nuspec_content)
    print(f"  Generated {legacy_name}.nuspec")

    # 5. proto/ (пустая, для совместимости)
    os.makedirs(os.path.join(staging, "proto"), exist_ok=True)

    # Добавить .keepdir в пустые папки (для совместимости)
    for keepdir in [dst_lib_net461, os.path.join(staging, "proto")]:
        keepfile = os.path.join(keepdir, ".keepdir")
        if not os.path.exists(keepfile):
            with open(keepfile, "w") as f:
                pass

    # 6. CMakeLists.var
    var_content = generate_cmakelists_var(
        name, version, components, platforms, definitions, dependencies
    )
    with open(os.path.join(staging, "CMakeLists.var"), "w", encoding="utf-8") as f:
        f.write(var_content)
    print(f"  Generated CMakeLists.var")

    # 7. LICENSE.txt
    src_license = os.path.join(pkg_path, "licenses")
    if os.path.exists(src_license):
        for lf in os.listdir(src_license):
            shutil.copy2(os.path.join(src_license, lf), os.path.join(staging, "LICENSE.txt"))
    else:
        with open(os.path.join(staging, "LICENSE.txt"), "w") as f:
            f.write("")

    # 8. Создать zip
    zip_name = f"{legacy_name}.zip"
    zip_path = os.path.join(output_dir, zip_name)
    staging_root = os.path.join(output_dir, "staging")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(staging_root):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, staging_root)
                zf.write(file_path, arcname)

    # Cleanup staging
    shutil.rmtree(staging_root)

    zip_size = os.path.getsize(zip_path) / (1024 * 1024)
    print(f"\n  Created: {zip_path} ({zip_size:.1f} MB)")
    print(f"  Structure: {variant_dir}/")
    print(f"    ├── build/native/{targets_name}.targets")
    print(f"    ├── include/")
    print(f"    ├── lib/")
    print(f"    ├── nuget/{legacy_name}.nuspec")
    print(f"    ├── proto/")
    print(f"    ├── CMakeLists.var")
    print(f"    └── LICENSE.txt")

    return zip_path


# Конфигурация пакетов — компоненты, платформы, зависимости
# (то, что сейчас в CMakeLists.var каждого пакета)
PACKAGE_CONFIG = {
    "gtest": {
        "components": ["gtest", "gtest_main", "gmock", "gmock_main"],
        "platforms": [
            "WINDOWS", "LINUX", "LINUX_ARM_NXP", "LINUX_ARM_LINARO",
            "LINUX_ARM64_ROCKCHIP", "LINUX_ARM64_LINARO", "LINUX_ATOM", "WINCE800"
        ],
        "definitions": [],
        "dependencies": [],
    },
    "curl": {
        "components": ["curl", "curltool"],
        "platforms": [
            "CROSS", "LINUX", "LINUX_ARM_RPI", "LINUX_ARM_LINARO",
            "LINUX_AARCH64_ROCKCHIP", "LINUX_AARCH64_LINARO", "LINUX_ATOM"
        ],
        "definitions": ["-DCURL_STATICLIB"],
        "dependencies": ["openssl-1.1.11", "zlib-1.3.0", "ssh2-1.11.0"],
    },
    "zlib": {
        "components": ["zlib"],
        "platforms": [
            "WINDOWS", "LINUX", "LINUX_ARM_NXP", "LINUX_ARM_LINARO",
            "LINUX_ARM64_ROCKCHIP", "LINUX_ARM64_LINARO", "LINUX_ATOM", "WINCE800"
        ],
        "definitions": [],
        "dependencies": [],
    },
}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Package Conan build into legacy TeamCity artifact format")
    parser.add_argument("--name", required=True, help="Conan package name (gtest, curl, ...)")
    parser.add_argument("--version", required=True, help="Package version (1.14.0)")
    parser.add_argument("--profile", required=True, help="Profile name (lin-gcc84-x86_64)")
    parser.add_argument("--shared", default="True", help="Shared library (True/False)")
    parser.add_argument("--output", default=".", help="Output directory for zip")

    args = parser.parse_args()
    shared = args.shared.lower() in ("true", "1", "yes", "on")

    config = PACKAGE_CONFIG.get(args.name, {})

    zip_path = package_legacy(
        name=args.name,
        version=args.version,
        profile_name=args.profile,
        shared=shared,
        output_dir=args.output,
        components=config.get("components"),
        platforms=config.get("platforms"),
        definitions=config.get("definitions"),
        dependencies=config.get("dependencies"),
    )

    print(f"\nDone! Artifact: {zip_path}")
