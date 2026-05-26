# Миграция third-party C++ библиотек на Conan 2.x (IN-353 / IN-658)

> Overview-страница для Confluence. Для технических деталей см. соседние документы.

## Что мы делали

Команда `conan-recipes` мигрировала **7 third-party C++ библиотек** с ручных TeamCity-билдов на **Conan 2.27.1**, сохранив байт-совместимость с легаси `.nupkg`-артефактами на ProGet. Цель — современный воспроизводимый build, переиспользуемый между Linux x86_64, Linux ARM (cross), Windows; без потери работающей экосистемы downstream-продуктов (el_conf, grpc_sdk, sura и др.), которые потребляют пакеты по легаси-именам.

| Пакет | Версия | Тикет |
|---|---|---|
| zlib | 1.3.0 | IN-353 |
| openssl | 1.1.11 | IN-353 |
| abseil | 20230802.1 (для grpc 1.60.x) | IN-353/IN-658 |
| c-ares | 1.25.0 | IN-353 |
| re2 | 20230301 | IN-353 |
| protobuf | 4.25.2 | IN-353 |
| grpc | 1.60.1 | IN-353/IN-658 |

## Зачем мигрировали

1. **Воспроизводимость** — Conan фиксирует версии и опции через профили; ручные TC-билды раньше зависели от состояния агента.
2. **Cross-platform** — один профиль `lin-gcc84-x86_64` / `lin-gcc75-arm-linaro` / `lin-gcc75-arm64-linaro` / `win-msvc`, без дублирования логики.
3. **Поддержка** — обновление до новой версии grpc/protobuf или добавление новой опции — один patch в `conandata.yml`, не правка кода TC.
4. **Open-source compliance** — переход на сборку из upstream-исходников вместо Elara-форков с локальными правками.

## Что осталось от легаси

`.nupkg` остаётся форматом артефакта (zip с фиксированным layout + `.nuspec` + `CMakeLists.var`). Имена слотов сохранены (`absl/0.2.0`, не `abseil/20230802.1`). Структура `lib/native/<suffix>/`, `include/`, `proto/`, `build/<name>.targets` — байт-совместима с тем что Elara CMake framework (`ResolveDependencies.cmake`, `FindInstalledPackage.cmake`) ожидает.

## Стратегия coexistence с легаси

Параллельно с легаси-пакетами на ProGet (`absl.lin.gcc84.shared.x86_64.0.2.0.nupkg`) публикуем наши с суффиксом `.1` в имени (`absl.lin.gcc84.shared.x86_64.0.2.0.1.nupkg`) через переменную окружения `LEGACY_NUPKG_VERSION_SUFFIX=.1`.

**Плюсы:**
- ProGet не конфликтует — оба слота coexist.
- Откат к легаси возможен (если что-то пойдёт не так — снять `.1`-пакет, останется только легаси).

**Минусы (открытый вопрос — обсудить с лидом):**
- Downstream-проекты не знают про `.1`-суффикс — их `_dependencies` пинят bare-версии (`absl:0.2.0`), резолвят легаси. Нужен один из подходов в `DOWNSTREAM-MIGRATION.md` (обновить пины, либо вытеснить легаси).

## Что технически проверено

### x86_64 — закрыто (✅)

7 пакетов собираются, упаковываются в `.nupkg`. Две downstream-сборки прошли end-to-end на dev-VM `Pushkarev/dev-astra18-13`:

- **grpc_sdk** 1.3.0 (Debug+Coverage+Shared) — конфигурация, компиляция, линковка, ctest (минус 2 теста с известным баг-паттерном в их test-коде).
- **el_conf** 0.22.0-alpha (Debug+Shared) — конфигурация, компиляция, линковка ВСЕХ 30+ компонентов и плагинов, тесты проходят.

### ARM (armv7hf + arm64) — следующая фаза

Инфраструктура готова (`test-astra/test_arm_cross.sh`, multi-stage Docker, linaro 7.5 toolchains). Прогон не делал.

