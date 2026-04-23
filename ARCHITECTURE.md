# Архитектура миграции на Conan — Elara SURA2

## Текущая система (AS-IS)

```
Bitbucket (1 репо на пакет)     TeamCity (CMAKE project)         Потребитель (SURA)
┌─────────────────────┐         ┌──────────────────────┐         ┌─────────────────────┐
│ curl/               │         │ Build Release:       │         │ CMakeLists.txt:     │
│   CMakeLists.txt    │ ──────► │   cmake              │         │   include(          │
│   CMakeLists.var    │  VCS    │     -DTOOLCHAIN=..   │         │     CMakeLists.var) │
│   cmake/toolchains/ │         │     -DBUILD_SHARED=ON│         │   resolve_          │
│   patch/            │         │   cmake --build      │         │     dependencies()  │
│   nuget/            │         │     --target install  │         │   add_subdirectory()│
└─────────────────────┘         └──────────┬───────────┘         └─────────────────────┘
                                           │ Artifacts
                                           ▼
                                ┌──────────────────────┐
                                │ curl.zip             │
                                │  └─lin.gcc.shared.x64│
                                │    ├─build/(.targets)│
                                │    ├─include/        │
                                │    ├─lib/            │
                                │    ├─nuget/(.nuspec) │
                                │    ├─CMakeLists.var  │
                                │    └─LICENSE.txt     │
                                └──────────────────────┘
```

### Ключевые файлы текущей системы

**CMakeLists.var** — метаданные пакета:
- project_name, version (major.minor.patch)
- components (список библиотек: gtest, gtest_main, gmock, gmock_main)
- платформы для каждого компонента (WINDOWS, LINUX, LINUX_ARM_LINARO, ...)
- definitions (compile defines)
- dependencies (зависимости: openssl-1.1.11, zlib-1.3.0, ...)

**Корневой CMakeLists.txt** (общий для всех пакетов):
- `include(CMakeLists.var)` — загрузка метаданных
- `include(ResolveDependencies.cmake)` — скачивание зависимостей
- `resolve_dependencies(DEPENDENCIES ${deps})` — фактическое разрешение
- `configure_targets()` — генерация .targets для NuGet
- `configure_nuspecs()` — генерация .nuspec для NuGet
- `install_package()` — установка

**Build Release скрипт** (TeamCity):
```bash
mkdir -p %projectName%/.build/lin.gcc.shared.x64
cd %projectName%/.build/lin.gcc.shared.x64
cmake -DCMAKE_TOOLCHAIN_FILE="../../cmake/toolchains/linux_x86_64.cmake" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
      ../..
cmake --build . --target install -- -j4
ctest -W -C Release
```

---

## Целевая система (TO-BE)

```
Bitbucket                     TeamCity                         Потребитель (SURA)
┌──────────────────────┐      ┌───────────────────────┐        ┌─────────────────────┐
│ conan-recipes/       │      │ CONAN project:        │        │                     │
│   profiles/          │      │                       │        │ Вариант A (быстрый):│
│     lin-gcc84-x86_64 │      │  conan create curl/   │        │   conan install .   │
│     lin-gcc75-arm    │ ───► │    --profile=lin-gcc84 │        │   cmake -DTOOLCHAIN │
│     win-v142-x64     │ VCS  │    -o shared=True     │        │     =conan_toolchain│
│   curl/              │      │                       │        │                     │
│     conanfile.py     │      │  conan upload curl/*  │        │ Вариант B (мягкий): │
│   grpc/              │      │    --remote=elara     │        │   resolve_deps() +  │
│     conanfile.py     │      │                       │        │   Conan fallback    │
│   openssl/           │      └───────────┬───────────┘        │                     │
│     conanfile.py     │                  │                    └─────────────────────┘
└──────────────────────┘                  ▼
                               ┌──────────────────┐
                               │  Conan Server    │
                               │  conan.elara     │
                               │  .local:9300     │
                               └──────────────────┘
```

---

## 1. Профили (полная матрица платформ)

Каждый профиль соответствует одной платформе из CMakeLists.var:

