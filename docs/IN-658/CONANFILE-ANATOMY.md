# Conanfile.py Anatomy — структура наших рецептов

Глубокий разбор девяти `<pkg>/conanfile.py`, которые живут в этом репозитории. Документ для того, кто будет обновлять рецепты из upstream `conan-center-index` или добавлять новые.

Связанная литература:

- `docs/IN-658/DEVELOPER.md` — orientation по репозиторию (`<pkg>/`, `extensions/deployers/`, `profiles/`, …).
- `docs/IN-658/MIGRATION-PLAYBOOK.md` — методология миграции и lessons learned. §«Пошаговая процедура» — соседний по теме разбор; здесь — глубже, по каждому файлу.
- `CLAUDE.md` (корень, локальный) — список багов Conan 2.27.1, которые рецепты обходят.
- `README.md` — общее описание проекта на русском.

---

## 1. Введение

### Что такое conanfile.py

`<pkg>/conanfile.py` — это Python-модуль с одним классом `<Pkg>Conan(ConanFile)`. Conan загружает его как обычный модуль, инстанциирует класс и **вызывает методы жизненного цикла в строго определённом порядке** (см. §2). Class-level атрибуты (`name`, `settings`, `options`, `exports_sources`) — статические свойства пакета; методы — динамика конкретного билда для конкретного profile/option-set.

В Conan 2.x recipe — это в первую очередь рецепт-программа: Conan не парсит его декларативно, а исполняет; всё что внутри `def source(self)` или `def package(self)` — обычный Python в контексте текущего билд-каталога.

### Наши 9 рецептов

| Recipe | Версия (legacy слот) | Build system | Особенности |
|---|---|---|---|
| `zlib/conanfile.py` | `1.3.0` (есть `1.3.1` patches) | CMake | простой, без зависимостей |
| `gtest/conanfile.py` | `1.15.2` (UI tests use `1.17.x`) | CMake | components: gtest/gmock; cppstd-sensitive |
| `c-ares/conanfile.py` | `1.25.0` | CMake | простой |
| `re2/conanfile.py` | `20230301` | CMake | требует abseil cppstd-match |
| `abseil/conanfile.py` | `20230802.1` (для grpc 1.60.x) | CMake | самый сложный — `_aggregate_legacy_coarse()` |
| `protobuf/conanfile.py` | `4.25.2` | CMake | пин abseil version range, debug_suffix |
| `openssl-1x/conanfile.py` | `1.1.11` (= 1.1.1w upstream) | Perl Configure + Autotools | legacy 1.1 line, отдельный класс |
| `openssl/conanfile.py` | (3.x line, `3.4.5` и др.) | Perl Configure + Autotools | upstream-newer, не используется в grpc 1.60 цепочке |
| `grpc/conanfile.py` | `1.60.1` | CMake | вершина дерева, ARM env-fallback |

«Legacy слот» — версия, которой пинят downstream-консьюмеры (`el_conf`, `mosquitto`, `sura_proto`). Эти строки `_dependencies` в `CMakeLists.var` устаревших пакетов задают абсолютно весь набор того, что мы пересобираем. Полная иерархия для grpc 1.60.x:

```
grpc 1.60.1
├── protobuf 4.25.2
│   ├── abseil 20230802.1
│   └── zlib 1.3.0
├── abseil 20230802.1   (pinned, см. requirements() ниже)
├── re2 20230301        (требует abseil)
├── c-ares 1.25.0
├── openssl 1.1.11      (через recipe openssl-1x)
└── zlib 1.3.0
```

### «Canonical-first»

Рецепты — **зеркало** `conan-center-index`. Это hard contract:

- Берём upstream `conanfile.py` целиком, *не* пишем с нуля.
- Локальные изменения делаются **только** через `<pkg>/patches/<version>/*.patch`, зарегистрированные в `<pkg>/conandata.yml` блок `patches:`.
- В сам `conanfile.py` — **два** разрешённых исключения (см. §3): `exports_sources = "src/*.tar.gz"` + `_offline_source_archive()` helper + модифицированный `source()`. На рецепты ARM-цепочки (abseil, re2, protobuf, grpc) — плюс env-fallback patch в `generate()` (§6).
- `conandata.yml`: URL/sha256 — *upstream-untouched*. Локально добавляем только блок `patches:`.

Когда обновляешь рецепт — копируешь свежий upstream `conanfile.py` и **повторно вставляешь** offline-edits и ARM-патч. Никогда не модифицируешь логику upstream-сборки руками в Python — только через `.patch`-файл на C++ исходники.

---

## 2. Lifecycle методов Conan-recipe

Порядок вызовов Conan'ом — фиксированный. Ниже только методы, которые реально используются в наших девяти файлах.

### 2.0. Class-level (statics)

```python
class AbseilConan(ConanFile):
    name = "abseil"
    description = "Abseil Common Libraries (C++) from Google"
    topics = ("algorithm", "container", "google", "common", "utility")
    homepage = "https://github.com/abseil/abseil-cpp"
    url = "https://github.com/conan-io/conan-center-index"  # url рецепта, не пакета
    license = "Apache-2.0"
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {"shared": False, "fPIC": True}
    short_paths = True
    extension_properties = {"compatibility_cppstd": False}
    exports_sources = "src/*.tar.gz"   # ← локальное добавление, см. §3
```

— `abseil/conanfile.py:15-37`. Поля читает Conan при загрузке. `package_type="library"` сигналит Conan'у про линковочные правила; `short_paths` для Windows MAX_PATH; `extension_properties` — мета для compatibility-плагина (см. §5, abseil/protobuf cppstd-sensitive).

### 2.1. `export_sources(self)` / `export(self)`

Вызывается при `conan export`. Копирует то, что должно попасть в *исходники* рецепта в cache (а не только в саму recipe-папку).

```python
def export_sources(self):
    export_conandata_patches(self)
```

