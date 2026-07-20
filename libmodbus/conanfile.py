from conan import ConanFile
from conan.tools.apple import fix_apple_shared_install_name
from conan.tools.cmake import CMake, CMakeToolchain
from conan.tools.files import apply_conandata_patches, copy, export_conandata_patches, get, replace_in_file, rm, rmdir
from conan.tools.gnu import Autotools, AutotoolsToolchain
from conan.tools.layout import basic_layout
from conan.tools.microsoft import is_msvc
import os

required_conan_version = ">=1.57.0"


class LibmodbusConan(ConanFile):
    name = "libmodbus"
    description = "libmodbus is a free software library to send/receive data according to the Modbus protocol"
    homepage = "https://libmodbus.org/"
    topics = ("modbus", "protocol", "industry", "automation")
    license = "LGPL-2.1"
    url = "https://github.com/conan-io/conan-center-index"

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

    @property
    def _settings_build(self):
        return getattr(self, "settings_build", self.settings)

    def export_sources(self):
        export_conandata_patches(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")
        self.settings.rm_safe("compiler.cppstd")
        self.settings.rm_safe("compiler.libcxx")

    def layout(self):
        basic_layout(self, src_folder="src")

    def build_requirements(self):
        # msvc собирается CMake-путём (см. CMakeLists.txt рядом): autotools на
        # Windows тянут msys2/automake/libtool, которых нет на офлайн-агенте.
        if is_msvc(self):
            return

        self.tool_requires("libtool/2.4.7")

        if self._settings_build.os == "Windows":
            self.win_bash = True
            if not self.conf.get("tools.microsoft.bash:path", check_type=str):
                self.tool_requires("msys2/cci.latest")

    # Offline-патч: локальный архив исходников уезжает в export_sources,
    # source() предпочитает его сетевому get() (closed-network CI).
    # CMakeLists.txt/config.h.cmake — CMake-бэкенд для msvc-пути.
    exports_sources = "src/*", "CMakeLists.txt", "config.h.cmake"

    def _offline_source_archive(self):
        """Return path to bundled source archive in export_sources, or None."""
        import os as _os
        src_dir = _os.path.join(self.export_sources_folder, "src")
        if not _os.path.isdir(src_dir):
            return None
        # Prefer matching the upstream URL filename from conandata.yml
        sources = self.conan_data.get("sources", {}).get(str(self.version), {})
        urls = sources.get("url")
        if isinstance(urls, str):
            urls = [urls]
        elif urls is None:
            urls = []
        for url in urls:
            fname = url.rsplit("/", 1)[-1]
            candidate = _os.path.join(src_dir, fname)
            if _os.path.isfile(candidate):
                return candidate
        # Fallback: any archive in src/ (assume single archive)
        for fname in _os.listdir(src_dir):
            if fname.endswith((".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2")):
                return _os.path.join(src_dir, fname)
        return None

    def source(self):
        _local = self._offline_source_archive()
        if _local:
            from conan.tools.files import unzip
            unzip(self, _local, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version], strip_root=True)
        apply_conandata_patches(self)
        # Патчи 0001/0002 меняют configure.ac, но без autoreconf они инертны -
        # применяем эквивалент прямо к сгенерённому ./configure: не затираем
        # пользовательские CFLAGS/CXXFLAGS (conan передаёт -m32 и пр.).
        import os as _os
        _cfg = _os.path.join(self.source_folder, "configure")
        if _os.path.isfile(_cfg):
            for _a, _b in (('CFLAGS="-O2"',       'CFLAGS="-O2 $CFLAGS"'),
                           ('CXXFLAGS="-O2"',     'CXXFLAGS="-O2 $CXXFLAGS"'),
                           ('CFLAGS="-g -O0"',    'CFLAGS="-g -O0 $CFLAGS"'),
                           ('CXXFLAGS="-g -O0"',  'CXXFLAGS="-g -O0 $CXXFLAGS"')):
                try: replace_in_file(self, _cfg, _a, _b, strict=False)
                except Exception: pass

        # Offline-патч: docker-станок без autoconf/automake/libtool. Патчи/tar
        # могли сделать *.ac/*.am новее сгенерённых configure/Makefile.in/
        # aclocal.m4 -> make включает maintainer-mode и зовёт aclocal (нет в
        # образе). "Старим" autotools-входы, чтобы готовые файлы были актуальны.
        import os as _os, time as _t
        _now = _t.time()
        _sf = self.source_folder
        for _root, _dirs, _files in _os.walk(_sf):
            for _f in _files:
                _p = _os.path.join(_root, _f)
                if _f.endswith((".ac", ".am")) or _f in ("acinclude.m4", "configure.in"):
                    try: _os.utime(_p, (_now - 300, _now - 300))
                    except OSError: pass
        for _root, _dirs, _files in _os.walk(_sf):
            for _f in _files:
                _p = _os.path.join(_root, _f)
                if _f in ("aclocal.m4", "configure", "config.h.in", "ltmain.sh",
                          "config.guess", "config.sub", "config.status") or _f.endswith("Makefile.in"):
                    try: _os.utime(_p, (_now, _now))
                    except OSError: pass

    def generate(self):
        if is_msvc(self):
            tc = CMakeToolchain(self)
            tc.generate()
            return
        tc = AutotoolsToolchain(self)
        tc.configure_args.append("--disable-tests")
        tc.generate()

    def _patch_sources(self):
        if not self.options.shared:
            for decl in ("__declspec(dllexport)", "__declspec(dllimport)"):
                replace_in_file(self, os.path.join(self.source_folder, "src", "modbus.h"), decl, "")

    def build(self):
        self._patch_sources()
        if is_msvc(self):
            for f in ("CMakeLists.txt", "config.h.cmake"):
                copy(self, f, self.export_sources_folder, self.source_folder)
            cmake = CMake(self)
            cmake.configure()
            cmake.build()
            return
        autotools = Autotools(self)
        # Offline-патч: autoreconf убран (нет autoconf/automake/libtool в станке).
        # Релиз-тарбол несёт готовый configure; патч respect-cflags применён прямо
        # к нему в source() (иначе CFLAGS="-O2" затирает conan-флаги, вкл. -m32).
        autotools.configure()
        autotools.make()

    def package(self):
        copy(self, pattern="COPYING*", src=self.source_folder, dst=os.path.join(self.package_folder, "licenses"))
        if is_msvc(self):
            cmake = CMake(self)
            cmake.install()
            return
        autotools = Autotools(self)
        autotools.install()
        rm(self, "*.la", os.path.join(self.package_folder, "lib"))
        rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))
        rmdir(self, os.path.join(self.package_folder, "share"))
        fix_apple_shared_install_name(self)

    def package_info(self):
        self.cpp_info.set_property("pkg_config_name", "libmodbus")
        self.cpp_info.libs = ["modbus"]
        self.cpp_info.includedirs.append(os.path.join("include", "modbus"))
        if self.settings.os == "Windows" and not self.options.shared:
            self.cpp_info.system_libs = ["ws2_32", "wsock32"]