| CMakeLists.var платформа | Conan-профиль | Компилятор | Arch |
|---|---|---|---|
| LINUX | lin-gcc84-x86_64 | gcc 8.4 | x86_64 |
| LINUX (x86) | lin-gcc84-i686 | gcc 8.4 | x86 |
| LINUX_ARM_LINARO | lin-gcc75-arm-linaro | gcc 7.5 (cross) | armv7 |
| LINUX_ARM_NXP | lin-gcc-arm-nxp | gcc (cross) | armv7 |
| LINUX_ARM64_LINARO | lin-gcc-aarch64-linaro | gcc (cross) | armv8 |
| LINUX_ARM64_ROCKCHIP | lin-gcc-aarch64-rockchip | gcc (cross) | armv8 |
| LINUX_ATOM | lin-gcc-atom | gcc | x86_64 |
| WINDOWS (x64) | win-v142-x64 | msvc 192 | x86_64 |
| WINDOWS (x86) | win-v142-x86 | msvc 192 | x86 |
| WINCE800 | win-wince-ce800 | msvc (cross) | armv7 |

Каждый профиль дополнительно может комбинироваться с shared/static через `-o *:shared=True/False`.

### Пример: profiles/lin-gcc84-x86_64

```ini
[settings]
os=Linux
arch=x86_64
compiler=gcc
compiler.version=8.4
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

[conf]
# Используем существующий toolchain (тот же, что в TeamCity)
tools.cmake.cmaketoolchain:toolchain_file={{os.getenv("CMAKE_TOOLCHAIN_FILE", "")}}
```

### Пример: profiles/lin-gcc75-arm-linaro

```ini
[settings]
os=Linux
arch=armv7
compiler=gcc
compiler.version=7.5
compiler.libcxx=libstdc++11
compiler.cppstd=14
build_type=Release

[conf]
tools.cmake.cmaketoolchain:toolchain_file=/opt/linaro/toolchain.cmake
```

### Пример: profiles/win-v142-x64

```ini
[settings]
os=Windows
arch=x86_64
compiler=msvc
compiler.version=192
compiler.cppstd=17
build_type=Release
```

---

## 2. Рецепты (conanfile.py)

### Подход: conan create (полная сборка)

Рецепт скачивает оригинальные исходники и собирает их через CMake.
Не модифицирует CMakeLists.txt пакета.

### Маппинг CMakeLists.var → conanfile.py

```python
# CMakeLists.var:
#   set(project_name curl)
#   set(${project_name}_major 8) _minor 0) _patch 1)
#   set(components curl curltool)
#   set(${project_name}_definitions -DCURL_STATICLIB)
#   set(${project_name}_dependencies openssl-1.1.11 zlib-1.3.0 ssh2-1.11.0)

# ↓ Становится ↓

class CurlConan(ConanFile):
    name = "curl"                                     # project_name
    version = "8.0.1"                                 # major.minor.patch

    settings = "os", "compiler", "build_type", "arch" # платформы
    options = {"shared": [True, False]}               # shared/static
    default_options = {"shared": True}

    def requirements(self):                            # dependencies
        self.requires("openssl/1.1.11")
        self.requires("zlib/1.3.0")
        self.requires("ssh2/1.11.0")

    def package_info(self):                            # components + definitions
        self.cpp_info.components["curl"].libs = ["curl"]
        self.cpp_info.components["curltool"].libs = ["curltool"]
        if not self.options.shared:
            self.cpp_info.components["curl"].defines = ["CURL_STATICLIB"]
```

### Пример полного рецепта: curl/conanfile.py

