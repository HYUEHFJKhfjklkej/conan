cmake_minimum_required(VERSION 3.15)
project(example_with_gtest LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# gtest найдётся автоматически через Conan-генератор CMakeDeps
find_package(gtest REQUIRED)

add_executable(example_test src/example.cpp src/example_test.cpp)
target_link_libraries(example_test gtest::gtest gtest::gtest_main)

enable_testing()
add_test(NAME example_test COMMAND example_test)
