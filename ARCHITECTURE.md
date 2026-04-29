# conan-recipes — архитектура и инструкция

Репозиторий рецептов Conan для third-party C++ библиотек проекта Elara.
Задача — заменить самописные TeamCity-сборки на Conan, сохранив бесшовную совместимость
с существующими `.nupkg` артефактами (структура, имена, метаданные).

Репозиторий: `git@github.com:HYUEHFJKhfjklkej/conan.git`

---

## Структура репо

```
conan-recipes/
├── gtest/                               ← рецепт пакета gtest
│   ├── conanfile.py                       рецепт сборки
│   └── src/v1.15.2.tar.gz                 исходники для offline-сборки
├── example/                             ← тестовый потребитель (sanity check)
├── profiles/                            ← профили компиляторов
│   ├── astra-gcc                          Astra Linux, GCC из дистрибутива
│   ├── lin-gcc84-x86_64                   Linux x64, GCC 8.4 (текущий TeamCity)
│   ├── lin-gcc84-i686                     Linux x86, GCC 8.4
│   ├── lin-gcc75-arm-linaro               Linux ARM, Linaro GCC 7.5
│   ├── lin-gcc-aarch64-linaro             Linux ARM64, Linaro GCC 7.5
│   ├── win-v142-x64 / win-v143-x64        Windows MSVC (VS 2019 / VS 2022)
│   └── …
├── extensions/deployers/
│   └── legacy_nupkg.py                  ← Conan-deployer: упаковщик в legacy .nupkg
├── packages-linux/                      ← offline pip-пакеты Conan (Linux x86_64)
├── packages/                            ← offline pip-пакеты Conan (Windows x86_64)
├── test-astra/                          ← скрипты для Linux/Astra
│   ├── install_deps.sh                    apt-get build-essential, cmake, python3
│   ├── setup.sh                           создание venv + offline install Conan
│   ├── run_test.sh                        полный e2e прогон
│   └── README.md                          краткая инструкция
├── test-windows/                        ← скрипты для Windows
│   ├── setup.bat                          создание venv + offline install Conan
│   └── run_test.bat                       полный e2e прогон
├── Dockerfile.astra-test                ← PoC в Docker (gcc:12-bookworm под Astra)
├── docker-compose.yml + server.conf     ← Conan-сервер (опционально, для будущей публикации)
├── requirements.txt                     ← conan>=2.0
└── .gitignore, .dockerignore
```

---

## Архитектура

### Идея

```
        ┌────────────────────┐
        │   <pkg>/           │  ← общее: рецепт + tarball
        │   conanfile.py     │
        │   src/*.tar.gz     │
        └─────────┬──────────┘
                  │
       ┌──────────┴──────────┐
       │                     │
┌──────▼──────┐      ┌───────▼──────┐
│ profiles/   │      │ profiles/    │
│ astra-gcc   │      │ win-v143-x64 │
└──────┬──────┘      └───────┬──────┘
       │                     │
       │ test-astra/         │ test-windows/
       │ run_test.sh         │ run_test.bat
       │ apt + bash          │ MSVC + cmd
       │                     │
┌──────▼──────────┐  ┌───────▼────────────┐
│ ~/.conan2/      │  │ %USERPROFILE%\.conan2\│
│ {Release,Debug} │  │ {Release,Debug}    │
│ libgtest.a etc  │  │ gtest.lib etc      │
└──────┬──────────┘  └───────┬────────────┘
       │                     │
       └──────────┬──────────┘
                  │ conan install --deployer=legacy_nupkg
                  ▼
         ┌────────────────────┐
         │ extensions/        │  ← общее: Python deployer
         │ deployers/         │
         │ legacy_nupkg.py    │
         └─────────┬──────────┘
                   │
                   ▼
         output/<name>.<os>.<compiler>.<linkage>.<arch>.<ver>.nupkg
```

### Ключевые компоненты

| Компонент | Назначение |
|---|---|
| `<pkg>/conanfile.py` | Описание сборки — `source/build/package/package_info`. Кроссплатформенный. |
| `<pkg>/src/v<version>.tar.gz` | Исходники, прибиты к рецепту для offline-сборки. |
| `profiles/<name>` | Настройки компилятора, архитектуры, runtime, флагов. По одному на платформу. |
| `extensions/deployers/legacy_nupkg.py` | Conan-deployer. Берёт собранные пакеты из кеша, генерит метаданные (`.targets`, `.nuspec`, `CMakeLists.var`, `.keepdir`), упаковывает в `.nupkg` с legacy-структурой. |
| `test-astra/`, `test-windows/` | Платформозависимые скрипты-обёртки для разработчика. |
| `packages-linux/`, `packages/` | wheel-файлы Conan для offline-установки на закрытых машинах. |

### Поток сборки одного пакета

1. **Подготовка окружения** (один раз):
   - Linux: `sudo ./test-astra/install_deps.sh && ./test-astra/setup.sh`
   - Windows: `test-windows\setup.bat`
