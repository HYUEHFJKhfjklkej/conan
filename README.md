# conan-recipes

Conan-рецепты для third-party C++ библиотек наших продуктов. Цель — заменить
самописные TeamCity-сборки стандартным Conan-пакетингом, **сохранив
байт-совместимость с legacy `.nupkg`** (имена, структура, метаданные), чтобы
потребители (el_conf, grpc_sdk, sura) не ломались. Миграция идёт пакет-за-пакетом.

Репозиторий **offline-self-contained**: все source-архивы и pip-колёса лежат
внутри. На закрытом контуре (Astra, изолированные TC-агенты) сборка идёт без интернета.

## Что мигрировано

| Пакет | Версия | Источник |
|---|---|---|
| gtest | 1.15.2 | conan-center-index |
| zlib | 1.3.1 | conan-center-index + patch |
| abseil | 20250127.0 | conan-center-index |
| c-ares | 1.34.6 | conan-center-index |
| re2 | 20251105 | conan-center-index |
| protobuf | 5.29.6 | conan-center-index |
| openssl | 3.4.5 | conan-center-index |
| grpc | 1.78.1 | conan-center-index |

Всё дерево grpc (+6 deps) собирается полностью offline. Параллельно поддерживается
линия **grpc 1.60.1** (паритет GR910): protobuf 4.25.2 / abseil 20230802.1 /
openssl 1.1.1 / zlib 1.3.0 — драйвер `test-astra/run_grpc_1601_upstream.sh`
(`ARCH=x86_64|arm|arm64|all`).

## Быстрый старт

```bash
# Один раз (Astra/Linux):
sudo ./test-astra/install_deps.sh   # apt: gcc, cmake, python3-venv
./test-astra/setup.sh               # venv + offline Conan из packages-linux/
source venv/bin/activate

# Собрать .nupkg в output/:
./test-astra/run_test.sh            # gtest          (1 артефакт)
./test-astra/run_test_zlib.sh       # zlib           (1)
./test-astra/run_test_grpc.sh       # grpc + 6 deps  (7)
```

Каждый скрипт делает `conan create` (Release+Debug), затем
`conan install --deployer=legacy_nupkg.py` — деплойер обходит install-граф и
пакует `.nupkg` на каждый пакет.

- **Windows** — зеркальные `.bat` в `test-windows/` (`setup.bat`, `run_test*.bat`).
- **x86_64 CI** идёт в Docker (`grpc-tc-mirror`), не на голой dev-VM.
- **ARM cross** — `./test-astra/test_arm_cross.sh build arm|arm64`.

## Три контракта (не нарушать)

1. **Байт-совместимость `.nupkg`.** Имя, внутренняя структура (`lib/native/...`),
   `.nuspec <id>` должны совпадать со старой TeamCity-схемой. За это отвечает
   `extensions/deployers/legacy_nupkg.py`.
2. **Offline / canonical-first.** Рецепты — зеркала conan-center-index, свои
   правки только через `<pkg>/patches/`. `conandata.yml` (URL/sha256) не трогаем.
   Никогда не полагаемся на интернет, никаких `file://` URL.
3. **Slot-tag ≠ контент.** Сегмент `<linkage>` в имени — селектор runtime-CRT
   слота (`shared` = DynamicRT, `static` = StaticRT), **не** описание содержимого
   (контент всегда static `.a`). По умолчанию публикуем в `.shared.`;
   переопределяется env `LEGACY_NUPKG_LINKAGE`.

## Имя и структура `.nupkg`

```
<name>.<os>.<compiler>.<linkage>.<arch>.<version>.nupkg
grpc.lin.gcc84.shared.x86_64.1.78.1.nupkg        # Windows: grpc.win.v143.shared.x64...
```
Внутри: `lib/native/...`, `.nuspec`, `CMakeLists.var` (зависимости — под legacy-именами).

## Добавление нового пакета

> Короткая шпаргалка (6 шагов) — `test-astra/HOWTO-new-recipe-short.md`; подробный
> гайд для новичка — `test-astra/GUIDE-new-recipe-from-zero.md`.

Сначала ищем на <https://conan.io/center>. Если есть — зеркалим (большинство случаев):

1. Скопировать `recipes/<pkg>/all/` из conan-center-index в `<pkg>/`.
2. Положить source-архив в `<pkg>/src/` — **имя файла = имя из URL** в `conandata.yml`.
3. В `conanfile.py` — **2 offline-правки** (остальное upstream as-is):
   ```python
   exports_sources = "src/*.tar.gz"

   def source(self):
       _local = self._offline_source_archive()   # ищет src/<filename-из-URL>
       if _local:
           unzip(self, _local, strip_root=True)   # не get(file://): он падает с SameFileError
       else:
           get(self, **self.conan_data["sources"][self.version], strip_root=True)
       apply_conandata_patches(self)
   ```
   Полный код `_offline_source_archive` — в любом нашем рецепте (напр. `zlib/conanfile.py`).
4. Если legacy-имя ≠ Conan-имя — добавить в `LEGACY_NAME_MAP` в деплойере.
5. Собрать (Release **и** Debug — деплойеру нужны оба) и упаковать:
   ```bash
   conan create <pkg>/ --version=<ver> -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc \
       -s build_type=Release --build=missing --no-remote
   conan install --requires=<pkg>/<ver> -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc \
       --no-remote --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/
   ```
   `-pr:b` обязателен — иначе offline-сборка падает на `tool_requires` (cmake/perl/nasm).

Проприетарные библиотеки без canonical-рецепта — пишем рецепт с нуля по тем же конвенциям.

## Профили

| Профиль | Когда |
|---|---|
| `astra-gcc` | smoke на голой dev-VM |
| `lin-gcc84-x86_64` | канонический CI (только в Docker `grpc-tc-mirror`) |
| `lin-gcc75-arm-linaro` / `lin-gcc-aarch64-linaro` | ARM / ARM64 cross |
| `win-v143-x64` / `win-v142-x64` | VS2022 / VS2019 |

`[platform_tool_requires]` в профиле критичен для offline — cmake/perl/nasm берутся
как системные, а не собираются из исходников.

## Conan

Версия **2.29.0**, ставится offline из `packages-linux/conan-2.29.0.tar.gz`
(`setup.sh`); зависимости — там же. Интернет не нужен.

## Структура репозитория

```
<pkg>/                      рецепты (conanfile.py + conandata.yml + src/ + patches/)
extensions/deployers/       legacy_nupkg.py — упаковка в legacy .nupkg
profiles/                   Conan-профили + toolchains/ (linaro ARM)
test-astra/ test-windows/   build-скрипты (Linux .sh / Windows .bat)
packages-linux/ packages/   offline pip-колёса (Conan + deps)
Dockerfile.grpc-tc-mirror-{x86_64,arm,arm64}  CI-зеркало по сборке: FROM базовый
                            образ (Bitbucket/ProGet) + Conan. По файлу на арку.
Dockerfile.*-test           локальный/online smoke (Docker Hub, не для ProGet)
```

Сборка и публикация CI-образов `grpc-tc-mirror-{x86_64,arm,arm64}` в ProGet —
драйвер `test-astra/prebake_push.sh` (раннбук — HELP `[20]`).

## Отладка

Диагностика и разбор типовых багов — пронумерованные блоки в **`test-astra/HELP.txt`**
(`[0]`…`[25]`). Частые грабли: `undefined reference to absl::lts_*` (inline-namespace
mismatch), `-lzlib` / `-lprotolib` (legacy-имена компонентов), `timestamp.proto:
File not found` (proto/-слой) — все разобраны в HELP.txt.
