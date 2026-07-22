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
        pkg = self.dependencies["qxorm"].package_folder
        libext = ".lib" if self.settings.os == "Windows" else ".a"
        libpref = "" if self.settings.os == "Windows" else "lib"
        lib = os.path.join(pkg, "lib", f"{libpref}QxOrm{libext}")
        for p in (lib,
                  os.path.join(pkg, "include", "QxOrm.h"),
                  # inl/ обязан быть сиблингом include/ — заголовки инклудят ../../inl/
                  os.path.join(pkg, "inl", "QxDao", "QxDao_Count.inl")):
            assert os.path.isfile(p), f"missing: {p}"
        if self.settings.os != "Windows":
            self.run(f'nm "{lib}" | grep -q -m1 -i qx', env="conanrun")
        self.output.info("qxorm ok: libQxOrm + include/ + inl/ present")
