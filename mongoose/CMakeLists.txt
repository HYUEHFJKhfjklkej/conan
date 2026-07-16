cmake_minimum_required(VERSION 3.15)
project(mongoose C)
add_library(mongoose ${MONGOOSE_SRC_DIR}/mongoose.c)
target_include_directories(mongoose PUBLIC ${MONGOOSE_SRC_DIR})
set_target_properties(mongoose PROPERTIES PUBLIC_HEADER "${MONGOOSE_SRC_DIR}/mongoose.h")
include(GNUInstallDirs)
install(TARGETS mongoose
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