```python
import os
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get, copy


class CurlConan(ConanFile):
    name = "curl"
    version = "8.0.1"
    description = "Command line tool and library for transferring data with URLs"
    license = "MIT"

    settings = "os", "compiler", "build_type", "arch"
    options = {
        "shared": [True, False],
        "with_ssl": [True, False],
        "with_ssh2": [True, False],
    }
    default_options = {
        "shared": True,
        "with_ssl": True,
        "with_ssh2": True,
    }

    # Offline: исходники рядом с рецептом
    exports = "src/*.tar.gz"

    def requirements(self):
        if self.options.with_ssl:
            self.requires("openssl/1.1.11")
        self.requires("zlib/1.3.0")
        if self.options.with_ssh2:
            self.requires("ssh2/1.11.0")

    def source(self):
        local_archive = os.path.join(self.recipe_folder, "src",
                                      f"curl-{self.version}.tar.gz")
        if os.path.exists(local_archive):
            get(self, f"file:///{local_archive}", strip_root=True)
        else:
            get(self, f"https://curl.se/download/curl-{self.version}.tar.gz",
                strip_root=True)

    def layout(self):
        cmake_layout(self)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["BUILD_SHARED_LIBS"] = self.options.shared
        tc.variables["BUILD_CURL_EXE"] = True
        tc.variables["CURL_USE_OPENSSL"] = self.options.with_ssl
        tc.variables["CURL_USE_LIBSSH2"] = self.options.with_ssh2
        tc.variables["BUILD_TESTING"] = False
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()
        copy(self, "COPYING", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"))

    def package_info(self):
        self.cpp_info.components["libcurl"].libs = ["curl"]
        self.cpp_info.components["libcurl"].requires = []

        if self.options.with_ssl:
            self.cpp_info.components["libcurl"].requires.append("openssl::openssl")
        self.cpp_info.components["libcurl"].requires.append("zlib::zlib")

        if not self.options.shared:
            self.cpp_info.components["libcurl"].defines = ["CURL_STATICLIB"]

        if self.settings.os == "Linux":
            self.cpp_info.components["libcurl"].system_libs = ["pthread", "dl"]
        elif self.settings.os == "Windows":
            self.cpp_info.components["libcurl"].system_libs = [
                "ws2_32", "crypt32", "wldap32"
            ]
```

---

## 3. TeamCity: Build Chain

### Структура проекта

```
SURA2
└── COMPONENTS
    └── CONAN                              ← новый проект
        ├── CN_GTEST                       ← subproject на пакет
        │   ├── CN100 Linux x64 shared
        │   ├── CN101 Linux x64 static
        │   ├── CN102 Linux ARM Linaro shared
        │   ├── CN110 Windows x64 shared
        │   ├── CN111 Windows x64 static
        │   └── CN900 PACKAGE (upload)
        ├── CN_CURL
        │   ├── CN200 Linux x64 shared
        │   └── ...
        └── CN_GRPC
            └── ...
```

### Шаблон Build Step (Linux)

```bash
#!/bin/bash
set -euo pipefail

REVISION="%build.vcs.number%"

# Выбор компилятора (как в текущей системе)
if [ "%useUpgradedBuild%" == "True" ]; then
    update-alternatives --auto cc && update-alternatives --auto c++
else
    update-alternatives --set cc /usr/local/gcc-5.3/bin/gcc-5.3 && \
    update-alternatives --set c++ /usr/local/gcc-5.3/bin/g++-5.3
fi

echo "##teamcity[progressMessage 'Conan: building %package.name% (%conan.profile%, shared=%shared%)']"

# Собрать пакет
conan create %package.name%/ \
    --profile=%conan.profile% \
    -o %package.name%/*:shared=%shared% \
    --build=missing

# Загрузить в remote
conan upload "%package.name%/*" --remote=%conan.remote% --confirm

echo "##teamcity[buildStatus text='%package.name% uploaded (%conan.profile%, shared=%shared%)']"
```

### Параметры Build Configuration

| Параметр | Значение (пример) |
|---|---|
| package.name | gtest |
| conan.profile | profiles/lin-gcc84-x86_64 |
| shared | True |
| conan.remote | elara |
| useUpgradedBuild | True |

### Docker

Сборка по-прежнему в Docker-контейнерах из ProGet.
Нужно добавить Conan в Docker-образы:

```dockerfile
# В существующий Dockerfile сборочного образа
RUN pip3 install conan==2.27.1
RUN conan profile detect
```

Или устанавливать Conan в build step перед сборкой (менее эффективно, но не требует
пересборки образов):

```bash
pip3 install conan==2.27.1 || true
conan profile detect --force
conan remote add elara http://conan.elara.local:9300 --force
conan remote login elara builder -p "${CONAN_PASSWORD}"
```

