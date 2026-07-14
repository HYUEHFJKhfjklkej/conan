from conan import ConanFile
from conan.tools.build import check_min_cppstd
from conan.tools.files import copy, get
from conan.tools.layout import basic_layout
import os

required_conan_version = ">=1.50.0"


class NlohmannJsonConan(ConanFile):
    name = "nlohmann_json"
    homepage = "https://github.com/nlohmann/json"
    description = "JSON for Modern C++ parser and generator."
    topics = "json", "header-only"
    url = "https://github.com/conan-io/conan-center-index"
    license = "MIT"
    package_type = "header-library"
    settings = "os", "arch", "compiler", "build_type"
    no_copy_source = True

    @property
    def _minimum_cpp_standard(self):
        return 11

    def layout(self):
        basic_layout(self, src_folder="src")

    def package_id(self):
        self.info.clear()

    def validate(self):
        if self.settings.compiler.cppstd:
            check_min_cppstd(self, self._minimum_cpp_standard)

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
        pass

    def build(self):
        pass

    def package(self):
        copy(self, "LICENSE*", self.source_folder, os.path.join(self.package_folder, "licenses"))
        copy(self, "*", os.path.join(self.source_folder, "include"), os.path.join(self.package_folder, "include"))

    def package_info(self):
        self.cpp_info.set_property("cmake_file_name", "nlohmann_json")
        self.cpp_info.set_property("cmake_target_name", "nlohmann_json::nlohmann_json")
        self.cpp_info.set_property("pkg_config_name", "nlohmann_json")
        self.cpp_info.bindirs = []
        self.cpp_info.libdirs = []
