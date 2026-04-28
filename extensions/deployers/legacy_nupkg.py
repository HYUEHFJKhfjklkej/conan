"""
Conan deployer: упаковка зависимостей в legacy NuGet-формат TeamCity.

Использование:
    conan install --requires=gtest/1.15.2 \
        --profile=astra-gcc \
        --deployer=legacy_nupkg \
        --deployer-folder=output/

Берёт каждый dependency из install-графа, находит в кеше Release и Debug
варианты (по settings.build_type), генерит .targets/.nuspec/CMakeLists.var,
кладёт бинари и заголовки, упаковывает в .nupkg.
"""
import json
import os
import shutil
import subprocess
import zipfile


# Маппинг имён Conan → legacy
LEGACY_NAME_MAP = {"gtest": "googletest"}

# Маппинг ОС: Conan settings.os → legacy os-короткое
OS_SHORT = {"Linux": "lin", "Windows": "win", "Macos": "mac"}

KEEPDIR_CONTENT = (
    "#\n"
    "# *** IMPORTANT NOTE ***\n"
    "#\n"
    "# Please, do not delete this file. This file is used for keeping empty directories.\n"
    "#\n"
)


def _short_compiler(compiler, version):
    """gcc 8.4 -> gcc84, msvc 192 -> v142 (упрощённо)."""
    if compiler == "msvc":
        return f"v{version}"
    ver = str(version).replace(".", "").replace("_", "")
    return f"{compiler}{ver}"


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


def _generate_cmakelists_var(legacy_name, version, components, platforms):
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
              "set(${project_name}_dependencies", "    )", ""]
    return "\n".join(lines)


def _copy_libs(src_lib, dst):
    if not os.path.isdir(src_lib):
        return 0
    n = 0
    os.makedirs(dst, exist_ok=True)
    for f in os.listdir(src_lib):
        sf = os.path.join(src_lib, f)
        if os.path.isfile(sf) and f.split('.')[-1] in ("a", "lib", "so", "dll", "dylib"):
            shutil.copy2(sf, os.path.join(dst, f))
            n += 1
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


def _make_keepdirs(*dirs):
    for d in dirs:
        os.makedirs(d, exist_ok=True)
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
        version = str(dep.ref.version)
        legacy_name = LEGACY_NAME_MAP.get(name, name)

        s = dep.settings
        os_name = str(s.os)
        compiler = str(s.compiler)
        compiler_version = str(s.compiler.version)
        arch = str(s.arch)
        build_type = str(s.build_type)

        try:
            shared = bool(dep.options.shared)
        except Exception:
            shared = False
        linkage = "shared" if shared else "static"

        os_short = OS_SHORT.get(os_name, os_name.lower())
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
        debug_pkg = _find_debug_package_path(name, version)
        if not debug_pkg:
            conanfile.output.warning(
                f"legacy_nupkg: Debug build of {name}/{version} not in cache; "
                "debug folder will mirror Release"
            )
            debug_pkg = release_pkg

        # Staging
        staging = os.path.join(output_folder, "staging", variant_dir)
        if os.path.isdir(staging):
            shutil.rmtree(staging)
        os.makedirs(staging, exist_ok=True)

        # 1. include/
        src_include = os.path.join(release_pkg, "include")
        dst_include = os.path.join(staging, "include")
        if os.path.exists(src_include):
            shutil.copytree(src_include, dst_include)

        # 2. lib/native/{,-d}/
        n_rel = _copy_libs(os.path.join(release_pkg, "lib"),
                           os.path.join(staging, "lib", "native", lib_suffix))
        n_dbg = _copy_libs(os.path.join(debug_pkg, "lib"),
                           os.path.join(staging, "lib", "native", f"{lib_suffix}-d"))
        libs = _list_libs(os.path.join(release_pkg, "lib"))

        # 3. .targets
        os.makedirs(os.path.join(staging, "build", "native"), exist_ok=True)
        with open(os.path.join(staging, "build", "native", f"{targets_name}.targets"),
                  "w", encoding="utf-8") as f:
            f.write(_generate_targets(legacy_name, os_short, compiler_short, linkage, arch, libs))

        # 4. .nuspec
        os.makedirs(os.path.join(staging, "nuget"), exist_ok=True)
        nuspec_deps = [(d.ref.name, str(d.ref.version)) for _, d in dep.dependencies.host.items()]
        with open(os.path.join(staging, "nuget", f"{legacy_name}.nuspec"),
                  "w", encoding="utf-8") as f:
            f.write(_generate_nuspec(legacy_name, version, os_short, compiler_short,
                                     linkage, arch, nuspec_deps))

        # 5. .keepdir markers
        _make_keepdirs(
            os.path.join(staging, "lib", "net461"),
            os.path.join(staging, "proto"),
            os.path.join(dst_include, "gmock", "internal", "custom") if os.path.isdir(dst_include) else os.path.join(staging, "_skip"),
            os.path.join(dst_include, "gtest", "internal", "custom") if os.path.isdir(dst_include) else os.path.join(staging, "_skip"),
        )
        skip = os.path.join(staging, "_skip")
        if os.path.isdir(skip):
            shutil.rmtree(skip)

        # 6. CMakeLists.var
        components = libs if libs else [name]
        platforms = ["WINDOWS", "LINUX", "LINUX_ARM_NXP", "LINUX_ARM_LINARO",
                     "LINUX_ARM64_ROCKCHIP", "LINUX_ARM64_LINARO", "LINUX_ATOM", "WINCE800"]
        with open(os.path.join(staging, "CMakeLists.var"), "w", encoding="utf-8") as f:
            f.write(_generate_cmakelists_var(legacy_name, version, components, platforms))

        # 7. LICENSE.txt
        src_lic = os.path.join(release_pkg, "licenses")
        dst_lic = os.path.join(staging, "LICENSE.txt")
        if os.path.isdir(src_lic):
            for lf in os.listdir(src_lic):
                shutil.copy2(os.path.join(src_lic, lf), dst_lic)
        else:
            open(dst_lic, "w").close()

        # 8. .nupkg
        nupkg = os.path.join(output_folder, f"{pkg_id}.{version}.nupkg")
        staging_root = os.path.join(output_folder, "staging")
        with zipfile.ZipFile(nupkg, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, _, files in os.walk(staging_root):
                for fname in files:
                    fp = os.path.join(root, fname)
                    arcname = os.path.relpath(fp, staging_root)
                    zf.write(fp, arcname)
        shutil.rmtree(staging_root)

        size_mb = os.path.getsize(nupkg) / (1024 * 1024)
        conanfile.output.success(
            f"legacy_nupkg: {os.path.basename(nupkg)} ({size_mb:.1f} MB) — "
            f"Release={n_rel} libs, Debug={n_dbg} libs"
        )