— `abseil/conanfile.py:39-40`. Стандартный helper, копирует `patches/<version>/*.patch` указанные в `conandata.yml`. В `grpc/conanfile.py:80-83` дополнительно копирует CMake-шаблон `grpc_plugin_template.cmake.in` и `conan_cmake_project_include.cmake` в exports — они нужны при сборке. В `protobuf/conanfile.py:61-63` копирует `protobuf-conan-protoc-target.cmake`.

`exports_sources = "src/*.tar.gz"` (class-level glob) — альтернативный декларативный способ; на него опирается наша offline-схема (§3).

### 2.2. `config_options(self)`

Удаляет опции, неприменимые для текущего OS. Вызывается *до* `configure()`.

```python
def config_options(self):
    if self.settings.os == "Windows":
        del self.options.fPIC
```

— `abseil/conanfile.py:42-44`. На Windows `fPIC` бессмысленна → удаляется чтобы не попадала в `package_id` и не плодила лишние варианты. В `grpc/conanfile.py:85-91` ещё убирает `with_libsystemd` на не-Linux и `otel_plugin` для grpc < 1.65.

### 2.3. `configure(self)`

Финальная настройка опций — обычно cross-effect между опциями (shared ⇒ fPIC бесполезен).

```python
def configure(self):
    if self.options.shared:
        self.options.rm_safe("fPIC")
```

— `abseil/conanfile.py:46-48`. В `grpc/conanfile.py:93-99` также пропагирует `shared` на dependency: `self.options["protobuf"].shared = True`. В `zlib/conanfile.py:42-46` и `c-ares/conanfile.py:39-43` дополнительно убирают `compiler.libcxx`/`compiler.cppstd` (C-only либы — cppstd не влияет на ABI, держать в `package_id` бессмысленно).

### 2.4. `validate(self)`

Проверка валидности комбинации settings+options. Бросает `ConanInvalidConfiguration`. Вызывается уже когда `package_id` известен.

```python
def validate(self):
    min_cppstd = 17 if self._protobuf_release >= "30.1" else 14
    check_min_cppstd(self, min_cppstd)

    if "abseil" in self.dependencies.host:
        abseil_cppstd = self.dependencies.host['abseil'].info.settings.compiler.cppstd
        if abseil_cppstd != self.settings.compiler.cppstd:
            raise ConanInvalidConfiguration(
                f"Protobuf and abseil must be built with the same compiler.cppstd setting")
```

— `protobuf/conanfile.py:93-107`. Жёсткая проверка cppstd-match с abseil. Если разные — линковка протобуфа дальше упадёт на inline-namespace mismatch (см. memory `project_protobuf_absl_namespace.md`). То же есть в `re2/conanfile.py:58-61` и `grpc/conanfile.py:172-174`.

### 2.5. `requirements(self)`

Объявление host-зависимостей через `self.requires(...)`. Аргументы `transitive_headers=True`/`transitive_libs=True` определяют, видит ли consumer наш `abseil` через нас.

```python
def requirements(self):
    if self.options.with_zlib:
        self.requires("zlib/[>=1.2.11 <2]")

    if self._protobuf_release >= "30.1":
        self.requires("abseil/[>=20230802.1 <=20260107.1]",
                      transitive_headers=True, transitive_libs=True)
    else:
        # 5.29.x cannot use newer abseil than this, because newer abseil
        # requires c++17 as minmum
        self.requires("abseil/[>=20230802.1 <=20250127.0]",
                      transitive_headers=True, transitive_libs=True)
```

— `protobuf/conanfile.py:82-91`. Версия указывается **через version range** в квадратных скобках. В `grpc/conanfile.py:104-153` requirements ветвятся по `grpc_version`: для линии `1.60.0..1.65.0` зашпилены **точные** версии (`abseil/20230802.1`, `protobuf/4.25.2`, …) — это для legacy GR113/120 parity. См. комментарий рецепта `grpc/conanfile.py:123-139` и memory `project_protobuf_absl_namespace.md`.

### 2.6. `build_requirements(self)`

Build-time зависимости — на build context (хост, на котором запущена сборка), не на target. Типичный пример: `protoc` нужен для cross-build (`tool_requires("protobuf/<host_version>")`).

```python
def build_requirements(self):
    # cmake >=3.25 required to use `cmake -E env --modify` below
    # Offline-патч: exact version вместо range, чтобы матчиться с
    # [platform_tool_requires] cmake/3.25.1 в профилях
    self.tool_requires("cmake/3.25.1")
    self.tool_requires("protobuf/<host_version>")
    if cross_building(self):
        # when cross compiling we need pre compiled grpc plugins for protoc
        self.tool_requires(f"grpc/{self.version}")
```

— `grpc/conanfile.py:176-184`. **Важно:** `cmake/3.25.1` — *точная* версия. Conan не всегда корректно резолвит range против `[platform_tool_requires]` в профиле; exact-pin даёт детерминированную сборку. Тот же паттерн в `abseil/conanfile.py:58-63`, `protobuf/conanfile.py:142-145`, `re2/conanfile.py:63-66`, `gtest/conanfile.py:82-85`.

### 2.7. `layout(self)`

Описание раскладки `source_folder`/`build_folder`. У нас везде `cmake_layout(self, src_folder="src")` (или `basic_layout` для openssl).

```python
def layout(self):
    cmake_layout(self, src_folder="src")
```

— `abseil/conanfile.py:65-66`. `src_folder="src"` критично для нашей offline-схемы (§3) — это там же, где лежит `<archive>.tar.gz`, и где `export_sources_folder` будет видеть бандл.

### 2.8. `source(self)` — **модифицированный**

Распаковка исходников. **У всех 9 рецептов** модифицирован под offline-режим (§3 — глубокий разбор):

```python
def source(self):
    _local = self._offline_source_archive()
    if _local:
        from conan.tools.files import unzip
        unzip(self, _local, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)
    apply_conandata_patches(self)
```

— `abseil/conanfile.py:92-99`. Если есть `src/<archive>.tar.gz` в exports — берём его, иначе fallback на `get()` из URL в `conandata.yml`. `apply_conandata_patches(self)` накатывает локальные `.patch`'и.

### 2.9. `generate(self)`

Генерация `conan_toolchain.cmake` + `*-config.cmake` deps. Это место, где CMake cache-переменные настраиваются:

