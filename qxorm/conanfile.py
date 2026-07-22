import os
from conan import ConanFile
from conan.errors import ConanException
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, get, unzip

# Qt через side-channel QT5_ROOT_DIR (образ станка / Qt агента), как qwt —
# см. qwt/conanfile.py и HELP [32]. Лицензия QxOrm двойная: GPLv3 или
# коммерческая QXPL (EUR 400/проект) — легаси QXORM уже жил в проде,
# лицензионная позиция Elara существует; фиксируем факт (HELP [34]).
# Boost НЕ нужен (опционален с 1.4.4, по умолчанию выключен).


class QxOrmConan(ConanFile):
    name = "qxorm"
    description = "QxOrm: C++ ORM (Object Relational Mapping) library for Qt (QtSql)"
    license = "GPL-3.0-only OR LicenseRef-QXPL-commercial"
    homepage = "https://www.qxorm.com"
    topics = ("qt", "orm", "database", "sql")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"

    exports_sources = "src/*"

    def layout(self):
        cmake_layout(self, src_folder="src")

    def _offline_source_archive(self):
        src_dir = os.path.join(self.export_sources_folder, "src")
        if not os.path.isdir(src_dir):
            return None
        for f in os.listdir(src_dir):
            if f.endswith((".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2")):
                return os.path.join(src_dir, f)
        return None

    def source(self):
        _local = self._offline_source_archive()
        if _local:
            unzip(self, _local, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version], strip_root=True)

    @property
    def _qt_prefix(self):
        qt_root = os.environ.get("QT5_ROOT_DIR", "").strip()
        if not qt_root:
            raise ConanException("qxorm: env QT5_ROOT_DIR не задан (см. HELP [32]/[34])")

        def _has_cmake(p):
            return os.path.isdir(os.path.join(p, "lib", "cmake"))

        if _has_cmake(qt_root):
            return qt_root
        for d in sorted(os.listdir(qt_root)):
            cand = os.path.join(qt_root, d)
            if os.path.isdir(cand) and _has_cmake(cand):
                return cand
        raise ConanException(f"qxorm: в QT5_ROOT_DIR={qt_root} нет lib/cmake")

    def generate(self):
        tc = CMakeToolchain(self)
        tc.cache_variables["CMAKE_PREFIX_PATH"] = self._qt_prefix.replace("\\", "/")
        # static .a (контент-контракт IN-658); фичи — stock-дефолты upstream
        # (без boost, без QtGui/QtNetwork-сериализации). ВАЖНО: _QX_ENABLE_*
        # меняют layout классов в заголовках — у потребителей дефолты должны
        # совпадать (совпадают, пока и мы, и они на stock).
        tc.variables["_QX_STATIC_BUILD"] = True
        tc.variables["_QX_ENABLE_BOOST"] = False
        tc.variables["_QX_ENABLE_QT_GUI"] = False
        tc.variables["_QX_ENABLE_QT_NETWORK"] = False
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "license.gpl3.txt", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()
        # безусловный CMAKE_DEBUG_POSTFIX "d" — нормализуем имя либы
        libdir = os.path.join(self.package_folder, "lib")
        if os.path.isdir(libdir):
            for suffixed, plain in (("libQxOrmd.a", "libQxOrm.a"),
                                    ("QxOrmd.lib", "QxOrm.lib")):
                sp = os.path.join(libdir, suffixed)
                pp = os.path.join(libdir, plain)
                if os.path.isfile(sp) and not os.path.isfile(pp):
                    os.rename(sp, pp)

    def package_info(self):
        self.cpp_info.libs = ["QxOrm"]
        # потребители статической QxOrm обязаны определять _QX_STATIC_BUILD
        # (на MSVC иначе dllimport; заголовки инклудят ../../inl/ — каталог
        # inl/ едет в пакет сиблингом include/)
        self.cpp_info.defines = ["_QX_STATIC_BUILD"]
        # Qt-либы (Core, Sql) потребитель линкует сам из QT5_ROOT_DIR.
