/* config.h для CMake-пути: значения от check_* в CMakeLists.txt.
 * HAVE_DECL_* всегда определены 0/1 — исходники читают их через #if,
 * как генерирует autoheader. */
#cmakedefine HAVE_ACCEPT4 1
#cmakedefine HAVE_GAI_STRERROR 1
#cmakedefine HAVE_NETINET_IN_H 1
#cmakedefine HAVE_NETINET_IP_H 1
#cmakedefine HAVE_STRLCPY 1
#cmakedefine01 HAVE_DECL_TIOCSRS485
#cmakedefine01 HAVE_DECL_TIOCM_RTS