```python
def generate(self):
    tc = CMakeToolchain(self)
    tc.cache_variables["ABSL_ENABLE_INSTALL"] = True
    tc.cache_variables["ABSL_PROPAGATE_CXX_STD"] = True
    tc.cache_variables["BUILD_TESTING"] = False
    if self.settings.os == "Windows" and ...:
        tc.cache_variables["ABSL_MSVC_STATIC_RUNTIME"] = runtime == "static"
    _user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
    if _user_tc and str(self.settings.arch) in ("armv7", "armv7hf", "armv7s",
            "armv8", "armv8_32", "armv8.3", "arm64ec"):
        tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
    tc.generate()
```

— `abseil/conanfile.py:101-112`. Последний блок — наш ARM env-fallback patch (§6). У рецептов которым нужны транзитивные CMake-find-files, ещё `CMakeDeps(self).generate()` (см. `protobuf/conanfile.py:187-188`, `re2/conanfile.py:108-109`, `grpc/conanfile.py:341-342`).

### 2.10. `build(self)`

Запуск CMake configure + build.

```python
def build(self):
    cmake = CMake(self)
    cmake.configure()
    cmake.build()
```

— `abseil/conanfile.py:114-117`. В `grpc/conanfile.py:377-381` и `protobuf/conanfile.py:190-210` `_patch_sources(self)` (sed-патчи CMakeLists на лету) вызывается **внутри** `build()` или прямо после `apply_conandata_patches()` в `source()`.

### 2.11. `package(self)`

Установка артефактов из `build_folder` в `package_folder`. Это и копирование лицензии, и `cmake.install()`, и чистка лишних файлов (например `lib/pkgconfig/` если pkgconfig не нужен).

```python
def package(self):
    copy(self, "LICENSE", src=self.source_folder,
         dst=os.path.join(self.package_folder, "licenses"))
    cmake = CMake(self)
    cmake.install()
    rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))
    # ...
    if not self.options.shared:
        self._aggregate_legacy_coarse()   # ← см. §5 abseil
```

— `abseil/conanfile.py:119-138`. Самый «активный» package — у abseil (агрегирует ~150 .a в 21 .a, см. §5).

### 2.12. `package_info(self)`

Описывает что пакет экспортирует консьюмеру: `libs`, `include_dirs`, CMake-target name, components-hierarchy, system_libs.

```python
def package_info(self):
    self.cpp_info.set_property("cmake_file_name", "re2")
    self.cpp_info.set_property("cmake_target_name", "re2::re2")
    self.cpp_info.set_property("pkg_config_name", "re2")
    self.cpp_info.libs = ["re2"]
    if self.settings.os in ["Linux", "FreeBSD"]:
        self.cpp_info.system_libs = ["m", "pthread"]
```

