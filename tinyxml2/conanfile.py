from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import apply_conandata_patches, copy, export_conandata_patches, get, rmdir
from conan.tools.scm import Version
import os

required_conan_version = ">=1.54.0"


class Tinyxml2Conan(ConanFile):
    name = "tinyxml2"
    description = "Simple, small, efficient, C++ XML parser that can be " \
                  "easily integrated into other programs."
    license = "Zlib"
    topics = ("tinyxml2", "xml", "parser")
    homepage = "https://github.com/leethomason/tinyxml2"
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

    # Offline-патч: локальный архив исходников уезжает в export_sources,
    # source() предпочитает его сетевому get() (closed-network CI).
    exports_sources = "src/*"

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

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["BUILD_TESTING"] = False
        if Version(self.version) < "8.1.0":
            # Relocatable shared lib on Macos
            tc.cache_variables["CMAKE_POLICY_DEFAULT_CMP0042"] = "NEW"
        tc.generate()

    def build(self):
        apply_conandata_patches(self)
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "LICENSE.txt", src=self.source_folder, dst=os.path.join(self.package_folder, "licenses"))
        cmake = CMake(self)
        cmake.install()
        rmdir(self, os.path.join(self.package_folder, "lib", "cmake"))
        rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))

    def package_info(self):
        self.cpp_info.set_property("cmake_file_name", "tinyxml2")
        self.cpp_info.set_property("cmake_target_name", "tinyxml2::tinyxml2")
        self.cpp_info.set_property("pkg_config_name", "tinyxml2")
        postfix = "d" if self.settings.build_type == "Debug" and Version(self.version) < "8.1.0" else ""
        self.cpp_info.libs = [f"tinyxml2{postfix}"]
        if self.settings.os == "Windows" and self.options.shared:
            self.cpp_info.defines.append("TINYXML2_IMPORT")
