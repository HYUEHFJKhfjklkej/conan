# Conan Usage Guide — как пользоваться Conan на нашей инфраструктуре

> **Аудитория:** разработчики и DevOps, которые впервые подходят к нашему `conan-recipes`. Это hands-on tutorial уровня "поставил, настроил, собрал" — **не** глубокая методология (она в `MIGRATION-PLAYBOOK.md`) и **не** CI-runbook (он в `DEVOPS-RUNBOOK.md`).
>
> Прочтите целиком один раз, потом возвращайтесь к нужным разделам — пункты 4-8 это рецепты copy-paste.

---

## 1. Что такое Conan и зачем оно нам

[Conan 2.x](https://docs.conan.io/2/) — менеджер C++ пакетов. Ключевые идеи:

- **Профиль = один target** (compiler + arch + build_type + ABI флаги). Один и тот же рецепт собирается в **разные** бинарные пакеты для разных профилей. Каждая комбинация даёт свой `package_id`.
- **ABI consistency.** Conan следит, чтобы все зависимости одного графа были скомпилированы совместимым компилятором/cppstd/libcxx. Несовместимость даст ошибку ещё до сборки, а не runtime-падение на проде.
- **Версии лочатся через graph.** Когда `grpc/1.60.1` объявляет `requires("abseil/[>=20230802.1 <=20250127.0]")`, Conan резолвит конкретную версию один раз и фиксирует её для всего билда.

### Наша версия

Мы используем **Conan 2.27.1**. Версия фиксирована, поставляется offline через `packages-linux/conan-2.27.1.tar.gz` (без `pip install conan` из интернета — у нас closed-network).

### Где Conan используется, а где нет

- **conan-recipes (этот репозиторий)** — здесь Conan работает по полной программе: профили, рецепты (`<pkg>/conanfile.py`), кэш, сборка.
- **Downstream-проекты** (`el_conf`, `grpc_sdk`, `sura`, и т. д.) — **не используют Conan напрямую**. Они потребляют наши `.nupkg` через legacy Elara CMake framework (`ResolveDependencies.cmake`). Сам Conan там не запускается.

Отношение:

```
conan-recipes  ─── (производит) ────►  .nupkg на ProGet
                                         │
                                         ▼
                                       Downstream
                                       (читает .nupkg
                                        через CMake framework,
                                        Conan не запускает)
```

Это критично: если вы **разработчик downstream**, вам Conan скорее всего вообще не нужно ставить. Идите в `DOWNSTREAM-MIGRATION.md`. Этот документ актуален если:

- вы пишете/чините рецепты в `conan-recipes` сами;
- вы хотите экспериментально использовать Conan в новом проекте;
- вы DevOps и настраиваете CI-агент;
- вы диагностируете проблему "что-то не собирается".

---

## 2. Установка Conan

### 2.1 На Linux (Astra или dev-VM)

```bash
# 1. Один раз — системные пакеты (gcc, cmake, python3-venv, git)
cd ~/conan-recipes
sudo ./test-astra/install_deps.sh

# 2. Создать venv и поставить Conan 2.27.1 из offline-tarball
./test-astra/setup.sh

# 3. Активировать venv
source venv/bin/activate

# 4. Проверка
conan --version
# ожидаем: Conan version 2.27.1
```

Что делает `setup.sh`:

1. Создаёт `venv/` в корне репо (если нет).
2. Ставит `pip`/`setuptools`/`wheel` из `packages-linux/` (offline, через `--no-index --find-links=`).
3. Ставит `conan` из `packages-linux/conan-2.27.1.tar.gz` со всеми deps (`pyyaml`, `requests`, `jinja2`, и т. д. — тоже offline).

**Важно:** venv нужно активировать в **каждой новой shell-сессии** (`source venv/bin/activate`). Можно прописать алиас:

```bash
alias act-conan='source ~/conan-recipes/venv/bin/activate'
```

### 2.2 На Windows (test-windows/)

Аналогичный путь через `test-windows/setup.bat`:

```cmd
cd C:\path\to\conan-recipes
test-windows\setup.bat
venv\Scripts\activate.bat
conan --version
```

Колёса в `packages/` собраны под конкретную Python-версию (cp314 win_amd64) — если у вас иной Python, `pip install` упадёт. Поставьте Python 3.14 с python.org с галкой "Add to PATH".

### 2.3 Внутри Docker (CI / cross-build)

Conan уже установлен в образе `grpc-tc-mirror` (собирается из `Dockerfile.grpc-tc-mirror`). Внутри запущенного контейнера `conan` сразу на PATH:

```bash
docker run --rm -it \
    proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0 \
    bash -c "source /work/venv/bin/activate; conan --version"
```

Для большинства CI-задач **сам Docker-образ не нужно собирать вручную** — скрипт `run_grpc_1601_upstream.sh` его авто-билдит из `Dockerfile.grpc-tc-mirror`, если в локальном docker нет образа `grpc-tc-mirror:latest`.

---

## 3. Профили — фундамент любой Conan-сборки

### 3.1 Что такое профиль

Файл в `profiles/` — описывает компилятор, архитектуру, build_type, ABI флаги, путь к toolchain. **Без профиля Conan сборку не запустит.**

Пример (`profiles/lin-gcc84-x86_64`):

```ini
[settings]
os=Linux
arch=x86_64
compiler=gcc
compiler.version=8.4
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

[platform_tool_requires]
# Используем системные cmake/perl вместо conan-built (мы в --no-remote).
cmake/3.25.1
perl/5.36.0

[buildenv]
CC=/opt/x64-native-gcc/bin/gcc
CXX=/opt/x64-native-gcc/bin/g++
AR=ar
AS=as
LD=ld
NM=nm
RANLIB=ranlib
STRIP=strip

[conf]
tools.build:compiler_executables={"c": "/opt/x64-native-gcc/bin/gcc", "cpp": "/opt/x64-native-gcc/bin/g++"}
```

Ключевые секции:

- `[settings]` — то, что Conan хеширует в `package_id`. Сменили `cppstd=17` → `cppstd=20` → новый `package_id` → пересборка.
- `[buildenv]` — переменные окружения для процесса сборки (`CC`, `CXX`, `LD`, ...).
- `[conf]` — Conan-конкретные ключи. Самый важный для нас — `tools.cmake.cmaketoolchain:user_toolchain` (грузит CMake toolchain-файл, см. ARM-профиль).
- `[platform_tool_requires]` — "не строй cmake/perl сам, используй системные".

### 3.2 Наши профили

| Профиль | Назначение |
|---|---|
| `lin-gcc84-x86_64` | Native Linux x86_64 — gcc 8.4 из `/opt/x64-native-gcc/`. Основной для x64-host билда. |
| `lin-gcc75-arm-linaro` | Linux ARM 32-bit cross — linaro 7.5 (armv7hf, hard-float). |
| `lin-gcc-aarch64-linaro` | Linux ARM 64-bit cross — linaro 7.5. |
| `lin-gcc84-i686` | Linux x86 (32-bit) — gcc 8.4. Редко. |
| `astra-gcc` / `linux-gcc` / `linux-gcc-debug` | Legacy/тестовые профили — для повседневной работы **не использовать**. |
| `win-v142-x64` / `win-v143-x64` | Windows MSVC 2019 / 2022 x64. |

Toolchain-файлы (для cross): `profiles/toolchains/linaro-arm.cmake`, `linaro-aarch64.cmake`.

### 3.3 Host vs Build профиль

Это центральная концепция Conan для cross-сборок:

- `-pr:h=` (host) — **для какого target** собираешь (куда побежит итоговый бинарь).
- `-pr:b=` (build) — **на чём** собираешь (CI-агент, dev-машина). Нужен для `tool_requires` (protoc, cmake, perl — собираемые/исполняемые **на build-host**).

Сценарии:

```bash
# Native x86_64 — host == build
conan create zlib/ --version=1.3.0 \
    -pr:h=profiles/lin-gcc84-x86_64 \
    -pr:b=profiles/lin-gcc84-x86_64

# Шорткат: одно -pr= применяется и к host, и к build
conan create zlib/ --version=1.3.0 -pr=profiles/lin-gcc84-x86_64

# Cross ARM32 — host=ARM, build=x86_64
conan create zlib/ --version=1.3.0 \
    -pr:h=profiles/lin-gcc75-arm-linaro \
    -pr:b=profiles/lin-gcc84-x86_64

# Cross ARM64 — host=ARM64, build=x86_64
conan create zlib/ --version=1.3.0 \
    -pr:h=profiles/lin-gcc-aarch64-linaro \
    -pr:b=profiles/lin-gcc84-x86_64
```

**Гранитное правило**: для cross **никогда не пишите** `-pr=` один раз. Всегда явно `-pr:h=` и `-pr:b=`. Иначе host-флаги протекут в build-tools (protoc слинкуется с `arm-ld` и упадёт). См. § 11.7.

---

## 4. Базовые команды Conan

Каждую команду — с реальным примером из нашего проекта.

### 4.1 `conan export` — экспорт рецепта в локальный кэш

Загружает `<pkg>/conanfile.py` + `<pkg>/conandata.yml` + `<pkg>/patches/` в локальный кэш `~/.conan2/` под именем `<name>/<version>@`. **Не строит** ничего, просто регистрирует.

```bash
conan export zlib/ --version=1.3.0
conan export abseil/ --version=20230802.1
```

Когда нужен: первый шаг любой сборки. Можно прогнать руками, но обычно вызывается из `run_grpc_1601_upstream.sh` для всех 7 рецептов сразу.

### 4.2 `conan create` — full build pipeline (export + install + build + package)

Самая частая команда. Делает за раз: export → resolve deps → build → package в кэш.

```bash
conan create zlib/ --version=1.3.0 \
    -pr:h=profiles/lin-gcc84-x86_64 \
    -pr:b=profiles/lin-gcc84-x86_64 \
    -s build_type=Release \
    -o '*/*:shared=True' \
    --build=missing \
    --no-remote
```

Разбор ключей:

| Ключ | Что делает |
|---|---|
| `-pr:h=`, `-pr:b=` | Host и build профили (см. § 3.3). |
| `-s build_type=Release` | Override настройки из профиля. Можно `-s compiler.cppstd=17`, `-s arch=...`. |
| `-o '*/*:shared=True'` | Опция для всех рекурсивных deps: shared (`.so`/`.dll`). Без — статика. Кавычки обязательны (shell-glob). |
| `--build=missing` | Строить только то, чего нет в кэше. Без — Conan берёт готовое (или падает). С `--build=*` — пересборка всего. |
| `--no-remote` | Не лезть в `conan-center.io`. **На production VM всегда указывать.** |

### 4.3 `conan install --requires=` — установка готовых пакетов

Не строит — только разворачивает существующий пакет (если есть в кэше) и генерирует `CMakeToolchain` / `CMakeDeps` файлы для consumer-проекта.

```bash
conan install --requires=grpc/1.60.1 \
    -pr:h=profiles/lin-gcc84-x86_64 \
    -pr:b=profiles/lin-gcc84-x86_64 \
    -s build_type=Release \
    -o '*/*:shared=True' \
    --build=missing \
    --no-remote
```

Используется в наших скриптах **с деплоером** для генерации `.nupkg`:

```bash
conan install --requires=zlib/1.3.0 \
    -pr=profiles/lin-gcc84-x86_64 \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/
```

`--deployer=` указывает кастомный python-скрипт, который копирует артефакты в `--deployer-folder=` и упаковывает в `.nupkg` (наш формат, см. `extensions/deployers/legacy_nupkg.py`).

### 4.4 `conan list` — что в кэше

```bash
conan list 'abseil/*'                # все версии abseil
conan list 'grpc/1.60.1:*'           # все binary-варианты grpc 1.60.1
conan list 'grpc/1.60.1#*:*'         # ещё и все recipe-ревизии
conan list '*'                       # вообще всё
```

Полезно после `conan create` чтобы убедиться что пакет реально оказался в кэше.

### 4.5 `conan remove` — чистка кэша

```bash
conan remove 'abseil/*' -c                  # снести abseil все версии и бинари
conan remove 'abseil/20230802.1' -c         # только эту версию (с её бинарями)
conan remove '*' -c                         # ВЫПАЛИТЬ всё. Перед re-билдом.
```

`-c` = `--confirm` (без подтверждения). Без него Conan спросит.

**Опасная нота:** `conan remove "abseil/*" -c` сносит и **recipe**, и **бинарь**. Если потом другой пакет резолвит `abseil/[>=20230802.1 <=20250127.0]`, граф упадёт, потому что нечего резолвить. В таком случае надо заново `conan export abseil/ --version=20230802.1`.

### 4.6 `conan inspect <recipe>` — посмотреть что внутри рецепта

```bash
conan inspect zlib/
# выведет name, version, settings, options, requires, ...
```

Полезно когда не помнишь какие опции у рецепта.

### 4.7 `conan profile show` — как Conan интерпретирует профиль

```bash
conan profile show \
    -pr:h=profiles/lin-gcc75-arm-linaro \
    -pr:b=profiles/lin-gcc84-x86_64
```

Печатает полный resolved-профиль. Самый верный способ проверить что `[buildenv]` / `[conf]` действительно подхватились, нет ли опечатки. **Первое что запустить, когда сборка падает с непонятным флагом.**

### 4.8 `conan config home` — где живёт кэш

```bash
conan config home
# по умолчанию ~/.conan2/
```

Если кэш разбух — `du -sh ~/.conan2/` обычно показывает 5-20GB после сборки grpc-цепочки. Чистить через `conan remove '*' -c` или просто `rm -rf ~/.conan2/p/` (директория с собранными бинарями; рецепты в `~/.conan2/c/` останутся).

---

## 5. Workflow: собрать одну библиотеку для теста

Сценарий: правлю `legacy_nupkg.py` или меняю патч в `zlib/patches/`, хочу проверить только zlib, не запуская всю цепочку.

```bash
cd ~/conan-recipes
source venv/bin/activate

# 1. Снести предыдущую сборку zlib (recipe + бинарь)
conan remove 'zlib/*' -c

# 2. Полная пересборка
conan create zlib/ --version=1.3.0 \
    -pr=profiles/lin-gcc84-x86_64 \
    -s build_type=Release \
    -o '*/*:shared=True' \
    --build=missing \
    --no-remote

# 3. Проверить что попало в кэш
conan list 'zlib/*'

# 4. Сгенерировать .nupkg через наш деплоер
mkdir -p output-test/
conan install --requires=zlib/1.3.0 \
    -pr=profiles/lin-gcc84-x86_64 \
    -s build_type=Release \
    -o '*/*:shared=True' \
    --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output-test/

# 5. Контроль артефакта
ls -lh output-test/
unzip -l output-test/zlib.lin.gcc84.shared.x86_64.1.3.0.nupkg | head -20
```

**Альтернатива через готовый скрипт** — `run_grpc_1601_upstream.sh` принимает имя одного пакета:

```bash
./test-astra/run_grpc_1601_upstream.sh zlib
# → собирает только zlib + транзитивные, кладёт в output-grpc-1601-upstream/zlib.*.nupkg
```

Это удобнее когда хочется учесть и docker-обёртку, и `LEGACY_NUPKG_VERSION_SUFFIX`.

---

## 6. Workflow: собрать всю grpc-цепочку для production

Главный entry-point для CI и для воспроизведения локально.

**Важно (см. memory `feedback_x86_64_needs_docker.md`):** `conan create -pr=lin-gcc84-x86_64` на голой dev-VM не запускайте. Профиль ссылается на `/opt/x64-native-gcc/bin/gcc`, которого нет на host. Скрипт сам обернётся в `docker run grpc-tc-mirror`, но запускать вручную `conan create` — только внутри контейнера.

```bash
cd ~/conan-recipes

# Закрытая сеть — base-образ из ProGet (не Docker Hub):
export X64_BASE_IMAGE=proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0
export BASE_IMAGE=$X64_BASE_IMAGE

# С .1-суффиксом для coexistence с легаси на ProGet:
LEGACY_NUPKG_VERSION_SUFFIX=.1 ./test-astra/run_grpc_1601_upstream.sh
# → ~15-25 минут на gcc84-x86_64 машине
# → 7 .nupkg в output-grpc-1601-upstream/
```

Что делает скрипт под капотом — детально расписано в `DEVOPS-RUNBOOK.md` § "x86_64 — полный билд цепочки grpc/1.60.1". Краткая схема:

1. Если нет docker-образа `grpc-tc-mirror` — собирает его из `Dockerfile.grpc-tc-mirror`.
2. Самовызывается через `docker run grpc-tc-mirror` (host-запуск автоматически оборачивается).
3. Внутри контейнера: `conan export` всех 7 рецептов, потом `conan create grpc` (тянет за собой 6 остальных через граф зависимостей).
4. `conan install --deployer=...` для каждого пакета → 7 `.nupkg` в `output-grpc-1601-upstream/`.

### Полезные env-overrides

```bash
SKIP_CACHE_CLEAN=1                            # не сносить кэш перед билдом (повторный прогон → быстро)
OUTPUT_DIR=output-experiment                   # своя output-директория
CACHE_VOLUME=conan-cache-experiment            # своя докер-volume под кэш
LEGACY_NUPKG_VERSION_SUFFIX=.2                 # альтернативный суффикс
```

---

## 7. Workflow: использовать готовые `.nupkg` в downstream-проекте

Главное напоминание: **downstream у нас не использует Conan напрямую.** Потребление через Elara CMake framework и `CMakeLists.var`:

```cmake
# В CMakeLists.var вашего проекта:
set(${project_name}_dependencies
    exceptions:0.5.0
    googletest:1.15.2
    grpc:1.60.1.1
    protobuf:4.25.2.1
    absl:0.2.0.1
)
```

Framework сам ходит на ProGet, скачивает `.nupkg`, разворачивает и регистрирует `<dep>_INCLUDE_DIRS` / `<dep>_LIBRARIES`. Никаких `conan install` в downstream-скриптах нет.

Полная процедура миграции — `DOWNSTREAM-MIGRATION.md` (там же таблица "старая версия → `.1`", список консьюмеров).

### А если всё-таки хочется потреблять через Conan напрямую?

Это нетипично для нашего стека, но поддерживается. См. § 8.

---

## 8. Workflow: добавить Conan в новый C++ проект

### 8.1 Создать `conanfile.txt`

```ini
[requires]
grpc/1.60.1
protobuf/4.25.2
zlib/1.3.0

[generators]
CMakeToolchain
CMakeDeps

[layout]
cmake_layout

[options]
*/*:shared=True
```

Альтернатива — `conanfile.py` (если нужна логика, conditional requires, custom options). См. примеры в `conan-recipes/<pkg>/conanfile.py`.

### 8.2 Установить deps и сгенерить CMake-glue

```bash
mkdir -p build/Release && cd build/Release
conan install ../.. \
    -pr=path/to/conan-recipes/profiles/lin-gcc84-x86_64 \
    -s build_type=Release \
    --build=missing \
    --no-remote
```

Это создаст в `build/Release/`:

- `conan_toolchain.cmake` — toolchain для CMake (CC/CXX/find_package пути).
- `<dep>-config.cmake` — для каждой зависимости (под `find_package(<dep> CONFIG)`).
- `conanrun.sh` / `conanbuild.sh` — env-настройки для запуска/сборки.

### 8.3 Билд через CMake

```bash
cmake ../.. \
    -DCMAKE_TOOLCHAIN_FILE=conan_toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release
cmake --build . -- -j$(nproc)
```

### 8.4 В `CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.20)
project(myapp CXX)

find_package(grpc REQUIRED CONFIG)
find_package(protobuf REQUIRED CONFIG)

add_executable(myapp main.cpp)
target_link_libraries(myapp PRIVATE
    grpc::grpc++
    protobuf::libprotobuf
)
```

Имена targets (`grpc::grpc++`) — те, что объявляет рецепт в `package_info()`. Можно подсмотреть в `<pkg>-config.cmake` после `conan install`.

---

## 9. Cross-build ARM

Подробный runbook — `DEVOPS-RUNBOOK.md` § "ARM cross-build" и `test-astra/TESTING_ARM.md`. Краткая последовательность:

```bash
cd ~/conan-recipes
export REGISTRY=proget.inc.elara.local/main

# Pre-flight — pull, image probe, docker build (без билда Conan)
./test-astra/test_arm_cross.sh smoke arm     # ~2 минуты
./test-astra/test_arm_cross.sh smoke arm64

# Если smoke зелёный — полный билд
./test-astra/test_arm_cross.sh build arm     # ~30-40 минут
./test-astra/test_arm_cross.sh build arm64

ls output-armv7hf/    # ожидаем 7 .nupkg
ls output-arm64/
```

Под капотом для ARM32:

- Docker-образ `grpc-tc-mirror-arm` (multi-stage, linaro toolchain в `/opt/linaro-arm-7.5.0/`).
- Host профиль: `lin-gcc75-arm-linaro` (target armv7hf).
- Build профиль: `lin-gcc84-x86_64` (native x86_64 для protoc и прочих tool_requires).
- CMake toolchain: `profiles/toolchains/linaro-arm.cmake`, цепляется через `[conf] tools.cmake.cmaketoolchain:user_toolchain` в host-профиле.

---

## 10. Closed-network ритуал

Критично для production VM (нет интернета).

| Правило | Зачем |
|---|---|
| **Всегда** `--no-remote` в каждой `conan` команде | Иначе Conan дёрнет `conan-center.io` и упадёт по timeout. |
| Source-archives **только** в `<pkg>/src/<filename>.tar.gz` | Имя должно точно совпадать с filename в `conandata.yml` URL. Если файла нет — Conan попытается скачать и упадёт. |
| Все pip-пакеты — **только** через `--no-index --find-links=packages-linux/` | `pip install conan` напрямую = ошибка resolve, в лучшем случае; mismatch версии — в худшем. |
| Docker base-image — **только** ProGet (`proget.inc.elara.local/main/library/...`) | `BASE_IMAGE=ubuntu:22.04` пытается `docker pull` с Docker Hub → нет интернета → fail. |
| `docker build --build-arg X64_BASE_IMAGE=...` и `--build-arg BASE_IMAGE=...` — **оба** на ProGet | См. memory `feedback_check_memory_first.md`. Одного `BASE_IMAGE` мало — `Dockerfile.grpc-tc-mirror` использует оба. |

---

## 11. Diagnostic checklist — "что-то не так с Conan"

Прогнать сверху вниз. Каждый блок начинается с симптома.

### 11.1 `conan: command not found`

```bash
# venv не активирован:
source ~/conan-recipes/venv/bin/activate
conan --version

# Если venv нет — пересоздать:
cd ~/conan-recipes
./test-astra/setup.sh
source venv/bin/activate
```

### 11.2 `ERROR: ... cannot fetch ...` / connection timeout

Conan пытается ходить в интернет. Проверки:

- Добавлен ли `--no-remote` в команду?
- Проверить что архив локально есть:
  ```bash
  ls -la <pkg>/src/
  ```
- Сверить имя архива с URL в `conandata.yml`:
  ```bash
  grep -A2 'url:' <pkg>/conandata.yml
  ```
  Filename из URL и filename в `src/` должны совпадать байт-в-байт.

### 11.3 `Conan recipe references not found` / `version 'X' not in cache`

Рецепт не экспортирован в кэш.

```bash
# Один пакет
conan export abseil/ --version=20230802.1

# Все 7 сразу — через основной скрипт (он начинает с export)
./test-astra/run_grpc_1601_upstream.sh   # экспортит и собирает
```

### 11.4 ABI mismatch — `undefined reference to absl::lts_NNNNNNNN::*`

Inline-namespace mismatch у abseil. В двух собранных бинарях разные namespace-стампы (`lts_20230802` vs `lts_20250127`).

Подробно: `MIGRATION-PLAYBOOK.md` Часть 2 § 1 и memory `project_protobuf_absl_namespace.md`. Quick check:

```bash
# В .nupkg должен быть lts_20230802 (для grpc/1.60.1 ветки)
mkdir /tmp/check && cd /tmp/check
unzip -q ~/.../abseil.lin.gcc84.shared.x86_64.20230802.1.1.nupkg
grep ABSL_OPTION_INLINE_NAMESPACE_NAME include/absl/base/options.h
# должно быть: #define ABSL_OPTION_INLINE_NAMESPACE_NAME lts_20230802
```

Готовый fix-скрипт — `test-astra/fix_legacy_protobuf_absl.sh`.

### 11.5 Stale `.nupkg` на dev-VM

После обновления пакета downstream может всё ещё видеть старую копию.

```bash
# Снести staged-копию, перекачать
HELP-блок [12] в test-astra/HELP.txt — полная процедура rm + unzip
```

См. `test-astra/HELP.txt` блок `[12]`.

### 11.6 Conan тратит часы на пересборку

Причины:

- Был `conan remove '*' -c` → кэш пустой → пересборка всего.
- Изменился профиль (любая строка в `[settings]` или `[conf]`) → новый `package_id` → пересборка. Это **нормально**.
- Сменили `-o shared=True` ↔ `False` → тоже новый `package_id`.

Чтобы пропустить чистку кэша в `run_grpc_1601_upstream.sh`:

```bash
SKIP_CACHE_CLEAN=1 ./test-astra/run_grpc_1601_upstream.sh
```

### 11.7 Cross-build падает с `arm-linux-gnueabihf-g++ -m64`

Toolchain leak: build context подхватил host-флаги (`-m64`, `-march=core2`) которые годятся только для x86_64.

Проверка:

```bash
conan profile show \
    -pr:h=profiles/lin-gcc75-arm-linaro \
    -pr:b=profiles/lin-gcc84-x86_64 \
    | grep -E "arch=|compiler=|cppstd=|cflags|cxxflags"
```

Host (ARM) не должен содержать x86-флагов. Build (x86_64) должен явно объявлять `[buildenv]` с `CC=/opt/x64-native-gcc/bin/gcc` (а не голым `gcc`, который в ARM-base-images указывает на Stretch system gcc 6.3 — abseil политики режут < gcc 7).

Подробности: `MIGRATION-PLAYBOOK.md` Часть 2 + `CLAUDE.md` quirks-section + `test-astra/HELP.txt` блок `[8]`.

### 11.8 abseil `-lrandom` / `-lflags` / `-lcord` not found

Гранулярность компонентов не сходится между легаси absl 0.2.0 (21 крупная `.a`, без cord) и upstream 0.2.0.1 (150 мелких `.so`, с cord). См. memory `project_absl_component_granularity.md`. Решается крупноблочной shared-сборкой с cord — в наших рецептах это уже сделано через `-o '*/*:shared=True'`.

### 11.9 `-lzlib` not found, хотя пакет zlib собран

Components в `CMakeLists.var` должны нести legacy-имя пакета (`zlib`), а не upstream basename либы (`z`). Фикс — `_legacy_component_names` в `extensions/deployers/legacy_nupkg.py`. См. memory `project_lzlib_components_naming.md`.

### 11.10 Где смотреть полные диагностические рецепты

`test-astra/HELP.txt` — пронумерованные блоки `[0]` ... `[12]`:

- `[0]` setup REGISTRY env.
- `[1]`-`[2]` диагностика base-images.
- `[3]`-`[4]` build mirror + x86_64 run.
- `[5]`-`[7]` ARM cross.
- `[8]` ARM build fails, под-блоки `[8a]` ... `[8h]`.
- `[12]` stale `.nupkg` recovery.

Если вы упёрлись и не нашли свой случай тут — сначала откройте `HELP.txt`, потом memory (`feedback_check_memory_first.md`).

---

## 12. Связанные документы

- `MIGRATION-PLAYBOOK.md` — полная методология миграции + lessons learned + 21 описанный кейс. Читать **после** освоения базы.
- `CONANFILE-ANATOMY.md` — анатомия наших `conanfile.py` (для тех, кто пишет/правит рецепты).
- `DEVOPS-RUNBOOK.md` — CI/TeamCity-конфигурация и автоматизация.
- `DOWNSTREAM-MIGRATION.md` — для команд-потребителей (`el_conf`, `grpc_sdk`, `sura`).
- `DEVELOPER.md` — orientation в репе (English).
- `STATUS.md` — текущий статус IN-658.
- `CONFLUENCE.md` — overview для Confluence.
- `../../test-astra/HELP.txt` — пронумерованные диагностические блоки.
- `../../test-astra/TESTING_ARM.md` — ARM runbook.
- `../../CLAUDE.md` — local-only context (для тех кто работает с Claude Code).
- Официальная Conan-документация: <https://docs.conan.io/2/>.

---

**Если упёрлись и ничего из § 11 не подходит** — соберите вывод `conan profile show`, последние 50 строк лога билда и `conan list '*' --format=text`, и приходите с этим к разработчику `conan-recipes`. Без этих трёх артефактов диагностика заочно невозможна.