— `re2/conanfile.py:123-129`. Простейший вариант — одна либа. Сложнее — `gtest/conanfile.py:100-138` (4 components: libgtest/gtest_main/gmock/gmock_main с requires-графом). Ещё сложнее — `abseil/conanfile.py:277-290` (~150 components, генерируется из json'а, заранее распарсенного из `abslTargets.cmake`).

---

## 3. Offline-edits — два локально-добавленных куска

Это **главное отличие наших рецептов от upstream conan-center-index**. На каждом обновлении надо вставлять обратно.

### 3.1. Class-level `exports_sources = "src/*.tar.gz"`

```python
class AbseilConan(ConanFile):
    # ...
    # Offline support: bundle the upstream archive with the recipe.
    exports_sources = "src/*.tar.gz"
```

— `abseil/conanfile.py:36-37`. Декларативно говорит Conan'у: при `conan export` скопировать всё подходящее под glob `src/*.tar.gz` (т.е. сам tarball исходников) в exports-папку cache. Без этого `_offline_source_archive()` ничего не найдёт когда recipe будет распаковываться из cache.

`exports_sources` существует у **всех 9** рецептов с дословно одинаковой строкой.

### 3.2. Helper `_offline_source_archive(self)`

Ищет архив в `<recipe>/src/`, имя которого совпадает с filename URL'а из `conandata.yml`. Fallback — любой `.tar.gz` из `src/`.

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
    # Fallback: any tarball in src/ (assume single archive)
    for fname in os.listdir(src_dir):
        if fname.endswith((".tar.gz", ".tgz")):
            return os.path.join(src_dir, fname)
    return None
```

— `abseil/conanfile.py:68-90`. Дословно идентичный helper в `protobuf/conanfile.py:109-131`, `c-ares/conanfile.py:48-70`, `re2/conanfile.py:68-90`, `grpc/conanfile.py:186-208`, `openssl/conanfile.py:152-174`, `openssl-1x/conanfile.py:122-140` (там чуть короче без явного `import os`).

`gtest/conanfile.py:60-66` и `zlib/conanfile.py:51-58` обходятся **без** helper'а — у них есть hard-coded filename и `os.path.exists()` напрямую в `source()` (формат `v{version}.tar.gz` для gtest, `zlib-{version}.tar.gz` для zlib). Эквивалентно по результату, но без fallback-вэйта на любой tarball.

### 3.3. Модифицированный `source(self)`

```python
def source(self):
    _local = self._offline_source_archive()
    if _local:
        from conan.tools.files import unzip
        unzip(self, _local, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)
    apply_conandata_patches(self)
```

— `abseil/conanfile.py:92-99`. Логика: попробовать локальный архив, иначе fallback на `conan.tools.files.get()` который скачает из URL.

### 3.4. Зачем

Closed-network билды на CI/Astra: интернета нет, conan-center недостижим. Если бы `source()` всегда делал `get(...)`, рецепт молча проваливался бы на download timeout. С offline-edits — берём `src/openssl-1.1.1w.tar.gz` (≈10 MB), `src/v1.60.1.tar.gz` (≈10 MB grpc) и т.д.

Hard contract:

- `conandata.yml` URL **никогда** не меняем под `file://`. Он должен дословно совпадать с upstream conan-center-index, чтобы `_offline_source_archive()` мог матчить filename (`https://github.com/abseil/abseil-cpp/archive/20230802.1.tar.gz` → `src/20230802.1.tar.gz`).
- При обновлении версии: сначала кладёшь новый tarball в `src/`, потом добавляешь блок в `conandata.yml`. Без архива — `conan create` упадёт на CI (на dev-машине с интернетом — fallback`get()` сработает, и баг проявится только в продакшене).

---

## 4. Patches mechanism

### 4.1. Регистрация в conandata.yml

`<pkg>/conandata.yml` имеет два корневых блока: `sources:` (URLs, upstream-untouched) и `patches:` (наши локальные).

```yaml
patches:
  "20240116.2":
    - patch_file: "patches/0003-absl-string-libm-20240116.patch"
      patch_description: "link libm to absl string"
      patch_type: "portability"
      patch_source: "https://github.com/abseil/abseil-cpp/issues/1100"
    - patch_file: "patches/20240116.1-0001-fix-filesystem-include.patch"
      patch_description: "Fix GCC 7 including <filesystem> in C++17 mode when it is not available (until GCC 8)"
      patch_type: "portability"
      patch_source: "https://github.com/abseil/abseil-cpp/commit/bb83aceacb554e79e7cd2404856f0be30bd00303"
    - patch_file: "patches/0004-test-allocator-testonly.patch"
      patch_description: "Do not build test_allocator target when tests are disabled"
      patch_type: "portability"
      patch_source: "https://github.com/abseil/abseil-cpp/commit/779a3565ac6c5b69dd1ab9183e500a27633117d5"
    - patch_file: "patches/0006-backport-arm-compilation-fix.patch"
      patch_source: "https://github.com/abseil/abseil-cpp/pull/1710"
  "20250127.0":
    - patch_file: "patches/20250127.0-0001-stacktrace-aarch64-binutils232.patch"
      patch_description: "Replace xpaclri inline asm with hint #7 (NOP-equivalent) for binutils 2.32 (linaro 7.5) compatibility on aarch64 cross-builds"
      patch_type: "portability"
```

— `abseil/conandata.yml:32-78`. Каждая запись — путь к `.patch` относительно `<pkg>/`, плюс мета-поля (description, type, source-url). Conan не использует мета — это для людей.

### 4.2. Применение в source()

```python
def source(self):
    _local = self._offline_source_archive()
    if _local:
        unzip(self, _local, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)
    apply_conandata_patches(self)   # ← здесь
```

`apply_conandata_patches(self)` (`conan.tools.files`) читает блок `patches[<version>]` из `conandata.yml` и накатывает `.patch`'и в `source_folder`. Если patch не применился — рецепт падает прямо тут, до build.

В `grpc/conanfile.py` apply_conandata_patches вызывается из `source()`, но дополнительно `_patch_sources(self)` (хардкод replace_in_file) — из `build()`. Это две разных категории: `.patch`'и упавшие в `patches/<version>/` и захардкоженные replace_in_file прямо в Python. По возможности предпочитаем `.patch`'и — они декларативны.

### 4.3. Hard contract по patches

- **Не модифицировать** `conandata.yml` source URLs/sha256 — они должны идентично совпадать с upstream conan-center-index. Это обеспечивает шанс быстрого `diff` против upstream при обновлении.
- Локальные изменения исходников — **только** через `patches/<version>/*.patch` + регистрация в блоке `patches:` в `conandata.yml`.
- Имя patch-файла обычно: `<version>-NNNN-<short-desc>.patch` или `NNNN-<short-desc>.patch` (старый стиль).

### 4.4. Что лежит у нас сейчас

```
abseil/patches/
  0003-absl-string-libm-20230802.patch   ← linkage с libm
  0003-absl-string-libm-20240116.patch
  0003-absl-string-libm.patch            ← версия для 20230125.3
  0004-test-allocator-testonly.patch     ← не строить test-only targets
  0006-backport-arm-compilation-fix.patch ← бэкпорт ARM-fix из upstream PR #1710
  20230802.1-0001-fix-mingw.patch
  20240116.1-0001-fix-filesystem-include.patch
  20250127.0-0001-stacktrace-aarch64-binutils232.patch ← см. §6
  20260107.1-0001-fix-heterogeneous_lookup-flag.patch

grpc/patches/v1.50.x/
  002-CMake-Add-gRPC_USE_SYSTEMD-option-34384.patch

openssl-1x/patches/
  1.1.1-tvos-watchos.patch

protobuf/patches/
  protobuf-3.20.0-upstream-macos-macros.patch
  protobuf-3.21.12-upstream-macos-macros.patch

zlib/patches/1.3.1/
```

c-ares, re2, gtest, openssl — без локальных patches.

---

## 5. Per-package особенности

### 5.1. abseil/conanfile.py — самый сложный

**`extension_properties = {"compatibility_cppstd": False}`** (`abseil/conanfile.py:34`). Это сигнал Conan'у: cppstd влияет на ABI (через inline namespace в abseil), не помечать пакеты с разным cppstd как «совместимые». Без этого Conan мог бы вернуть из cache pre-built `gnu14` пакет для `gnu17`-консьюмера, и линкер бы упал на «undefined reference to `absl::lts_NNNNNNNN::...`».

**`_aggregate_legacy_coarse()`** (`abseil/conanfile.py:140-209`) — функция, вызываемая из `package()` для static builds. Upstream abseil ставит ~150 fine-grained `libabsl_<X>.a` (одна на CMake-target). Legacy Elara `absl/0.2.0` ждёт 21 крупный `.a` (один на top-level `absl/<subdir>/`). Алгоритм:

```python
def _aggregate_legacy_coarse(self):
    import glob, tempfile
    src_absl = os.path.join(self.source_folder, "absl")
    lib_dir = os.path.join(self.package_folder, "lib")
    coarse_dir = os.path.join(lib_dir, "legacy-coarse")

    # 1. target -> subdir via regex parse of each absl/<subdir>/CMakeLists.txt
    target_to_subdir = {}
    subdirs = []
    for entry in sorted(os.listdir(src_absl)):
        cmakelists = os.path.join(src_absl, entry, "CMakeLists.txt")
        if not os.path.isfile(cmakelists):
            continue
        content = load(self, cmakelists)
        blocks = re.findall(r"absl_cc_library\(([^)]*)\)", content, re.S)
        if not blocks:
            continue
        subdirs.append(entry)
        for block in blocks:
            m = re.search(r"\bNAME\s+(\S+)", block)
            if m:
                target_to_subdir["absl_" + m.group(1)] = entry

    # 2. group libabsl_<target>.a by subdir
    groups = {s: [] for s in subdirs}
    for archive in sorted(glob.glob(os.path.join(lib_dir, "libabsl_*.a"))):
        target = os.path.basename(archive)[3:-2]
        subdir = target_to_subdir.get(target)
        if subdir is None:
            self.output.warning(f"legacy-coarse: no subdir for '{target}', skipped")
            continue
        groups[subdir].append(archive)

    # 3. ar-merge each subdir's archives into one lib<subdir>.a
    ar = os.environ.get("AR") or "ar"
    os.makedirs(coarse_dir, exist_ok=True)
    for subdir in subdirs:
        out = os.path.join(coarse_dir, f"lib{subdir}.a")
        objects = []
        workdir = tempfile.mkdtemp(prefix=f"absl-coarse-{subdir}-")
        for idx, archive in enumerate(groups[subdir]):
            extract = os.path.join(workdir, str(idx))
            os.makedirs(extract)
            self.run(f'"{ar}" x "{archive}"', cwd=extract)
            objects += glob.glob(os.path.join(extract, "*.o"))
        if objects:
            args = " ".join(f'"{o}"' for o in objects)
            self.run(f'"{ar}" rcs "{out}" {args}')
        else:
            save(self, out, "!<arch>\n")   # пустой архив для header-only subdir
        rmdir(self, workdir)
```

Выход: `lib/legacy-coarse/libstrings.a`, `libflags.a`, `librandom.a`, …, всего 21 файл. Native `libabsl_*.a` в `lib/` остаются — Conan-консьюмеры (grpc, protobuf) линкуются с ними через `absl::*` targets. Legacy-консьюмеры (через legacy_nupkg deployer) — с coarse. Подробный фон: memory `project_absl_component_granularity.md`.

**`_load_components_from_cmake_target_file()`** (`abseil/conanfile.py:211-267`) — парсер upstream-сгенерированного `abslTargets.cmake`. Извлекает все 150 target'ов с их INTERFACE_LINK_LIBRARIES / INTERFACE_COMPILE_DEFINITIONS, складывает в json (`lib/components.json`). `package_info()` потом восстанавливает оттуда корректный components-граф (вместо ручного описания 150 components).

### 5.2. protobuf/conanfile.py

**Пин abseil через version range** (`protobuf/conanfile.py:82-91`):
```python
if self._protobuf_release >= "30.1":
    self.requires("abseil/[>=20230802.1 <=20260107.1]",
                  transitive_headers=True, transitive_libs=True)
else:
    self.requires("abseil/[>=20230802.1 <=20250127.0]",
                  transitive_headers=True, transitive_libs=True)
```

Range — потому что abseil — moving target, но новые abseil 20250512+ требуют cppstd=17 и protobuf 5.29.x не пересоберётся.

**Жёсткий cppstd-match validate** (`protobuf/conanfile.py:93-107`) — см. §2.4.

**Опция `debug_suffix`** (`protobuf/conanfile.py:31, 40`, default `True`) — на Windows debug-сборка получает `libprotobufd.lib` (с суффиксом `d`). Используется в `package_info()` через `lib_suffix`:
```python
lib_suffix = "d" if self.settings.build_type == "Debug" and self.options.debug_suffix else ""
self.cpp_info.components["libprotobuf"].libs = [lib_prefix + "protobuf" + lib_suffix]
```

**CMake target setup в package_info()** — components `libprotobuf`, `libprotoc`, `libprotobuf-lite`, `utf8_range`, `utf8_validity`, плюс опционально `upb`. Каждому `set_property("cmake_target_name", "protobuf::libXXX")`. См. `protobuf/conanfile.py:228-313`.

**Ещё одна Linux-специфика** (`protobuf/conanfile.py:174-180`):
```python
if self.settings.os == "Linux":
    # Use RPATH instead of RUNPATH to help with specific case
    # in the grpc recipe when grpc_cpp_plugin is run with protoc
    # in the same build. RPATH ensures that the rpath in the binary
    # is respected for transitive dependencies too
    tc.extra_exelinkflags.append("-Wl,--disable-new-dtags")
    tc.extra_sharedlinkflags.append("-Wl,--disable-new-dtags")
```

### 5.3. grpc/conanfile.py

**Жёсткий пин deps для линии 1.60.x** (`grpc/conanfile.py:123-139`):
```python
elif grpc_version >= "1.60.0":
    # Legacy GR113/120 parity. Pin every transitive dep to the
    # exact version Elara already publishes so binary
    # _dependencies records in CMakeLists.var match in-tree
    # consumers (el_conf, mosquitto, gsd_parser, sura_proto).
    # abseil 20230802.1 (NOT 20240116.2): grpc 1.60 (Dec 2023)
    # predates the 20240116 LTS, and the legacy Elara `absl/0.2.0`
    # slot that el_conf/grpc_sdk compile against is abseil 20230802.
    # A different abseil here yields an inline-namespace mismatch
    # (`lts_20240116` vs `lts_20230802`) that breaks every absl
    # symbol at downstream link time.
    self.requires("abseil/20230802.1", transitive_headers=True, transitive_libs=True)
    self.requires("protobuf/4.25.2", transitive_headers=True)
    self.requires("re2/20230301")
    self.requires("c-ares/1.25.0")
    self.requires("openssl/1.1.11")
    self.requires("zlib/1.3.0")
```

Это фикс из коммита `615cf9f` (см. memory `project_grpc_sdk_integration_validated.md`). До него был version range, и `abseil/20240116.2` тянул `lts_20240116` inline namespace, что ломало downstream'ы, скомпилированные против `lts_20230802` legacy `absl/0.2.0`.

**Offline-pre-extraction транзитивных grpc deps для < 1.62** (`grpc/conanfile.py:218-269`, `_preextract_grpc_offline_deps`). grpc/CMakeLists.txt безусловно вызывает `download_archive()` на envoy-api/googleapis/opencensus-proto/xds. Каждый вызов обёрнут в `if(NOT EXISTS third_party/<dep>)`, так что мы pre-populate'им эти dirs из бандлов в `src/` (4 tarball'а). С grpc ≥ 1.62 есть toggle `gRPC_DOWNLOAD_ARCHIVES=OFF` и эта пляска не нужна.

