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
        # Компиляция потребителя требует Qt (side-channel) — смоук состава.
        pkg = self.dependencies["qwindowkit"].package_folder
        libext = ".lib" if self.settings.os == "Windows" else ".a"
        libpref = "" if self.settings.os == "Windows" else "lib"
        for name in ("QWKCore", "QWKWidgets"):
            p = os.path.join(pkg, "lib", f"{libpref}{name}{libext}")
            assert os.path.isfile(p), f"missing: {p}"
        hdr = os.path.join(pkg, "include", "QWindowKit", "QWKWidgets", "widgetwindowagent.h")
        assert os.path.isfile(hdr), f"missing: {hdr}"
        if self.settings.os != "Windows":
            lib = os.path.join(pkg, "lib", "libQWKWidgets.a")
            self.run(f'nm "{lib}" | grep -q -m1 WidgetWindowAgent', env="conanrun")
        self.output.info("qwindowkit ok: QWKCore+QWKWidgets libs, headers present")
