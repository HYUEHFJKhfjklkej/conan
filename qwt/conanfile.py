import os
from conan import ConanFile
from conan.errors import ConanException
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import apply_conandata_patches, copy, export_conandata_patches, get, rmdir, unzip

# Qt НЕ является conan-депом: легаси резолвит его сайд-ченнелом QT5_ROOT_DIR
# (Qt 5.15.2 вшит в CI-образ gcc84-build-x86_64 deb'ом qt5-devel-elara;
# Qt5Configure.cmake фреймворка читает ту же переменную). Сборка — CMake-графт
# из CCI (патчи 0001-0003): qmake использовать НЕЛЬЗЯ — образный Qt собран
# commercial-редакцией, и qmake требует лицензионный файл (licheck), которого
# в контейнере нет; CMake find_package лицензию не проверяет — ровно так же
# собирается весь легаси Qt-код. Mac-смоук: brew qt (Qt6, патч 0003).


class QwtConan(ConanFile):
    name = "qwt"
    description = "Qwt: Qt Widgets for Technical Applications (plots, dials, sliders)"
    license = "LGPL-2.1-only WITH Qwt-exception-1.0"
    homepage = "https://qwt.sourceforge.io"
    topics = ("qt", "plot", "widgets", "charts")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
        "plot": [True, False],
        "widgets": [True, False],
        "svg": [True, False],
        "opengl": [True, False],
        "designer": [True, False],
        "polar": [True, False],
    }
    # svg=True (у CCI False): контент либы держим по stock-конфигу upstream —
    # наиболее вероятный состав легаси-пакета (ground-truth gap, HELP [32])
    default_options = {
        "shared": False,
        "fPIC": True,
        "plot": True,
        "widgets": True,
        "svg": True,
        "opengl": True,
        "designer": False,
        "polar": True,
    }

    exports_sources = "src/*"

    def export_sources(self):
        export_conandata_patches(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

    def layout(self):
        cmake_layout(self, src_folder="src")

    def _offline_source_archive(self):
        src_dir = os.path.join(self.export_sources_folder, "src")
        if not os.path.isdir(src_dir):
            return None
        for f in os.listdir(src_dir):
            if f.endswith((".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2")):
                return os.path.join(src_dir, f)
        return None

    def source(self):
        _local = self._offline_source_archive()
        if _local:
            unzip(self, _local, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version], strip_root=True)

    @property
    def _qt_prefix(self):
        qt_root = os.environ.get("QT5_ROOT_DIR", "").strip()
        if not qt_root:
            raise ConanException("qwt: env QT5_ROOT_DIR не задан. На линукс-станке его "
                                 "выставляет образ (/opt/Qt/5.15.2); на win-агенте задать "
                                 "корень Qt-инсталляции; для Mac-смоука — brew-префикс qt. "
                                 "См. HELP [32]")

        def _has_cmake(p):
            return os.path.isdir(os.path.join(p, "lib", "cmake"))

        if _has_cmake(qt_root):
            return qt_root
        # Qt-инсталляции кладут тулчейн-подкаталог: gcc_64 (Linux),
        # msvc2019_64 и т.п. (Windows), clang_64 (mac installer).
        for d in sorted(os.listdir(qt_root)):
            cand = os.path.join(qt_root, d)
            if os.path.isdir(cand) and _has_cmake(cand):
                return cand
        raise ConanException(f"qwt: в QT5_ROOT_DIR={qt_root} нет lib/cmake "
                             "ни в корне, ни в тулчейн-подкаталогах")

    @property
    def _qt_major(self):
        return 6 if os.path.isdir(os.path.join(self._qt_prefix, "lib", "cmake", "Qt6")) else 5

    def generate(self):
        tc = CMakeToolchain(self)
        tc.cache_variables["CMAKE_PREFIX_PATH"] = self._qt_prefix.replace("\\", "/")
        tc.variables["QWT_QT_VERSION_MAJOR"] = self._qt_major
        tc.variables["QWT_DLL"] = bool(self.options.shared)
        tc.variables["QWT_STATIC"] = not bool(self.options.shared)
        tc.variables["QWT_PLOT"] = bool(self.options.plot)
        tc.variables["QWT_WIDGETS"] = bool(self.options.widgets)
        tc.variables["QWT_SVG"] = bool(self.options.svg)
        tc.variables["QWT_OPENGL"] = bool(self.options.opengl)
        tc.variables["QWT_DESIGNER"] = bool(self.options.designer)
        tc.variables["QWT_POLAR"] = bool(self.options.polar)
        tc.variables["QWT_BUILD_PLAYGROUND"] = False
        tc.variables["QWT_BUILD_EXAMPLES"] = False
        tc.variables["QWT_BUILD_TESTS"] = False
        tc.variables["QWT_FRAMEWORK"] = False
        tc.variables["CMAKE_INSTALL_DATADIR"] = "res"
        tc.generate()

    def build(self):
        apply_conandata_patches(self)
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "COPYING", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()
        rmdir(self, os.path.join(self.package_folder, "lib", "cmake"))
        rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))

    def package_info(self):
        self.cpp_info.libs = ["qwt"]
        # Qt-либы потребитель линкует сам из QT5_ROOT_DIR (side-channel,
        # как во всём легаси-фреймворке) — conan-депа на Qt нет намеренно.
        if self.settings.os == "Windows" and self.options.shared:
            self.cpp_info.defines.append("QWT_DLL")
        if not self.options.plot:
            self.cpp_info.defines.append("NO_QWT_PLOT")
        if not self.options.polar:
            self.cpp_info.defines.append("NO_QWT_POLAR")
        if not self.options.widgets:
            self.cpp_info.defines.append("NO_QWT_WIDGETS")
        if not self.options.opengl:
            self.cpp_info.defines.append("QWT_NO_OPENGL")
        if not self.options.svg:
            self.cpp_info.defines.append("QWT_NO_SVG")