**Опции** (`grpc/conanfile.py:27-58`): много `*_plugin` (cpp/csharp/node/objective_c/php/python/ruby/otel), `secure`, `with_libsystemd`, `codegen`, `csharp_ext`. По default cpp_plugin=True, остальные плагины=True по upstream-привычке (мы их не используем).

**`target_info/grpc_<version>.yml`** (`grpc/conanfile.py:74-75, 383-390`) — внешний yaml со списком grpc targets/components/plugins на каждую minor-версию grpc. `package_info()` его читает, чтобы построить components-граф. Файл бандлится в exports через `def export(self)`.

### 5.4. c-ares/conanfile.py

Маленький, простой. CMake-сборка. Опции `shared`, `fPIC`, `tools` (билд утилит), `multithreading`. Один component `cares`. Полная либа в 123 строки.

Особенностей нет: ровно следует canonical conan-center-index recipe + наши offline-edits.

### 5.5. re2/conanfile.py

Требует abseil (`re2/conanfile.py:40-47`). Жёсткий cppstd-match validate (как у protobuf). Один component, простой `package_info`. Использует `implements = ["auto_shared_fpic"]` (Conan 2.x convention для auto-derived опций).

ARM env-fallback patch присутствует (`re2/conanfile.py:103-105`).

### 5.6. gtest/conanfile.py

