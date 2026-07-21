import os
import textwrap
from conan import ConanFile
from conan.tools.build import can_run
from conan.tools.files import save
from conan.tools.layout import basic_layout


class TestConan(ConanFile):
    settings = "os", "arch", "compiler", "build_type"
    generators = "VirtualRunEnv"
    test_type = "explicit"

    def requirements(self):
        self.requires(self.tested_reference_str, run=True)

    def layout(self):
        # без layout() build_folder = каталог рецепта — смоук мусорил
        # сгенерированным кодом прямо в дерево test_package/
        basic_layout(self)

    def test(self):
        if not can_run(self):
            return
        self.run("iec2c -v", env="conanrun")
        # end-to-end: транслируем минимальную ST-программу; -I указывает на
        # include/ пакета (там ieclib.txt и заголовки — единый каталог).
        matiec = self.dependencies["matiec"]
        inc = os.path.join(matiec.package_folder, "include")
        st = os.path.join(self.build_folder, "smoke.st")
        save(self, st, textwrap.dedent("""\
            PROGRAM prog0
            VAR x : INT; END_VAR
            x := 1;
            END_PROGRAM
            CONFIGURATION conf0
            RESOURCE res0 ON PLC
            TASK t0(INTERVAL := T#20ms, PRIORITY := 0);
            PROGRAM inst0 WITH t0 : prog0;
            END_RESOURCE
            END_CONFIGURATION
            """))
        self.run(f'iec2c -I "{inc}" "{st}"', env="conanrun", cwd=self.build_folder)
        for f in ("POUS.c", "conf0.c", "res0.c"):
            assert os.path.isfile(os.path.join(self.build_folder, f)), f"{f} not generated"
        self.output.info("matiec ok: iec2c translated smoke.st (POUS.c/conf0.c/res0.c)")
