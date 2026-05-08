message(STATUS "==LINARO-ARM-TC== included from ${CMAKE_CURRENT_LIST_FILE}")

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(_LINARO /opt/linaro-arm-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf)
set(_SYSROOT /opt/linaro-arm-7.5.0/sysroot-glibc-linaro-2.25-2019.12-rc1-arm-linux-gnueabihf)

set(CMAKE_C_COMPILER   ${_LINARO}/bin/arm-linux-gnueabihf-gcc   CACHE FILEPATH "linaro arm gcc"   FORCE)
set(CMAKE_CXX_COMPILER ${_LINARO}/bin/arm-linux-gnueabihf-g++   CACHE FILEPATH "linaro arm g++"   FORCE)
set(CMAKE_AR           ${_LINARO}/bin/arm-linux-gnueabihf-ar    CACHE FILEPATH "linaro arm ar"    FORCE)
set(CMAKE_RANLIB       ${_LINARO}/bin/arm-linux-gnueabihf-ranlib CACHE FILEPATH "linaro arm ranlib" FORCE)
set(CMAKE_STRIP        ${_LINARO}/bin/arm-linux-gnueabihf-strip CACHE FILEPATH "linaro arm strip" FORCE)

# Workaround for linaro 7.5 BFD-ld (binutils 2.32): when cross-linking
# shared libraries with debug info (e.g. libabsl_cordz_*.so), the BFD
# linker corrupts .strtab and the next link step fails with
# "invalid string offset >= ... for section '.strtab'". Switch to the
# gold linker which is shipped alongside (arm-linux-gnueabihf-ld.gold)
# and does not have this bug.
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=gold")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-fuse-ld=gold")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=gold")

set(CMAKE_SYSROOT ${_SYSROOT})
set(CMAKE_FIND_ROOT_PATH ${_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