Поставляет `gtest`, `gtest_main`, `gmock`, `gmock_main` — 4 components в `package_info()` (`gtest/conanfile.py:100-138`).

Опции:
- `build_gmock` (default True) — собирать gmock рядом с gtest.
- `no_main` — не собирать `gtest_main`/`gmock_main` (бывает нужно для embedded).
- `hide_symbols`, `disable_pthreads`.

**`extension_properties = {"compatibility_cppstd": False}`** (`gtest/conanfile.py:40`) — cppstd влияет на ABI gtest (`std::source_location` в новых версиях и т.д.).

`implements = ["auto_shared_fpic"]` — современный Conan 2.x идиом, автогенерит `config_options()`/`configure()` под shared/fPIC.

В source() simpler-path без `_offline_source_archive()` — hard-coded `v{version}.tar.gz`:
```python
def source(self):
    local_archive = os.path.join(self.export_sources_folder, "src", f"v{self.version}.tar.gz")
    if os.path.exists(local_archive):
        unzip(self, local_archive, destination=self.source_folder, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    internal_utils = os.path.join(self.source_folder, "googletest", "cmake", "internal_utils.cmake")
    replace_in_file(self, internal_utils, "-WX", "")
```

`-WX` (warnings-as-errors на MSVC) убирается — иначе чужие предупреждения внутри gtest валят билд.

### 5.7. openssl/conanfile.py (3.x line)

**Не CMake**. Upstream OpenSSL использует Perl-based Configure script + GNU make. Conan-recipe оборачивает это через `Autotools` toolchain:

- `generate()` создаёт `AutotoolsToolchain` + сохраняет cflags/cxxflags/defines/ldflags в `gen_info.conf`.
- `_create_targets()` (`openssl/conanfile.py:463+`) генерирует Perl-config файл с custom target (`conan-<build_type>-<os>-<arch>-<compiler>-<version>`).
- `_configure_args` собирает аргументы для `./Configure`.
- `build()` запускает `./Configure ...` → `make` → `make install`.

Очень много опций (>50) — все `no_*` (отключение конкретных модулей: `no_md2`, `no_ssl3`, `no_engine`, …). На Linux все default `False` (всё включено).

`requirements()`: `zlib` если `not no_zlib`.

`build_requirements()`: на Windows — nasm (asm), strawberryperl (если MSVC) или msys2/bash.

Файл огромный (728 строк) — большая часть это `_targets` dict (mapping `<os>-<arch>-<compiler>` → OpenSSL target string).

### 5.8. openssl-1x/conanfile.py — клон для 1.1 line

Это **отдельный recipe** для OpenSSL 1.1.x — `license = "OpenSSL"` (legacy license OpenSSL 1.x, не Apache 2.0 как в OpenSSL 3.x). Внутри `class OpenSSLConan(ConanFile)` — то же имя класса и `name = "openssl"`, но recipe-папка `openssl-1x/`, и `conandata.yml` содержит только версии 1.1.x:

```yaml
sources:
  "1.1.11":
    # Elara internal nomenclature "1.1.11" maps to upstream OpenSSL 1.1.1w.
    url: "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz"
    sha256: "cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
```

— `openssl-1x/conandata.yml`. **Внимание на номенклатуру**: Elara legacy слот зовётся `1.1.11`, а upstream tarball — `1.1.1w`. Mapping сидит только в conandata.

Структурно очень похож на `openssl/`: те же `_targets`, `_configure_args`, `Autotools`-обёртка над Perl Configure. Список опций чуть короче (нет `no_legacy`, `no_module`, `tls_security_level`, `enable_trace` — этих фич не было в 1.1).

Используется `grpc/1.60.x` через requires `openssl/1.1.11`.

### 5.9. zlib/conanfile.py

Простейший — 116 строк. CMake-сборка, одна опция `shared`+`fPIC`. Имя либы зависит от платформы (`zlib/conanfile.py:104-116`):
```python
if self.settings.os == "Windows" and self.settings.get_safe("compiler.runtime"):
    libname = "zdll" if self.options.shared else "zlib"
else:
    libname = "z"
```

