import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, CMakeDeps, cmake_layout
from conan.tools.files import copy, get, unzip


class SoemConan(ConanFile):
    name = "soem"
    description = "Simple Open EtherCAT Master library"
    license = "GPL-2.0-only"
    homepage = "https://github.com/OpenEtherCATsociety/SOEM"
    topics = ("ethercat", "fieldbus", "industrial", "realtime")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"
    options = {"fPIC": [True, False]}
    default_options = {"fPIC": True}

    # Offline: локальный архив исходников в export_sources, source() предпочитает его.
    exports_sources = "src/*"

    def _offline_source_archive(self):
        src_dir = os.path.join(self.export_sources_folder, "src")
        if not os.path.isdir(src_dir):
            return None
        for f in os.listdir(src_dir):
            if f.endswith((".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2")):
                return os.path.join(src_dir, f)
        return None

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def layout(self):
        cmake_layout(self, src_folder="src")

    def source(self):
        _local = self._offline_source_archive()
        if _local:
            unzip(self, _local, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version], strip_root=True)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.cache_variables["SOEM_BUILD_SAMPLES"] = False
        tc.cache_variables["SOEM_BUILD_TESTS"] = False
        tc.generate()
        CMakeDeps(self).generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build(target="soem")

    def package(self):
        copy(self, "LICENSE", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        copy(self, "*.h", src=self.source_folder,
             dst=os.path.join(self.package_folder, "include"), keep_path=False)
        for pat in ("*.a", "*.lib"):
            copy(self, pat, src=self.build_folder,
                 dst=os.path.join(self.package_folder, "lib"), keep_path=False)

    def package_info(self):
        self.cpp_info.libs = ["soem"]
        if self.settings.os in ("Linux", "FreeBSD"):
            self.cpp_info.system_libs = ["pthread", "rt"]
        elif self.settings.os == "Windows":
            self.cpp_info.system_libs = ["ws2_32", "winmm"]
