# MIGRATION PLAYBOOK — IN-658

> Полное практическое руководство по миграции third-party C++ пакетов на Conan 2.x в `conan-recipes`. Документ собран по итогам **IN-353** (x86_64 phase, closed) и **IN-658** (grpc-цепочка, x86_64 закрыто; ARM — следующая фаза).
>
> Состоит из трёх логических частей: (1) **методология и пошаговая процедура** для нового пакета, (2) **тонкие моменты и lessons learned** из закрытой x86_64-фазы, (3) **что можно улучшить, антипаттерны и координация** для следующего разработчика и команды.
>
> Аудитория — разработчик который придёт за IN-658 (ARM, Windows, грядущий bump grpc-линии), плюс лид/devops по координационным вопросам.

## Оглавление

- [Часть 1 — Методология и пошаговая процедура](#часть-1--методология-и-пошаговая-процедура)
  - [Введение и контекст](#введение-и-контекст)
  - [Подход к миграции — методология](#подход-к-миграции--методология)
  - [Пошаговая процедура для нового пакета](#пошаговая-процедура-для-нового-пакета)
  - [Особый случай: пакет с уникальной структурой](#особый-случай-пакет-с-уникальной-структурой)
  - [Когда пакет считается «готовым»](#когда-пакет-считается-готовым)
- [Часть 2 — Тонкие моменты и lessons learned](#часть-2--тонкие-моменты-и-lessons-learned)
  - [Карта граблей x86_64-фазы](#карта-граблей-x86_64-фазы)
  - [Краткий чек-лист отладки «что-то не линкуется»](#краткий-чек-лист-отладки-что-то-не-линкуется)
- [Часть 3 — Что можно улучшить, антипаттерны и координация](#часть-3--что-можно-улучшить-антипаттерны-и-координация)
  - [Возможные улучшения](#1-возможные-улучшения)
  - [Антипаттерны — что НЕ делать](#2-антипаттерны--что-не-делать)
  - [Координация и решения](#3-координация-и-решения)
  - [Контрольный чек-лист — миграция готова к merge](#4-контрольный-чек-лист--миграция-готова-к-merge--release)
  - [Дальнейшие шаги (handover)](#5-дальнейшие-шаги-handover)
- [Связанные документы](#связанные-документы)

---

# Часть 1 — Методология и пошаговая процедура

## Введение и контекст

Этот раздел — для разработчика, которому предстоит добавить в `conan-recipes` новый third-party C++ пакет (или мигрировать ещё одну legacy-библиотеку с ручного TeamCity-билда на Conan 2.x). Он формализует методологию, сложившуюся в ходе **IN-353** (x86_64 phase, closed) и **IN-658** (grpc-цепочка закрыта, ARM — следующая фаза).

Покрывает: hard contracts, пошаговый workflow от mirror-recipe до пуша в master, что делать при структурных расхождениях с легаси, done-критерии.

Не покрывает (соседние документы):

- инфраструктура CI / TeamCity — `docs/IN-658/DEVOPS-RUNBOOK.md`;
- шаги для downstream-команд — `docs/IN-658/DOWNSTREAM-MIGRATION.md`;
- текущий статус и открытые вопросы IN-658 — `docs/IN-658/STATUS.md`;
- overview для лида / нетехнических читателей — `docs/IN-658/CONFLUENCE.md`;
- быстрая ориентация в репозитории — `docs/IN-658/DEVELOPER.md`.

Все команды подразумевают запуск из корня `conan-recipes/`. Real-сборки x86_64 — внутри Docker-образа `proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0` (тот же, что использует TeamCity), не на голой dev-VM (память [[feedback_x86_64_needs_docker]]).

## Подход к миграции — методология

### Canonical-first

Каждый recipe в `<pkg>/` — это **mirror** соответствующего рецепта из [conan-center-index](https://github.com/conan-io/conan-center-index). Базовое правило: `conanfile.py` и `conandata.yml` не модифицируются «по месту» под локальные нужды. Любая правка upstream-источников — это patch-файл в `<pkg>/patches/<version>/*.patch`, зарегистрированный в `conandata.yml` (`patches → "<version>" → [...]`).

Что даёт:

- обновление до новой версии — берётся свежий рецепт + накладываются наши patches; не «merge всей логики Elara обратно в новый рецепт»;
- open-source compliance — собираемся из upstream-исходников;
- понятная сторона delta — наши изменения видны как diff к canonical.

Из правила — **два** разрешённых исключения в каждом `conanfile.py`: offline-source helper (`exports_sources = "src/*.tar.gz"` + блок `_offline_source_archive()` в `source()` — см. `CLAUDE.md` → «Recipe layout»). Эти два блока сохраняются дословно при обновлении.

### Hard contracts

Эти инварианты ломают downstream, если их нарушить:

1. **`.nupkg`-совместимость.** Имена слотов (`absl/0.2.0`, не `abseil/20230802.1`), внутренний layout (`lib/native/<suffix>/`, `include/`, `proto/`, `build/<name>.targets`), `<id>` в `.nuspec` — должны структурно совпадать с тем, что выкатывал старый TC-билд. Enforcement живёт в `extensions/deployers/legacy_nupkg.py`.
2. **Offline / `--no-remote`.** Real-сборки на closed-network Astra-агентах. Никакого `conan-center`, никакого `file://` в `conandata.yml`. Архив исходников — `<pkg>/src/<filename>.tar.gz`; pip-wheels — `packages-linux/` и `packages/`; Conan 2.27.1 пиннут как `packages-linux/conan-2.27.1.tar.gz`.
3. **Two platforms in lockstep.** Любое изменение в `test-astra/<script>.sh` должно иметь зеркало в `test-windows/<script>.bat`. Если делаешь только linux-сторону — оставь `TODO(win)` в коммит-сообщении и заведи тикет.

### Delta-only

Вся разница между upstream и Elara-экосистемой сосредоточена в **двух** местах:

- `extensions/deployers/legacy_nupkg.py` — имена, layout, alias'ы, proto-mirror, `.keepdir`-cleanup и т.п.;
- `<pkg>/conanfile.py` — только то, что нельзя выразить в deployer'е (например, `_aggregate_legacy_coarse()` в `abseil/conanfile.py`).

Если хочется третий слой (отдельный скрипт в `tools/`, трогающий уже собранный пакет) — это знак, что обходишь deployer. Скорее всего то же самое нужно делать внутри `legacy_nupkg.py`.

### Слот-имена и version-pinning

Легаси использует свои имена/версии: `absl/0.2.0`, `cares/1.19.0`, `googletest/...`. Upstream — `abseil/20230802.1`, `c-ares/1.25.0`, `gtest/...`. Маппинги — наверху `legacy_nupkg.py`:

```python
LEGACY_NAME_MAP = {
    "gtest":  "googletest",
    "abseil": "absl",
    "c-ares": "cares",
}

# Имя, под которым пакет упоминается в `_dependencies` ДРУГИХ пакетов
# (если отличается от LEGACY_NAME_MAP). Обычно пуст.
LEGACY_DEP_NAME_MAP = {}

# Подменяет версию в имени .nupkg, в .nuspec <version> и в каждом
# _dependencies-упоминании. Cache по-прежнему хранит upstream-версию
# (20240116.2), но артефакт выкатывается как 0.2.0.
LEGACY_DEP_VERSION_MAP = {
    "abseil": "0.2.0",
}

LIB_FILENAME_ALIASES = {
    "zlib":     {"z": "zlib"},          # libz.so → libzlib.so symlink
    "protobuf": {"protoc": "protolib"}, # libprotoc.so → libprotolib.so symlink
}
```

Первое, что делаешь при миграции пакета — смотришь, как его слот называется в легаси (по `.nupkg` на ProGet или артефактам старого TC), и регистрируешь маппинг. Без этого downstream-проекты с легаси-пинами в `_dependencies` не зарезолвят твой пакет.

## Пошаговая процедура для нового пакета

Workflow на новый пакет. Последовательность важна — каждый шаг отлавливает свой класс ошибок до того, как они дорастают до dev-VM, где цикл проверки 10-25 минут.

### Шаг 1. Mirror рецепта из conan-center-index

С машины с интернетом:

```bash
curl -L https://github.com/conan-io/conan-center-index/archive/refs/heads/master.tar.gz \
    | tar xz -C /tmp
cp -r /tmp/conan-center-index-master/recipes/<pkg>/all <pkg>/
```

В `conanfile.py` добавь два offline-блока:

```python
exports_sources = "src/*.tar.gz"

def _offline_source_archive(self):
    # match conandata.yml URL filename → src/<that-filename>.tar.gz,
    # fallback any tarball
    ...

def source(self):
    _local = self._offline_source_archive()
    if _local:
        unzip(self, _local, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version], strip_root=True)
    apply_conandata_patches(self)
```

`conandata.yml` оставь как upstream — никаких подмен URL/sha256.

### Шаг 2. Положить upstream-архив в `<pkg>/src/`

Имя файла = filename из URL в `conandata.yml`. Если URL — `https://github.com/fmtlib/fmt/archive/9.1.0.tar.gz`, то файл — `fmt/src/9.1.0.tar.gz`. При точном совпадении `_offline_source_archive()` найдёт сразу; при несовпадении возьмёт любой `.tar.gz` из `src/` — но лучше точное имя.

### Шаг 3. Локальные правки → patches

```bash
mkdir -p <pkg>/patches/<version>
# редактируешь unpacked-upstream, потом
git diff > <pkg>/patches/<version>/0001-fix-foo.patch
```

Регистрируешь в `conandata.yml`:

```yaml
patches:
  "<version>":
    - patch_file: "patches/<version>/0001-fix-foo.patch"
      patch_description: "Fix foo on gcc 8.4"
      patch_type: "portability"
```

### Шаг 4. Маппинг имени и версии в deployer

Если легаси-слот именуется иначе — добавь в `extensions/deployers/legacy_nupkg.py`:

```python
LEGACY_NAME_MAP["<pkg>"] = "<legacy_name>"
LEGACY_DEP_VERSION_MAP["<pkg>"] = "<legacy_version>"  # если версия тоже отличается
```

Если имя и версия совпадают с легаси — маппинг не нужен.

### Шаг 5. Маппинг имени файла либы

Если downstream линкует через имя, отличное от upstream basename:

```python
LIB_FILENAME_ALIASES["<pkg>"] = {"<upstream_libname>": "<legacy_libname>"}
```

Прецеденты:

- `-lzlib` (`03a20c0`) — `components` в `CMakeLists.var` должны нести legacy-имя пакета (`zlib`), не upstream-basename либы (`z`). Фикс — `_legacy_component_names()` в deployer'е.
- `-lprotolib` (`a611fc1`) — alias `protoc → protolib` + components emits **оба** имени.

### Шаг 6. Регистрация в build-скрипте

Если пакет идёт в grpc-tree — добавляешь в `EXPORTS` в `test-astra/run_grpc_1601_upstream.sh`:

```bash
declare -A EXPORTS=(
    [zlib]=1.3.0
    [openssl]=1.1.11
    [abseil]=20230802.1
    [c-ares]=1.25.0
    [re2]=20230301
    [protobuf]=4.25.2
    [grpc]=1.60.1
    [<pkg>]=<version>
)
```

Если автономный — отдельный `test-astra/run_<pkg>.sh` по аналогии с `run_test_zlib.sh`.

### Шаг 7. Локальная синтаксис-проверка на Mac

Прежде чем гонять docker — проверь синтаксис, цикл 1 секунда вместо 10 минут (память [[feedback_verify_locally_first]]):

```bash
python3 -c "import ast; ast.parse(open('<pkg>/conanfile.py').read())"
python3 -c "import ast; ast.parse(open('extensions/deployers/legacy_nupkg.py').read())"
bash -n test-astra/run_grpc_1601_upstream.sh
```

### Шаг 8. Тестовый билд в Docker

x86_64 — обязательно в `grpc-tc-mirror` контейнере, не на голой dev-VM (память [[feedback_x86_64_needs_docker]]):

```bash
docker run --rm -it \
    -v "$PWD":/work -w /work \
    proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0 \
    bash -lc '
        source venv/bin/activate &&
        conan create <pkg>/ --version=<version> \
            -pr:h=profiles/lin-gcc84-x86_64 \
            -pr:b=profiles/lin-gcc84-x86_64 \
            --build=missing --no-remote
    '
```

Прогоняешь **обе** конфигурации — Release и Debug — иначе deployer не найдёт обе в кеше.

### Шаг 9. Deploy и проверка структуры `.nupkg`

```bash
conan install --requires=<pkg>/<version> \
    -pr:h=profiles/lin-gcc84-x86_64 \
    -pr:b=profiles/lin-gcc84-x86_64 --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py \
    --deployer-folder=output/

./test-astra/diff_two_dirs.sh \
    <(unzip -d /tmp/ours   output/<legacy_name>.lin.gcc84.shared.x86_64.<version>.nupkg) \
    <(unzip -d /tmp/legacy /path/to/legacy/<legacy_name>.lin.gcc84.shared.x86_64.<version>.nupkg)
```

`diff_two_dirs.sh` (`3b3485a`) проверяет 12 осей: tree, md5, perms, owner, xattr, ACL, SELinux, MIME, line endings, symlinks, realpath, inode. Если расхождения **ожидаемые** (фиксы багов легаси, наш суффикс `.1`) — норма; если непонятные — итерируйся.

### Шаг 10. End-to-end на dev-VM с downstream-консюмером

Перенеси `.nupkg` на `Pushkarev/dev-astra18-13` (через ProGet test-feed или прямо в кеш downstream'а), запусти полную сборку downstream: cmake configure + build + ctest. Последний бастион — здесь ловятся проблемы вроде `cannot find -lprotolib`, видимые только через `ResolveDependencies.cmake`.

### Шаг 11. HELP.txt block

Если наткнулся на новый класс диагностики (новая ошибка, нетривиальная причина или workaround) — добавь нумерованный блок в `test-astra/HELP.txt`. На dev-VM доступ только через `git pull` — ценная диагностика в чате бесполезна (память [[feedback_runbook_to_help_txt]]). Прецеденты: `[11]` (abseil namespace mismatch), `[12]` (`5df4aa6` — reinstall stale `.1`-slots).

### Шаг 12. Memory update

Нюансы, неочевидные из кода, обнови короткой запиской в `~/.claude/projects/.../memory/`.

### Шаг 13. Commit + push в master

```bash
git checkout master
git pull --rebase
git add <pkg>/ extensions/deployers/legacy_nupkg.py \
        test-astra/run_grpc_1601_upstream.sh
git commit -m "<pkg>: add <version> recipe, legacy <legacy_name> alias"
git push origin master
```

В сообщении упомяни **что именно** меняется (alias / version pin / patch / deployer hook) — это попадёт в `STATUS.md` ссылкой на короткий хеш. Не коммить `CLAUDE.md` / `ARCHITECTURE.md` — они в `.gitignore`.

## Особый случай: пакет с уникальной структурой

Иногда легаси разбивает upstream-либу на несколько, либо склеивает много мелких в одну крупную. Два проверенных шаблона:

### Aggregation pattern

**Когда:** upstream даёт N мелких либ, легаси экспортирует M крупных (M ≪ N), downstream линкует через M-имена.

**Прецедент:** abseil. Upstream `abseil/20230802.1` — ~150 мелких `.a` (`libabsl_strings.a`, `libabsl_random_internal_pool_urbg.a`, ...). Легаси `absl/0.2.0` — 21 крупная (`libstrings.a`, `librandom.a`, ...). Решение — `_aggregate_legacy_coarse()` в `abseil/conanfile.py`, вызывается в конце `package()`:

```python
def _aggregate_legacy_coarse(self):
    """
    Обходит исходники, мапит upstream-targets в 21 top-level subdir
    абсейла, склеивает соответствующие .o в одну крупную .a через `ar rcs`.
    """
    LEGACY_COARSE = {
        "strings":  ["strings", "strings_internal", "str_format_internal", ...],
        "random":   ["random_internal_*", "random_distributions", ...],
        ...
    }
    for coarse, fines in LEGACY_COARSE.items():
        _objs = collect_object_files(self, fines)
        subprocess.check_call(["ar", "rcs", f"lib{coarse}.a"] + _objs)
```

Результат — `lib/native/<suffix>/libstrings.a` и т.д., 21 файл, структурно близко к легаси. Deployer находит coarse-папку через `LEGACY_LIBDIR_OVERRIDE = {"abseil": "legacy-coarse"}`.

### Alias pattern

**Когда:** upstream даёт либу под одним именем, легаси ожидает под другим (один-к-одному переименование).

**Прецедент:** protobuf. Upstream даёт `libprotoc.so` (исполняемый protoc + runtime). Легаси разделял: `protoc` исполняемый, `libprotolib.so` отдельная либа, downstream `profibus_dp_ui_plugin` линкуется через `-lprotolib`. Решение (`a611fc1`):

```python
LIB_FILENAME_ALIASES["protobuf"] = {"protoc": "protolib"}
```

После deploy появляется симлинк `libprotolib.so → libprotoc.so`, а в `components` секции `CMakeLists.var` эмитятся **оба** имени.

### Когда ни то, ни другое не подходит

Третий случай — ABI-несовместимое расхождение (другой inline-namespace, другие `-D` defines, другие компил-флаги). Alias/Aggregation бесполезны. Нужно либо version pin под нужный namespace (как `615cf9f` — пин `abseil/20230802.1` → `lts_20230802` под grpc/1.60.x, совпадает с legacy `absl/0.2.0`), либо patch в `patches/<version>/` с правкой ABI. Не пытайся «склеить» runtime, который ABI-несовместим — упадёт линкер с `undefined reference to absl::lts_NNNNNNNN::...` (память [[project_protobuf_absl_namespace]]). Подробный разбор — Часть 2 пункт 1.

## Когда пакет считается «готовым»

Workflow-level done-критерии. Без галочек по списку — коммит в master не идёт. **Развёрнутый чек-лист с подпунктами для каждой стадии — Часть 3, [«Контрольный чек-лист — миграция готова к merge / release»](#4-контрольный-чек-лист--миграция-готова-к-merge--release).**

1. **Recipe собирается** на `lin-gcc84-x86_64` в Release **и** Debug, без ошибок, в Docker-образе `proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0`.
2. **`.nupkg` структурно совпадает с легаси.** `diff_two_dirs.sh` (`3b3485a`) показывает расхождения **только** в ожидаемых местах (наш суффикс `.1`, фиксы багов легаси). Неожиданное расхождение — итерация.
3. **Downstream-консюмер собирается end-to-end** на dev-VM: `cmake configure` без ошибок (`ResolveDependencies.cmake` находит пакет, все компоненты резолвятся), build без ошибок (никаких `cannot find -l<name>`), `ctest` проходит (минус известные баги downstream-кода — например, `grpc_sdk` segfault `GrpcServiceTcp/.StartStop` — память [[project_grpc_sdk_typed_test_fixture_collision]]).
4. **Inline-namespace согласован** (если применимо):

   ```bash
   grep ABSL_OPTION_INLINE_NAMESPACE_NAME \
       /usr/local/include/absl/base/options.h
   # для grpc/1.60.x — должно быть "lts_20230802"
   ```

5. **Опубликован на ProGet test-feed.** Не сразу production — сначала `.1`-суффикс через `LEGACY_NUPKG_VERSION_SUFFIX=.1` на test-feed, чтобы downstream-команды проверили свои `_dependencies`-пины без риска. Окончательная стратегия (`.1` vs вытеснение легаси) — за лидом, см. `STATUS.md` пункт 2 и Часть 3 §1.1.
6. **Документация обновлена.** `STATUS.md` получил строчку с коротким хешем и описанием эффекта. `HELP.txt` — новый блок, если был нетривиальный класс ошибок. Память — обновлена.

Не сокращай этот список — каждый пункт ловит свой класс ошибок, в продакшене обходится дороже.

---

# Часть 2 — Тонкие моменты и lessons learned

Карта граблей, на которые наступали при закрытии x86_64-фазы IN-658 (24–26 мая 2026). Каждый пункт описан как: **симптом → причина → решение → как ловить заранее**. Читай ДО того, как начнёшь ARM-фазу, и ДО того, как полезешь править `legacy_nupkg.py`.

## Карта граблей x86_64-фазы

### 1. Inline-namespace abseil

**Симптом:**

```text
undefined reference to `absl::lts_20230802::log_internal::LogMessage::LogMessage(...)`
undefined reference to `absl::lts_20240116::flags_internal::FlagOps(...)`
```

(в одной линковке смешаны разные `lts_*` префиксы).

**Причина:** В `absl/base/options.h` есть макрос `ABSL_OPTION_INLINE_NAMESPACE_NAME`, который определяет inline-namespace в виде `lts_<YYYYMMDD>`. Между upstream-релизами abseil значение меняется: `20230802`, `20240116`, `20250127`, … Из-за этого C++ mangling включает дату в имя символа. Заголовки и `.a/.so`, собранные с разными датами, ABI-несовместимы — даже если оба «abseil 0.2.0».

В нашей схеме это проявляется так:

- grpc/1.60.x ожидает `lts_20230802` (потому что upstream grpc 1.60 пинит abseil 20230802 LTS);
- если на dev-VM лежит `.1`-абсейл, собранный с upstream `20240116.2`, он экспортирует символы `lts_20240116::…`;
- линкер grpc-консюмера ищет `lts_20230802::…`, ничего не находит.

**Решение:** Пин abseil под версию grpc-линии. Для grpc/1.60.x в `grpc/conanfile.py` (и в скрипте сборки) — `abseil/20230802.1`. Коммит `615cf9f`. Если потом перейдём на grpc/1.65+ — пин нужно сверить заново.

**Урок / как избежать:**

- ВСЕГДА при любом подозрении на mismatch — `grep ABSL_OPTION_INLINE_NAMESPACE_NAME <pkg>/include/absl/base/options.h` на dev-VM. Это даёт точную дату, которую видят headers.
- Если headers говорят `20230802`, а ошибка линкера — `20240116`, значит на диске лежит stale `.nupkg` от предыдущего билда (см. пункт 6).
- На разных VM может быть разный stale-state. Не доверяй «у меня собирается» — `grep` на КАЖДОЙ.

**Связано:** [[project_protobuf_absl_namespace]].

---

### 2. Component naming в CMakeLists.var

**Симптом:**

```text
/usr/bin/ld: cannot find -lzlib
```

при том, что `zlib.lin-gcc84-...nupkg` корректно установлен, файлы `libz.so*` в `lib/native/...` присутствуют, и `find_installed_package(zlib …)` отрабатывает успешно.

**Причина:** `legacy_nupkg.py` (deployer) в секцию `components` файла `CMakeLists.var` писал **upstream-basename** библиотеки (то, что после `lib` и до `.so`/`.a` — для `libz.so` это `z`), а не **legacy-имя пакета** (`zlib`).

Elara cmake-framework работает так:

1. `find_installed_package(zlib …)` → находит папку, читает `CMakeLists.var`.
2. Для каждого имени в `components` делает `find_library(NAMES <name>)` и `add_library(<name> IMPORTED)`.
3. Консюмер пишет в своём `CMakeLists.var`: `target_libraries: zlib`.
4. Framework ищет IMPORTED target `zlib` — НЕ находит (есть только `z`), деградирует до bare linker flag `-lzlib`.
5. ld: `cannot find -lzlib`. Прибил.

**Решение:** Функция `_legacy_component_names()` в deployer'е, использующая словарь `LIB_FILENAME_ALIASES` (mapping upstream basename → legacy package name): `z → zlib`, `protoc → protolib`. Коммит `03a20c0`. С её появлением `components` в CMakeLists.var корректно содержит legacy-имена.

**Урок / как избежать:**

- При добавлении новой либы в миграцию — проверь, как её называют downstream'ы в их `target_libraries`. Если basename файла отличается от ожидаемого имени — обязательно добавь в `LIB_FILENAME_ALIASES`.
- Команда быстрой проверки на dev-VM: `grep -h target_libraries: */CMakeLists.var | tr ',;' '\n' | sort -u` — выдаёт список всех имён, которые downstream'ы ждут от тебя.

**Связано:** [[project_lzlib_components_naming]].

---

### 3. Дефис в имени пакета ломает `-D<name>_..._DEFINE`

**Симптом:**

```text
<command-line>: error: expected ',' or '...' before '-' token
```

при попытке собрать downstream-проект, зависящий от `c-ares`.

**Причина:** `ResolveDependencies.cmake` (часть Elara framework) генерирует для каждого пакета строку вида `add_definitions(-D${_name}_${_component}_${_type}_DEFINE)`. Sanitize имени там НЕТ — `_name` подставляется как есть.

Для пакета c-ares это даёт: `-Dc-ares_resolver_SHARED_DEFINE`. Препроцессор GCC видит `c-ares_...` и интерпретирует дефис как минус → `expected ',' or '...' before '-'`. Bottom line: дефис в имени пакета в принципе несовместим с cmake-фреймворком в его текущем виде.

**Решение:** В deployer'е появился `LEGACY_NAME_MAP` (переименование на уровне имени `.nupkg`-файла и содержимого `CMakeLists.var`): `c-ares → cares`. Коммит `3d9ae77`. Downstream'ы линии IN-658 уже пинят `cares` (legacy convention) — никто не сломался.

**Урок / как избежать:**

- Дефисы, точки, плюсы в имени Conan-пакета — мина замедленного действия. Перед добавлением нового пакета: `echo "$name" | grep -E '[^a-zA-Z0-9_]'` → если что-то находит, сразу решай как сглаживаешь.
- Если `LEGACY_NAME_MAP` пуст для пакета — имя берётся как есть из conan-recipe.

---

### 4. Resolver asymmetry — headers vs libs

**Симптом:** Линкер падает на абсейле, при этом:

```text
$ grep absl_INCLUDE_DIRS .build/.../CMakeCache.txt
absl_INCLUDE_DIRS:STRING=/home/user/absl.lin-gcc84-shared-x86_64.0.2.0/include
$ grep absl_log_LIBRARY_RELEASE .build/.../CMakeCache.txt
absl_log_LIBRARY_RELEASE:FILEPATH=/home/user/absl.lin-gcc84-shared-x86_64.0.2.0.1/lib/native/.../libabsl_log.so
```

То есть headers — из `0.2.0` (легаси), libs — из `0.2.0.1` (наш Conan-билд). Inline-namespace headers'ов не сходится с тем, что внутри `.so`.

**Причина:** Две разные функции в Elara cmake-фреймворке резолвят headers и libs **независимо**:

- `FindInstalledPackage.cmake::find_installed_package()` ищет папку **по точному имени с версией** (`<name>.<suffix>.<version>`) и подставляет `include/` оттуда. Версия берётся из `_dependencies` потребителя.
- `find_library()` глобит `lib/native/.../<libname>.so` по wildcard и берёт ПЕРВЫЙ match — если на диске несколько `*absl*` папок, выбор недетерминированный (зависит от sort order файловой системы).

Результат: headers пинятся пином потребителя, libs — алфавитом в `/home/user/`.

**Решение (3 варианта по убыванию инвазивности):**

- **(А) Обновить пин у потребителя.** В `<consumer>/CMakeLists.var._dependencies` заменить `absl:0.2.0` → `absl:0.2.0.1`. Headers подтянутся из правильной папки. Это «production» решение — но требует пересборки потребителя.
- **(Б) Переименовать наш `.1`-слот.** Распаковать `.1.nupkg` в папку без `.1`-суффикса. Тогда `find_installed_package(absl … 0.2.0)` найдёт наши файлы. Опасно: ломает легаси-потребителей, которые ждут именно «легаси-абсейл 0.2.0».
- **(В) Удалить легаси-слот.** Если уверен, что на этой VM никто его не использует — `rm -rf absl.lin-gcc84-shared-x86_64.0.2.0` (после backup). Тогда headers вынужденно резолвятся в наш.

**Где ловить заранее:**

```bash
grep -E 'absl_INCLUDE_DIRS|absl_.*_LIBRARY_RELEASE' .build/<config>/CMakeCache.txt
```

Если пути расходятся по версии — это пункт 4.

**Урок:** Asymmetry между двумя resolver'ами — это **архитектурный изъян фреймворка**, не баг твоего deployer'а. Лечить можно только согласованием версий на стороне потребителя/диска.

**Связано:** [[project_dev_vm_package_resolution_pitfalls]].

---

### 5. Транзитивные пины legacy-пакетов

**Симптом:** В `CMakeCache.txt` потребителя:

```text
dependencies:STRING=...;absl:0.2.0;...
```

хотя сам потребитель пинит `absl:0.2.0.1`, и ты только что переустановил `.1`-абсейл.

**Причина:** `ResolveDependencies.cmake::get_package_version(_name _out)` идёт по агрегированному списку `dependencies` (своих + всех транзитивных) и берёт **последнее** вхождение `_name:<version>`. Приоритета по версии (semver-max или подобного) — нет.

Что произошло: другой установленный пакет (например, легаси `utf8_range.lin-gcc84-shared-x86_64.0.1.0`) в своём `CMakeLists.var._dependencies` пинит `absl:0.2.0`. Этот легаси `utf8_range` подтянулся транзитивно через protobuf. В порядке топологической сортировки он оказался **после** твоего grpc.1.1 пакета (который пинит `absl:0.2.0.1`). Результат: `get_package_version("absl")` вернул `0.2.0`. Headers — снова из легаси-папки. См. пункт 4.

**Решение:**

- **Workaround (быстро, на одной VM):** sed-фикс `CMakeLists.var` всех легаси-пакетов:

  ```bash
  find /home/user -maxdepth 3 -name CMakeLists.var \
    | xargs grep -lE 'absl:0\.2\.0([^.0-9]|$)' \
    | xargs sed -i 's/absl:0\.2\.0\b/absl:0.2.0.1/g'
  ```

- **Production:** пересобрать легаси-пакеты с обновлёнными пинами и опубликовать `.1.nupkg`-версии. Это правильный путь, но требует ресурса от owner'ов соответствующих пакетов.

**Команда поиска проблемных пинов:**

```bash
find /home/user -maxdepth 3 -name CMakeLists.var \
  | xargs grep -lE 'absl:0\.2\.0([^.0-9]|$)'
```

**Урок:** Любой stale-пакет на VM, который пинит чужие старые версии, может «переголосовать» твой новый пин через order-зависимость в `get_package_version`. Это специфика Elara framework'а — не баг Conan'а или твоего скрипта.

**Связано:** [[project_dev_vm_package_resolution_pitfalls]].

---

### 6. Stale `.1`-пакет от старого билда

**Симптом:** Headers и libs одинаково в `.1`-слоте (по диагностике из пункта 4 расхождений нет). И всё равно линкер требует `lts_20240116::…`, хотя «по идее» `.1`-абсейл должен экспортировать `lts_20230802::…`.

**Причина:** Установленный `.nupkg` собран ДО коммита `615cf9f`, когда скрипт сборки ещё пинил `abseil/20240116.2`. После коммита `615cf9f` в conan-recipes пин обновился на `20230802.1`, но **установленный на dev-VM .nupkg остался прежним**. `git pull` в `conan-recipes/` не переустанавливает уже распакованные пакеты в `/home/user/`.

**Решение:** Полная процедура переустановки (`HELP.txt`, блок `[12]`):

```bash
rm -rf /home/user/absl.lin-gcc84-shared-x86_64.0.2.0.1
cd /home/user
unzip /path/to/fresh/absl.lin-gcc84-shared-x86_64.0.2.0.1.nupkg \
  -d absl.lin-gcc84-shared-x86_64.0.2.0.1
```

(если `.nupkg` принёс из docker — проверь права после unzip, см. пункт 15).

**Урок / как избежать:**

- После КАЖДОГО `git pull` в `conan-recipes/` пройдись по `/home/user/*.lin-gcc84-*.1` и проверь дату модификации vs дата соответствующего билда (`build-logs/`). Если установленный пакет старше — переустанавливай.
- На dev-VM полезно иметь маленький helper-скрипт `check-stale-packages.sh`, который пробегает по всем `.1`-папкам и сравнивает с актуальными `.nupkg` в выводе билда. Положить в `test-astra/`.

**Связано:** [[project_dev_vm_package_resolution_pitfalls]].

---

### 7. CMake cache stickiness

**Симптом:** Распаковал свежий `.nupkg`, перезапустил `cmake --build .build/<config>`, и `absl_INCLUDE_DIRS` в `CMakeCache.txt` всё ещё указывает на старую папку (или на легаси).

**Причина:** `CMakeCache.txt` помнит результаты предыдущего `cmake ../..` — все `find_*` вычисления закешированы. Инкрементальный `cmake --build .` НЕ пересчитывает их. Даже `cmake ../..` повторно может не помочь, если кеш-переменные уже set'нуты.

**Решение:**

```bash
rm -rf .build/<config>
mkdir -p .build/<config>
cd .build/<config>
cmake -DCMAKE_TOOLCHAIN_FILE=... ../..
make -j$(nproc)
```

Никаких `make clean` или `cmake --fresh` — они не достаточны.

**Урок / как избежать:** При любой смене зависимостей (новый `.nupkg`, обновлённый пин в `CMakeLists.var`, sed-фикс по пункту 5) — `.build/<config>` сносить целиком. На dev-VM это 3-15 минут полной сборки потребителя — терпимо, но лучше, чем диагностировать призраки.

---

### 8. proto/ layout — well-known типы

**Симптом:**

```text
google/protobuf/timestamp.proto: File not found.
```

при `protoc` на downstream-`.proto`-файле, импортирующем well-known тип через `import "google/protobuf/timestamp.proto";`.

**Причина:** Elara framework для протобуф-кодогенерации вызывает `protoc --proto_path=<protobuf_pkg>/proto ...`. Папка `proto/` в нашем `.nupkg` (на тот момент) **была пуста или отсутствовала** — deployer туда `.proto` файлы не клал. Зато они лежали в `include/google/protobuf/timestamp.proto` — но в `--proto_path` это не передавалось.

Легаси-`.nupkg` от ручного TC-билда содержал ровно 12 well-known `.proto` файлов в `proto/google/protobuf/`. Наш Conan-билд это игнорировал.

**Решение:** В `legacy_nupkg.py` добавлено зеркалирование `*.proto` из `include/` в `proto/` с сохранением относительного пути. Коммит `6674d29`.

**Урок / как избежать:**

- При миграции пакета, где есть `.proto` файлы, СРАЗУ сверь `unzip -l legacy.nupkg | grep '\.proto$'` vs `unzip -l our.nupkg | grep '\.proto$'`. Списки должны совпадать (с поправкой на well-known list ниже).
- Не предполагай, что framework находит `.proto` рядом с headers'ами. Он ищет ровно в `proto/`.

**Связано:** [[project_legacy_nupkg_proto_layout]].

---

### 9. Лишние `.proto` в дереве (`compiler/`, `java/`)

**Симптом:** После фикса пункта 8 папка `proto/` полна, но `timestamp.proto: File not found` всё равно (или вылетают другие странные protoc-ошибки про неподдерживаемый syntax).

**Причина:** Upstream protobuf-релиз кладёт в `include/google/protobuf/` не только 12 канонических well-known, но и:

- `google/protobuf/compiler/plugin.proto` — protoc plugin API, не предназначен для downstream-импорта;
- `google/protobuf/java/java_features.proto` (и соседние) — использует edition-2023 syntax, наш protoc 4.25.2 не парсит, валится с ошибкой синтаксиса.

При `os.walk('include/google/protobuf/')` без фильтрации эти файлы попадают в `proto/` и ломают downstream.

Точная связь с симптомом из пункта 8: protoc, видимо, при scan-time валидации проходит по всем `.proto` в `--proto_path`, натыкается на `java_features.proto`, fail-fast — и **сообщение об ошибке** ассоциирует с первым импортом (`timestamp.proto`), хотя реальная проблема в другом файле. Может быть отдельная диагностика, нужно проверить точное поведение protoc 4.25.

**Решение:** В deployer'е исключение `compiler/` и `java/` из `os.walk` через идиому:

```python
_PROTO_EXCLUDE_DIRS = {"compiler", "java"}
for root, dirs, files in os.walk(src_include):
    dirs[:] = [d for d in dirs if d not in _PROTO_EXCLUDE_DIRS]
    ...
```

Коммит `457ad47`.

**Урок / как избежать:**

- Bench-стандарт: легаси-`.nupkg` для protobuf содержит ровно **12 well-known** файлов в `proto/google/protobuf/`. Список: `any.proto`, `api.proto`, `descriptor.proto`, `duration.proto`, `empty.proto`, `field_mask.proto`, `source_context.proto`, `struct.proto`, `timestamp.proto`, `type.proto`, `wrappers.proto`, `compiler/plugin.proto` (legacy ВКЛЮЧАЕТ его, мы — НЕТ; нужно сверять). Делать так же.
- Whitelist лучше blacklist'а: вместо «исключи compiler+java» можно реализовать «возьми только эти 12 имён». Менее хрупко при будущих upstream-релизах abseil/protobuf, которые могут добавить новые подкаталоги.

---

### 10. `.keepdir` маркер ломает downstream framework

**Симптом:** После фиксов пунктов 8 и 9 содержимое `proto/` идеальное (точно 12 файлов или сколько надо), но protoc всё равно ругается `timestamp.proto: File not found`.

**Причина:** В `legacy_nupkg.py` есть функция `_make_keepdirs()` — она создаёт пустой файл-маркер `.keepdir` в каждой ожидаемой папке (`bin/`, `lib/`, `proto/`, `share/`, …), чтобы ZIP-архив сохранил структуру пустых директорий (ZIP в принципе не хранит пустые dirs). Раньше она клала `.keepdir` БЕЗУСЛОВНО, даже в населённую `proto/`.

Elara framework при подготовке к protoc-у делает `file(GLOB proto_files RELATIVE … *)` — без фильтра по `*.proto`. `.keepdir` оказывался в списке как «файл для protoc'а». Дальше — два варианта:

- protoc валится на `.keepdir` (это не валидный `.proto`), и сообщение об ошибке об «отсутствующем» импорте — побочный эффект fail-fast;
- framework сам валится при попытке вычислить protoc-аргументы.

**Решение:** `_make_keepdirs()` теперь проверяет: если папка непустая — маркер не создаёт. Коммит `7bb065d`.

**Урок / как избежать:**

- Marker-файлы для ZIP-retention НУЖНЫ ТОЛЬКО в пустых директориях. В населённых — мусор, и в худшем случае — взрыв downstream.
- Когда добавляешь любой служебный файл (`.keepdir`, `.gitkeep`, `.placeholder`) в `.nupkg` — спроси себя: как на него отреагируют consumer'ские `file(GLOB)`-выражения? Если ответ непонятен — не клади.

---

### 11. `libprotolib.a` — Elara split

**Симптом:**

```text
/usr/bin/ld: cannot find -lprotolib
```

при сборке `profibus_dp_ui_plugin` (один из downstream'ов).

**Причина:** Elara-форк протобуфа разбивает upstream `libprotoc.so` на 4 отдельные цели:

- `libprotobuf.so` — core runtime;
- `libprotobuf-lite.so` — урезанный runtime;
- `protoc` — исполняемый файл компилятора;
- `libprotolib.so` — собственно код protoc-как-библиотеки (api для compiler-plugins).

Наш Conan-билд upstream-протобуфа собирает всё компиляторное вместе в `libprotoc.so`. Downstream'ы (профайбас и Co.) пинят `protolib` в их `target_libraries` — а такой `.so` у нас нет.

**Решение:** В `legacy_nupkg.py`:

1. Создаётся симлинк `libprotolib.so → libprotoc.so` в `lib/native/...`.
2. `_legacy_component_names()` для протобуф-пакета эмитит ДВА имени: `protoc` (upstream) **и** `protolib` (alias). Оба указывают на тот же физический файл через симлинк.

Коммит `a611fc1`. Downstream'ы видят оба имени, доволны оба варианта пина.

**Урок / как избежать:**

- При миграции форк-зависимой либы — сверь имена `.so` файлов в легаси-`.nupkg` vs upstream. Если в легаси есть имена, которых у тебя нет — создавай симлинки.
- Документируй такие split'ы. В файле `legacy_nupkg.py` рядом с `LIB_FILENAME_ALIASES` имеет смысл держать комментарий-таблицу: для какой Elara-либы какие имена ожидаются.

**Связано:** [[project_legacy_protolib_alias]].

---

### 12. Порядок static libraries в линковке

**Симптом:**

```text
undefined reference to `absl::lts_20230802::log_internal::CheckOpMessageBuilder::ForVar2()'
```

в `libgsd_parser.a`, при этом `liblog.a` (или `libabsl_log.a`) присутствует в командной строке линкера, и nm подтверждает что нужный символ в нём есть.

**Причина:** ld для статических архивов делает **один проход слева направо**. Когда видит `liblog.a` — на тот момент unresolved-список ПУСТ (нет ещё ничего, что ссылалось бы на absl::log). Поэтому ld берёт из `liblog.a` НИЧЕГО (`.a` подтягивается выборочно — только нужные объекты). Дальше ld видит `libgsd_parser.a` — обнаруживает новые ссылки на `absl::log_internal::…` — но `liblog.a` УЖЕ ПОЗАДИ в командной строке, и второй проход по нему ld не делает.

Результат: undefined reference.

Это классическая проблема порядка static link'а, ничего специфичного для нашего стека.

**Решение (3 варианта):**

- **(А) Переставить в `target_libraries`:** консьюмеры (`gsd_parser`) — ПЕРЕД либами абсейла. Этот порядок естественен для shared, контринтуитивен для static. Не всегда возможно (cyclic dep'ы).
- **(Б) `target_libraries_whole_archive`:** Elara framework это умеет — добавляет `-Wl,--whole-archive ... -Wl,--no-whole-archive`. Linker берёт ВСЕ объекты из `.a`, независимо от потребности. Цена: разбухание бинаря на несколько MB.
- **(В) `-Wl,--start-group ... -Wl,--end-group`:** даёт ld многопроходный режим. Цена: компиляция линкуется в 2-3 раза медленнее на больших проектах.

**Рекомендация для grpc-линии:** вариант (Б) — `target_libraries_whole_archive` с абсейл-либами. Бюджет — несколько MB на бинарь, для серверного железа приемлемо. Применять точечно (не на всё подряд) — `whole-archive` несовместим с `-Wl,--exclude-libs` и подобными.

**Урок / как избежать:**

- При static-линковке абсейла (и любых header-only-heavy либ) ОБЯЗАТЕЛЬНО разобраться с порядком ДО первого билда, не после первой undefined-ошибки.
- При первом столкновении — попробовать `--start-group` как диагностику: если ошибка уходит — это пункт 12, не пункт 1 (inline-namespace).

---

### 13. gtest TYPED_TEST + анонимный namespace (НЕ наш баг)

**Симптом:** `grpc_sdk_test` падает с:

```text
GrpcServiceTcp/.StartStop: All tests in the same test suite must use the same test fixture class
```

И segfault или abort в gtest-инфраструктуре.

**Причина:** В `tests/GRPCServiceTest.cpp` (репо `grpc_sdk`) класс `GRPCService` объявлен в **анонимном namespace**. `TYPED_TEST_CASE` объявляется с **двумя типами** (`GrpcServiceTcp`, `GrpcServiceUnix`). gtest внутри использует `TypeIdHelper<T>` (через `&TypeIdHelper<T>::dummy_`), чтобы получить уникальный typeid каждой fixture. Для типов из анонимного namespace в разных translation unit'ах — `&TypeIdHelper<…>::dummy_` имеет разные адреса (linkage = internal). gtest сравнивает адреса → видит «разные fixture'ы», ругается.

В этом баге **виноват код grpc_sdk**, не наша инфраструктура. Подтверждение:

- собирается ровно в том же Docker'е что и TC;
- gtest тот же `gtest/1.14`;
- наша Conan-сборка grpc_sdk даёт ту же ошибку, что и ручной TC-билд (если бы был);
- значит, наш стек **байт-совместим**.

**Решение (на стороне grpc_sdk):** вынести `class GRPCService` из анонимного namespace в именованный (или в global namespace). Альтернатива — переписать тест без `TYPED_TEST_CASE` или с одним типом.

**Урок / как избежать:**

- Когда падает что-то в downstream-тестах — НЕ предполагай сразу что виноват deployer/Conan. Сначала собери **тот же downstream** на чистом легаси-стеке (если есть). Если падает — баг downstream'а.
- Документировать такие «не наши баги» в отдельных memory-файлах с явной пометкой «НЕ наша часть», чтобы при ARM-фазе не тратить время повторно.

**Связано:** [[project_grpc_sdk_typed_test_fixture_collision]].

---

### 14. LD_LIBRARY_PATH transitive RUNPATH

**Симптом:** Бинарь успешно собрался и линкер ни на что не ругается, но запуск даёт:

```text
./grpc_sdk_test: error while loading shared libraries: libupb_collections_lib.so.37: cannot open shared object file: No such file or directory
```

**Причина:** ELF dynamic loader (glibc `ld-linux.so`) **НЕ пропагирует RUNPATH транзитивно**. Если:

- исполняемый бинарь зависит от `libgrpc.so`,
- `libgrpc.so` зависит от `libupb_collections_lib.so.37`,
- RUNPATH прописан только в самом бинаре (а не в `libgrpc.so`),

то loader при попытке разрешить `libupb_collections_lib.so.37` (как зависимость `libgrpc.so`) **не использует** RUNPATH бинаря. Он смотрит только в RUNPATH `libgrpc.so`. Если там пусто (или указывает на пути, недоступные с целевой VM) — мисс, отказ запуска.

Это **поведение Linux loader'а by design** (POSIX-совместимый — RPATH/RUNPATH локальны к ELF-объекту). Не связано с нашим deployer'ом.

**Решение:**

- **(А) `LD_LIBRARY_PATH` при запуске:**

  ```bash
  export LD_LIBRARY_PATH="$(find /home/user -maxdepth 4 \
    -path '*/lib/native/lin-gcc84-shared-x86_64*' -type d \
    | tr '\n' ':')${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  ```

  Самый простой и стандартный путь для тестов на dev-VM.

- **(Б) Линковать с `--allow-shlib-undefined`** — не лечит проблему, но позволяет хотя бы загрузить (с риском runtime-ошибок).
- **(В) Патчить RUNPATH во всех зависимых `.so` через `chrpath`** после установки `.nupkg` — нагляднее, но требует хука.
- **(Г) Линковать с `$ORIGIN`-relative RPATH** — самое чистое решение, но требует пересборки всех зависимых `.so` с правильным флагом.

**Урок / как избежать:**

- Эта проблема — НЕ баг deployer'а. Не пытайся фиксить её в `legacy_nupkg.py`.
- При runtime-тестах на dev-VM держи готовый bash-snippet для setup `LD_LIBRARY_PATH` в `test-astra/run-with-env.sh`.

---

### 15. Разные права/owner в `.nupkg`

**Симптом:** После `unzip` файлы в `/home/user/<pkg>...` принадлежат не текущему пользователю или имеют странные права (`-rwsr-x---`, например). Дальнейшие операции (cmake-генерация, patch файлов) валятся на permission.

**Причина:** `.nupkg` создаётся внутри Docker-контейнера, в котором процесс часто запущен от `root`. ZIP сохраняет owner/group/mode из source-файлов. `unzip` на целевой машине обычно даёт файлы текущему пользователю (если запущен под ним), но **не во всех версиях unzip** — старые могут сохранять оригинальный uid/gid.

**Решение:**

- В Dockerfile билд-образа добавить `chown -R builder:builder` (или uid:gid целевого пользователя) перед упаковкой в `.nupkg`.
- На целевой машине после распаковки:

  ```bash
  chown -R $(id -u):$(id -g) /home/user/<pkg>...
  chmod -R u+rwX,go+rX,go-w /home/user/<pkg>...
  ```

**Проверка:** `ls -la` после распаковки. Если видишь uid=0 или странный suid-bit — почисти.

**Урок / как избежать:**

- При сравнении легаси-`.nupkg` и нашего — `diff_two_dirs.sh` уже проверяет это (оси 3 — permissions, 4 — owner/group). Запускай ОБА после первого успешного билда.

**Связано:** `test-astra/diff_two_dirs.sh`.

---

### 16. Conan recipe `package_info()` vs Elara framework

**Симптом:** Conan-сборка проходит, `.nupkg` создаётся, но `CMakeLists.var` пустой по части `components` (или содержит дефолтное `<pkgname>` вместо реальных под-либ).

**Причина:** `package_info()` в `conanfile.py` декларирует Conan-`components` для CONAN-консюмеров (через CMakeDeps generator). Наш deployer (`legacy_nupkg.py`) **не читает Conan-`components`** напрямую — он сканирует `lib/native/.../*.so*` и формирует свой список. Если в conanfile НЕ сгенерированы реальные `.so` (например, упомянуты только в `cpp_info.components[].libs`, но не сбилдились) — deployer найдёт пустоту.

**Решение:**

- Сверять `conanfile.py::package_info()` со списком реально сбилженных `.so`/`.a` в `<conan_pkg>/lib/`. Они должны совпадать.
- Если упустил `.so` — проверь `build()`-стадию: возможно cmake флаги не покрывают нужный target.

**Урок:** Conan «component decl» и реальный output — два независимых пространства. Doc'а сама себя не делает.

---

### 17. `version()` в `conanfile.py` и `.nupkg`-suffix

**Симптом:** Сгенерированный `.nupkg` имеет имя `pkg.lin-gcc84-shared-x86_64.0.2.0.1.nupkg` — а ожидался `0.2.0.2` (после bump'а). Или наоборот — версия не bump'нулась.

**Причина:** В `legacy_nupkg.py` суффикс `.N` (где N — номер итерации Conan-сборки той же upstream-версии) определяется отдельно от `version` в conanfile. Источник суффикса — переменная окружения `LEGACY_NUPKG_VERSION_SUFFIX` (через `VERSION_SUFFIX = os.environ.get(...)` в deployer'е). Bump базовой версии без учёта суффикса даёт неожиданное имя.

**Решение:** При создании новой ревизии (например, чинишь баг в той же upstream-`0.2.0`):

1. инкрементируй `LEGACY_NUPKG_VERSION_SUFFIX` (например, `.1` → `.2`);
2. ничего НЕ трогай в `version` (upstream-версия не меняется);
3. собирай.

**Урок:** Documenting convention: `<upstream>.<N>` = «наша N-я ревизия upstream-`<upstream>`». Не путать с Conan-`revision` (хешем содержимого recipe).

---

### 18. Параллельные сборки и file-lock в `~/.conan2`

**Симптом:** Два параллельных `conan create` (например, в скрипте на dev-VM, когда параллельно строятся zlib и openssl) дают `OSError: [Errno 11] Resource temporarily unavailable` или порчу cache.

**Причина:** Conan 2.x использует file lock на `~/.conan2/p/<pkgid>/`. При обращении из двух процессов одновременно — один блокирует, второй ждёт ИЛИ падает (зависит от настроек таймаута).

**Решение:** Запускать `conan create` строго последовательно. В `test-astra/*.sh` НЕ ставить `&` для параллельности — только цепочки `&&`.

**Урок:** Хочешь параллелить — параллель на уровне разных Conan-cache-папок (`CONAN_HOME=/tmp/conan-a`, `CONAN_HOME=/tmp/conan-b`). Не на одной.

---

### 19. Conan profile и `tools.cmake.cmaketoolchain:user_toolchain`

**Симптом:** Сборка с `-pr=lin-gcc84-x86_64` падает рано на cmake-фазе:

```text
CMake Error: TARGET_PLATFORM is not set
```

**Причина:** Elara cmake-framework требует переменные `TARGET_PLATFORM`, `TARGET_ARCH_CPU`, `BUILD_SHARED_LIBS` (см. память [[reference_elara_cmake_framework]]). Conan по дефолту их НЕ выставляет — они должны прийти через user-toolchain, подцепленный через `tools.cmake.cmaketoolchain:user_toolchain` в profile.

**Решение:** В `profiles/lin-gcc84-x86_64` (и аналогичных) должна быть строка:

```text
[conf]
tools.cmake.cmaketoolchain:user_toolchain=["{{ os.path.join(profile_dir, '../toolchains/lin-gcc84-x86_64.cmake') }}"]
```

И сам toolchain-файл должен set'ить три переменные.

**Урок:** При создании нового профиля (новая архитектура — ARM на следующей фазе!) — toolchain-файл из x86_64 копировать и адаптировать. Иначе грабли мгновенные.

**Связано:** [[reference_elara_cmake_framework]].

---

### 20. ProGet credentials и closed-network на dev-VM

**Симптом:** `conan install` падает с 401/403 при попытке скачать рецепт.

**Причина:** dev-VM в закрытой сети, доступ только к корпоративному ProGet. `~/.conan2/remotes.json` должен иметь ProGet remote, и credentials должны быть set через `conan remote login`. После reboot VM креды могут потеряться (если хранились в keychain, которого нет).

**Решение:** В `test-astra/setup-conan-remote.sh` явно регистрировать remote и логинить:

```bash
conan remote add proget https://proget.local/conan-recipes
conan remote login proget <user> -p <token>
```

Хранить токен в `/home/user/.proget-token` с `chmod 600`.

**Урок:** Closed-network подразумевает повторяющийся ритуал setup'а после reboot. Документировать в `HELP.txt` блок `[00] First boot`.

---

### 21. `package_id_mode` и почему `.nupkg` стабилен

**Заметка (не баг, но важное понимание):** Conan 2.x вычисляет `package_id` (хеш) на основе recipe + settings + options + зависимостей. По дефолту изменение patch-версии зависимости даёт другой `package_id`. Наш deployer ИГНОРИРУЕТ Conan `package_id` — он формирует имя `.nupkg` по схеме `<name>.<profile-suffix>.<version><LEGACY_NUPKG_VERSION_SUFFIX>` (см. пункт 17). Это значит:

- два разных Conan `package_id` (например, собранные с разными микро-флагами) могут дать **одинаковое имя `.nupkg`**, и второй перезапишет первый;
- НИКОГДА не доверяй имени `.nupkg` для определения уникальности билда. Сверяй содержимое через `diff_two_dirs.sh`.

**Урок:** При публикации `.nupkg` в TeamCity-зеркало (ProGet) — overwrite-policy должна быть осознанной. Если включён «no overwrite» — старый билд с тем же именем будет тихо игнорироваться, и downstream получит вчерашнюю версию.

---

## Краткий чек-лист отладки «что-то не линкуется»

Когда падает downstream и непонятно почему — пройди по списку, **в этом порядке**:

1. `grep ABSL_OPTION_INLINE_NAMESPACE_NAME .../include/absl/base/options.h` — пункт 1.
2. `grep -E 'absl_INCLUDE_DIRS|absl_.*_LIBRARY_RELEASE' .build/.../CMakeCache.txt` — пункт 4.
3. `grep -E 'absl:0\.2\.0([^.0-9]|$)' /home/user/*/CMakeLists.var` — пункт 5.
4. `ls -la /home/user/absl.lin-gcc84-shared-x86_64.0.2.0.1/` — дата vs последний `git pull` — пункт 6.
5. `rm -rf .build/<config>` и повторить — пункт 7.
6. `unzip -l <pkg>.nupkg | grep '\.proto$'` — пункт 8 и 9.
7. `unzip -l <pkg>.nupkg | grep -E '\.(so|a)(\.[0-9]+)*$'` — пункт 11 (есть ли protolib?).
8. Если undefined references при static — пункт 12, попробуй `--start-group`.
9. Runtime-падение — `ldd <binary>` и `LD_LIBRARY_PATH` — пункт 14.

Если все 9 пунктов пройдены и проблема осталась — это **новый** грабли, документируй в memory и в этот плейбук как пункт 22+.

### Связанные memory-файлы (карта Части 2)

- [[project_protobuf_absl_namespace]] — пункт 1
- [[project_lzlib_components_naming]] — пункт 2
- [[project_dev_vm_package_resolution_pitfalls]] — пункты 4, 5, 6
- [[project_legacy_nupkg_proto_layout]] — пункт 8
- [[project_legacy_protolib_alias]] — пункт 11
- [[project_grpc_sdk_typed_test_fixture_collision]] — пункт 13
- [[reference_elara_cmake_framework]] — пункт 19
- [[project_in658_grpc_dockerised]] — общий контекст IN-658
- [[project_grpc_sdk_integration_validated]] — финальный статус интеграции

---

# Часть 3 — Что можно улучшить, антипаттерны и координация

> Аудитория — разработчик который придёт за x86_64-фазой (ARM, Windows, грядущий bump grpc-линии до 1.62+) и команда координации (лид, devops, downstream-team-lead'ы).
>
> Это не пересказ `STATUS.md` / `CONFLUENCE.md` / `DOWNSTREAM-MIGRATION.md` — это **аналитический слой над ними**: что сейчас держится «на честном слове», куда расти, и какие лужи не повторять.
>
> Стиль: размышление. Где есть готовые рецепты — даю их; где решение организационное — называю явно.

## 1. Возможные улучшения

Каждая идея ниже — отдельный backlog-item. Для каждой даю ЧТО, ЗАЧЕМ, КАК. Сложность субъективная по шкале L/M/H.

### 1.1. Eliminate `.1`-суффикса в production [L organisational, H technical если вариант А]

**Что.** Сейчас на ProGet coexistence: легаси-`absl.lin.gcc84.shared.x86_64.0.2.0.nupkg` и наш `*.0.2.0.1.nupkg` лежат параллельно. Стратегия coexistence была выбрана осознанно для безопасного отката, но это **временный режим**, не конечная точка.

**Зачем убрать.** Потребители, у которых `_dependencies` пинит bare-версию `absl:0.2.0`, продолжают резолвить **легаси**. Наш пакет видит только тот downstream, кто проактивно обновил пин. Это значит: пока легаси на ProGet — ABI-консистентности по всей экосистеме нет, и каждый продукт выбирает между нашими и легаси-пакетами **индивидуально**. Долго так жить нельзя — рано или поздно кто-то соберёт `el_conf` с нашими `absl/0.2.0.1` и подмешает легаси-`grpc/1.60.1`, получит inline-namespace mismatch на ровном месте.

**Как.** Стратегия А, Б или В из `DOWNSTREAM-MIGRATION.md` (выбор за лидом). Технические шаги для каждой стратегии расписаны там же — здесь не дублирую.

**Кто.** Лид + devops (ProGet retention/replace). Связано: память [[feedback_tc_layout_needs_lead]].

---

### 1.2. Автоматизированный ABI-validation в CI [M]

**Что.** Сейчас inline-namespace проверяется руками: `grep ABSL_OPTION_INLINE_NAMESPACE_NAME` в `absl/base/options.h` и `nm -C libprotobuf.so | grep absl::lts_`. Делается на dev-VM по диагностической команде из `HELP.txt` блока `[11]`. Если разработчик забыл прогнать — узнаёт о mismatch'е на стадии линковки downstream-продукта, через 30+ минут после билда.

**Зачем.** Inline-namespace mismatch — это **самый частый и самый дорогой** регресс в этой цепочке (см. Часть 2 пункт 1 и память [[project_protobuf_absl_namespace]]). Перевод проверки в CI ловит проблему на минуте 0, а не на минуте 30.

**Как.** Новый bash-скрипт `test-astra/verify_abi_consistency.sh`, ~30 строк:

1. Извлечь `ABSL_OPTION_INLINE_NAMESPACE_NAME` из `absl/base/options.h` (из распакованного abseil `.nupkg`) — это **ожидаемый** namespace.
2. Для каждого `.nupkg` в свежем билде распаковать все `.so` и через `nm -C --defined-only | grep -oE 'absl::lts_[0-9]+'` собрать **реальные** namespaces.
3. Сверить — реальное должно быть подмножеством ожидаемого. Если нет — exit 1 с понятным сообщением.

**Куда положить.** Сам скрипт — `test-astra/verify_abi_consistency.sh`. Hook вызова — в конце `run_grpc_1601_upstream.sh` после упаковки `.nupkg`. Параллельный блок в `HELP.txt` для ручного запуска на dev-VM.

**Windows-зеркало** обязательно (контракт «two platforms in lockstep»): `test-windows/verify_abi_consistency.bat` через `dumpbin /symbols` вместо `nm`.

---

### 1.3. Semver-aware `_dependencies` resolution в Elara framework [H, outside conan-recipes]

**Что.** `ResolveDependencies.cmake::get_package_version()` берёт **последний** match по имени пакета из коллекции `_dependencies` транзитивного замыкания. Без приоритета по версии, без обнаружения конфликта.

**Минус — конкретный.** Когда легаси-пакет `utf8_range/0.1.0` пинит `absl:0.2.0`, а наш `protobuf/4.25.2.1` пинит `absl:0.2.0.1`, framework берёт ту версию, что встретилась последней в обходе. Это породило необходимость в `sed`-хаках на dev-VM (см. `STATUS.md` пункт 2 и Часть 2 пункт 5) — пользователь руками правил пины в установленных легаси-пакетах, чтобы они тоже указывали на `.1`.

**Идеал.** Framework должен:

1. Собирать **все** пины по пакету из транзитивного замыкания.
2. Если все совпадают — взять их.
3. Если различаются — либо prefer-highest-semver, либо явная diagnostic-ошибка `dependency conflict: absl 0.2.0 (from utf8_range) vs 0.2.0.1 (from protobuf)`.

**Препятствия.** Framework живёт в downstream-репах, изменения трогают всех потребителей. Семантика prefer-highest может ломать кейс «явный pin на старую версию ради совместимости». Поэтому, скорее всего, путь — **diagnostic-only** в первой итерации, без автоматического выбора.

**Кто.** Architect/lead + команды продуктов. Conan-recipes здесь не главный — мы только пострадавшая сторона.

---

### 1.4. Cross-platform parity — Windows MSVC + ARM end-to-end [M-H]

**Что.** Сейчас:

- x86_64 Linux: закрыт, всё работает.
- ARM cross (`armv7hf`, `arm64`): инфраструктура готова (`test_arm_cross.sh`, multi-stage `Dockerfile.grpc-tc-mirror`, linaro toolchains), **прогона не было**.
- Windows MSVC: `test-windows/` имеет каркас и `.bat`-зеркала, рецепты содержат `is_msvc()` ветки, но **end-to-end сборка не валидирована**.

**Зачем.** Каждая платформа закрытая в одиночку — это нестабильная позиция. Платформа, которую месяц не собирали, накапливает skew (новые upstream-патчи в recipe, изменения в deployer, новые версии зависимостей). Раз в квартал ловишь регресс на платформе, которой никто не пользовался.

**Идея конкретная — CI smoke matrix.** Один `.proto` файл (тривиальный, типа `message Hello { string name = 1; }`), компилируется через `protoc` из свежего `.nupkg` на всех трёх платформах. Сравнить `.pb.cc/.pb.h` через diff на смысловую часть (не байт-в-байт, у `protoc` разных платформ могут быть line endings / `#line` директивы).

**Куда положить.** Новый job в TeamCity, runs after `run_grpc_1601_upstream.sh` (и его ARM/Windows эквивалентов). Скрипт `test-astra/smoke_proto_cross_platform.sh`.

---

### 1.5. Downstream-test в CI conan-recipes [M, есть препятствия]

**Что.** Сейчас downstream-валидация (`grpc_sdk`, `el_conf`) делается **руками** на dev-VM после публикации `.nupkg`. Цикл: собрал → опубликовал → пошёл на dev-VM → запустил → 25 минут ждёшь → видишь регресс → возвращаешься в conan-recipes.

**Идея.** После успешного `run_grpc_1601_upstream.sh` в CI **автоматически** клонировать `grpc_sdk` и `el_conf` (по фиксированным known-good commit'ам), `cmake configure && cmake --build`, ctest. Сравнить с baseline'ом — все ли тесты что проходили вчера проходят и сегодня.

**Препятствия.**

1. **Время сборки.** Полный grpc-tree билдится ~45 мин в Docker. Добавить `grpc_sdk` (~15 мин) и `el_conf` (~30 мин с 30+ компонентами) → CI-job вырастает до 90 мин. Нужен либо параллельный pipeline, либо downstream-стадия на отдельном агенте.
2. **Доступ к downstream-репам.** TeamCity-агент должен уметь клонировать `grpc_sdk` и `el_conf`. Это организационно (SSH-ключи, credentials).
3. **Pinning.** Downstream-репы обновляются независимо. Нужно решить — пинить commit (стабильно, но устаревает), или брать master (свежо, но downstream-баги ломают наш CI).

**Компромисс.** Запускать downstream-validation **ночью** (nightly job), не на каждый push. Регресс ловится с задержкой 1 день, но не блокирует обычный workflow.

---

### 1.6. Диагностические утилиты — расширение [L каждая по отдельности]

Сейчас в `test-astra/` есть `diff_two_dirs.sh` (12 осей сравнения двух деревьев). Это один очень мощный инструмент. Стоит добавить ещё несколько узкоспециализированных.

#### 1.6.1. `nm_symbol_diff.sh`

Сравнение экспортируемых символов двух `.so`/`.a`:

- `nm -C --defined-only` по обоим, отсортированные, через `diff -u`.
- Удобен для проверки «не сломал ли я ABI после bump'а версии recipe».
- Связано с 1.2, но шире — не только absl namespace, а вообще любые символы.

#### 1.6.2. `link_line_analyzer.py`

Парсинг `link.txt` (генерируется cmake в `CMakeFiles/<target>.dir/link.txt`):

- Обнаружение order-issues (либа `A` упомянута раньше своей зависимости `B` — потенциальный undefined ref на single-pass линкере).
- Дубликаты `-lX` (часто следствие транзитивных пинов через несколько путей).
- Missing `-l` для known-used symbols (если знаем мапу `symbol → library`).
- Output — human-readable отчёт + exit-code для CI.

#### 1.6.3. `nupkg_schema_validator.sh`

Проверяет что внутри свежего `.nupkg`:

- Есть `lib/native/<expected-suffix>/` и в ней хотя бы один `.so`/`.a`.
- Есть `include/` (если пакет header-only — это допустимо).
- Есть `proto/` (если пакет — `protobuf` или потребитель его well-known типов).
- Есть `CMakeLists.var` + `.nuspec`, последний с правильным `<id>`.
- `.nuspec` `<id>` совпадает с легаси-именем (через `LEGACY_NAME_MAP`).
- `CMakeLists.var` содержит `components` со списком либ.

Запускать на каждый `.nupkg` сразу после deployer'а. Поймает регресс типа `7bb065d` (лишний `.keepdir`) до выхода артефакта на ProGet.

#### 1.6.4. `dev_vm_health_check.sh`

Проверка состояния dev-VM:

- Какие пакеты установлены в `/home/user/*.lin.gcc84.*` (список + версии).
- Какие из них имеют `.1`-суффикс, какие — bare.
- Сверка inline-namespace всех absl-пакетов с эталонным значением.
- Обнаружение transitive-pin-shadowing (пакет A пинит `absl:0.2.0`, пакет B пинит `absl:0.2.0.1` — конфликт).
- Stale-detection (пакет распакован > N дней назад, новее на ProGet).

Это эквивалент «`doctor`-команды» из других проектов. Запускается перед каждой сборкой downstream — на 30 секунд экономит часы дебага.

---

### 1.7. Source archive — internal mirror автоматически [M]

**Что.** Сейчас `<pkg>/src/<archive>.tar.gz` лежит **в репе** (в git, через LFS или просто как blob — зависит от конфигурации). Это работает, но:

- Раздувает репо (`protobuf-4.25.2.tar.gz` ~10 MB, на 7 пакетов — 50+ MB просто за `src/`).
- При bump'е версии нужно вручную скачать новый архив, проверить sha256, закоммитить.

**Идея.** Внутренний mirror server (`mirror.elara.local` или подобный, может быть тот же ProGet, но с `npm` / `tarball` репой). В `conandata.yml` урл остаётся upstream-канонический (по контракту canonical-first), но рядом — `<conan-config>` с `core.sources:download_urls` или Conan source-replacer hook, который **переписывает** урл на internal mirror в момент скачивания, если closed-network.

**Как.** Conan 2.x поддерживает `core.sources:download_urls` — глобальная конфигурация которая пробует список URL'ов по порядку. Можно прописать `[mirror.elara.local/<basename>, <upstream-url>]`. Сначала идёт mirror, fallback на upstream (для dev-машин с internet).

**Препятствия.**

- Нужна инфра — mirror server и retention policy.
- Девопсы должны вручную туда залить архивы по факту bump'а версии (или сделать sync-скрипт с upstream).
- Преимущество над «лежит в git» — небольшое; решающий аргумент только если git-репо становится сильно тяжёлым.

---

### 1.8. Документация — синхронизация с кодом [L]

**Что.** `docs/IN-658/` — статика на момент закрытия x86_64-фазы. Через 3 месяца `STATUS.md` устаревает: коммит-хеши перестают соответствовать актуальному master, ссылки на файлы ломаются (если файл переименован), `DOWNSTREAM-MIGRATION.md` пинит конкретные `.1`-версии которые могут уже не существовать.

**Идея — markdown-линтер в CI.**

1. Проверка broken cross-refs (`[...](other.md)` где `other.md` удалён).
2. Проверка что commit-хеши в `STATUS.md` (`03a20c0`, `3d9ae77`, ...) реально существуют в `git log master`.
3. Проверка что упомянутые версии (`grpc/1.60.1`, `abseil/20230802.1`) совпадают с тем что в `<pkg>/conandata.yml`.

**Инструменты.** `markdown-link-check`, `lychee`, или самописный bash с `git rev-parse --verify` + `grep` по `conandata.yml`. Запускать на каждый PR трогающий `docs/`.

**Куда положить.** Новый GitHub Action / TeamCity hook в pre-merge.

---

## 2. Антипаттерны — что НЕ делать

Каждый антипаттерн ниже сформулирован как **запрет**, чтобы было читаемо. Под запретом — короткое объяснение почему и что делать вместо.

### 2.1. НЕ полагаться на `md5sum` для идентичности файлов

**Почему.** md5 совпадает только для **содержимого**. Не ловит:

- Permissions (`0644` vs `0755`).
- Owner / group (`root:root` vs `user:user`).
- Extended attributes (`xattr`, например `com.apple.quarantine` или SELinux-context).
- POSIX ACL (`getfacl`).
- Line endings (`\n` vs `\r\n` — внутри текстовых файлов md5 разный, но если ты этого не ожидаешь, можешь не понять причину).
- Symlinks vs realfiles (`md5sum` follow'ит symlink по умолчанию, разница теряется).
- Inode-level различия (когда важно — например, при hardlinking).

**Что делать.** Использовать `test-astra/diff_two_dirs.sh` (12 осей, появился в коммите `3b3485a`). Если нужна программная проверка — `tar -cf - <dir> | sha256sum` с правильными `--owner=0 --group=0 --mtime=...` для воспроизводимости.

---

### 2.2. НЕ оставлять диагностические команды в чате

**Почему.** Цикл «правка в conan-recipes → push → pull на dev-VM → тест» — 10-25 минут. Каждое забытое решение, которое осталось висеть в истории чата вместо `HELP.txt`, — это потенциальное повторение цикла когда коллега (или ты сам через месяц) столкнётся с похожей проблемой.

**Что делать.** Сразу в `test-astra/HELP.txt` как пронумерованный блок (`[13]`, `[14]`, ...). Push в master. На dev-VM `git pull` → `less test-astra/HELP.txt` → команда доступна.

**Связано:** память [[feedback_runbook_to_help_txt]].

---

### 2.3. НЕ верить «работает на dev-VM» без чистой сборки

**Почему.** На dev-VM может быть stale конфигурация — из прошлых `sed`-хаков (см. `STATUS.md` пункт 2), из CMakeCache'а старого билда, из распакованного `.nupkg` который старее текущего на ProGet. «Работает» на этом окружении не означает «работает в принципе».

**Что делать.** После изменений deployer'а или recipe:

```bash
rm -rf .build/
rm -rf /home/user/<pkg>.lin.gcc84.*   # стереть распакованные пакеты
# заново скачать .nupkg из output/ или ProGet
# unzip в /home/user/...
mkdir -p .build && cd .build && cmake ../..
cmake --build . -- -j$(nproc)
```

**Связано:** память [[feedback_verify_locally_first]].

---

### 2.4. НЕ применять `sed`-хаки на легаси-`/home/user/*.lin.gcc84.*` как production-решение

**Почему.** Правки руками (например, `sed -i 's/absl:0.2.0/absl:0.2.0.1/' /home/user/utf8_range.lin.gcc84.*/CMakeLists.var`) **не уходят в git**, не пропагируются на другие машины, теряются при переустановке пакета.

**Что делать.**

- `sed`-хаки полезны как **bisection** — быстро проверить «если бы пакет X имел версию Y, починилось бы?». Это диагностическая стадия.
- Фикс **должен быть** в одном из:
  - `extensions/deployers/legacy_nupkg.py` (если правка автогенерируема из метаданных пакета).
  - `<pkg>/conanfile.py` (если правка специфична для рецепта).
  - `<pkg>/patches/<version>/*.patch` (если правка — патч upstream-исходников).
- Коммит в master. Перебилд `.nupkg`. Публикация. Перепроверка на чистой dev-VM.

---

### 2.5. НЕ бамп abseil версию без проверки inline-namespace

**Почему.** `ABSL_OPTION_INLINE_NAMESPACE_NAME` меняется между версиями abseil (`lts_20230802`, `lts_20240116`, `lts_20250127`, ...). **Любая** перемешка библиотек с разными namespace'ами в один линк → `undefined reference to absl::lts_NNNN::...`. Это **самый коварный** регресс — компилируется, не компилируется только на линковке, и сообщение об ошибке не указывает на причину явно. Подробный разбор — Часть 2 пункт 1.

**Что делать ДО bump'а.**

1. `grep ABSL_OPTION_INLINE_NAMESPACE_NAME` в headers новой версии abseil.
2. Сверить с тем что ожидают protobuf / grpc / downstream того же tree.
3. Обновить `EXPORTS[abseil]=<новая>` в `run_grpc_1601_upstream.sh` (или его наследниках для других линий).
4. Пересобрать **весь tree** (не только abseil — protobuf и grpc должны прокинуть новый namespace в свои `.so`).
5. После сборки — прогнать ABI-validation (см. 1.2) и `nm_symbol_diff.sh` (см. 1.6.1).

**Связано:** память [[project_protobuf_absl_namespace]].

---

### 2.6. НЕ модифицировать `conandata.yml` source URLs/sha256

**Почему.** Это нарушение **canonical-first principle** (см. `CLAUDE.md` hard contract #3). `conandata.yml` мирорит `conan-center-index` ровно — это позволяет в любой момент свериться с upstream, бампать версию через простой `git pull` upstream'а, и не «зарастать» Elara-специфичными деталями в общем файле.

**Что делать.**

- Локальные правки исходников — только через `<pkg>/patches/<version>/*.patch`, зарегистрированный в `conandata.yml` секции `patches`.
- Bump версии — обновить sha256 **совпадая с upstream releases** (скачать архив, проверить sha256, обновить и `sha256`, и сам archive в `<pkg>/src/`).
- Offline-mirror — отдельный механизм (`_offline_source_archive`, см. `CLAUDE.md`), он не трогает `conandata.yml`.

---

### 2.7. НЕ скриптовать через `transfer-to-dev-vm/`

**Почему.** Скрипты в `transfer-to-dev-vm/` — это **одноразовый канал** для случаев когда git недоступен. Регулярные диагностические скрипты, runbook'и, helper'ы — это **многократный** контекст, который должен жить в git.

**Что делать.** Диагностические скрипты — в `test-astra/`. Push в master. На dev-VM `git pull`. Все знают где искать.

**Связано:** память [[feedback_scripts_via_git_not_transfer]].

---

### 2.8. НЕ забывать обновлять `test-windows/` параллельно с `test-astra/`

**Почему.** Hard contract «two platforms in lockstep» (см. `CLAUDE.md` #4). Если в `test-astra/` появился `verify_abi_consistency.sh`, а в `test-windows/` не появился `verify_abi_consistency.bat` — Windows-фаза, когда до неё дойдут руки, провалится на отсутствии инструмента, который для Linux давно решённая задача.

**Что делать.** Каждый PR трогающий `test-astra/*.sh` — должен либо содержать соответствующий `test-windows/*.bat`, либо иметь явный TODO + tracker-issue.

---

### 2.9. НЕ удалять файлы из staging deployer'а слепо

**Почему.** Конкретный пример — `.keepdir` маркер. В коммите до `7bb065d` deployer добавлял `.keepdir` файлики в пустые директории чтобы Python `zipfile` сохранил пустую папку в `.nupkg` (zipfile-формат не хранит пустые директории по умолчанию). Когда downstream-framework начал перечислять файлы в `proto/`, он принял `.keepdir` за `.proto`-файл и упал.

«Очевидное» решение — удалить `.keepdir`. Но это сломает другие места, где пустая папка реально нужна (например, `lib/native/<suffix>/` для header-only пакета).

**Что делать.** **Условный** фикс — удалить `.keepdir` только если папка непустая после заполнения остальным содержимым. Так сделано в `7bb065d`: `_make_keepdirs()` пропускает непустые папки.

Перед удалением любого файла из staging deployer'а — задать вопрос **«почему он сюда попал»**. Если ответ «не знаю», ответ найти, потом удалить (или не удалить).

---

### 2.10. НЕ ассертить linker-order через переупорядочивание `target_libraries`

**Почему.** Переставление либ в `target_libraries` (`A B C` → `C A B`) ради того чтобы single-pass linker нашёл символы — **хрупко**:

- Любой downstream-разработчик может «откатить порядок к алфавитному» из чистоплотности.
- Транзитивная сборка `target_libraries` через framework может перемешать порядок непредсказуемо.
- Документировать «не трогай порядок здесь, иначе сломается» — никто не прочтёт.

**Что делать.** Использовать явные linker-механизмы:

- `target_libraries_whole_archive` (Elara framework wrapper над `-Wl,--whole-archive ... -Wl,--no-whole-archive`) — гарантирует включение всех символов либы независимо от порядка.
- `--start-group ... --end-group` (если нужен multi-pass линкер на узком scope, без затраты на whole-archive).

Связано: `DOWNSTREAM-MIGRATION.md` секция «Build падает на цепочке абсейл-символов», Часть 2 пункт 12.

---

## 3. Координация и решения

Технические правки делает разработчик conan-recipes сам, после code review. Но **многие** решения по миграции — организационные, не технические. Эта секция — карта «кто за что отвечает».

### 3.1. Кто решает что — карта

| Решение | Кто | Как зафиксировать |
|---|---|---|
| Технические правки в conan-recipes (deployer, recipe, patches) | Разработчик conan-recipes | PR + review + commit в master |
| Структурные решения о слотах на ProGet (`.1`-суффикс vs замена легаси) | Лид | Решение в `STATUS.md` + уведомление команд |
| Замена или удаление легаси-пакетов на ProGet (retention) | Лид + devops | TeamCity / ProGet config |
| TeamCity layout (заменить GR121/GR122 vs параллельные конфиги) | Лид + TC-админ | TC config + `DEVOPS-RUNBOOK.md` update |
| Обновление downstream `_dependencies` пинов | Команды продуктов (`el_conf`, `grpc_sdk`, `sura`) | PR в их репах, по гайду `DOWNSTREAM-MIGRATION.md` |
| Версии abseil/protobuf/grpc для следующей grpc-линии (1.62+) | Architect/lead + согласование с downstream | RFC-документ + решение командой архитекторов |
| Bisection-решения по конкретному багу (sed-хаки, patches) | Разработчик conan-recipes | См. антипаттерн 2.4 — фикс уходит в git, не остаётся на dev-VM |
| Фикс багов в downstream-коде (например, `grpc_sdk` fixture-collision) | Команда downstream-продукта | Их PR в их репе |

### 3.2. Когда обращаться к лиду

Стоп-сигналы — без лида не делать:

- Любой шаг, меняющий **имена** или **версии** слотов на ProGet (включая bump `.1` → `.2`, переключение с `.1`-суффикса на bare, замена легаси-имени).
- Замена или удаление легаси-пакетов на ProGet (даже когда они нам кажутся «мёртвыми»).
- TeamCity-конфигурация / pipeline (новые build configurations, изменение триггеров, retention policy).
- Кросс-командные изменения (синхронное обновление `_dependencies` в нескольких downstream-репах).
- Bump-стратегия grpc-линии (1.60.x → 1.62+ → 1.78.x).

**Связано:** память [[feedback_tc_layout_needs_lead]].

### 3.3. Когда обращаться к команде продукта (downstream)

- Обновление их `_dependencies` пинов под наш `.1`-суффикс (если выбран вариант В из `DOWNSTREAM-MIGRATION.md`).
- Тест-фейлы в их коде, проявившиеся при использовании наших пакетов (как `grpc_sdk` gtest fixture-collision — это их код, не наш).
- Performance / size regression в их бинарях после переключения на наш пакет (нужен их репорт + reproduce).
- Запрос на новую опцию сборки (например, `protobuf` с `-DPROTOBUF_USE_DLLS` для Windows) — нужно понять кто потребитель, нужно ли реально.

### 3.4. Документирование решений

Иерархия фиксации решений:

1. **`docs/IN-658/STATUS.md`** — текущее состояние, коммит-таблица, открытые вопросы. Обновляется при каждом значимом шаге. **Главный source of truth** для статуса.
2. **`docs/IN-658/DEVOPS-RUNBOOK.md`** — операционные команды. Обновляется когда появляется новая команда или меняется существующая.
3. **`docs/IN-658/DOWNSTREAM-MIGRATION.md`** — для команд продуктов. Обновляется когда меняется контракт `.1`-суффикса или появляется новый известный issue в downstream.
4. **`test-astra/HELP.txt`** — диагностические команды, нумерованные блоки. Обновляется на каждое новое известное «как это диагностировать».
5. **Memory files** (`~/.claude/projects/.../memory/`) — для последующих сессий Claude. Любой нюанс, который повторится — туда.
6. **Commit messages** — каждый коммит подробно объясняет ЧТО и ЗАЧЕМ. См. style существующих коммитов IN-658 (`03a20c0`, `615cf9f`, и т.д. — header + 5-15 строк объяснения).

**Не путать:** `STATUS.md` — для коллег и лида. Memory files — для Claude. Commit messages — для git-археологов через год. Каждый канал нужен.

---

## 4. Контрольный чек-лист — миграция готова к merge / release

Применять для **каждого** пакета (или группы пакетов одной линии) **перед** пушем в master и публикацией `.nupkg` на ProGet. Workflow-level краткий список — Часть 1, [«Когда пакет считается готовым»](#когда-пакет-считается-готовым).

### Сборка

- [ ] Recipe собирается без ошибок в **обоих** конфигурациях: `Release` и `Debug`.
- [ ] Сборка работает на профиле `lin-gcc84-x86_64` (host == build).
- [ ] (Для ARM-фазы) Сборка работает на `lin-gcc75-arm-linaro` и `lin-gcc75-arm64-linaro` (host arm, build x86_64).
- [ ] (Для Windows-фазы) Сборка работает на `win-msvc-x64`.

### Артефакт

- [ ] `.nupkg`-файл создаётся в `output-grpc-1601-upstream/` (или соответствующий output-dir).
- [ ] Имя `.nupkg` соответствует легаси-схеме: `<legacy_name>.<os>.<compiler_short>.<linkage>.<arch_short>.<version>[.1].nupkg`.
- [ ] Внутри `.nupkg` есть: `lib/native/<suffix>/`, `include/`, `proto/` (если применимо), `CMakeLists.var`, `.nuspec`, `LICENSE.txt`.
- [ ] `CMakeLists.var.components` корректно перечисляет либы (legacy-имена, не upstream — см. коммит `03a20c0`).
- [ ] `.nuspec` `<id>` = legacy-имя (через `LEGACY_NAME_MAP`).

### ABI

- [ ] Inline-namespace abseil/protobuf соответствует ожидаемому для grpc-линии (`lts_20230802` для grpc 1.60.x).
- [ ] `nm -C libprotobuf.so | grep absl::lts_` показывает только ожидаемый namespace, без миксов.
- [ ] (Когда 1.2 имплементирована) `test-astra/verify_abi_consistency.sh` проходит.

### Сравнение с легаси

- [ ] `diff_two_dirs.sh` сравнение нашего `.nupkg` (распакованного) с легаси `.nupkg` (распакованным) — разница только в **ожидаемых** местах (например, новые символы из upstream-патчей, обновлённые SHA в `.nuspec`).
- [ ] Неожиданных потерь файлов нет (ничего из легаси не пропало, кроме того что осознанно удалили — см. `457ad47` про `compiler/plugin.proto`).

### Downstream-валидация

- [ ] End-to-end сборка downstream на dev-VM проходит (минимум — `grpc_sdk` cmake configure + build).
- [ ] (Желательно) `el_conf` cmake configure + build.
- [ ] Тесты downstream запускаются (если падают — отдельно проверить, наш ли это регресс или известный их баг).

### Документация и runbook

- [ ] `docs/IN-658/STATUS.md` обновлён: коммит-таблица содержит новый коммит с описанием эффекта.
- [ ] `docs/IN-658/DEVOPS-RUNBOOK.md` обновлён (если изменилась команда сборки или появилась новая).
- [ ] `docs/IN-658/DOWNSTREAM-MIGRATION.md` обновлён (если изменилось что-то касающееся потребителей).
- [ ] `test-astra/HELP.txt` — диагностический блок добавлен (если был новый класс проблем при сборке).
- [ ] Memory file написан (если нюанс многоразовый — см. примеры в memory index).
- [ ] Зеркало в `test-windows/` (если правка задела `test-astra/`).

### Sanity

- [ ] Python syntax check для `extensions/deployers/legacy_nupkg.py` (`python3 -m py_compile`).
- [ ] Bash syntax check для новых скриптов (`bash -n <script>`).
- [ ] Никаких локальных `*.bak`, `output-*/`, `.build/` в коммите.
- [ ] `CLAUDE.md` и `ARCHITECTURE.md` **не** в `git add` (они в `.gitignore`, должны там и остаться).

### Релиз

- [ ] Push в master.
- [ ] Уведомление команд downstream (если меняется что-то их касающееся — см. 3.3).
- [ ] (Если применимо) Публикация на ProGet через TC.

---

## 5. Дальнейшие шаги (handover)

Краткая perspective — что осталось после x86_64-фазы. Подробности — в `STATUS.md` секция «Что НЕ закрыто».

### Технические задачи

- **ARM x86 cross прогон.** Инфра готова (см. `STATUS.md` пункт 3 + `test-astra/TESTING_ARM.md`). Нужно: `./test-astra/test_arm_cross.sh build arm` и `build arm64`, проверка артефактов, добавление в TeamCity. Объём — 1-2 рабочих дня, если без сюрпризов.
- **Windows MSVC end-to-end.** `test-windows/` имеет каркас, рецепты содержат `is_msvc()` ветки, но реального прогона не было. Объём — 2-5 дней + 1 день на координацию с Windows-агентом TeamCity.
- **Bump до следующей grpc-линии (1.62+ или 1.78+).** Связан с пересмотром abseil-версии и inline-namespace. Требует RFC у архитекторов (см. 3.1). Объём — недели, не дни; делать после стабилизации текущей x86_64+ARM+Windows линии.

### Организационные задачи

- **Production rollout `.1`-стратегии.** Выбор вариантов А/Б/В из `DOWNSTREAM-MIGRATION.md` — за лидом. После выбора — координация: либо мы пересобираем легаси (вариант А), либо devops снимает легаси с ProGet (вариант Б), либо команды продуктов обновляют пины (вариант В).
- **TeamCity миграция layout.** Заменять GR121/GR122 или параллельно — с лидом + TC-админом. См. память [[feedback_tc_layout_needs_lead]].

### Внешние зависимости

- **Команда `grpc_sdk`** — фикс gtest fixture-collision (вынести `class GRPCService` из анонимного namespace; подробности в `STATUS.md` пункт 1 + Часть 2 пункт 13 + память [[project_grpc_sdk_typed_test_fixture_collision]]). Мы дали воспроизводимый кейс, ответственность их.

### Backlog (идеи из секции 1)

Расставлены по убыванию value/effort ratio:

1. **1.2 ABI-validation в CI** (M effort, H value) — самый частый класс регрессов автоматизируется одним 30-строчным скриптом.
2. **1.6.3 `nupkg_schema_validator.sh`** (L effort, M value) — поймает регресс типа `7bb065d` до выхода в production.
3. **1.6.1 `nm_symbol_diff.sh`** (L effort, M value) — полезно при bump'ах.
4. **1.4 Cross-platform parity smoke** (M effort, M value) — но требует Windows-фазы сначала.
5. **1.5 Downstream-test nightly** (M effort, H value, есть препятствия) — нужны организационные шаги (доступ к downstream-репам).
6. **1.8 Markdown-линтер** (L effort, L value) — приятно иметь, не критично.
7. **1.1 Eliminate `.1`-суффикса** (L technical, организационно H) — ждём решения лида.
8. **1.3 Semver-aware resolution** (H effort, outside conan-recipes) — долгая инициатива через архитектора.
9. **1.7 Internal mirror** (M effort, M value) — нужна инфра.

---

## Финальная нота

Сделано **работающее**, не **идеальное**. Это нормально для миграции такого масштаба — 7 пакетов, 3 платформы, 5+ downstream-продуктов, обратная совместимость с легаси. Каждый из пунктов в секции 1 — это не «недоделка», а **осознанный technical debt**, который можно отдавать по мере того как доходят руки и появляются ресурсы.

Главное — не путать debt с **антипаттернами** (секция 2). Debt можно копить аккуратно. Антипаттерны — это путь к регрессам, которые потом дорого ловить.

И — память. На каждый нюанс который повторится больше одного раза — пишите memory file. Через 3 месяца Claude забудет контекст этой сессии; memory-индекс — единственное что переживёт.

---

# Связанные документы

Документы в `docs/IN-658/` сгруппированы по аудитории. Этот плейбук — самый объёмный и универсальный; ниже — навигация на остальные:

- **[STATUS.md](STATUS.md)** — текущее состояние x86_64-фазы, таблица из 9 коммитов IN-658 (`03a20c0`, `3d9ae77`, `615cf9f`, `6674d29`, `5df4aa6`, `3b3485a`, `457ad47`, `7bb065d`, `a611fc1`), открытые вопросы, риски. Главный source-of-truth для статуса.
- **[CONFLUENCE.md](CONFLUENCE.md)** — overview миграции глазами лида / команды; контекст, hard contracts, ключевые технические решения. Точка входа для нетехнических читателей.
- **[DEVOPS-RUNBOOK.md](DEVOPS-RUNBOOK.md)** — как собрать и опубликовать `.nupkg` на CI / TeamCity, sanity-checks внутри `.nupkg`, troubleshooting инфраструктуры.
- **[DOWNSTREAM-MIGRATION.md](DOWNSTREAM-MIGRATION.md)** — для команд `el_conf`, `grpc_sdk`, `sura` и других потребителей: как обновить `_dependencies`-пины, варианты миграционной стратегии (А/Б/В), известные проблемы и решения.
- **[DEVELOPER.md](DEVELOPER.md)** — быстрая ориентация в репозитории для следующего разработчика conan-recipes (англ): структура файлов, hard contracts, ключевые функции deployer'а, что НЕ повторять.
- **`test-astra/HELP.txt`** (в корне репо) — диагностические блоки `[0]`–`[12]`. Особенно актуальные: `[11]` (abseil namespace mismatch), `[12]` (reinstall stale `.1`-slots).
- **`test-astra/TESTING_ARM.md`** — runbook ARM-фазы (следующий шаг IN-658).
- **`CLAUDE.md`** (в корне репо, local-only) — оперативный контекст для Claude Code: текущая инфра, Conan 2.27.1 quirks, ARM workarounds.