`_patch_sources()` (`zlib/conanfile.py:72-86`) обходит проблему с `#ifdef HAVE_UNISTD_H` — апд исправлен в upstream zlib после Apple Clang 12. Не наш patch — просто replace_in_file inlined.

simpler-path `source()` без `_offline_source_archive()`, hard-coded `zlib-{version}.tar.gz`.

---

## 6. Conan 2.27.1 quirks worked-around

Полный список — в `CLAUDE.md` корневом. Здесь — те, что трогают непосредственно содержимое `conanfile.py`.

### 6.1. `tools.cmake.cmaketoolchain:user_toolchain` не пропагируется на transitive deps

`abseil`, `re2`, `protobuf`, `grpc` — все четыре рецепта в `generate()` имеют env-fallback patch:

```python
_user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
if _user_tc and str(self.settings.arch) in ("armv7", "armv7hf", "armv7s",
        "armv8", "armv8_32", "armv8.3", "arm64ec"):
    tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
tc.generate()
```

— `abseil/conanfile.py:109-112`, дословно то же в `protobuf/conanfile.py:182-185`, `re2/conanfile.py:103-105`, `grpc/conanfile.py:336-338`.

**Что происходит:** при ARM cross-build хост-профиль `lin-gcc75-arm-linaro` задаёт в `[conf]`:
```
tools.cmake.cmaketoolchain:user_toolchain=/work/profiles/toolchains/linaro-arm.cmake
```
Conan 2.27.1 пропагирует это значение на сам grpc-recipe (тот, что в командной строке), но **не** на transitive deps (abseil, re2, …) когда они собираются как часть grpc'шного `--build=missing`. Без linaro-toolchain CMake внутри dep-recipe берёт системный gcc и собирает x86_64 .a.

**Env-fallback читает `$CONAN_USER_TOOLCHAIN`** (переменная установлена `run_test_grpc.sh` / `test_arm_cross.sh`) и **руками** инжектит её в `tc.blocks["user_toolchain"]`.

**Arch-gate критичен** — `if str(self.settings.arch) in ("armv7", ...)`. Без gate'а при сборке build-context'а (x86_64 protoc для cross) — toolchain тоже бы инжектился, и protoc собирался бы под ARM, что валит дальше всю цепочку с ошибкой `arm-linux-gnueabihf-g++ -m64` (gcc 8.4 не умеет -m64 ему говорит arm-ld).

### 6.2. `[buildenv]` из host профиля leak'ает в build context

Не правка в `conanfile.py`, а в профиле `profiles/lin-gcc84-x86_64`. Профиль явно объявляет `[buildenv]` (`CC=/opt/x64-native-gcc/bin/gcc`, `LD=ld`, `CXX=g++`, …) чтобы перебить leak'ающие `arm-linux-gnueabihf-*` переменные когда этот профиль выступает как `pr:b` для ARM хоста.

Упомянуто здесь потому что **связка**: env-fallback в `generate()` + explicit `[buildenv]` в `pr:b` — together покрывают весь class пропаганды ARM cross. Если расширяешь профильную систему — оба места держи синхронно.

### 6.3. cmake/3.25.1 exact-version pin

```python
self.tool_requires("cmake/3.25.1")
```

В каждом рецепте где есть `build_requirements()`. Conan 2.27.1 не всегда корректно резолвит version range против `[platform_tool_requires] cmake/3.25.1` в профиле, и резолвер может выбрать wrong-version. Exact-pin → детерминированно.

---

## 7. Как обновить рецепт из upstream conan-center-index

Пошаговая инструкция:

### 7.1. Найти upstream

```
https://github.com/conan-io/conan-center-index/tree/master/recipes/<pkg>
```

В upstream структура: `recipes/<pkg>/all/conanfile.py` + `recipes/<pkg>/config.yml` (mapping версия→папка). У некоторых пакетов вместо `all/` — `1.x/`, `2.x/` и т.д.

### 7.2. Сравнить с нашим

Наш layout — flat: `<pkg>/conanfile.py`, без `config.yml`. Свежий upstream `conanfile.py` сравнивай с нашим, отмечая:
- offline-edits (§3) — должны остаться,
- ARM env-fallback в `generate()` (§6) — должен остаться (если рецепт это требует),
- `tool_requires("cmake/3.25.1")` exact-pin — должен остаться,
- наши `extension_properties` / `package_id` / `requires` пины — должны остаться, если они нужны.

### 7.3. Скопировать upstream conanfile.py

Полностью перетереть `<pkg>/conanfile.py`. **Не копировать** `config.yml` (у нас его нет).

### 7.4. Восстановить два offline-edits

Дословно (см. §3):

```python
class <Pkg>Conan(ConanFile):
    # ...
    exports_sources = "src/*.tar.gz"

def _offline_source_archive(self):
    # … 23 строки

def source(self):
    _local = self._offline_source_archive()
    if _local:
        from conan.tools.files import unzip
        unzip(self, _local, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)
    apply_conandata_patches(self)
```

`exports_sources` ставится сразу после `default_options`. `_offline_source_archive` — обычно перед `source`. Сама `source` — заменяет upstream-вариант.

### 7.5. Восстановить ARM env-fallback в generate()

Если рецепт в ARM-цепочке (abseil/re2/protobuf/grpc), в конец `generate()` (до `tc.generate()`):

```python
_user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
if _user_tc and str(self.settings.arch) in ("armv7", "armv7hf", "armv7s",
        "armv8", "armv8_32", "armv8.3", "arm64ec"):
    tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
tc.generate()
```

### 7.6. Сравнить conandata.yml

Источники: блок `sources:` — *идентично* upstream conan-center-index. Если upstream добавил новые версии — добавь. Если удалил старые — оставь (downstream может пинить старое).

Patches: блок `patches:` — *только наши локальные*. Upstream-патчи (если они есть в conan-center-index) либо игнорируем (если фикс уже в нашей версии исходников), либо берём — но регистрируем в нашем формате.

### 7.7. Прогнать локально

