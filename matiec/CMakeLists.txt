cmake_minimum_required(VERSION 3.15)
project(matiec CXX)

# Состав повторяет upstream Makefile.am: общая часть = absyntax + absyntax_utils
# + stage1_2 (с предзапечёнными flex/bison-выходами) + stage3 + stage4/stage4.cc;
# generate_c.cc и generate_iec.cc — unity-TU (сами инклудят свои generate_*_*.cc),
# util/*.cc не компилируются отдельно (шаблоны, инклудятся из .hh).
set(MATIEC_SRC_DIR "" CACHE PATH "matiec source tree")
set(MATIEC_HGVERSION "" CACHE STRING "pinned upstream changeset id")
set(_s ${MATIEC_SRC_DIR})

add_library(matiec_common STATIC
    ${_s}/absyntax/absyntax.cc
    ${_s}/absyntax/visitor.cc
    ${_s}/absyntax_utils/absyntax_utils.cc
    ${_s}/absyntax_utils/add_en_eno_param_decl.cc
    ${_s}/absyntax_utils/decompose_var_instance_name.cc
    ${_s}/absyntax_utils/array_dimension_iterator.cc
    ${_s}/absyntax_utils/case_element_iterator.cc
    ${_s}/absyntax_utils/function_call_iterator.cc
    ${_s}/absyntax_utils/function_call_param_iterator.cc
    ${_s}/absyntax_utils/function_param_iterator.cc
    ${_s}/absyntax_utils/get_sizeof_datatype.cc
    ${_s}/absyntax_utils/get_var_name.cc
    ${_s}/absyntax_utils/search_il_label.cc
    ${_s}/absyntax_utils/search_base_type.cc
    ${_s}/absyntax_utils/search_fb_instance_decl.cc
    ${_s}/absyntax_utils/search_fb_typedecl.cc
    ${_s}/absyntax_utils/search_varfb_instance_type.cc
    ${_s}/absyntax_utils/search_var_instance_decl.cc
    ${_s}/absyntax_utils/spec_init_separator.cc
    ${_s}/absyntax_utils/type_initial_value.cc
    ${_s}/absyntax_utils/debug_ast.cc
    ${_s}/absyntax_utils/get_datatype_info.cc
    ${_s}/stage1_2/iec_bison.cc
    ${_s}/stage1_2/iec_flex.cc
    ${_s}/stage1_2/create_enumtype_conversion_functions.cc
    ${_s}/stage1_2/stage1_2.cc
    ${_s}/stage3/stage3.cc
    ${_s}/stage3/flow_control_analysis.cc
    ${_s}/stage3/fill_candidate_datatypes.cc
    ${_s}/stage3/narrow_candidate_datatypes.cc
    ${_s}/stage3/forced_narrow_candidate_datatypes.cc
    ${_s}/stage3/print_datatypes_error.cc
    ${_s}/stage3/datatype_functions.cc
    ${_s}/stage3/lvalue_check.cc
    ${_s}/stage3/array_range_check.cc
    ${_s}/stage3/case_elements_check.cc
    ${_s}/stage3/constant_folding.cc
    ${_s}/stage3/declaration_check.cc
    ${_s}/stage3/enum_declaration_check.cc
    ${_s}/stage3/remove_forward_dependencies.cc
    ${_s}/stage4/stage4.cc)
target_include_directories(matiec_common PUBLIC
    ${_s} ${_s}/config ${_s}/absyntax ${_s}/absyntax_utils
    ${_s}/stage1_2 ${_s}/stage3 ${_s}/stage4 ${_s}/util)
target_compile_definitions(matiec_common PUBLIC
    HAVE_CONFIG_H "HGVERSION=\"${MATIEC_HGVERSION}\""
    # флаги stage1_2 из upstream Makefile.am (без них flex-выход не собирается)
    DEFAULT_LIBDIR="lib" YY_BUF_SIZE=65536)
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    target_compile_options(matiec_common PUBLIC -fpermissive)
endif()

add_executable(iec2c ${_s}/main.cc ${_s}/stage4/generate_c/generate_c.cc)
add_executable(iec2iec ${_s}/main.cc ${_s}/stage4/generate_iec/generate_iec.cc)
target_link_libraries(iec2c PRIVATE matiec_common)
target_link_libraries(iec2iec PRIVATE matiec_common)

include(GNUInstallDirs)
install(TARGETS iec2c iec2iec RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
# Дерево lib/ апстрима -> include/: *.txt-таблицы читает iec2c -I, заголовки
# для сгенерированного C-кода лежат в lib/C/ (Beremiz передаёт оба пути -I).
# lib/C/* дублируем и в корень include/, чтобы потребителю хватало одного -I.
install(DIRECTORY ${_s}/lib/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY ${_s}/lib/C/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