2. **Сборка Release**: `conan create <pkg>/ --profile=<profile> -s build_type=Release --build=missing --no-remote`
3. **Сборка Debug**: тот же `conan create` с `-s build_type=Debug`. У них разные `package_id`, обе версии живут в кеше параллельно.
4. **Тест потребителя** (опционально, sanity): `conan install` + `cmake` + `ctest` в `example/`.
5. **Упаковка**: `conan install --requires=<pkg>/<ver> --profile=<profile> --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/`. Deployer находит обе версии (Release и Debug) в кеше, собирает legacy-структуру, упаковывает в `.nupkg`.

### Структура выходного `.nupkg`

```
googletest.lin.gcc84.shared.x86_64.1.15.2.nupkg
└── lin.gcc84.shared.x86_64/
    ├── build/native/googletest.lin.gcc84.shared.x86_64.targets
    ├── include/{gmock,gtest}/...
    ├── lib/native/lin-gcc84-shared-x86_64/   ← Release: libgtest.a, libgmock.a, ...
    ├── lib/native/lin-gcc84-shared-x86_64-d/ ← Debug: те же файлы, с -g -O0
    ├── lib/net461/.keepdir
    ├── nuget/googletest.nuspec
    ├── proto/.keepdir
    ├── CMakeLists.var
    └── LICENSE.txt
```

Структура — байт-в-байт совпадает с тем, что выкладывает текущий TeamCity.

---

## Различия Linux vs Windows

| Аспект | Linux | Windows |
|---|---|---|
| Скрипт прогона | `test-astra/run_test.sh` | `test-windows/run_test.bat` |
| Установка зависимостей | apt-get (нужен интернет один раз) | предустановлены: VS 2019/2022, CMake, Python |
| Offline pip-пакеты | `packages-linux/` (cp311 manylinux) | `packages/` (cp311 win_amd64) |
| Кеш Conan | `~/.conan2/` | `%USERPROFILE%\.conan2\` |
| Компилятор | gcc | MSVC (`cl.exe`, `link.exe`, `rc.exe`) |
| CMake-генератор | Unix Makefiles | Visual Studio 17 2022 (multi-config) |
| Расширение библиотек | `.a` (static), `.so` (shared) | `.lib`, `.dll` |
| Имена файлов | `libgtest.a` | `gtest.lib` |
| `compiler.runtime` | не используется | критично: `dynamic` (`/MD`) или `static` (`/MT`) |
| Профиль | `astra-gcc`, `lin-gcc84-x86_64` | `win-v142-x64`, `win-v143-x64` |

**Windows-специфика**: переменная `RC` в bat-скриптах **не использовать** — она зарезервирована под Resource Compiler (`rc.exe`). Перезаписывание ломает CMake.

---

## Как добавить новый пакет

На примере **zlib 1.3.1**.

### Шаг 1. Создать папку рецепта

```bash
mkdir -p zlib/src
```

### Шаг 2. Написать `zlib/conanfile.py`

```python
import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get, copy


class ZlibConan(ConanFile):
    name = "zlib"
    version = "1.3.1"
    description = "zlib data compression library"
    license = "Zlib"
    url = "https://github.com/madler/zlib"

    settings = "os", "compiler", "build_type", "arch"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
    }

    exports = "src/*.tar.gz"   # tarball едет вместе с рецептом

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def source(self):
        local = os.path.join(self.recipe_folder, "src", f"v{self.version}.tar.gz")
        if os.path.exists(local):
            get(self, f"file:///{local}", strip_root=True)
        else:
            get(self,
                f"https://github.com/madler/zlib/releases/download/v{self.version}/zlib-{self.version}.tar.gz",
                strip_root=True)

    def layout(self):
        cmake_layout(self)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["BUILD_SHARED_LIBS"] = self.options.shared
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()
        copy(self, "LICENSE", self.source_folder,
             os.path.join(self.package_folder, "licenses"))

    def package_info(self):
        self.cpp_info.libs = ["z" if self.settings.os != "Windows" else "zlib"]
```

### Шаг 3. Положить исходники

```bash
wget https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz \
    -O zlib/src/v1.3.1.tar.gz
```

Имя должно быть **`v{version}.tar.gz`** — этого ждёт `source()`.

### Шаг 4. (опционально) Маппинг имени для legacy

Если в TeamCity артефакт называется не так, как Conan-имя — добавить в deployer:

```python
# extensions/deployers/legacy_nupkg.py
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    # "zlib": "zlib-shared",   ← если нужно
}
```

### Шаг 5. (опционально) Зависимости

```python
def requirements(self):
    self.requires("openssl/3.2.0")
    self.requires("zlib/1.3.1")
