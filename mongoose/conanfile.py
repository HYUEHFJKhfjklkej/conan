import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, get, unzip


class MongooseConan(ConanFile):
    name = "mongoose"
    description = "Embedded networking library: TCP/UDP, HTTP, WebSocket, MQTT clients/servers"
    license = "GPL-2.0-only"  # dual-licensed GPLv2 / commercial
    homepage = "https://github.com/cesanta/mongoose"
    topics = ("http", "websocket", "mqtt", "tcp", "embedded", "networking")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"
    options = {"fPIC": [True, False]}
    default_options = {"fPIC": True}

    # Offline: локальный архив + наш CMakeLists (mongoose не несёт своего build-скрипта).
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
            if f.endswith((".tar.gz", ".tgz")):
                return os.path.join(src_dir, f)
        return None

    def source(self):
        _local = self._offline_source_archive()
        if _local:
            unzip(self, _local, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version], strip_root=True)

    def generate(self):
        tc = CMakeToolchain(self)
        # наш CMakeLists лежит в recipe/export root; исходники — в source_folder
        tc.cache_variables["MONGOOSE_SRC_DIR"] = self.source_folder.replace("\\", "/")
        tc.generate()

    def build(self):
        cmake = CMake(self)
        # конфигурируем по нашему CMakeLists (export_sources root), не по source_folder
        cmake.configure(build_script_folder=os.path.join(self.source_folder, os.pardir))
        cmake.build()

    def package(self):
        copy(self, "LICENSE", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["mongoose"]
        if self.settings.os in ("Linux", "FreeBSD"):
            self.cpp_info.system_libs = ["pthread"]
