import os
from conan import ConanFile
from conan.errors import ConanException
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, unzip

# Пин апстрима: github.com/beremiz/matiec @ 7949c0bda1787de9c7cacaa4876ede49f85262dd
# (2026-05-12; релизов/тегов у matiec нет, AC_INIT-версия вечная 0.1 —
# версия пакета 0.1.<дата коммита>).
MATIEC_HGVERSION = "7949c0bda178"


class MatiecConan(ConanFile):
    name = "matiec"
    description = "MatIEC: IEC 61131-3 (ST/IL/SFC) to C compiler (iec2c, iec2iec) + IEC runtime headers"
    license = "GPL-3.0-or-later AND LGPL-3.0-or-later"  # компилятор GPL, lib/ (рантайм) LGPL
    homepage = "https://github.com/beremiz/matiec"
    topics = ("iec-61131", "plc", "structured-text", "compiler", "beremiz")
    settings = "os", "arch", "compiler", "build_type"

    # Offline: локальный архив + наш CMakeLists. Upstream — autotools БЕЗ
    # shipped configure + flex/bison кодген; в архиве предзапечены
    # stage1_2/iec_{bison,flex}.cc|hh и config/config.h, поэтому на станке
    # не нужны ни autotools, ни flex, ни bison.
    exports_sources = "src/*", "CMakeLists.txt"

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
        if not _local:
            # Codeload-тарбол коммита не содержит генерённых flex/bison-выходов
            # и config.h — сетевой фолбэк дал бы несобираемое дерево.
            raise ConanException("matiec: нет офлайн-архива src/matiec-*.tar.gz "
                                 "(нужна переупаковка с предзапечёнными parser'ами, см. HELP [31])")
        unzip(self, _local, strip_root=True)

    def generate(self):
        tc = CMakeToolchain(self)
        # наш CMakeLists лежит в recipe/export root; исходники — в source_folder
        tc.cache_variables["MATIEC_SRC_DIR"] = self.source_folder.replace("\\", "/")
        tc.cache_variables["MATIEC_HGVERSION"] = MATIEC_HGVERSION
        tc.generate()

    def build(self):
        cmake = CMake(self)
        # конфигурируем по нашему CMakeLists (export_sources root), не по source_folder
        cmake.configure(build_script_folder=os.path.join(self.source_folder, os.pardir))
        cmake.build()

    def package(self):
        for lic in ("COPYING", "README.build"):
            copy(self, lic, src=self.source_folder,
                 dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        # lib/ (рантайм) — LGPL, отдельная лицензия
        copy(self, "COPYING.LESSER", src=os.path.join(self.source_folder, "lib"),
             dst=os.path.join(self.package_folder, "licenses"), keep_path=False)
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        # Пакет-инструмент: либ нет, полезная нагрузка — bin/iec2c, bin/iec2iec
        # и include/ = дерево lib/ апстрима (iec_std_lib.h и др. для компиляции
        # сгенерированного C; *.txt-таблицы читает сам iec2c через `-I`).
        self.cpp_info.libs = []
        self.cpp_info.includedirs = ["include"]
        bindir = os.path.join(self.package_folder, "bin")
        self.buildenv_info.prepend_path("PATH", bindir)
        self.runenv_info.prepend_path("PATH", bindir)
