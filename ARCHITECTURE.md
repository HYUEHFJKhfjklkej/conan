# conan-recipes

Conan-рецепты для third-party C++ библиотек, используемых в наших продуктах.

**Цель:** перейти с самописных TeamCity-сборок на стандартный Conan-пакетинг, сохранив бесшовную совместимость с существующими `.nupkg`-артефактами (имена, структура, метаданные) — миграция идёт пакет-за-пакетом, потребители не ломаются.

---

## Содержание

- [Подход: canonical-first](#подход-canonical-first)
- [Структура репозитория](#структура-репозитория)
- [Как это работает](#как-это-работает)
- [Linux vs Windows](#linux-vs-windows)
- [Добавление нового пакета](#добавление-нового-пакета)
- [Профили Conan](#профили-conan)
- [Интеграция с TeamCity](#интеграция-с-teamcity)
- [Типовые проблемы](#типовые-проблемы)

---

## Подход: canonical-first

В сообществе Conan есть [conan-center-index](https://github.com/conan-io/conan-center-index) — репозиторий из тысяч рецептов под популярные C++ библиотеки. Они проходят CI на десятках платформ (Linux, Windows, macOS, gcc/clang/MSVC), их поддерживает большое сообщество.

**Стратегия:**

| Тип пакета | Что делаем |
|---|---|
| Есть на conan-center, подходит | Зеркалим рецепт в этот репо, адаптируем под закрытый контур (локальные URL источников). Минимум кода — максимум переиспользования. |
| Есть на conan-center, нужны правки | Форк рецепта в наш репо + патч в `<pkg>/patches/<version>/`. Свои изменения изолированы и переживут обновление upstream. |
| Нет на conan-center / проприетарный | Пишем рецепт с нуля по тем же conan-конвенциям. Это нормально и для индустриальных библиотек (OPC UA SDK, EtherCAT-стеки, протоколы Siemens S7 и т.п.). |

**Почему так:**
- Меньше bugs на нестандартных платформах (canonical-рецепты учли крайние случаи годами CI)
- Bus-factor: любой инженер с Conan-опытом подхватит, не нужно знать наш внутренний код
- Обновление upstream → `git pull` в форк, не переписывание с нуля
- Меньше времени на миграцию: для большинства зависимостей рецепт уже написан

---

## Структура репозитория

```
conan-recipes/
├── ARCHITECTURE.md                 ← этот документ
├── README.md
├── requirements.txt                ← conan>=2.0
│
├── gtest/                          ← пример: canonical-рецепт + локальный архив
│   ├── conanfile.py                  с conan-center-index, без правок
│   ├── conandata.yml                 версии + sha256 + URL источников (локальный + upstream)
│   ├── src/                          tarball-ы для offline-сборки
│   │   └── v1.16.0.tar.gz
│   └── test_package/                 минимальный consumer-тест (smoke-check)
│       ├── conanfile.py
│       ├── CMakeLists.txt
│       ├── main.cpp
│       └── test_package.cpp
│
├── zlib/                           ← пример: canonical-рецепт + патч
│   ├── conanfile.py
│   ├── conandata.yml
│   ├── patches/1.3.1/
│   │   └── 0001-fix-cmake.patch
│   ├── src/
│   │   └── zlib-1.3.1.tar.gz
│   └── test_package/
│
├── profiles/                       ← один файл на платформу/тулчейн
│   ├── astra-gcc                     Astra Linux, GCC из дистрибутива
│   ├── lin-gcc84-x86_64              Linux x64, GCC 8.4
│   ├── lin-gcc84-i686                Linux x86, GCC 8.4
│   ├── lin-gcc75-arm-linaro          Linux ARM, Linaro GCC 7.5
│   ├── lin-gcc-aarch64-linaro        Linux ARM64, Linaro GCC 7.5
│   ├── win-v142-x64                  Windows MSVC 2019 x64
│   ├── win-v142-x86                  Windows MSVC 2019 x86
│   └── win-v143-x64                  Windows MSVC 2022 x64
│
├── extensions/deployers/
│   └── legacy_nupkg.py             ← Conan-deployer: упаковщик в legacy `.nupkg`
│
├── example/                        ← consumer-проект для end-to-end проверки
│   ├── conanfile.txt
│   ├── CMakeLists.txt
│   └── src/
│
├── packages-linux/                 ← offline pip-колёса Conan для Linux x86_64
├── packages/                       ← offline pip-колёса Conan для Windows x86_64
│
├── test-astra/                     ← bash-скрипты валидации на Linux
│   ├── install_deps.sh
│   ├── setup.sh
│   ├── run_test.sh
│   ├── run_zlib.sh
│   └── run_gtest.sh
│
├── test-windows/                   ← bat-скрипты валидации на Windows
│   ├── setup.bat
│   └── run_test.bat
│
├── Dockerfile.astra-test           ← e2e тест в контейнере (gcc:12-bookworm)
├── Dockerfile.gtest-test
├── Dockerfile.zlib-test
└── docker-compose.yml + server.conf  ← опциональный локальный Conan-сервер
```

---

## Как это работает

```
        ┌─────────────────────┐
        │   <pkg>/            │   рецепт + версии + патчи + tarball
        │   conanfile.py      │
        │   conandata.yml     │
        │   patches/<ver>/    │
        │   src/<archive>     │
        │   test_package/     │
        └──────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
 ┌──────▼──────┐      ┌───────▼──────┐
 │ profiles/   │      │ profiles/    │
 │ astra-gcc   │      │ win-v143-x64 │
 └──────┬──────┘      └───────┬──────┘
        │                     │
        │ test-astra/         │ test-windows/
        │ run_*.sh (bash)     │ run_*.bat (cmd)
        │                     │
 ┌──────▼──────────┐  ┌───────▼────────────────┐
 │ ~/.conan2/      │  │ %USERPROFILE%\.conan2\ │
 │ Release + Debug │  │ Release + Debug        │
 │ libgtest.a etc. │  │ gtest.lib etc.         │
 └──────┬──────────┘  └───────┬────────────────┘
        │                     │
        └──────────┬──────────┘
                   │ conan install --deployer=legacy_nupkg
                   ▼
         ┌─────────────────────┐
         │ extensions/         │   общий Python-deployer
         │ deployers/          │
         │ legacy_nupkg.py     │
         └──────────┬──────────┘
                    │
                    ▼
   output/<name>.<os>.<compiler>.<linkage>.<arch>.<ver>.nupkg
```

### Поток сборки одного пакета

1. **Подготовка окружения** (один раз):
   - Linux: `sudo ./test-astra/install_deps.sh && ./test-astra/setup.sh`
   - Windows: `test-windows\setup.bat`
2. **Release**: `conan create <pkg>/ --profile=<profile> -s build_type=Release --build=missing --no-remote`
3. **Debug**: тот же `conan create` с `-s build_type=Debug`. У них разные `package_id` — обе версии параллельно живут в кеше.
4. **Smoke-тест**: `conan create` автоматически запускает `<pkg>/test_package/`, если он есть — это минимальный consumer-проект, проверяющий, что `find_package(...)` цепляется и линковка работает.
5. **Упаковка legacy**: `conan install --requires=<pkg>/<ver> --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/`. Deployer берёт обе сборки из кеша и собирает `.nupkg` со старой структурой.

### Структура выходного `.nupkg`

```
googletest.lin.gcc84.shared.x86_64.1.16.0.nupkg
└── lin.gcc84.shared.x86_64/
    ├── build/native/googletest.lin.gcc84.shared.x86_64.targets
    ├── include/{gmock,gtest}/...
    ├── lib/native/lin-gcc84-shared-x86_64/   ← Release: libgtest.a, libgmock.a, ...
    ├── lib/native/lin-gcc84-shared-x86_64-d/ ← Debug:   те же файлы, -g -O0
    ├── lib/net461/.keepdir
    ├── nuget/googletest.nuspec
    ├── proto/.keepdir
    ├── CMakeLists.var
    └── LICENSE.txt
```

Структура — байт-в-байт совпадает с тем, что выкладывает текущий TeamCity. Существующие потребители продолжают работать без правок.

---

## Linux vs Windows

| Аспект | Linux | Windows |
|---|---|---|
| Скрипт прогона | `test-astra/run_*.sh` | `test-windows/run_*.bat` |
| Установка зависимостей | apt-get (один раз с интернетом) | предустановлены: VS 2019/2022, CMake, Python |
| Offline pip-пакеты | `packages-linux/` (cp311 manylinux) | `packages/` (cp311 win_amd64) |
| Кеш Conan | `~/.conan2/` | `%USERPROFILE%\.conan2\` |
| Компилятор | gcc | MSVC (`cl.exe`, `link.exe`, `rc.exe`) |
| CMake-генератор | Ninja / Unix Makefiles | Visual Studio 17 2022 (multi-config) |
| Расширения | `.a` (static), `.so` (shared) | `.lib`, `.dll` |
| Имена файлов | `libgtest.a` | `gtest.lib` |
| `compiler.runtime` | не используется | критично: `dynamic` (`/MD`) или `static` (`/MT`) |
| Профиль | `astra-gcc`, `lin-gcc84-x86_64` | `win-v142-x64`, `win-v143-x64` |

**Windows-специфика.** В `.bat`-скриптах **нельзя использовать переменную `RC`** как локальную — она зарезервирована под Resource Compiler (`rc.exe`). Перезаписывание ломает CMake.

---

## Добавление нового пакета

Сначала проверьте, есть ли пакет на conan-center: <https://conan.io/center>. По возможности используйте Вариант А.

### Вариант А — Адаптация canonical-рецепта (большинство случаев)

На примере **zlib**.

**Шаг 1.** Найти рецепт в conan-center-index:
- Веб: https://conan.io/center/recipes/zlib
- GitHub: https://github.com/conan-io/conan-center-index/tree/master/recipes/zlib/all

**Шаг 2.** Скачать всё содержимое папки `recipes/zlib/all/` в `conan-recipes/zlib/`:
```
zlib/
├── conanfile.py        ← как есть
├── conandata.yml       ← как есть
├── patches/<ver>/*.patch  ← если есть
└── test_package/       ← как есть
```

**Шаг 3.** Скачать оригинальный source archive (URL и SHA256 — в `conandata.yml`):
```bash
mkdir -p zlib/src
curl -fsSL -o zlib/src/zlib-1.3.1.tar.gz \
    https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
shasum -a 256 zlib/src/zlib-1.3.1.tar.gz   # должен совпадать с conandata.yml
```

**Шаг 4.** Прописать локальный URL первым в `conandata.yml` для offline-сборки в закрытом контуре:
```yaml
sources:
  "1.3.1":
    url:
      - "file:///work/conan-recipes/zlib/src/zlib-1.3.1.tar.gz"
      - "https://zlib.net/fossils/zlib-1.3.1.tar.gz"
      - "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
    sha256: "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
```

Conan пробует URL по порядку; в закрытом контуре сработает локальный, в открытом — upstream.

**Шаг 5.** (опционально) Маппинг имени для legacy `.nupkg`, если внутреннее имя отличается от Conan-name:
```python
# extensions/deployers/legacy_nupkg.py
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    # "zlib":  "zlib-shared",
}
```

**Шаг 6.** Собрать:

Linux:
```bash
source venv/bin/activate
conan create zlib/ --profile=profiles/astra-gcc -s build_type=Release --build=missing --no-remote
conan create zlib/ --profile=profiles/astra-gcc -s build_type=Debug   --build=missing --no-remote
```

Windows:
```cmd
call venv\Scripts\activate.bat
conan create zlib\ --profile=profiles\win-v143-x64 -s build_type=Release --build=missing --no-remote
conan create zlib\ --profile=profiles\win-v143-x64 -s build_type=Debug   --build=missing --no-remote
```

**Шаг 7.** Проверить кеш и упаковать legacy:
```bash
conan list "zlib/1.3.1:*"

conan install --requires=zlib/1.3.1 \
    --profile=profiles/astra-gcc \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

**Шаг 8.** Закоммитить:
```bash
git add zlib/ extensions/deployers/legacy_nupkg.py
git commit -m "Add zlib 1.3.1 recipe (canonical from conan-center-index)"
```

---

### Вариант Б — Свой рецепт с нуля (проприетарные / индустриальные)

Применяется, когда пакета нет на conan-center или это закрытое вендорное SDK.

Минимальный шаблон:

```python
import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get, copy

class FooConan(ConanFile):
    name = "foo"
    version = "1.0.0"
    license = "Proprietary"
    settings = "os", "compiler", "build_type", "arch"
    options = {"shared": [True, False], "fPIC": [True, False]}
    default_options = {"shared": False, "fPIC": True}

    exports = "src/*.tar.gz"

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def source(self):
        local = os.path.join(self.recipe_folder, "src", f"v{self.version}.tar.gz")
        get(self, f"file:///{local}", strip_root=True)

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
        self.cpp_info.libs = ["foo"]
```

После — те же шаги 6–8, что в Варианте А.

### Зависимости между пакетами

```python
def requirements(self):
    self.requires("openssl/3.2.0")
    self.requires("zlib/1.3.1")
```

Conan автоматически:
- проверяет/собирает зависимости при `conan install`
- передаёт их пути в build (через `CMakeDeps`)
- заполняет `<dependencies>` в `.nuspec` через deployer

---

## Профили Conan

Цепочка: **профиль → settings → CMakeToolchain.cmake → CMake → компилятор**.

### Базовые настройки

Секция `[settings]`:
```ini
[settings]
os=Linux
compiler=gcc
compiler.version=12
compiler.libcxx=libstdc++11
compiler.cppstd=17
arch=x86_64
build_type=Release
```

### Дополнительные флаги

Секция `[conf]`:
```ini
[conf]
tools.cmake.cmaketoolchain:generator=Ninja
tools.build:jobs=8
tools.build:cxxflags=["-g3", "-ggdb", "-fno-omit-frame-pointer"]
tools.build:cflags=["-fPIC"]
tools.build:exelinkflags=["-Wl,--as-needed"]
```

### Кастомный/форк-компилятор

Секция `[buildenv]`:
```ini
[buildenv]
CC=/opt/custom-gcc/bin/gcc
CXX=/opt/custom-gcc/bin/g++
AR=/opt/custom-gcc/bin/ar
```

### Tool-чейн (cmake/ninja фиксированной версии)

Секция `[tool_requires]`:
```ini
[tool_requires]
cmake/3.27.0
```

### Переопределение из CLI

```bash
conan create gtest/ --profile=astra-gcc \
    -s build_type=Debug \
    -s compiler.cppstd=20 \
    -o "gtest/*:shared=True" \
    -c tools.build:jobs=16
```

---

## Интеграция с TeamCity

Один билд-конфиг = один пакет × один профиль. Параметры билд-конфига:

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
    conan create "$NAME/" --profile="$PROFILE" -s build_type=$BT --build=missing --no-remote
done

mkdir -p output
conan install --requires="$NAME/$VERSION" \
    --profile="$PROFILE" \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

Артефакт TeamCity: `output/*.nupkg`.

---

## Чек-лист добавления пакета

- [ ] `<name>/conanfile.py` (адаптация conan-center или свой)
- [ ] `<name>/conandata.yml` с локальным URL первым и upstream-fallback
- [ ] `<name>/src/<archive>` положен, sha256 совпадает с `conandata.yml`
- [ ] `<name>/patches/<ver>/*.patch` (если у canonical были — переносим)
- [ ] `<name>/test_package/` со smoke-тестом
- [ ] (опц.) `LEGACY_NAME_MAP` в deployer
- [ ] (опц.) `requirements()` для зависимостей
- [ ] `conan create` Release + Debug на Linux прошёл
- [ ] `conan create` Release + Debug на Windows прошёл
- [ ] `test_package` отработал на обеих платформах
- [ ] `conan install --deployer=…` дал валидный `.nupkg`
- [ ] Структура `.nupkg` совпадает со старым артефактом
- [ ] Запушено в репо
- [ ] TeamCity билд-конфиг создан с параметрами `package.{name,version,profile}`
- [ ] TeamCity билд прошёл, артефакт опубликован

---

## Типовые проблемы

**`'settings.compiler.runtime' value not defined`** на Windows
— в профиле MSVC отсутствует `compiler.runtime=dynamic` или `=static`. Добавить.

**`Package 'xxx' build failed: Could not find compiler in env RC`** на Windows
— bat-скрипт перезаписал переменную `RC`. Имя `RC` зарезервировано под Resource Compiler.

**`Invalid: 'libcxx' value not defined`** на Linux
— в gcc-профиле отсутствует `compiler.libcxx`. Должно быть `libstdc++11` для C++11 ABI.

**`Package gtest/X.Y.Z not found in cache`** при `conan install --requires=…`
— забыли `conan create` перед `conan install`. Без remote Conan не скачает.

**`shared` в имени `.nupkg`, но внутри `.lib`/`.a`**
— это NuGet-конвенция: `shared` означает динамический MSVC runtime (`/MD`), а не shared-линковку самой библиотеки. Не баг.

**`sha256 mismatch`** при первом `conan create`
— скачали не тот tarball (например, github auto-archive `v1.3.1.tar.gz` вместо официального release `zlib-1.3.1.tar.gz`). Сравните с `sha256` в `conandata.yml`.

**`patch failed: ... already exists`**
— патч из `patches/<ver>/` уже применён (например, при повторном `conan create` после ручной правки исходника в кеше). Очистить кеш: `conan remove "<pkg>/<ver>" --confirm` и повторить.
