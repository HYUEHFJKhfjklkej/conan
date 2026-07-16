import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, get, unzip


class NanopbConan(ConanFile):
    name = "nanopb"
    description = "Protocol Buffers with small code size (embedded C runtime)"
    license = "Zlib"
    homepage = "https://github.com/nanopb/nanopb"
    topics = ("protobuf", "embedded", "serialization")
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
        tc.cache_variables["nanopb_BUILD_RUNTIME"] = True
        # генератор (protoc-плагин) требует python + protobuf — оффлайн не тянем;
        # мигрируем только рантайм-библиотеку (pb_encode/decode/common).
        tc.cache_variables["nanopb_BUILD_GENERATOR"] = False
        tc.cache_variables["BUILD_SHARED_LIBS"] = False
        tc.cache_variables["BUILD_STATIC_LIBS"] = True
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "LICENSE.txt", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["protobuf-nanopb"]
        self.cpp_info.includedirs = ["include/nanopb"]   # nanopb ставит заголовки в include/nanopb/
        self.cpp_info.set_property("cmake_file_name", "nanopb")
        self.cpp_info.set_property("cmake_target_name", "nanopb::protobuf-nanopb")
