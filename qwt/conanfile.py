import os
import shutil
from conan import ConanFile
from conan.errors import ConanException
from conan.tools.files import copy, get, replace_in_file, unzip
from conan.tools.layout import basic_layout

# Qt НЕ является conan-депом: легаси резолвит его сайд-ченнелом QT5_ROOT_DIR
# (Qt 5.15.2 вшит в CI-образ gcc84-build-x86_64 deb'ом qt5-devel-elara;
# Qt5Configure.cmake фреймворка читает ту же переменную). Рецепт повторяет
# схему: qmake берётся из $QT5_ROOT_DIR/gcc_64/bin, фолбэк — qmake с PATH
# (Mac-смоук на brew qt6 — qwt 6.2 совместим с Qt5/Qt6).


class QwtConan(ConanFile):
    name = "qwt"
    description = "Qwt: Qt Widgets for Technical Applications (plots, dials, sliders)"
    license = "LGPL-2.1-only WITH Qwt-exception-1.0"
    homepage = "https://qwt.sourceforge.io"
    topics = ("qt", "plot", "widgets", "charts")
    settings = "os", "arch", "compiler", "build_type"
    package_type = "static-library"

    exports_sources = "src/*"

    def layout(self):
        basic_layout(self, src_folder="src")

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
        # static .a (контент-контракт IN-658) + без designer/examples/playground/
        # tests — они не входят в libqwt; Plot/Polar/Widgets/Svg/OpenGL остаются.
        pri = os.path.join(self.source_folder, "qwtconfig.pri")
        replace_in_file(self, pri, "QWT_CONFIG           += QwtDll",
                        "# QWT_CONFIG           += QwtDll")
        for knob in ("QwtDesigner", "QwtExamples", "QwtPlayground", "QwtTests"):
            replace_in_file(self, pri, f"QWT_CONFIG     += {knob}",
                            f"# QWT_CONFIG     += {knob}")
        # qwtbuild.pri форсит release (debug_and_release на win) и инклудится
        # каждым subdir-.pro заново — CLI-переопределение qmake не доезжает.
        # Сорс общий для Release/Debug, поэтому build-type приходит через env.
        build_pri = os.path.join(self.source_folder, "qwtbuild.pri")
        replace_in_file(self, build_pri, "CONFIG           += debug_and_release",
                        "CONFIG           += $$(QWT_BUILD_TYPE)")
        replace_in_file(self, build_pri, "CONFIG           += release",
                        "CONFIG           += $$(QWT_BUILD_TYPE)")

    @property
    def _qmake(self):
        qt_root = os.environ.get("QT5_ROOT_DIR", "").strip()
        if qt_root:
            for sub in ("gcc_64", ""):
                cand = os.path.join(qt_root, sub, "bin", "qmake")
                if os.path.isfile(cand):
                    return cand
        found = shutil.which("qmake") or shutil.which("qmake6")
        if not found:
            raise ConanException("qwt: qmake не найден (нет QT5_ROOT_DIR и qmake не на PATH). "
                                 "x86_64-станок несёт Qt 5.15.2 в /opt/Qt — см. HELP [32]")
        return found

    def build(self):
        njobs = self.conf.get("tools.build:jobs", default=os.cpu_count() or 4, check_type=int)
        bt = "debug" if self.settings.build_type == "Debug" else "release"
        # env нужен ОБЕИМ командам: SUBDIRS-Makefile генерит sub-Makefile'ы
        # повторными вызовами qmake уже изнутри make
        self.run(f'QWT_BUILD_TYPE={bt} "{self._qmake}" '
                 f'"{os.path.join(self.source_folder, "qwt.pro")}"',
                 cwd=self.build_folder)
        self.run(f"QWT_BUILD_TYPE={bt} make -j{njobs}", cwd=self.build_folder)

    def package(self):
        # make install не используем (macx-ветка qwt не ставит заголовки):
        # у qwt ВСЕ публичные заголовки лежат плоско в src/, либа — в build/lib.
        copy(self, "COPYING", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        copy(self, "*.h", src=os.path.join(self.source_folder, "src"),
             dst=os.path.join(self.package_folder, "include"), keep_path=False)
        copy(self, "*.a", src=os.path.join(self.build_folder, "lib"),
             dst=os.path.join(self.package_folder, "lib"), keep_path=False)
        copy(self, "*.lib", src=os.path.join(self.build_folder, "lib"),
             dst=os.path.join(self.package_folder, "lib"), keep_path=False)
        # macx/win debug qwt суффиксует таргет (libqwt_debug.a) — нормализуем,
        # имя либы едино на всех платформах (на linux суффикса и так нет)
        libdir = os.path.join(self.package_folder, "lib")
        for suffixed, plain in (("libqwt_debug.a", "libqwt.a"), ("qwtd.lib", "qwt.lib")):
            sp = os.path.join(libdir, suffixed)
            pp = os.path.join(libdir, plain)
            if os.path.isfile(sp) and not os.path.isfile(pp):
                os.rename(sp, pp)

    def package_info(self):
        self.cpp_info.libs = ["qwt"]
        # Qt-либы потребитель линкует сам из QT5_ROOT_DIR (side-channel,
        # как во всём легаси-фреймворке) — conan-депа на Qt нет намеренно.
