###############################################################################
# Минимальный потребитель на легаси-фреймворке Elara.
#
# Это НЕ копия боевого корневого CMakeLists.txt из репозиториев SU2 (там 330
# строк: nuspec, clang-tools, install_package, systemdb). Здесь оставлено
# ровно то, что нужно, чтобы прогнать resolve_dependencies() над нашим
# .nupkg и проверить, доезжают ли до цели заголовки.
#
# Подставляется драйвером test-astra/test_legacy_consume.sh.
###############################################################################
cmake_minimum_required(VERSION 3.18 FATAL_ERROR)

include("${CMAKE_SOURCE_DIR}/CMakeLists.var")

project(${project_name} C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Кеш-переменные, которые боевой корень инициализирует до резолва.
set(project_include_dirs "" CACHE INTERNAL "")
set(project_definitions  "" CACHE STRING "" FORCE)
set(project_proto_dirs   "" CACHE STRING "" FORCE)
set(dependencies         "" CACHE STRING "" FORCE)
set(added_once           "" CACHE STRING "" FORCE)

# Резолвер зовёт find_package_handle_standard_args, но сам модуль не
# подключает: в боевом дереве это делает кто-то до него по цепочке include.
include(FindPackageHandleStandardArgs)

include("${CMAKE_SOURCE_DIR}/cmake/ResolveDependencies.cmake")

message(STATUS "consumer: TARGET_PLATFORM=${TARGET_PLATFORM} TARGET_ARCH_CPU=${TARGET_ARCH_CPU} BUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}")
message(STATUS "consumer: dependencies=${${project_name}_dependencies}")

resolve_dependencies(DEPENDENCIES ${${project_name}_dependencies})

message(STATUS "consumer: project_include_dirs=${project_include_dirs}")
message(STATUS "consumer: ${dep_name}_INCLUDE_DIRS=${${dep_name}_INCLUDE_DIRS}")

add_subdirectory(app)