## Ключевые технические решения и компромиссы

### 1. Abseil — 21 «крупный» компонент вместо upstream 150

Легаси `absl/0.2.0` экспортирует 21 крупную либу (`libstrings.a`, `librandom.a`, ...). Upstream абсейл — 150 мелких (`libabsl_strings.a`, `libabsl_random_internal_*.a`, ...). Downstream Elara framework линкует через 21 крупный коарс-formal.

**Решение:** В `abseil/conanfile.py` добавлена функция `_aggregate_legacy_coarse()` — после `cmake --install` обходит исходники, мапит upstream-targets в 21 top-level subdir абсейла, склеивает соответствующие `.o` файлы в одну `.a` через `ar rcs`.

### 2. Inline-namespace `lts_NNNNNNNN`

Abseil ABI определяется inline-namespace в `absl/base/options.h` (`ABSL_OPTION_INLINE_NAMESPACE_NAME`). Любая cross-package mix ведёт к undefined references.

**Решение:** В рамках grpc/1.60.x пины зафиксировали `abseil/20230802.1` → namespace `lts_20230802`. Совпадает с legacy `absl/0.2.0`. Protobuf/grpc/grpc_sdk потребители получают консистентный namespace.

### 3. `.nupkg` layout — обратная совместимость

Deployer `legacy_nupkg.py` накладывает несколько преобразований:
- Версии: `LEGACY_VERSION_MAP` — `abseil/20230802.1` → `absl/0.2.0(.1)`.
- Имена: `LEGACY_NAME_MAP` — `c-ares → cares`, `gtest → googletest`, `abseil → absl`.
- Файлы либ: `LIB_FILENAME_ALIASES` — `libz.so → libzlib.so` симлинк, `libprotoc.so → libprotolib.so` симлинк.
- Префиксы: `LIB_FILENAME_PREFIX_STRIP` — `libabsl_*.so → lib*.so`.
- `proto/google/protobuf/*.proto` — well-known `.proto` файлы мирорятся отдельной верхнеуровневой папкой (Elara framework передаёт `--proto_path=<pkg>/proto`).

### 4. ABI consistency

Все 7 пакетов собираются в одном Docker-образе с одной gcc 8.4, одним glibc, одинаковыми `-std=c++17`, `-fPIC`. Это исключает inline-namespace mismatch и mangling-конфликты.

## Куда дальше

1. **Production rollout** — координация с лидом по `.1`-суффикс стратегии (см. `STATUS.md` пункт 2).
2. **ARM фаза** — прогон `test_arm_cross.sh`, валидация артефактов, добавление в TeamCity (`DEVOPS-RUNBOOK.md`).
3. **Команда grpc_sdk** — фикс gtest fixture-collision (детали в `STATUS.md` пункт 1).
4. **TeamCity миграция** — заменить legacy GR121/GR122 конфиги на новые Conan-based, либо параллельно. Решение архитектуры — с лидом (память `feedback-tc-layout-needs-lead`).

## Контакты / ответственные

- **Реализация conan-recipes** — текущий разработчик (dev-VM `Pushkarev/dev-astra18-13`).
- **TeamCity / CI** — devops, см. `DEVOPS-RUNBOOK.md`.
- **Downstream-команды** — см. `DOWNSTREAM-MIGRATION.md` для шагов миграции каждой.

## Полезные ссылки

- [Репозиторий conan-recipes](https://bitbucket.inc.elara.local/projects/CYPA2/repos/conan)
- [GitHub-mirror](https://github.com/HYUEHFJKhfjklkej/conan)
- [STATUS.md](STATUS.md) — текущее состояние, коммиты, открытые вопросы.
- [DEVOPS-RUNBOOK.md](DEVOPS-RUNBOOK.md) — команды для CI.
- [DOWNSTREAM-MIGRATION.md](DOWNSTREAM-MIGRATION.md) — для команд продуктов.
- [DEVELOPER.md](DEVELOPER.md) — для следующего conan-recipes разработчика.
