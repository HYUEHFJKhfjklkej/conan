# CMake-бэкенд для MSVC: тарбол libmodbus несёт только autotools, а этот путь
# на Windows тянет msys2+automake+libtool на агент. Тот же приём, что у vcpkg.
# Файл экспортируется рецептом и копируется в source_folder только при is_msvc.
cmake_minimum_required(VERSION 3.15)
project(libmodbus C)

include(CheckIncludeFiles)
include(CheckSymbolExists)

if(WIN32)
    list(APPEND CMAKE_REQUIRED_LIBRARIES ws2_32)
    check_symbol_exists(gai_strerror "winsock2.h;ws2tcpip.h" HAVE_GAI_STRERROR)
else()
    check_include_files("netinet/in.h" HAVE_NETINET_IN_H)
    # ip.h без предварительного in.h не компилируется (как в configure.ac)
    check_include_files("netinet/in.h;netinet/ip.h" HAVE_NETINET_IP_H)
    check_symbol_exists(accept4 "sys/socket.h" HAVE_ACCEPT4)
    check_symbol_exists(strlcpy "string.h" HAVE_STRLCPY)
    check_symbol_exists(gai_strerror "netdb.h" HAVE_GAI_STRERROR)
    check_symbol_exists(TIOCSRS485 "sys/ioctl.h" HAVE_DECL_TIOCSRS485)
    check_symbol_exists(TIOCM_RTS "sys/ioctl.h" HAVE_DECL_TIOCM_RTS)
endif()

configure_file(config.h.cmake "${CMAKE_CURRENT_BINARY_DIR}/config.h")

add_library(modbus
    src/modbus.c
    src/modbus-data.c
    src/modbus-rtu.c
    src/modbus-tcp.c)
target_include_directories(modbus PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" src)
# Makefile.am форс-инклудит config.h во все TU (-include); повторяем —
# modbus-tcp.c читает HAVE_* без явного #include <config.h>
if(MSVC)
    target_compile_options(modbus PRIVATE "/FI${CMAKE_CURRENT_BINARY_DIR}/config.h")
else()
    target_compile_options(modbus PRIVATE "SHELL:-include ${CMAKE_CURRENT_BINARY_DIR}/config.h")
endif()

if(WIN32)
    target_link_libraries(modbus PRIVATE ws2_32)
    if(BUILD_SHARED_LIBS)
        target_compile_definitions(modbus PRIVATE DLLBUILD)
    endif()
endif()

include(GNUInstallDirs)
install(TARGETS modbus
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
# та же раскладка, что у autotools-пути: include/modbus/
install(FILES src/modbus.h src/modbus-version.h src/modbus-rtu.h src/modbus-tcp.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/modbus)