```

Conan автоматически:
- проверит/соберёт зависимости при `conan install`
- передаст их пути в build curl
- заполнит `<dependencies>` в `.nuspec`

### Шаг 6. Собрать локально

**Linux:**
```bash
source venv/bin/activate
conan create zlib/ --profile=profiles/astra-gcc -s build_type=Release --build=missing --no-remote
conan create zlib/ --profile=profiles/astra-gcc -s build_type=Debug   --build=missing --no-remote
```

**Windows:**
```cmd
call venv\Scripts\activate.bat
conan create zlib\ --profile=profiles\win-v143-x64 -s build_type=Release --build=missing --no-remote
conan create zlib\ --profile=profiles\win-v143-x64 -s build_type=Debug   --build=missing --no-remote
```

### Шаг 7. Проверить кеш

```bash
conan list "zlib/1.3.1:*"
```

Должно быть два `package_id` (Release + Debug).

### Шаг 8. Упаковать через deployer

```bash
conan install --requires=zlib/1.3.1 \
    --profile=profiles/astra-gcc \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

На выходе: `output/zlib.lin.gcc12.static.x86_64.1.3.1.nupkg`.

### Шаг 9. (опционально) Тест в потребителе

`example/conanfile.txt`:
```
[requires]
zlib/1.3.1

[generators]
CMakeDeps
CMakeToolchain
```

```bash
cd example/
conan install . --output-folder=build --profile=profiles/astra-gcc
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake
cmake --build build
```

### Шаг 10. Закоммитить

```bash
git add zlib/ extensions/deployers/legacy_nupkg.py
git commit -m "Add zlib 1.3.1 conan recipe"
git push
```

---

## TeamCity — интеграция

Один билд-конфиг = один пакет + профиль. Параметры билд-конфига:

```
package.name=zlib
package.version=1.3.1
package.profile=lin-gcc84-x86_64
```

Скрипт сборки (общий для всех пакетов):

```bash
#!/bin/bash
set -e
source venv/bin/activate

NAME=%package.name%
VERSION=%package.version%
PROFILE=profiles/%package.profile%

for BT in Release Debug; do
    conan create $NAME/ --profile=$PROFILE -s build_type=$BT --build=missing --no-remote
done

mkdir -p output
conan install --requires=$NAME/$VERSION \
    --profile=$PROFILE \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

Артефакт TeamCity: `output/*.nupkg`.

---

## Куда передаются переменные компилятора

Цепочка: `профиль Conan → settings → CMakeToolchain.cmake → CMake → gcc/cl.exe`.

**Базовые настройки** — секция `[settings]` профиля:
```
[settings]
os=Linux
compiler=gcc
compiler.version=12
compiler.libcxx=libstdc++11
compiler.cppstd=17
arch=x86_64
build_type=Release
```

**Дополнительные флаги** (`-g3`, `-O0`, `-fPIC`, …) — секция `[conf]`:
```
[conf]
tools.build:cxxflags=["-g3", "-ggdb", "-fno-omit-frame-pointer"]
tools.build:cflags=["-fPIC"]
tools.build:exelinkflags=["-Wl,--as-needed"]
```

**Кастомный/форк-компилятор** — секция `[buildenv]`:
```
[buildenv]
CC=/opt/elara-gcc-fork/bin/gcc
CXX=/opt/elara-gcc-fork/bin/g++
AR=/opt/elara-gcc-fork/bin/ar
```

**Переопределение из CLI**:
```bash
conan create gtest/ --profile=astra-gcc -s build_type=Debug -s compiler.cppstd=20
```

---

## Чек-лист добавления пакета

- [ ] `<name>/conanfile.py` с правильными `source/build/package/package_info`
- [ ] `<name>/src/v<version>.tar.gz` положен
- [ ] (опционально) `LEGACY_NAME_MAP` в deployer
- [ ] (опционально) `requirements()` если есть зависимости
- [ ] `conan create` Release + Debug на Linux прошёл
- [ ] `conan create` Release + Debug на Windows прошёл
- [ ] `conan install --deployer=…` дал валидный `.nupkg`
- [ ] Структура `.nupkg` совпадает со старым TeamCity-артефактом
- [ ] Тест-потребитель линкуется
- [ ] Запушено в репо
- [ ] TeamCity билд-конфиг создан с параметрами `package.{name,version,profile}`
- [ ] TeamCity билд прошёл, артефакт опубликован

---

## Типовые проблемы

**`'settings.compiler.runtime' value not defined`** на Windows
— в профиле MSVC отсутствует `compiler.runtime=dynamic` или `=static`. Добавить.

**`Package 'xxx' build failed: Could not find compiler in env RC`** на Windows
— bat-скрипт перезаписал переменную `RC`. Нельзя использовать имя `RC` как локальную переменную в bat — оно зарезервировано под Resource Compiler.

**`Invalid: 'libcxx' value not defined`** на Linux
— в профиле gcc отсутствует `compiler.libcxx`. Должно быть `libstdc++11` для C++11 ABI.

**`Package gtest/X.Y.Z not found in cache`** при `conan install --requires=…`
— забыли запустить `conan create` перед `conan install`. Conan не найдёт без явного билда (если нет remote).

**`shared` в имени `.nupkg`, но внутри `.lib`/`.a`**
— это NuGet-конвенция, `shared` означает «динамический MSVC runtime» (`/MD`), а не shared-линковку самой библиотеки. Не баг.
