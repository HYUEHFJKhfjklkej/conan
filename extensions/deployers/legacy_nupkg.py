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
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    # Replace our upstream-built `abseil` package with the legacy Elara
    # `absl` slot so downstream consumers (exceptions/googletest tied to
    # `absl:0.2.0`) pick up the upstream binaries — which include the
    # missing `cord` components.
    "abseil": "absl",
    # The conan recipe is `c-ares` (the conan-center name), but the legacy
    # Elara slot is `cares` — no dash. Critical: downstream
    # ResolveDependencies.cmake emits `add_definitions(-D${_name}_..._DEFINE)`
    # WITHOUT sanitizing the package name (only the component name gets
    # `-`->`_`). A dash there yields a broken `-Dc-ares_..._DEFINE` flag ->
    # `<command-line>: expected ',' or '...' before '-' token`.
    "c-ares": "cares",
}

# When emitting `${project_name}_dependencies` entries inside another
# package's CMakeLists.var, the dep name is taken from this map if
# present, else falls back to LEGACY_NAME_MAP, else to the Conan name.
LEGACY_DEP_NAME_MAP = {
}

# Override the version used in .nupkg filename, .nuspec <version>, and
# every _dependencies entry that references the package. The Conan
# cache still keys by the real upstream version (`20240116.2`); this
# only changes what the deployed artifact advertises.
LEGACY_DEP_VERSION_MAP = {
    # Pretend our abseil/20240116.2 is absl/0.2.0 so it slots in as a
    # higher version (with .1 suffix) than the legacy `absl/0.2.0`
    # already in ProGet, taking precedence in downstream ResolveDependencies.
    "abseil": "0.2.0",
}

# Version suffix applied to every emitted .nupkg + nuspec + _dependencies
# entry, sourced from env LEGACY_NUPKG_VERSION_SUFFIX. Use when uploading
# upstream-mirror artifacts to a ProGet feed that already carries the
# same versions from a different source (Bitbucket forks) — the suffix
# disambiguates without renaming packages. Example values: ".1",
# "-elara1". Default empty → behavior unchanged.
VERSION_SUFFIX = os.environ.get("LEGACY_NUPKG_VERSION_SUFFIX", "")

# Маппинг ОС: Conan settings.os → legacy os-короткое
OS_SHORT = {"Linux": "lin", "Windows": "win", "Macos": "mac"}

# Arch shorthand differs per OS — derived from real CI artifact naming
# observed in TeamCity (see photo_index.md, photo_2026-04-27_17-31-50.jpg):
#   googletest.lin.gcc84.shared.x86_64.1.15.2.nupkg          (Linux: full arch)
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
    """Map (compiler, version) → CI-style short form.

    Real CI artifact names from TeamCity (see photo_index.md):
      gcc 8   → 'gcc8'    (e.g. abseil.lin.gcc8.static.x86_64.20250127.0.nupkg)
      gcc 8.4 → 'gcc84'   (e.g. googletest.lin.gcc84.shared.x86_64.1.15.2.nupkg)
      gcc 7.5 → 'gcc75'   (e.g. googletest.lin.gcc75.shared.arm-linaro.1.15.2.nupkg)
      gcc 9.3 → 'gcc93'   (e.g. googletest.lin.gcc93.shared.x64-e3300.1.15.2.nupkg)
      msvc 142 → 'v142'   (e.g. googletest.win.v142.shared.x64.1.15.2.nupkg)

    Astra is handled separately — see _resolve_os_short(): the Astra CI
    artifact (googletest.astra.gcc.static.x86_64) drops the gcc version
    entirely. Caller must pass LEGACY_OS_SHORT=astra env to opt in.
    """
    if compiler == "msvc":
        return f"v{version}"
    ver = str(version).replace(".", "").replace("_", "")
    if compiler == "gcc":
        return f"gcc{ver}" if ver else "gcc"
    return f"{compiler}{ver}"


def _resolve_os_short(os_name):
    """Resolve OS shortname, allowing env override for Astra (and similar).

    Conan doesn't natively distinguish AstraLinux from generic Linux, so the
    orchestrator script (test_all_profiles.sh) sets LEGACY_OS_SHORT=astra
    when building with the astra-gcc profile. Without override, falls back
    to standard Linux/Windows/Macos mapping.
    """
    override = os.environ.get("LEGACY_OS_SHORT", "").strip().lower()
    if override:
        return override
    return OS_SHORT.get(os_name, os_name.lower())


