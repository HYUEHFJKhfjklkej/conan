import os
from conan import ConanFile
from conan.tools.layout import basic_layout


class TestConan(ConanFile):
    settings = "os", "arch", "compiler", "build_type"
    test_type = "explicit"

    def requirements(self):
        self.requires(self.tested_reference_str)

    def layout(self):
        basic_layout(self)

    def test(self):
        # Компиляция qwt-потребителя требует Qt-заголовков (QT5_ROOT_DIR
        # side-channel) — вне графа conan. Смоук пакета: состав + символы.
        qwt = self.dependencies["qwt"]
        pkg = qwt.package_folder
        lib = os.path.join(pkg, "lib", "libqwt.a")
        for p in (lib, os.path.join(pkg, "include", "qwt_plot.h"),
                  os.path.join(pkg, "include", "qwt.h")):
            assert os.path.isfile(p), f"missing: {p}"
        self.run(f'nm "{lib}" | grep -q -m1 QwtPlot', env="conanrun")
        self.output.info("qwt ok: libqwt.a + headers, QwtPlot symbols present")
