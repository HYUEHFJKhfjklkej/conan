message(STATUS "==LINARO-ARM64-TC== included from ${CMAKE_CURRENT_LIST_FILE}")

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(_LINARO /opt/linaro-arm64-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_aarch64-linux-gnu)
set(_SYSROOT /opt/linaro-arm64-7.5.0/sysroot-glibc-linaro-2.25-2019.12-rc1-aarch64-linux-gnu)

set(CMAKE_C_COMPILER   ${_LINARO}/bin/aarch64-linux-gnu-gcc    CACHE FILEPATH "linaro aarch64 gcc"    FORCE)
set(CMAKE_CXX_COMPILER ${_LINARO}/bin/aarch64-linux-gnu-g++    CACHE FILEPATH "linaro aarch64 g++"    FORCE)
set(CMAKE_AR           ${_LINARO}/bin/aarch64-linux-gnu-ar     CACHE FILEPATH "linaro aarch64 ar"     FORCE)
set(CMAKE_RANLIB       ${_LINARO}/bin/aarch64-linux-gnu-ranlib CACHE FILEPATH "linaro aarch64 ranlib" FORCE)
set(CMAKE_STRIP        ${_LINARO}/bin/aarch64-linux-gnu-strip  CACHE FILEPATH "linaro aarch64 strip"  FORCE)

# Workaround for linaro 7.5 BFD-ld (binutils 2.32): when cross-linking
# shared libraries with debug info, the BFD linker corrupts .strtab.
# Switch to the gold linker shipped alongside (aarch64-linux-gnu-ld.gold).
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=gold")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-fuse-ld=gold")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=gold")

set(CMAKE_SYSROOT ${_SYSROOT})
set(CMAKE_FIND_ROOT_PATH ${_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
