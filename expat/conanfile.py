from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import collect_libs, copy, get, rmdir
from conan.tools.microsoft import is_msvc, is_msvc_static_runtime
from conan.tools.scm import Version
import os

required_conan_version = ">=2"


class ExpatConan(ConanFile):
    name = "expat"
    description = "Fast streaming XML parser written in C."
    license = "MIT"
    url = "https://github.com/conan-io/conan-center-index"
    homepage = "https://github.com/libexpat/libexpat"
    topics = ("xml", "parsing")
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
        "char_type": ["char", "wchar_t", "ushort"],
        "large_size": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
        "char_type": "char",
        "large_size": False,
    }

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")
        self.settings.rm_safe("compiler.cppstd")
        self.settings.rm_safe("compiler.libcxx")

    def layout(self):
        cmake_layout(self, src_folder="src")

    def build_requirements(self):
        if Version(self.version) >= "2.7.4":
            # Offline-патч: exact version вместо range, чтобы матчиться с [platform_tool_requires]
            self.tool_requires("cmake/3.25.1")

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
        tc.variables["EXPAT_BUILD_DOCS"] = False
        tc.variables["EXPAT_BUILD_EXAMPLES"] = False
        tc.variables["EXPAT_SHARED_LIBS"] = self.options.shared
        tc.variables["EXPAT_BUILD_TESTS"] = False
        tc.variables["EXPAT_BUILD_TOOLS"] = False
        tc.variables["EXPAT_CHAR_TYPE"] = self.options.char_type
        if is_msvc(self):
            tc.variables["EXPAT_MSVC_STATIC_CRT"] = is_msvc_static_runtime(self)
        tc.variables["EXPAT_BUILD_PKGCONFIG"] = False
        tc.variables["EXPAT_LARGE_SIZE"] = self.options.large_size
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "COPYING", src=self.source_folder, dst=os.path.join(self.package_folder, "licenses"))
        cmake = CMake(self)
        cmake.install()
        rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))
        rmdir(self, os.path.join(self.package_folder, "lib", "cmake"))
        rmdir(self, os.path.join(self.package_folder, "share"))

    def package_info(self):
        self.cpp_info.set_property("cmake_find_mode", "both")
        self.cpp_info.set_property("cmake_module_file_name", "EXPAT")
        self.cpp_info.set_property("cmake_module_target_name", "EXPAT::EXPAT")
        self.cpp_info.set_property("cmake_file_name", "expat")
        self.cpp_info.set_property("cmake_target_name", "expat::expat")
        self.cpp_info.set_property("pkg_config_name", "expat")

        self.cpp_info.libs = collect_libs(self)
        if not self.options.shared:
            self.cpp_info.defines = ["XML_STATIC"]
        if self.options.get_safe("char_type") in ("wchar_t", "ushort"):
            self.cpp_info.defines.append("XML_UNICODE")
        if self.options.get_safe("char_type") == "wchar_t":
            self.cpp_info.defines.append("XML_UNICODE_WCHAR_T")
        if self.options.large_size:
            self.cpp_info.defines.append("XML_LARGE_SIZE")

        if self.settings.os in ["Linux", "FreeBSD"]:
            self.cpp_info.system_libs.append("m")
