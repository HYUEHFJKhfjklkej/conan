import os
from conan import ConanFile
from conan.errors import ConanException
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, rmdir, unzip

# Qt через side-channel QT5_ROOT_DIR (образ станка / Qt агента), как qwt —
# см. qwt/conanfile.py и HELP [32]. Сборка CMake; build-деп qmsetup (+ его
# syscmdline) вендорен в src/-тарбол (git-сабмодули, codeload их не несёт) —
# корневой CMakeLists сам собирает его из qmsetup/ nested-cmake'ом, сети нет.
# Требует PRIVATE-заголовки Qt (core/gui/widgets-private) — полная
# Qt-инсталляция их несёт.


class QWindowKitConan(ConanFile):
    name = "qwindowkit"
    description = "QWindowKit: cross-platform frameless window framework for Qt (Widgets)"
    license = "Apache-2.0"
    homepage = "https://github.com/stdware/qwindowkit"
    topics = ("qt", "frameless", "window", "gui")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"

    exports_sources = "src/*"

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
        if not _local:
            # Codeload-тарбол тега НЕ содержит сабмодулей qmsetup/syscmdline —
            # сетевой фолбэк дал бы несобираемое дерево (см. HELP [33]).
            raise ConanException("qwindowkit: нет офлайн-архива src/qwindowkit-*.tar.gz "
                                 "(нужна переупаковка с вендоренными сабмодулями)")
        unzip(self, _local, strip_root=True)

    @property
    def _qt_prefix(self):
        qt_root = os.environ.get("QT5_ROOT_DIR", "").strip()
        if not qt_root:
            raise ConanException("qwindowkit: env QT5_ROOT_DIR не задан (см. HELP [32]/[33])")

        def _has_cmake(p):
            return os.path.isdir(os.path.join(p, "lib", "cmake"))

        if _has_cmake(qt_root):
            return qt_root
        for d in sorted(os.listdir(qt_root)):
            cand = os.path.join(qt_root, d)
            if os.path.isdir(cand) and _has_cmake(cand):
                return cand
        raise ConanException(f"qwindowkit: в QT5_ROOT_DIR={qt_root} нет lib/cmake")

    def generate(self):
        tc = CMakeToolchain(self)
        tc.cache_variables["CMAKE_PREFIX_PATH"] = self._qt_prefix.replace("\\", "/")
        tc.variables["QWINDOWKIT_BUILD_STATIC"] = True
        tc.variables["QWINDOWKIT_BUILD_WIDGETS"] = True
        tc.variables["QWINDOWKIT_BUILD_QUICK"] = False
        tc.variables["QWINDOWKIT_BUILD_EXAMPLES"] = False
        tc.variables["QWINDOWKIT_BUILD_DOCUMENTATIONS"] = False
        tc.variables["QWINDOWKIT_INSTALL"] = True
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "LICENSE", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()
        rmdir(self, os.path.join(self.package_folder, "lib", "cmake"))
        rmdir(self, os.path.join(self.package_folder, "share"))
        # MSVC debug-постфикс 'd' — нормализуем, имя либы едино на платформах
        libdir = os.path.join(self.package_folder, "lib")
        if os.path.isdir(libdir):
            for f in os.listdir(libdir):
                for base in ("QWKCore", "QWKWidgets"):
                    for ext in (".lib", ".a"):
                        if f in (f"{base}d{ext}", f"lib{base}d{ext}"):
                            plain = f.replace(f"{base}d", base, 1)
                            if not os.path.exists(os.path.join(libdir, plain)):
                                os.rename(os.path.join(libdir, f), os.path.join(libdir, plain))

    def package_info(self):
        self.cpp_info.libs = ["QWKWidgets", "QWKCore"]
        # апстрим ставит заголовки в include/QWindowKit/QWK*/ — инклуды
        # пишутся как <QWKWidgets/...>, поэтому оба корня
        self.cpp_info.includedirs = ["include", os.path.join("include", "QWindowKit")]
        # Qt-либы потребитель линкует сам из QT5_ROOT_DIR (side-channel).
        if self.settings.os == "Windows":
            self.cpp_info.system_libs = ["uxtheme"]
