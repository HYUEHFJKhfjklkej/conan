import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get


class GTestConan(ConanFile):
    name = "gtest"
    version = "1.14.0"
    description = "Google Testing and Mocking Framework"
    license = "BSD-3-Clause"
    url = "https://github.com/google/googletest"

    settings = "os", "compiler", "build_type", "arch"
    options = {
        "shared": [True, False],
        "build_gmock": [True, False],
        "hide_symbols": [True, False],
    }
    default_options = {
        "shared": False,
        "build_gmock": True,
        "hide_symbols": False,
    }

    # Export source tarball with the recipe for offline builds
    exports = "src/*.tar.gz"

    def source(self):
        # Try local archive first (offline), fallback to GitHub (online)
        local_archive = os.path.join(self.recipe_folder, "src", f"v{self.version}.tar.gz")
        if os.path.exists(local_archive):
            get(self, f"file:///{local_archive}", strip_root=True)
        else:
            get(self, f"https://github.com/google/googletest/archive/refs/tags/v{self.version}.tar.gz",
                strip_root=True)

    def layout(self):
        cmake_layout(self)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["BUILD_GMOCK"] = self.options.build_gmock
        tc.variables["INSTALL_GTEST"] = True
        tc.variables["gtest_force_shared_crt"] = True
        tc.variables["BUILD_SHARED_LIBS"] = self.options.shared
        tc.variables["gtest_hide_internal_symbols"] = self.options.hide_symbols
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.components["libgtest"].libs = ["gtest"]
        self.cpp_info.components["gtest_main"].libs = ["gtest_main"]
        self.cpp_info.components["gtest_main"].requires = ["libgtest"]

        if self.options.build_gmock:
            self.cpp_info.components["libgmock"].libs = ["gmock"]
            self.cpp_info.components["libgmock"].requires = ["libgtest"]
            self.cpp_info.components["gmock_main"].libs = ["gmock_main"]
            self.cpp_info.components["gmock_main"].requires = ["libgmock"]

        if self.settings.os == "Linux":
            self.cpp_info.components["libgtest"].system_libs = ["pthread"]