---

## 4. Интеграция с потребителем (SURA)

### Проблема

Текущий потребитель использует:
```cmake
include(CMakeLists.var)
resolve_dependencies(DEPENDENCIES ${${project_name}_dependencies})
```

Нужно, чтобы потребитель мог подключать как NuGet-пакеты (пока не всё мигрировано),
так и Conan-пакеты.

### Вариант A: Постепенная миграция (рекомендуется)

Модифицировать `ResolveDependencies.cmake` — добавить Conan-fallback:

```cmake
# ResolveDependencies.cmake — добавить в resolve_dependencies()

function(resolve_dependencies)
    cmake_parse_arguments(ARG "" "" "DEPENDENCIES" ${ARGN})

    foreach(dep IN LISTS ARG_DEPENDENCIES)
        # Извлечь имя и версию: "openssl-1.1.11" → name=openssl, version=1.1.11
        string(REGEX MATCH "^([a-zA-Z0-9_]+)-(.+)$" _match "${dep}")
        set(_dep_name "${CMAKE_MATCH_1}")
        set(_dep_version "${CMAKE_MATCH_2}")

        # Попробовать найти через Conan (find_package)
        find_package(${_dep_name} ${_dep_version} QUIET)

        if(${_dep_name}_FOUND)
            message(STATUS "Dependency ${dep}: found via Conan (find_package)")
        else()
            # Fallback на текущую систему (NuGet/артефакты)
            message(STATUS "Dependency ${dep}: using legacy resolver")
            _resolve_dependency_legacy(${dep})
        endif()
    endforeach()
endfunction()
```

Потребитель при этом:
1. Запускает `conan install . --profile=...` перед cmake
2. CMake находит Conan-пакеты через `find_package()`
3. Пакеты, которые ещё не мигрированы, разрешаются старым способом

### Вариант B: Полная миграция (для новых проектов)

Потребитель использует `conanfile.txt` или `conanfile.py`:

```ini
# conanfile.txt
[requires]
gtest/1.14.0
curl/8.0.1
grpc/1.60.1
openssl/1.1.11

[generators]
CMakeDeps
CMakeToolchain
```

И в CMakeLists.txt:
```cmake
find_package(GTest REQUIRED)
find_package(CURL REQUIRED)
find_package(gRPC REQUIRED)
target_link_libraries(myapp
    GTest::gtest
    CURL::libcurl
    gRPC::grpc++
)
```

### Вариант C: conan export-pkg (минимум изменений)

Если не хочется переписывать рецепты сборки — TeamCity собирает как сейчас,
а Conan только пакует результат:

```python
class CurlConan(ConanFile):
    name = "curl"
    version = "8.0.1"

    def export_package(self):
        # Берём уже собранные артефакты
        copy(self, "*.h", src="include", dst=os.path.join(self.package_folder, "include"))
        copy(self, "*.lib", src="lib", dst=os.path.join(self.package_folder, "lib"))
        copy(self, "*.so*", src="lib", dst=os.path.join(self.package_folder, "lib"))
        copy(self, "*.dll", src="lib", dst=os.path.join(self.package_folder, "bin"))
```

Этот вариант полезен на переходный период.

---

## 5. Полная матрица сборки

Для каждого пакета нужно собрать все комбинации:

| Пакет | Платформы (из CMakeLists.var) | shared | static | Итого конфигураций |
|---|---|---|---|---|
| gtest | 8 (WIN, LIN, ARM_NXP, ARM_LINARO, ARM64_ROCK, ARM64_LIN, ATOM, WINCE) | + | + | 16 |
| curl | 7 (без WINCE) | + | + | 14 |
| grpc | зависит | + | + | ... |

В TeamCity это можно реализовать через **build matrix** или **meta-runner**:

```bash
# build-matrix.sh — запускается один раз, создаёт все комбинации
PROFILES=(
    "profiles/lin-gcc84-x86_64"
    "profiles/lin-gcc75-arm-linaro"
    "profiles/win-v142-x64"
    # ...
)

SHARED_OPTIONS=("True" "False")

for profile in "${PROFILES[@]}"; do
    for shared in "${SHARED_OPTIONS[@]}"; do
        echo "##teamcity[progressMessage 'Building %package.name% ($profile, shared=$shared)']"
        conan create %package.name%/ \
            --profile="$profile" \
            -o "%package.name%/*:shared=$shared" \
            --build=missing || true
    done
done

conan upload "%package.name%/*" --remote=elara --confirm
```