def _resolve_arch_with_toolchain(arch, os_name):
    """Append '-linaro' suffix when the user_toolchain points to a Linaro
    cmake file — matches CI naming for cross-compiled builds:
      googletest.lin.gcc75.shared.arm-linaro.1.15.2.nupkg
      googletest.lin.gcc75.shared.arm64-linaro.1.15.2.nupkg
    Detection is by env CONAN_USER_TOOLCHAIN (set per-arch by the
    orchestrator script), so native x86_64/i686 builds are unaffected.
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
    """Recognize static/shared/import libraries including versioned shared
    objects (e.g. libfoo.so.0.1.2). The simple tail-extension test misses
    those because `'libfoo.so.0.1.2'.split('.')[-1]` is '2'."""
    # Static + Windows imports + macOS dylib + bare .so / .dll.
    if fname.endswith((".a", ".lib", ".dll", ".dylib", ".so")):
        return True
    # Versioned ELF shared object: libfoo.so.0, libfoo.so.0.1.2, etc.
    if ".so." in fname:
        return True
    return False


# Aliases for libraries whose upstream filename ('libz.so') doesn't match
# the legacy package name ('zlib'). Downstream Elara CMake framework
# emits `-l<pkg_name>` on the link line, so the lib must also exist
# under that name. Resolved as additional symlinks alongside the
# original files (originals are kept too, so `-lz` still works).
LIB_FILENAME_ALIASES = {
    "zlib": {"z": "zlib"},     # libz.so       -> libzlib.so       (symlink)
                                # libz.so.1.3.0 -> libzlib.so.1.3.0
}

# Packages whose libs have a name prefix that downstream Elara CMake
# framework does NOT include — strip the prefix by creating an alias
# symlink. Example: upstream abseil ships `libabsl_strings.so`, but the
# Elara `absl/0.2.0` slot has `libstrings.so` — downstream resolver
# emits `-lstrings`, so we mint that symlink alongside the original.
LIB_FILENAME_PREFIX_STRIP = {
    "abseil": "absl_",          # libabsl_<X>.so -> lib<X>.so
}

# abseil is deployed differently from the rest — see abseil/conanfile.py.
# The Elara CMake framework expects abseil as 21 coarse component libs
# (`-lstrings`, `-lrandom`, ... — one per absl/<subdir>/), matching the
# legacy `absl/0.2.0` slot. abseil/conanfile.py aggregates those into
# `lib/legacy-coarse/`; its native ~150 fine libs stay in `lib/` for
# Conan consumers. For abseil the deployer packages that coarse set.
LEGACY_LIBDIR_OVERRIDE = {"abseil": "legacy-coarse"}
# The legacy `absl/0.2.0` artifact is tagged `.shared.` in its package id
# even though the coarse libs are static `.a`. Keep that tag so the
# downstream `absl:0.2.0(.1)` slot id keeps matching.
LEGACY_LINKAGE_OVERRIDE = {"abseil": "shared"}


def _add_lib_aliases(dst, pkg_name):
    """Create alias symlinks alongside the real libraries. Two mechanisms:
    1. LIB_FILENAME_ALIASES — explicit per-package base→alias rename.
    2. LIB_FILENAME_PREFIX_STRIP — drop a known prefix from every lib name.
    Originals are kept untouched so both naming conventions work."""
    if not os.path.isdir(dst):
        return
    aliases = LIB_FILENAME_ALIASES.get(pkg_name)
    if aliases:
        for fname in list(os.listdir(dst)):
            if not fname.startswith("lib"):
                continue
            stem_and_ext = fname[3:]  # strip 'lib'
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
        # Still create dst so the empty `-d/` directory is preserved by
        # downstream `.keepdir` logic — the legacy CMake framework expects
        # the directory to exist even if Debug libs are unavailable.
        os.makedirs(dst, exist_ok=True)
        return 0
    n = 0
    os.makedirs(dst, exist_ok=True)
    for f in os.listdir(src_lib):
        sf = os.path.join(src_lib, f)
        # Preserve symlinks instead of dereferencing them: libfoo.so ->
        # libfoo.so.X.Y.Z must stay a link in the .nupkg.
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
    """Map raw library basenames (from _list_libs, e.g. 'z', 'absl_strings')
    to the names the downstream Elara framework expects in the `components`
    list of CMakeLists.var.

    Must mirror the FILE renaming done by _add_lib_aliases — otherwise
    ResolveDependencies.cmake (foreach over `components`, line ~306) builds
    an IMPORTED target under the UPSTREAM name ('z') while consumers link
    the LEGACY name ('zlib'). CMake then degrades the unknown name to a
    bare link flag -> `ld: cannot find -lzlib`.
    """
    aliases = LIB_FILENAME_ALIASES.get(pkg_name, {})
    prefix = LIB_FILENAME_PREFIX_STRIP.get(pkg_name)
    out = []
    for lib in libs:
        if lib in aliases:
            out.append(aliases[lib])
        elif prefix and lib.startswith(prefix):
            out.append(lib[len(prefix):])
        else:
            out.append(lib)
    return out


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
        # `version_real` matches what is in the Conan cache (used for
        # cache lookups via `_find_debug_package_path` etc).
        # `version` is what we EMIT (filename, nuspec, _dependencies):
        # LEGACY_DEP_VERSION_MAP override (if any) + ProGet-conflict
        # VERSION_SUFFIX appended.
        version_real = str(dep.ref.version)
        version = LEGACY_DEP_VERSION_MAP.get(name, version_real) + VERSION_SUFFIX
        legacy_name = LEGACY_NAME_MAP.get(name, name)

        s = dep.settings
        os_name = str(s.os)
        compiler = str(s.compiler)
        compiler_version = str(s.compiler.version)
        arch = _resolve_arch_with_toolchain(s.arch, os_name)
        build_type = str(s.build_type)

        try:
            shared = bool(dep.options.shared)
        except Exception:
            shared = False
        linkage = "shared" if shared else "static"
        # abseil keeps its legacy `.shared.` slot tag even though built static.
        linkage = LEGACY_LINKAGE_OVERRIDE.get(name, linkage)

        os_short = _resolve_os_short(os_name)
        # Astra CI convention: drop gcc version (astra.gcc.static.x86_64).
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

        # Staging — unique per pkg_id; final archive packs from this dir
        # so root entries (.nuspec, CMakeLists.var, ...) land at zip root.
        staging = os.path.join(output_folder, "staging", pkg_id)
        if os.path.isdir(staging):
            shutil.rmtree(staging)
        os.makedirs(staging, exist_ok=True)

        # 1. include/
        src_include = os.path.join(release_pkg, "include")
        dst_include = os.path.join(staging, "include")
        if os.path.exists(src_include):
            shutil.copytree(src_include, dst_include)

        # 1b. proto/ — legacy layout ships `.proto` files (protobuf
        # well-knowns: timestamp.proto, duration.proto, ...; grpc plugin
        # protos) in a separate top-level `proto/` tree with the same
        # relative path structure as `include/`. Upstream protobuf installs
        # them into `<prefix>/include/google/protobuf/*.proto`, so mirror
        # any `*.proto` we copied above into `proto/` to match what the
        # legacy Elara framework's `protobuf_generate_grpc_cpp()` consumes
        # (`--proto_path=<pkg>/proto`). Without this, downstream `.proto`
        # files that `import "google/protobuf/timestamp.proto";` fail with
        # `File not found` during protoc invocation in el_conf builds.
        #
        # EXCLUDE upstream-only extras the Elara legacy fork strips:
        #   - `**/compiler/plugin.proto` — protoc plugin API; not in legacy
        #     .nupkg, and its presence breaks downstream protoc when it
        #     resolves transitive imports (verified IN-658 el_conf build,
        #     2026-05-25 — see test-astra/diff_two_dirs.sh).
        #   - `**/java/...` — Java-specific well-knowns like
        #     `java_features.proto` (edition-2023 syntax that older protoc
        #     can't parse); legacy doesn't ship them and they're irrelevant
        #     to C++ consumers.
        # Legacy protobuf 4.25.2 nupkg ships exactly 12 well-known .proto
        # files under `proto/google/protobuf/`; we match.
        dst_proto = os.path.join(staging, "proto")
        _PROTO_EXCLUDE_DIRS = {"compiler", "java"}
        if os.path.isdir(src_include):
            for root, dirs, files in os.walk(src_include):
                # Prune excluded subdirs in-place (os.walk respects this).
                dirs[:] = [d for d in dirs if d not in _PROTO_EXCLUDE_DIRS]
                for fname in files:
                    if not fname.endswith(".proto"):
                        continue
                    rel = os.path.relpath(os.path.join(root, fname), src_include)
                    target = os.path.join(dst_proto, rel)
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copy2(os.path.join(root, fname), target)

        # 2. lib/native/{,-d}/
        # abseil ships its legacy coarse libs in a lib/ sub-folder
        # (LEGACY_LIBDIR_OVERRIDE); everything else uses lib/ directly.
        _lib_sub = LEGACY_LIBDIR_OVERRIDE.get(name)

        def _libdir(pkg_root):
            base = os.path.join(pkg_root, "lib")
            return os.path.join(base, _lib_sub) if _lib_sub else base

        n_rel = _copy_libs(_libdir(release_pkg),
                           os.path.join(staging, "lib", "native", lib_suffix),
                           pkg_name=name)
        n_dbg = _copy_libs(_libdir(debug_pkg),
                           os.path.join(staging, "lib", "native", f"{lib_suffix}-d"),
                           pkg_name=name)
        # Component names must use the LEGACY naming (zlib, not z) — see
        # _legacy_component_names. The .so files themselves are aliased by
        # _add_lib_aliases inside _copy_libs above.
        libs = _legacy_component_names(_list_libs(_libdir(release_pkg)), name)

        # 3. .targets
        os.makedirs(os.path.join(staging, "build", "native"), exist_ok=True)
        with open(os.path.join(staging, "build", "native", f"{targets_name}.targets"),
                  "w", encoding="utf-8") as f:
            f.write(_generate_targets(legacy_name, os_short, compiler_short, linkage, arch, libs))

        # 4. .nuspec — NuGet/ProGet require it at archive root, not in nuget/.
        # Apply the same name+version remap that _dependencies uses, so the
        # .nuspec advertises the slots the downstream feed actually serves.
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

        # 5. .keepdir markers
        # `lib/native/<lib_suffix>{,-d}` must survive ZIP archiving even
        # when empty (ZipFile drops empty dirs). Downstream
        # ResolveDependencies.cmake checks the path exists and fails
        # hard ("Unable to find debug version of <pkg>") otherwise.
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
        components = libs if libs else [name]
        platforms = ["WINDOWS", "LINUX", "LINUX_ARM_NXP", "LINUX_ARM_LINARO",
                     "LINUX_ARM64_ROCKCHIP", "LINUX_ARM64_LINARO", "LINUX_ATOM", "WINCE800"]
        # Direct deps of THIS package only (not the whole transitive closure):
        # downstream Elara CMake framework (ResolveDependencies.cmake in
        # grpc_sdk and friends) resolves transitives by walking each
        # consumed package's own _dependencies var. Format that framework
        # expects: `<legacy_name>:<version>` per line, matching the
        # legacy_name + version of the corresponding .nupkg in the feed.
        var_deps = []
        for _, d in dep.dependencies.host.items():
            dep_legacy_name = LEGACY_DEP_NAME_MAP.get(
                d.ref.name, LEGACY_NAME_MAP.get(d.ref.name, d.ref.name))
            dep_version = (LEGACY_DEP_VERSION_MAP.get(d.ref.name, str(d.ref.version))
                           + VERSION_SUFFIX)
            var_deps.append(f"{dep_legacy_name}:{dep_version}")
        # Extra pseudo-deps that downstream ResolveDependencies.cmake
        # expects (because the legacy Elara grpc/1.60.1 fork shipped them
        # as separate packages) but upstream grpc/protobuf 1.60.1/4.25.2
        # have vendored internally. Only emitted for grpc 1.60.x. These
        # refer to packages from the legacy Bitbucket feed in ProGet
        # (not produced by this build), so VERSION_SUFFIX is NOT applied.
        if name == "grpc" and version.startswith("1.60."):
            var_deps.extend(["address_sorting:1.0.0", "upb:0.2.0"])
        with open(os.path.join(staging, "CMakeLists.var"), "w", encoding="utf-8") as f:
            f.write(_generate_cmakelists_var(legacy_name, version, components, platforms, var_deps))

        # 7. LICENSE.txt — некоторые рецепты (openssl) кладут в licenses/ не только
        # файлы, но и подпапки (licenses/external/...). Берём только plain-файлы;
        # последний выигрывает (одного файла достаточно для legacy-формата).
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

        # 8. .nupkg — pack from `staging` so .nuspec lands at archive root
        # (was packing from parent `staging/`, leaving an extra <variant_dir>/
        # wrapper that broke ProGet upload and downstream CMakeLists.var resolution).
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
