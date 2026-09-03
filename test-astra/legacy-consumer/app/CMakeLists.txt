###############################################################################
# Компонент-потребитель. Три способа получить заголовки зависимости, ровно те,
# между которыми выбирает разработчик у себя в проекте. Способ выбирается
# переменной CONSUME_MODE.
###############################################################################
add_executable(app main.cpp)

if(WITH_QT)
    set(CMAKE_AUTOMOC ON)
    find_package(Qt5 COMPONENTS Core REQUIRED)
    target_sources(app PRIVATE qt_user.cpp qt_user.h)
    target_link_libraries(app PRIVATE Qt5::Core)
    set_target_properties(app PROPERTIES AUTOMOC ON)
endif()

if("${CONSUME_MODE}" STREQUAL "link")
    # Так пишут для обычного пакета с библиотекой: имя компонента = имя
    # IMPORTED-таргета, заголовки приезжают через его
    # INTERFACE_INCLUDE_DIRECTORIES. Для headers-only пакета таргета НЕТ,
    # потому что components пустой, и заголовки не приедут.
    target_link_libraries(app PRIVATE ${dep_name})

elseif("${CONSUME_MODE}" STREQUAL "include")
    # Так надо писать для headers-only пакета: переменную ставит сам резолвер
    # (`set(<pkg>_INCLUDE_DIRS ...)`, комментарий в исходнике —
    # "global for using with headers only packages").
    target_include_directories(app PRIVATE ${${dep_name}_INCLUDE_DIRS})

elseif("${CONSUME_MODE}" STREQUAL "project")
    # Вариант без привязки к имени пакета: все include-каталоги всех
    # зависимостей разом.
    target_include_directories(app PRIVATE ${project_include_dirs})

else()
    message(FATAL_ERROR "CONSUME_MODE must be link|include|project, got '${CONSUME_MODE}'")
endif()
