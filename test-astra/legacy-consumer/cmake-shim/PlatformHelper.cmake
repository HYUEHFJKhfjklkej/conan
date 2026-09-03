###############################################################################
# ЗАГЛУШКА, не легаси-код. Повторяет только те функции PlatformHelper.cmake,
# которые вызывает ResolveDependencies.cmake. Нужна, чтобы harness запускался
# там, где полного фреймворка нет (Mac, чистая dev-VM).
#
# Если FRAMEWORK указывает на настоящий cmake/ из репозитория SU2, драйвер
# берёт оттуда настоящий PlatformHelper, а этот файл не подключается.
#
# Формулы сверены с настоящим PlatformHelper.cmake (zlib/cmake, develop):
#   get_package_suffix -> ${platform}.${compiler}.${library}.${processor}
#   get_folder_suffix  -> ${platform}-${compiler}-${library}-${processor}
###############################################################################
cmake_minimum_required(VERSION 3.18 FATAL_ERROR)

function(get_platform_prefix)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    if("${TARGET_PLATFORM}" MATCHES "^LINUX")
        set(_p "lin")
    elseif("${TARGET_PLATFORM}" STREQUAL "WINDOWS")
        set(_p "win")
    elseif("${TARGET_PLATFORM}" STREQUAL "WINCE800")
        set(_p "wince800")
    else()
        message(FATAL_ERROR "shim: TARGET_PLATFORM='${TARGET_PLATFORM}' не распознан")
    endif()
    set(${_a_RESULT} "${_p}" PARENT_SCOPE)
endfunction()

function(get_processor_prefix)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    string(TOLOWER "${TARGET_ARCH_CPU}" _c)
    if(NOT "${_c}" STREQUAL "x86_64")
        string(REPLACE "_" "-" _c "${_c}")
    endif()
    set(${_a_RESULT} "${_c}" PARENT_SCOPE)
endfunction()

function(get_compiler_prefix)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    if(DEFINED LEGACY_COMPILER_PREFIX AND NOT "${LEGACY_COMPILER_PREFIX}" STREQUAL "")
        set(${_a_RESULT} "${LEGACY_COMPILER_PREFIX}" PARENT_SCOPE)
        return()
    endif()
    if(CMAKE_COMPILER_IS_GNUCXX)
        execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -dumpversion
                        OUTPUT_VARIABLE _v OUTPUT_STRIP_TRAILING_WHITESPACE)
        if("${_v}" MATCHES "^([0-9]+)\\.([0-9]+)")
            set(${_a_RESULT} "gcc${CMAKE_MATCH_1}${CMAKE_MATCH_2}" PARENT_SCOPE)
            return()
        endif()
        set(${_a_RESULT} "gcc" PARENT_SCOPE)
        return()
    endif()
    # Не GCC: harness'у достаточно любого стабильного префикса. Настоящее имя
    # слота считает настоящий PlatformHelper, здесь оно не проверяется.
    string(TOLOWER "${CMAKE_CXX_COMPILER_ID}" _id)
    set(${_a_RESULT} "${_id}" PARENT_SCOPE)
endfunction()

function(get_library_prefix)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    if(BUILD_SHARED_LIBS)
        set(${_a_RESULT} "shared" PARENT_SCOPE)
    else()
        set(${_a_RESULT} "static" PARENT_SCOPE)
    endif()
endfunction()

function(get_package_suffix)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    get_platform_prefix(RESULT _pl)
    get_compiler_prefix(RESULT _co)
    get_library_prefix(RESULT _li)
    get_processor_prefix(RESULT _pr)
    set(${_a_RESULT} "${_pl}.${_co}.${_li}.${_pr}" PARENT_SCOPE)
endfunction()

function(get_folder_suffix)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    get_platform_prefix(RESULT _pl)
    get_compiler_prefix(RESULT _co)
    get_library_prefix(RESULT _li)
    get_processor_prefix(RESULT _pr)
    set(${_a_RESULT} "${_pl}-${_co}-${_li}-${_pr}" PARENT_SCOPE)
endfunction()

function(get_rel_output_dir)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    set(${_a_RESULT} "${CMAKE_BINARY_DIR}/output/release" PARENT_SCOPE)
endfunction()

function(get_deb_output_dir)
    cmake_parse_arguments(_a "" "RESULT" "" ${ARGN})
    set(${_a_RESULT} "${CMAKE_BINARY_DIR}/output/debug" PARENT_SCOPE)
endfunction()