---

## 6. Граф зависимостей (известные)

```
grpc/1.60.1
├── openssl/1.1.11
├── protobuf/3.21.12
├── zlib/1.3.0
├── cares/1.x
├── absl/x.x
└── address_sorting/x.x

curl/8.0.1
├── openssl/1.1.11
├── zlib/1.3.0
└── ssh2/1.11.0

googletest/1.15.2
└── (нет зависимостей)
```

Порядок сборки: zlib → openssl → ssh2 → curl, protobuf → grpc, googletest (независимо).

---

## 7. План миграции

### Фаза 1: Инфраструктура (1-2 дня)
- [ ] Поднять Conan Server (docker-compose)
- [ ] Создать репо conan-recipes в Bitbucket
- [ ] Установить Conan на 1-2 агентах SANDBOX

### Фаза 2: Пилот — googletest (1-2 дня)
- [ ] Обновить профили под реальные компиляторы (gcc-8.4, не gcc-12)
- [ ] Собрать gtest для lin-gcc84-x86_64 + win-v142-x64
- [ ] Настроить TeamCity build configuration
- [ ] Проверить пример-потребитель

### Фаза 3: Простые пакеты (1 неделя)
- [ ] zlib (нет зависимостей)
- [ ] cjson (нет зависимостей)
- [ ] gflags, glog
- [ ] Протестировать на реальном проекте из SURA2

### Фаза 4: Пакеты с зависимостями (1-2 недели)
- [ ] openssl
- [ ] curl (зависит от openssl, zlib, ssh2)
- [ ] protobuf
- [ ] grpc (самый сложный — много зависимостей)

### Фаза 5: Интеграция с SURA (1-2 недели)
- [ ] Модифицировать ResolveDependencies.cmake (Вариант A)
- [ ] Протестировать сборку SURA2 с Conan-пакетами
- [ ] Документация для разработчиков

### Фаза 6: Полная миграция (по мере готовности)
- [ ] Перенести все third party
- [ ] Отключить старую NuGet-систему
- [ ] Удалить CMakeLists.var, .targets, .nuspec генерацию

---

## 8. Структура репо (целевая)

```
conan-recipes/
├── ARCHITECTURE.md              # Этот документ
├── CONCEPT.md
├── DEPLOY.md
├── profiles/
│   ├── lin-gcc84-x86_64         # Linux x64 (основной)
│   ├── lin-gcc84-i686           # Linux x86
│   ├── lin-gcc75-arm-linaro     # ARM Linaro (cross)
│   ├── lin-gcc-arm-nxp          # ARM NXP (cross)
│   ├── lin-gcc-aarch64-linaro   # ARM64 Linaro (cross)
│   ├── lin-gcc-aarch64-rockchip # ARM64 Rockchip (cross)
│   ├── lin-gcc-atom             # Atom
│   ├── win-v142-x64             # Windows x64
│   ├── win-v142-x86             # Windows x86
│   └── win-wince-ce800          # WinCE (cross)
├── gtest/
│   ├── conanfile.py
│   └── src/v1.14.0.tar.gz      # offline
├── curl/
│   ├── conanfile.py
│   └── src/curl-8.0.1.tar.gz
├── openssl/
│   └── conanfile.py
├── zlib/
│   └── conanfile.py
├── grpc/
│   └── conanfile.py
├── example/                     # пример-потребитель
│   ├── conanfile.txt
│   ├── CMakeLists.txt
│   └── src/
├── teamcity/
│   ├── build-recipe.sh          # один пакет + один профиль
│   ├── build-all.sh             # все пакеты
│   └── build-matrix.sh          # все комбинации для одного пакета
├── docker-compose.yml           # Conan Server
├── server.conf
├── setup.bat                    # offline установка Conan (Windows)
└── requirements.txt
```
