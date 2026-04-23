from conan import ConanFile
from conan.tools.cmake import CMake, cmake_layout


class ExampleConsumer(ConanFile):
    name = "example"
    version = "1.0.0"
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    def requirements(self):
        # Используем gtest, собранный нашим кастомным рецептом
        self.requires("gtest/1.14.0")

    def layout(self):
        cmake_layout(self)

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
        cmake.test()
