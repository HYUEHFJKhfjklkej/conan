import os
from conan import ConanFile
from conan.errors import ConanException
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, unzip


class Snap7Conan(ConanFile):
    name = "snap7"
    description = "Snap7: multi-platform Ethernet communication suite for Siemens S7 PLCs"
    license = "LGPL-3.0-or-later"
    homepage = "https://snap7.sourceforge.net"
    topics = ("siemens", "s7", "plc", "ethernet", "industrial")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"
    options = {"fPIC": [True, False]}
    default_options = {"fPIC": True}

    # Offline: локальный архив + наш CMakeLists (upstream собирается платформенными
    # makefile'ами build/unix/*.mk без aarch64-варианта; CMake покрывает все арки).
    exports_sources = "src/*", "CMakeLists.txt"

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

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
            # Upstream-релиз существует только как .7z (conan unzip() его не
            # распаковывает, на станке нет 7z) — сетевого фолбэка нет, нужен
            # переупакованный tar.gz в src/. Как пересоздать: HELP.txt [30].
            raise ConanException("snap7: нет офлайн-архива src/snap7-*.tar.gz "
                                 "(upstream .7z требует переупаковки, см. conandata.yml)")
        unzip(self, _local, strip_root=True)

    def generate(self):
        tc = CMakeToolchain(self)
        # наш CMakeLists лежит в recipe/export root; исходники — в source_folder
        tc.cache_variables["SNAP7_SRC_DIR"] = self.source_folder.replace("\\", "/")
        tc.generate()

    def build(self):
        cmake = CMake(self)
        # конфигурируем по нашему CMakeLists (export_sources root), не по source_folder
        cmake.configure(build_script_folder=os.path.join(self.source_folder, os.pardir))
        cmake.build()

    def package(self):
        for lic in ("lgpl-3.0.txt", "gpl.txt", "README.txt"):
            copy(self, lic, src=self.source_folder,
                 dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["snap7"]
        if self.settings.os in ("Linux", "FreeBSD"):
            self.cpp_info.system_libs = ["pthread", "rt"]
        elif self.settings.os == "Windows":
            self.cpp_info.system_libs = ["ws2_32", "winmm"]
