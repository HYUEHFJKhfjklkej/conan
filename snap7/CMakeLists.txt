cmake_minimum_required(VERSION 3.15)
project(snap7 CXX)

# Состав либы = Objects0 из build/unix/common.mk (12 .cpp ядра) + C/C++
# consumer-обёртка release/Wrappers/c-cpp/snap7.cpp — вкомпилирована, чтобы
# классы TS7Client/TS7Server были доступны по одному -lsnap7; snap7.h — её
# заголовок и единственный публичный.
set(SNAP7_SRC_DIR "" CACHE PATH "snap7-full source tree")
set(_sys  ${SNAP7_SRC_DIR}/src/sys)
set(_core ${SNAP7_SRC_DIR}/src/core)
set(_lib  ${SNAP7_SRC_DIR}/src/lib)
set(_wrap ${SNAP7_SRC_DIR}/release/Wrappers/c-cpp)

add_library(snap7
    ${_sys}/snap_msgsock.cpp
    ${_sys}/snap_sysutils.cpp
    ${_sys}/snap_tcpsrvr.cpp
    ${_sys}/snap_threads.cpp
    ${_core}/s7_client.cpp
    ${_core}/s7_isotcp.cpp
    ${_core}/s7_micro_client.cpp
    ${_core}/s7_partner.cpp
    ${_core}/s7_peer.cpp
    ${_core}/s7_server.cpp
    ${_core}/s7_text.cpp
    ${_lib}/snap7_libmain.cpp
    ${_wrap}/snap7.cpp)
target_include_directories(snap7 PRIVATE ${_sys} ${_core} ${_lib} ${_wrap})

find_package(Threads REQUIRED)
target_link_libraries(snap7 PRIVATE Threads::Threads)
if(UNIX AND NOT APPLE)
    target_link_libraries(snap7 PRIVATE rt)
endif()
if(WIN32)
    target_link_libraries(snap7 PRIVATE ws2_32 winmm)
endif()

set_target_properties(snap7 PROPERTIES PUBLIC_HEADER "${_wrap}/snap7.h")
include(GNUInstallDirs)
install(TARGETS snap7
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
