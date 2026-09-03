###############################################################################
# ЗАГЛУШКА, не легаси-код. Harness кладёт пакет заранее как <pkg>.bin, поэтому
# до скачивания с фида дело доходить не должно. Если дошло — значит резолвер
# не увидел подложенный пакет, и падаем тем же текстом, что настоящий
# NuGetInstall.cmake, чтобы симптом совпадал с боевым.
###############################################################################
cmake_minimum_required(VERSION 3.18 FATAL_ERROR)

function(install_nuget_packages)
    cmake_parse_arguments(_a "" "PATH;RESULTS" "PACKAGES" ${ARGN})
    foreach(_p ${_a_PACKAGES})
        string(REPLACE ":" ";" _t "${_p}")
        list(GET _t 0 _n)
        message(FATAL_ERROR "Not found package ${_n} on nuget server!")
    endforeach()
    set(${_a_RESULTS} "" PARENT_SCOPE)
endfunction()
