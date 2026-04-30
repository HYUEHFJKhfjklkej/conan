# conan-recipes

Conan-рецепты для third-party C++ библиотек, используемых в наших продуктах.

**Цель:** перейти с самописных TeamCity-сборок на стандартный Conan-пакетинг, сохранив бесшовную совместимость с существующими `.nupkg`-артефактами (имена, структура, метаданные) — миграция идёт пакет-за-пакетом, потребители не ломаются.

**Ключевое свойство:** репозиторий полностью **offline-self-contained** — все source-архивы third-party и pip-колёса Conan лежат внутри. На закрытом контуре (Astra, изолированные TC-агенты) сборка идёт без обращений к интернету.

---

## Содержание

- [Подход: canonical-first](#подход-canonical-first)
- [Что уже мигрировано](#что-уже-мигрировано)
- [Структура репозитория](#структура-репозитория)
- [Как это работает](#как-это-работает)
- [Linux vs Windows](#linux-vs-windows)
- [gRPC: особенности](#grpc-особенности)
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
| Есть на conan-center, подходит | Зеркалим рецепт в этот репо, добавляем offline-патч (см. ниже). Минимум кода — максимум переиспользования. |
| Есть на conan-center, нужны правки | Форк рецепта в наш репо + патч в `<pkg>/patches/<version>/`. Свои изменения изолированы и переживут обновление upstream. |
| Нет на conan-center / проприетарный | Пишем рецепт с нуля по тем же conan-конвенциям. Это нормально и для индустриальных библиотек (OPC UA SDK, EtherCAT-стеки, протоколы Siemens S7 и т.п.). |

**Почему так:**
- Меньше bugs на нестандартных платформах (canonical-рецепты учли крайние случаи годами CI)
- Bus-factor: любой инженер с Conan-опытом подхватит, не нужно знать наш внутренний код
- Обновление upstream → `git pull` в форк, не переписывание с нуля
- Меньше времени на миграцию: для большинства зависимостей рецепт уже написан

---

## Что уже мигрировано

| Пакет | Версия | Источник рецепта |
|---|---|---|
| **gtest** | 1.15.2 (+ 1.16.0, 1.17.0) | conan-center-index, без правок |
| **zlib** | 1.3.1 | conan-center-index + canonical patch |
| **abseil** | 20250127.0 | conan-center-index |
| **c-ares** | 1.34.6 | conan-center-index |
| **re2** | 20251105 | conan-center-index |
| **protobuf** | 5.29.6 | conan-center-index |
| **openssl** | 3.4.5 | conan-center-index |
| **grpc** | 1.78.1 | conan-center-index |

Сборка всего дерева gRPC (со всеми deps + zlib) подтверждена в Docker `gcc:12-bookworm` с `--network=none` — полностью offline.

---

## Структура репозитория

```
conan-recipes/
├── README.md                              ← этот документ
├── requirements.txt                       ← conan>=2.0
├── .gitignore
├── .dockerignore
│
├── gtest/                                 ← пример: canonical-рецепт + два архива
│   ├── conanfile.py
│   ├── conanfile.py.my-poc.bak            (бэкап исходного PoC, можно удалить)
│   ├── conandata.yml                      версии 1.15.2, 1.16.0, 1.17.0
│   ├── src/
│   │   ├── v1.15.2.tar.gz
│   │   └── v1.16.0.tar.gz
│   └── test_package/                      минимальный consumer-тест (smoke)
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       ├── main.cpp
│       └── test_package.cpp
│
├── zlib/                                  ← пример: canonical + canonical-патч
│   ├── conanfile.py
│   ├── conanfile.py.my-poc.bak            (бэкап PoC, можно удалить)
│   ├── conandata.yml
│   ├── patches/
│   │   └── 1.3.1/
│   │       └── 0001-fix-cmake.patch
│   ├── src/
│   │   └── zlib-1.3.1.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       └── test_package.c
│
├── abseil/
│   ├── conanfile.py
│   ├── conandata.yml
│   ├── patches/                           canonical-патчи под разные версии
│   │   ├── 0003-absl-string-libm.patch
│   │   ├── 0003-absl-string-libm-20230802.patch
│   │   ├── 0003-absl-string-libm-20240116.patch
│   │   ├── 0004-test-allocator-testonly.patch
│   │   ├── 0006-backport-arm-compilation-fix.patch
│   │   ├── 20230802.1-0001-fix-mingw.patch
│   │   ├── 20240116.1-0001-fix-filesystem-include.patch
│   │   └── 20260107.1-0001-fix-heterogeneous_lookup-flag.patch
│   ├── src/
│   │   └── 20250127.0.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       └── test_package.cpp
│
├── c-ares/                                (без patches)
│   ├── conanfile.py
│   ├── conandata.yml
│   ├── src/
│   │   └── c-ares-1.34.6.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       └── test_package.c
│
├── re2/                                   (без patches)
│   ├── conanfile.py
│   ├── conandata.yml
│   ├── src/
│   │   └── 2025-11-05.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       └── test_package.cpp
│
├── protobuf/
│   ├── conanfile.py
│   ├── conandata.yml
│   ├── patches/
│   │   ├── protobuf-3.20.0-upstream-macos-macros.patch
│   │   └── protobuf-3.21.12-upstream-macos-macros.patch
│   ├── protobuf-conan-protoc-target.cmake ← хелпер для импорта protoc-таргета
│   ├── src/
│   │   └── protobuf-29.6.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── addressbook.proto              .proto-файл для генерации
│       ├── conanfile.py
│       └── test_package.cpp
│
├── openssl/                               (без patches)
│   ├── conanfile.py
│   ├── conandata.yml
│   ├── src/
│   │   └── openssl-3.4.5.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       ├── digest.c                       тест нового provider API
│       ├── digest_legacy.c                тест legacy ENGINE API
│       └── test_package.c
│
├── grpc/                                  ← см. раздел «gRPC: особенности»
│   ├── conanfile.py
│   ├── conandata.yml                      версии 1.78.1, 1.69.0, 1.54.3
│   ├── conan_cmake_project_include.cmake  линкер-фикс check_epollexclusive
│   ├── cmake/
│   │   └── grpc_plugin_template.cmake.in  шаблон executable imported targets
│   ├── target_info/                       декларативные описания компонентов
│   │   ├── grpc_1.54.3.yml
│   │   ├── grpc_1.69.0.yml
│   │   └── grpc_1.78.1.yml
│   ├── patches/
│   │   └── v1.50.x/
│   │       └── 002-CMake-Add-gRPC_USE_SYSTEMD-option-34384.patch
│   ├── src/
│   │   └── v1.78.1.tar.gz
│   └── test_package/
│       ├── CMakeLists.txt
│       ├── conanfile.py
│       └── test_package.cpp
│
├── profiles/                              ← один файл на платформу/тулчейн
│   ├── astra-gcc                          Astra Linux, GCC из дистрибутива
│   ├── lin-gcc84-x86_64                   Linux x64, GCC 8.4
│   ├── lin-gcc84-i686                     Linux x86, GCC 8.4
│   ├── lin-gcc75-arm-linaro               Linux ARM, Linaro GCC 7.5
│   ├── lin-gcc-aarch64-linaro             Linux ARM64, Linaro GCC 7.5
│   ├── linux-gcc                          generic Linux GCC (без привязки к Astra)
│   ├── linux-gcc-debug                    то же + build_type=Debug дефолтом
│   ├── win-v142-x64                       Windows MSVC 2019 x64
│   ├── win-v142-x86                       Windows MSVC 2019 x86
│   ├── win-v143-x64                       Windows MSVC 2022 x64
│   ├── windows-msvc                       generic-MSVC (без фиксации toolset)
│   └── windows-msvc-debug                 то же + Debug
│
├── extensions/
│   └── deployers/
│       └── legacy_nupkg.py                ← Conan-deployer: упаковщик в legacy `.nupkg`
│
├── example/                               ← consumer-проект для end-to-end проверки (gtest)
│   ├── CMakeLists.txt
│   ├── conanfile.txt
│   └── src/
│       ├── example.cpp
│       ├── example.hpp
│       └── example_test.cpp
│
├── packages-linux/                        ← 18 offline pip-колёс Conan для Linux x86_64
│   ├── conan-2.27.1.tar.gz                core
│   └── … (certifi, charset_normalizer, colorama, distro, fasteners, idna,
│           jinja2, markupsafe, packaging, patch_ng, python_dateutil, pyyaml,
│           requests, setuptools, six, urllib3, wheel)
│
├── packages/                              ← 17 offline pip-колёс Conan для Windows x86_64
│   ├── conan-2.27.1.tar.gz
│   └── … (тот же набор без distro, под cp314-win_amd64)
│
├── test-astra/                            ← bash-скрипты валидации на Linux/Astra
│   ├── README.md                          инструкция запуска на Astra
│   ├── install_deps.sh                    apt-зависимости (gcc, cmake, python3-venv)
│   ├── setup.sh                           создание venv + offline install Conan
│   ├── run_gtest.sh                       gtest sanity (Release+Debug)
│   ├── run_zlib.sh                        zlib sanity (Release+Debug)
│   ├── run_grpc.sh                        grpc + 6 deps (sanity, только static/Release)
│   ├── run_test.sh                        gtest e2e + legacy `.nupkg` через deployer
│   └── run_test_zlib.sh                   zlib e2e + legacy `.nupkg`
│
├── test-windows/                          ← bat-скрипты валидации на Windows
│   ├── setup.bat
│   ├── run_gtest.bat                      (зеркала Linux-скриптов)
│   ├── run_zlib.bat
│   ├── run_grpc.bat                       4 варианта (static/shared × Release/Debug)
│   ├── run_test.bat
│   └── run_test_zlib.bat
│
├── Dockerfile.astra-test                  ← e2e тест в контейнере (gcc:12-bookworm)
├── Dockerfile.gtest-test                  ← минимальный — только gtest
├── Dockerfile.zlib-test                   ← только zlib
├── Dockerfile.grpc-test                   ← grpc + 6 deps (offline с --network=none)
├── docker-compose.yml                     ← опциональный локальный Conan-сервер
└── server.conf                            ← конфиг Conan-сервера для docker-compose
```

> **`.my-poc.bak`-файлы в `gtest/` и `zlib/`** — бэкапы PoC-рецептов с начала миграции, оставлены для истории. После полной TC-валидации соответствующих пакетов — можно удалить.
>
> **`venv/`** в репо не коммитится (см. `.gitignore`), создаётся через `test-astra/setup.sh` или `test-windows/setup.bat`.

---

## Как это работает

```
        ┌─────────────────────┐
        │   <pkg>/            │   рецепт + версии + патчи + tarball
        │   conanfile.py      │   (с offline-патчем: exports_sources + unzip)
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
 │ + platform_ │      │ + platform_  │
 │ tool_req'es │      │ tool_req'es  │
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
2. **Release**: `conan create <pkg>/ --version=<ver> -pr:h=<profile> -pr:b=<profile> -s build_type=Release --build=missing --no-remote`
3. **Debug**: тот же `conan create` с `-s build_type=Debug`. У них разные `package_id` — обе версии параллельно живут в кеше.
4. **Smoke-тест**: `conan create` автоматически запускает `<pkg>/test_package/`, если он есть — это минимальный consumer-проект, проверяющий, что `find_package(...)` цепляется и линковка работает.
5. **Упаковка legacy**: `conan install --requires=<pkg>/<ver> --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/`. Deployer берёт обе сборки из кеша и собирает `.nupkg` со старой структурой.

> **Важно: `-pr:b=<profile>`** обязательно для offline-сборок. Без явного build-профиля Conan возьмёт default profile для build-context, который не содержит наших `[platform_tool_requires]` — и упадёт на `cmake/[>=3.16] not resolved` для пакетов с `tool_requires`.

### Структура выходного `.nupkg`

```
googletest.lin.gcc84.shared.x86_64.1.15.2.nupkg
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
| Установка зависимостей | apt-get (один раз) | предустановлены: VS 2019/2022, CMake, Python, **Strawberry Perl**, **NASM** (для openssl) |
| Offline pip-пакеты | `packages-linux/` | `packages/` |
| Кеш Conan | `~/.conan2/` | `%USERPROFILE%\.conan2\` |
| Компилятор | gcc | MSVC (`cl.exe`, `link.exe`, `rc.exe`) |
| CMake-генератор | Ninja / Unix Makefiles | Visual Studio 17 2022 (multi-config) |
| Расширения | `.a` (static), `.so` (shared) | `.lib`, `.dll` |
| Имена файлов | `libgtest.a` | `gtest.lib` |
| `compiler.runtime` | не используется | критично: `dynamic` (`/MD`) или `static` (`/MT`) |
| Профиль | `astra-gcc`, `lin-gcc84-x86_64` | `win-v142-x64`, `win-v143-x64` |

**Windows-специфика.** В `.bat`-скриптах **нельзя использовать переменную `RC`** как локальную — она зарезервирована под Resource Compiler (`rc.exe`). Перезаписывание ломает CMake.

---

## gRPC: особенности

gRPC — самый «толстый» пакет в репо: 6 транзитивных зависимостей, ~80 CMake-targets, 7 опциональных языковых плагинов. Поэтому его рецепт отличается от остальных и требует пояснений.

### Структура папки

```
grpc/
├── conanfile.py                        ← рецепт + offline-патч (стандартный)
├── conandata.yml                       ← версии (1.78.1, 1.69.0, 1.54.3) + patches
├── conan_cmake_project_include.cmake   ← инжект в CMakeLists.txt верхнего уровня
├── cmake/
│   └── grpc_plugin_template.cmake.in   ← шаблон для эмуляции executable imported targets
├── target_info/                        ← декларативное описание компонентов
│   ├── grpc_1.54.3.yml
│   ├── grpc_1.69.0.yml
│   └── grpc_1.78.1.yml
├── patches/v1.50.x/                    ← legacy-патчи (только для 1.54.3)
├── src/v1.78.1.tar.gz                  ← bundled tarball для offline
└── test_package/
```

Три файла, которых нет у других пакетов:

- **`target_info/grpc_<ver>.yml`** — описание всех `cpp_info.components`, которые exposes пакет: имя, тип библиотеки, requires, плагины. Читается в `package_info()` → `cpp_info.components[...]`. Файл свой на каждую версию gRPC, потому что список targets между релизами меняется. В `export()` копируется в `export_folder` рецепта, чтобы быть доступным при build-time у consumer'а.
- **`cmake/grpc_plugin_template.cmake.in`** — шаблон CMake-модуля для каждого языкового плагина (`grpc_cpp_plugin`, `grpc_python_plugin`, …). Conan-генераторы не умеют делать executable imported targets, поэтому в `package()` для каждого включённого плагина из шаблона генерируется свой `<plugin>.cmake` в `lib/cmake/conan_trick/`, и они подключаются через `cmake_build_modules`.
- **`conan_cmake_project_include.cmake`** — крошечный фикс: `set_target_properties(check_epollexclusive PROPERTIES LINKER_LANGUAGE CXX)`. Без него gcc падает на линковке epoll-теста при резолве abseil-символов. Подключается через `CMAKE_PROJECT_grpc_INCLUDE` (CMake-хук, который выполняется внутри `project(grpc ...)`).

### Дерево зависимостей и порядок сборки

```
grpc/1.78.1
├── protobuf/5.29.6
│   ├── abseil/20250127.0
│   └── zlib/1.3.1
├── abseil/20250127.0
├── re2/20251105 → abseil
├── c-ares/1.34.6
├── openssl/3.4.5 → zlib
└── zlib/1.3.1
```

Поэтому `test-astra/run_grpc.sh` перед `conan install` делает `conan export` всех 7 пакетов в локальный кеш:

```bash
for pkg in zlib abseil c-ares re2 protobuf openssl grpc; do
    conan export "$ROOT_DIR/$pkg/" --version="$ver"
done
conan install --requires=grpc/1.78.1 --build=missing --no-remote -o "*/*:shared=$shared"
```

Без `export` всех зависимостей `--no-remote` свалится: для транзитивных рецептов Conan не имеет ни кеша, ни источника.

### Жёсткие version-ranges

`requirements()` хардкодит совместимые диапазоны зависимостей в зависимости от версии gRPC:

| grpc | protobuf | abseil | re2 |
|---|---|---|---|
| > 1.69 | `[>=5.27.0 <7]` | `[*]` | `[>=20251105]` |
| 1.65–1.69 | `[>=5.27.0 <6]` | `[>=20240116.1 <=20250127.0]` | `20250722` |
| < 1.65 | `3.21.12` | `[>=20230125.3 <=20230802.1]` | `20230301` |

Для 1.78.1 у нас есть только **abseil 20250127.0** в репо — это попадает в диапазон `[*]` (т.е. любой), но если когда-нибудь обновим protobuf до 6.x, придётся пересмотреть.

> Ошибка `Version range 'abseil/[>=20230802.1 <=20250127.0]' could not be resolved` (см. «Типовые проблемы») — это именно про эти таблицы.

### Языковые плагины (опции)

```python
options = {
    "cpp_plugin": [True, False],          # grpc_cpp_plugin   — нужен всегда, дефолт True
    "csharp_plugin": [...],
    "node_plugin": [...],
    "objective_c_plugin": [...],
    "php_plugin": [...],
    "python_plugin": [...],               # grpc_python_plugin
    "ruby_plugin": [...],
    "otel_plugin": [True, False],         # OpenTelemetry, доступно с 1.65, дефолт False
    "csharp_ext": [True, False],
    "codegen": [True, False],             # grpc++_reflection, grpcpp_channelz
    "secure": [True, False],              # выбрасывает unsecure-варианты из cpp_info
    "with_libsystemd": [...]              # только Linux/FreeBSD
}
```

Каждый плагин = отдельный `<name>.cmake` в `lib/cmake/conan_trick/`, регистрируемый через `cmake_build_modules`. Если потребитель не использует язык — отключайте через `-o "grpc/*:python_plugin=False"` и т.п. чтобы не ставить лишние executables.

### Offline-критичные CMake-переменные

В `generate()` в toolchain прописываются:

```python
tc.cache_variables["gRPC_DOWNLOAD_ARCHIVES"] = False     # gRPC ≥1.62: не лезть в сеть за архивами
tc.cache_variables["gRPC_INSTALL"] = True                 # нужны сгенерированные cmake/-файлы
tc.cache_variables["gRPC_BUILD_TESTS"] = "OFF"
tc.cache_variables["gRPC_ZLIB_PROVIDER"] = "package"      # findpackage(ZLIB) — Conan-овский
tc.cache_variables["gRPC_CARES_PROVIDER"] = "package"
tc.cache_variables["gRPC_RE2_PROVIDER"] = "package"
tc.cache_variables["gRPC_SSL_PROVIDER"] = "package"
tc.cache_variables["gRPC_PROTOBUF_PROVIDER"] = "package"
tc.cache_variables["gRPC_ABSL_PROVIDER"] = "package"
tc.cache_variables["gRPC_OPENTELEMETRY_PROVIDER"] = "package"
tc.cache_variables["CMAKE_PROJECT_grpc_INCLUDE"] = ".../conan_cmake_project_include.cmake"
```

`gRPC_*_PROVIDER=package` — главное: без них grpc попытается тянуть свои собственные copies зависимостей через `FetchContent`. С ними он использует `find_package(...)` и берёт всё из Conan-кеша.

### `tool_requires("protobuf/<host_version>")`

```python
def build_requirements(self):
    self.tool_requires("cmake/[>=3.25]")
    self.tool_requires("protobuf/<host_version>")
    if cross_building(self):
        self.tool_requires(f"grpc/{self.version}")
```

protobuf нужен **и как host-зависимость** (линкуем `libprotobuf.a` в gRPC), **и как build-tool** (`protoc` запускается на этапе сборки). `<host_version>` гарантирует одинаковую версию в обоих контекстах. Следствие: при кросс-сборке protobuf компилируется дважды — для host и для build машины.

### Кросс-сборка

Если `cross_building(self)`:
- gRPC требует сам себя как `tool_requires` — нужен предсобранный `grpc_cpp_plugin` для build-машины.
- В `configure()` принудительно `protobuf:shared=True` если `grpc:shared=True` — иначе `grpc_cpp_plugin` (запускающийся на build-машине во время сборки потребителя) не сможет slинковаться с системной libprotobuf.

### Workaround для shared protobuf/abseil

Если protobuf и abseil собраны как shared, при запуске `protoc` (host = build, обычная сборка) или `grpc_cpp_plugin` нужно дотянуть `LD_LIBRARY_PATH` / `PATH` / `DYLD_LIBRARY_PATH` до их `.so`/`.dll`. `_patch_sources()` оборачивает CMake-команду:

```cmake
COMMAND ${_gRPC_PROTOBUF_PROTOC_EXECUTABLE} ...
# →
COMMAND ${CMAKE_COMMAND} -E env --modify "LD_LIBRARY_PATH=path_list_prepend:$<JOIN:${CMAKE_LIBRARY_PATH},:>" ${_gRPC_PROTOBUF_PROTOC_EXECUTABLE} ...
```

`cmake -E env --modify` появилось в **CMake 3.25** — отсюда `tool_requires("cmake/[>=3.25]")`. На Astra с предустановленным cmake 3.16 это означает `[platform_tool_requires] cmake/3.25.1` в профиле должна быть реальная версия ≥ 3.25, иначе сборка свалится при первом же запуске protoc.

### MSVC runtime

В `source()`:

```python
replace_in_file(self, "CMakeLists.txt", "include(cmake/msvc_static_runtime.cmake)", "")
```

gRPC по дефолту сам выбирает `/MD` или `/MT`. Мы это убираем, чтобы Conan определял `CMAKE_MSVC_RUNTIME_LIBRARY` через `compiler.runtime` в профиле. Без этой замены — конфликт между значением профиля и хардкодом gRPC.

### Известные ограничения

- **Shared на MSVC не поддерживается** (`raise ConanInvalidConfiguration` в `validate()`). Только static на Windows.
- **`compiler.cppstd` должен совпадать с abseil**. gRPC ≥1.70 требует C++17, ≤1.69 — C++14. Профиль с `cppstd=20` для grpc 1.78.1 ОК, но abseil должен быть собран тоже с 20.
- **`with_libsystemd`** — только Linux/FreeBSD. Сейчас по дефолту `False`, у нас `libsystemd` рецепта нет.
- **Heavy build**: чистая сборка дерева ≈ 8–15 минут на 8 ядрах. `run_grpc.sh` собирает только static/Release; для полного цикла Release+Debug нужно гонять руками или дописать скрипт.

### Получение `.nupkg` для сравнения с TeamCity

`run_grpc.sh` / `run_grpc.bat` сейчас выполняют только sanity-сборку дерева, **deployer-шаг в них не включён** — `.nupkg` на выходе не появляется. Чтобы получить артефакт, идентичный TeamCity-сборке, и сравнить его с текущим:

**Linux:**
```bash
source venv/bin/activate
PROFILE=profiles/astra-gcc

# 1. Собрать дерево Release+Debug (для legacy-формата нужны оба варианта одновременно)
for BT in Release Debug; do
    conan install --requires=grpc/1.78.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        --build=missing --no-remote \
        -s build_type="$BT" \
        -o "*/*:shared=False"
done

# 2. Запустить deployer
mkdir -p output && rm -f output/*.nupkg
conan install --requires=grpc/1.78.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

**Windows** — то же самое, но `--profile=profiles\win-v143-x64` и `^` вместо `\` в continuation.

### Что попадёт в `output/`

Deployer обходит **весь install-граф**, поэтому одна команда выдаёт `.nupkg` на каждый пакет дерева — 7 артефактов:

```
output/
├── grpc.lin.gcc84.static.x86_64.1.78.1.nupkg
├── protobuf.lin.gcc84.static.x86_64.5.29.6.nupkg
├── abseil.lin.gcc84.static.x86_64.20250127.0.nupkg
├── re2.lin.gcc84.static.x86_64.20251105.nupkg
├── c-ares.lin.gcc84.static.x86_64.1.34.6.nupkg
├── openssl.lin.gcc84.static.x86_64.3.4.5.nupkg
└── zlib.lin.gcc84.static.x86_64.1.3.1.nupkg
```

Сравнение с TeamCity:

| Что сравнивать | Как |
|---|---|
| Имя файла | `<name>.<os>.<compiler>.<linkage>.<arch>.<ver>.nupkg` — должно совпадать с TeamCity байт-в-байт |
| Структура внутри | `unzip -l <our>.nupkg` vs `unzip -l <tc>.nupkg` — то же дерево директорий и тот же набор файлов |
| `.nuspec` | `<dependencies>` должен включать те же 6 транзитивных deps с теми же версиями (см. `_grpc_components` для списка) |
| `.targets` | `<AdditionalDependencies>` — список `.lib`/`.a` в правильном порядке линковки |
| `lib/native/.../`| диффом: `diff <(unzip -p our grpc.a) <(unzip -p tc grpc.a)` — для бинарей не сойдётся (timestamps), но размеры должны быть в одном порядке |
| `include/` | `diff -r` распакованных include-директорий — должно быть одинаково |

**Подводный камень: `LEGACY_NAME_MAP`.** Если у TeamCity grpc пакуется под другим именем (например, `grpcpp` или с суффиксом), нужно добавить в `extensions/deployers/legacy_nupkg.py`:
```python
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    # "grpc": "grpcpp",  # если TeamCity использует другое имя
}
```

То же самое для зависимостей — если abseil/openssl/etc. в TeamCity называются иначе.

**TODO в скриптах.** В `run_grpc.sh` пока собирается только `static/Release` (одна вариация). Чтобы получить `.nupkg` идентичный TeamCity, нужно добавить Debug-проход и deployer-шаг — по аналогии с `run_test_zlib.sh`.

### Что делать при обновлении версии gRPC

1. Скачать новый tarball: `curl -L https://github.com/grpc/grpc/archive/refs/tags/v<ver>.tar.gz -o grpc/src/v<ver>.tar.gz`, проверить sha256.
2. Добавить запись в `conandata.yml`.
3. **Создать `target_info/grpc_<ver>.yml`** — взять из conan-center-index `recipes/grpc/all/target_info/`. Без этого `package_info()` упадёт.
4. Свериться с upstream `requirements()` — диапазоны abseil/protobuf/re2 для нового minor могут поменяться. Проверить, что в репо есть версия каждой зависимости в новом диапазоне; иначе — обновлять и их.
5. Если новая major протобуфа (>= 6.x) — abseil-диапазон тоже сдвинется.
6. Прогнать `test-astra/run_grpc.sh` в Docker `gcc:12-bookworm` с `--network=none`.

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

**Файл должен называться так же, как имя файла в URL `conandata.yml`** — `_offline_source_archive` ищет совпадение по filename из URL.

**Шаг 4.** Адаптировать рецепт для offline-сборки. Это **2 правки** в `conanfile.py`:

a) Добавить класс-атрибут — Conan скопирует архив в кеш вместе с рецептом:
```python
exports_sources = "src/*.tar.gz"
```

b) Добавить helper и переписать `source()` так, чтобы сначала пробовался локальный архив, и только потом fallback на upstream URL:
```python
def _offline_source_archive(self):
    """Return path to bundled source archive in export_sources, or None."""
    import os
    src_dir = os.path.join(self.export_sources_folder, "src")
    if not os.path.isdir(src_dir):
        return None
    # Prefer matching the upstream URL filename from conandata.yml
    sources = self.conan_data.get("sources", {}).get(str(self.version), {})
    urls = sources.get("url")
    if isinstance(urls, str):
        urls = [urls]
    elif urls is None:
        urls = []
    for url in urls:
        fname = url.rsplit("/", 1)[-1]
        candidate = os.path.join(src_dir, fname)
        if os.path.isfile(candidate):
            return candidate
    # Fallback: any tarball in src/
    for fname in os.listdir(src_dir):
        if fname.endswith((".tar.gz", ".tgz")):
            return os.path.join(src_dir, fname)
    return None

def source(self):
    _local = self._offline_source_archive()
    if _local:
        from conan.tools.files import unzip
        unzip(self, _local, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)
    # ... остальные шаги source() (apply_conandata_patches, replace_in_file и т.п.) — без изменений
```

**`conandata.yml` оставляй как у upstream — без правок.** Никаких `file:///` URL: они хардкодятся под путь Docker и ломаются на Windows из-за UNC-интерпретации.

**Почему именно `unzip()`, а не `get(file://...)`:** modern Conan 2 в `get()` имеет download-семантику и пытается «скачать» в `source_folder`. Если файл уже там (а после `exports_sources` он будет в кеше) — `get()` сваливается с `SameFileError`. `unzip()` распаковывает напрямую, без шага download.

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
conan create zlib/ --version=1.3.1 \
    -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc \
    -s build_type=Release --build=missing --no-remote
conan create zlib/ --version=1.3.1 \
    -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc \
    -s build_type=Debug   --build=missing --no-remote
```

Windows:
```cmd
call venv\Scripts\activate.bat
conan create zlib --version=1.3.1 ^
    -pr:h=profiles\win-v143-x64 -pr:b=profiles\win-v143-x64 ^
    -s build_type=Release --build=missing --no-remote
```

> Не забывайте `-pr:b` — иначе при offline-сборке упадёт на `tool_requires` (cmake/perl/nasm).

**Шаг 7.** Проверить кеш и упаковать legacy:
```bash
conan list "zlib/1.3.1:*"

conan install --requires=zlib/1.3.1 \
    -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc \
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
from conan.tools.files import copy, unzip

class FooConan(ConanFile):
    name = "foo"
    version = "1.0.0"
    license = "Proprietary"
    settings = "os", "compiler", "build_type", "arch"
    options = {"shared": [True, False], "fPIC": [True, False]}
    default_options = {"shared": False, "fPIC": True}

    # Bundle the upstream archive — works on offline machines.
    exports_sources = "src/*.tar.gz"

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def source(self):
        # Локальный архив всегда есть (внутренние пакеты не из интернета).
        archive = os.path.join(self.export_sources_folder, "src", f"v{self.version}.tar.gz")
        unzip(self, archive, destination=self.source_folder, strip_root=True)

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
    self.requires("openssl/3.4.5")
    self.requires("zlib/1.3.1")
```

Conan автоматически:
- проверяет/собирает зависимости при `conan install`
- передаёт их пути в build (через `CMakeDeps`)
- заполняет `<dependencies>` в `.nuspec` через deployer

Для пакетов с deps (как grpc) скрипт сборки делает `conan export` каждой зависимости заранее (см. `test-astra/run_grpc.sh`), потом `conan install --requires=grpc/X.Y.Z --build=missing` собирает всё дерево.

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

### `[platform_tool_requires]` — критично для offline

Многие canonical-рецепты имеют `tool_requires("cmake/[>=3.16]")`, `tool_requires("nasm/2.16.01")` и т.п. В режиме `--no-remote` Conan не может скачать рецепт cmake/nasm, и сборка падает. Решение — заявить системные тулзы как «уже установленные»:

```ini
[platform_tool_requires]
cmake/3.25.1
perl/5.36.0
nasm/2.16.01            # на Windows — для openssl
strawberryperl/5.32.1.1 # на Windows — для openssl
```

Conan примет это как «cmake/3.25.1 уже есть, не пытайся его собирать», и `tool_requires` рецептов разрешатся через системные бинари.

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

### Переопределение из CLI

```bash
conan create gtest/ --version=1.15.2 \
    -pr:h=astra-gcc -pr:b=astra-gcc \
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
    conan create "$NAME/" --version="$VERSION" \
        -pr:h="$PROFILE" -pr:b="$PROFILE" \
        -s build_type=$BT --build=missing --no-remote
done

mkdir -p output
conan install --requires="$NAME/$VERSION" \
    -pr:h="$PROFILE" -pr:b="$PROFILE" \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

Артефакт TeamCity: `output/*.nupkg`.

---

## Чек-лист добавления пакета

- [ ] `<name>/conanfile.py` — canonical + offline-патч (`exports_sources` + helper + `source()`)
- [ ] `<name>/conandata.yml` — без правок относительно upstream
- [ ] `<name>/src/<archive>` положен с тем же именем, что в URL conandata, sha256 совпадает
- [ ] `<name>/patches/<ver>/*.patch` — если у canonical были, переносим
- [ ] `<name>/test_package/` со smoke-тестом
- [ ] (опц.) `LEGACY_NAME_MAP` в deployer
- [ ] (опц.) `requirements()` для зависимостей
- [ ] При зависимостях — обновить test-скрипт, добавить `conan export` для каждой
- [ ] `conan create` Release + Debug на Linux прошёл (с `-pr:b`)
- [ ] `conan create` Release + Debug на Windows прошёл (с `-pr:b`)
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

**`Package 'cmake/[>=X.Y]' not resolved`**
— рецепт имеет `tool_requires("cmake/...")`, но нет ни remote, ни системного объявления. Добавить `cmake/X.Y.Z` в `[platform_tool_requires]` профиля. То же для `nasm`, `perl`, `strawberryperl`.

**Тот же error даже после правки профиля**
— забыли `-pr:b=<profile>`. Conan для build-context использует default profile, который наших `[platform_tool_requires]` не видит. Передавайте профиль и в host (`-pr:h`), и в build (`-pr:b`).

**`Could not download from the URL ...: NameResolutionError`** в offline-сборке
— ваш `_offline_source_archive` не нашёл локальный архив, и Conan ушёл в сеть. Проверьте, что имя файла в `<pkg>/src/` совпадает с filename из URL в `conandata.yml`.

**`Package 'xxx' build failed: Could not find compiler in env RC`** на Windows
— bat-скрипт перезаписал переменную `RC`. Имя `RC` зарезервировано под Resource Compiler.

**`Invalid: 'libcxx' value not defined`** на Linux
— в gcc-профиле отсутствует `compiler.libcxx`. Должно быть `libstdc++11` для C++11 ABI.

**`Package gtest/X.Y.Z not found in cache`** при `conan install --requires=…`
— забыли `conan create` (или `conan export`) перед `conan install`. Без remote Conan не скачает.

**`shared` в имени `.nupkg`, но внутри `.lib`/`.a`**
— это NuGet-конвенция: `shared` означает динамический MSVC runtime (`/MD`), а не shared-линковку самой библиотеки. Не баг.

**`sha256 mismatch`** при первом `conan create`
— скачали не тот tarball (например, github auto-archive `v1.3.1.tar.gz` вместо официального release `zlib-1.3.1.tar.gz`). Сравните с `sha256` в `conandata.yml`.

**`Version range 'abseil/[>=20230802.1 <=20250127.0]' could not be resolved`** при сборке protobuf/grpc
— взяли слишком новую abseil. Каждая версия protobuf жёстко ограничивает диапазон abseil. Подберите версию в указанных границах (см. `requirements()` соответствующего рецепта).

**`patch failed: ... already exists`**
— патч из `patches/<ver>/` уже применён (например, при повторном `conan create` после ручной правки исходника в кеше). Очистить кеш: `conan remove "<pkg>/<ver>" --confirm` и повторить.

**`SameFileError`** при `conan create`
— старый паттерн `get(self, f"file:///{local}", ...)` в `source()`. В Conan 2 он сваливается, если файл уже скопирован через `exports_sources`. Замените на `unzip()` (см. шаблон в Шаге 4).