```bash
conan create <pkg>/ --version=<v> -pr=lin-gcc84-x86_64 \
    -s build_type=Release --build=missing --no-remote
conan create <pkg>/ --version=<v> -pr=lin-gcc84-x86_64 \
    -s build_type=Debug --build=missing --no-remote
```

Оба билд-типа, иначе deployer не наберёт пакет.

**Важно:** `conan create -pr=lin-gcc84-x86_64` для legacy-сборки запускается **только** внутри `docker run grpc-tc-mirror`, не на голой dev-VM (memory `feedback_x86_64_needs_docker.md`).

### 7.8. Если падает

Добавить новый patch в `patches/<version>/<NNNN>-<short-desc>.patch` + регистрация в `conandata.yml` блок `patches: "<version>": - patch_file: ...`. Перезапустить `conan create`.

### 7.9. Sanity check на структуру .nupkg

```bash
conan install --requires=<pkg>/<v> -pr=lin-gcc84-x86_64 --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/
ls output/   # должны лежать .nupkg
```

Если есть с чем сравнивать — `test-astra/diff_two_dirs.sh old_extract/ new_extract/` (см. `DEVELOPER.md` §«Tools added in IN-658»).

### 7.10. Документация

Если открыли новый класс quirk'а — добавь блок в `test-astra/HELP.txt` ([0]–[12] нумерация) и memory-файл (`~/.claude/projects/-Users-zero-Documents-projects-elara-work/memory/`).

### 7.11. Commit + push

```bash
git checkout -b update-<pkg>-<version>
git add <pkg>/conanfile.py <pkg>/conandata.yml <pkg>/patches/...
git commit -m "<pkg>: update to <version> from upstream conan-center-index"
git push origin update-<pkg>-<version>
```

---

## 8. Чек-лист «рецепт готов»

- [ ] `conan create -pr=lin-gcc84-x86_64 -s build_type=Release --build=missing --no-remote` проходит.
- [ ] То же с `-s build_type=Debug` проходит.
- [ ] `--deployer=extensions/deployers/legacy_nupkg.py` создаёт `.nupkg` правильной структуры (имя `<legacy>.<os>.<comp>.<linkage>.<arch>.<ver>.nupkg`).
- [ ] Внутри `.nupkg` есть `lib/native/<lib_suffix>/{libXXX.a,libXXX.so}` и `include/`.
- [ ] `class-level exports_sources = "src/*.tar.gz"` присутствует.
- [ ] `_offline_source_archive(self)` helper присутствует (или равнозначный hard-coded path как в zlib/gtest).
- [ ] `source(self)` использует local-first → fallback `get()` схему.
- [ ] `apply_conandata_patches(self)` (или эквивалент) есть в `source()` если есть `<pkg>/patches/`.
- [ ] Если рецепт в ARM-цепочке (abseil/re2/protobuf/grpc) — env-fallback в `generate()` есть, gate'нут на ARM-only arches.
- [ ] Если рецепт cppstd-sensitive (abseil/protobuf/gtest) — `extension_properties = {"compatibility_cppstd": False}`.
- [ ] Если рецепт требует точной abseil-версии (grpc 1.60.x) — `self.requires("abseil/<exact>")` вместо range, с комментарием почему.
- [ ] `cmake/3.25.1` exact-pin в `build_requirements()` если рецепт использует `tool_requires("cmake/...")`.
- [ ] `package_info()` объявляет:
  - [ ] `cmake_file_name` через `set_property`,
  - [ ] `cmake_target_name` (или components с `cmake_target_name` для multi-lib),
  - [ ] `pkg_config_name`,
  - [ ] корректные `libs`, `system_libs`, `requires`.
- [ ] `conandata.yml` source URLs/sha256 идентичны upstream conan-center-index (если есть откуда сравнить).
- [ ] `conandata.yml` patches регистрируют все файлы из `patches/<version>/`.
- [ ] Tarball `src/<filename>.tar.gz` присутствует и filename совпадает с URL filename в `conandata.yml`.
- [ ] Сборка проходит на закрытой сети (тест: timeout/no-route, `--no-remote` + полное отсутствие интернета — Conan должен взять local archive).
- [ ] Sanity test — downstream-проект (например `grpc_sdk`) собирается с этим пакетом и линкуется без `undefined reference`.
- [ ] Если новый quirk — задокументирован в `test-astra/HELP.txt` + memory.

---

## 9. Связанные документы

- `docs/IN-658/MIGRATION-PLAYBOOK.md` — методология и lessons learned (включая baremetal Conan-проблем). §«Пошаговая процедура» — соседняя инструкция, без deep-dive по lifecycle.
- `docs/IN-658/DEVELOPER.md` — repo orientation (`<pkg>/`, `extensions/deployers/`, `profiles/`, …).
- `docs/IN-658/DEVOPS-RUNBOOK.md` — операционные процедуры для CI/Astra.
- `docs/IN-658/DOWNSTREAM-MIGRATION.md` — как продакшен переходит на новые `.nupkg`.
- `docs/IN-658/STATUS.md` — текущее состояние IN-658.
- `docs/IN-658/CONFLUENCE.md` — высокоуровневый overview.
- `CLAUDE.md` (корень, локальный, не в git) — Conan 2.27.1 quirks list + ARM cross pipeline + linaro toolchain workarounds.
- `README.md` (корень) — общее описание проекта на русском, build matrix, чек-лист «Добавление нового пакета».
- `test-astra/HELP.txt` — нумерованные диагностические блоки `[0]`–`[12]` для конкретных проблем.
- `test-astra/TESTING_ARM.md` — ARM runbook.
- Memory files `~/.claude/projects/-Users-zero-Documents-projects-elara-work/memory/` — persistent context:
  - `project_in658_grpc_dockerised.md`
  - `project_protobuf_absl_namespace.md`
  - `project_absl_component_granularity.md`
  - `project_grpc_sdk_integration_validated.md`
  - `project_lzlib_components_naming.md`
  - `reference_elara_cmake_framework.md`
- Per-package `<pkg>/README.md` (если есть для конкретного пакета — на момент написания их нет, но структурно поддерживается).
