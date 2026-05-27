# DevOps / CI Runbook — IN-658

Сборка и публикация `.nupkg`-пакетов цепочки `grpc/1.60.1` (7 пакетов) на CI / TeamCity.

## Среда

- **Docker-образ для сборки:** `proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0` (Debian Stretch + gcc 8.4 в `/usr/local/gcc-8.4/`).
- **Conan:** 2.27.1, поставляется в `conan-recipes/packages-linux/conan-2.27.1.tar.gz`. Внутри Docker устанавливается через `test-astra/setup.sh`.
- **Python в Docker:** standalone 3.11.10 из `packages-linux/cpython-3.11.10+20240909-x86_64-linux-gnu.tar.gz` (Stretch system Python 2.7 не годится).
- **ProGet (NuGet feed):** `proget.inc.elara.local/main`. NuGet-пакеты типа `<name>.lin.gcc84.static.x86_64.<version>.nupkg`.

## x86_64 — полный билд цепочки grpc/1.60.1

### Шаг 1: Чистый клон conan-recipes

```bash
git clone <repo-url> conan-recipes
cd conan-recipes
git checkout master
# Подтверди что есть последние коммиты IN-658:
git log --oneline | grep -E '(a611fc1|7bb065d|457ad47|3b3485a|5df4aa6|6674d29|615cf9f|3d9ae77|03a20c0)'
# должны быть видны все 9
```

### Шаг 2: Запуск билда

```bash
# С .1-суффиксом в именах .nupkg (рекомендуется — coexistence с легаси на ProGet)
LEGACY_NUPKG_VERSION_SUFFIX=.1 ./test-astra/run_grpc_1601_upstream.sh

# БЕЗ суффикса (если решено вытеснить легаси — обсудить с лидом)
./test-astra/run_grpc_1601_upstream.sh
```

Скрипт сам:
1. Проверяет наличие docker-образа `grpc-tc-mirror`, билдит его из `Dockerfile.grpc-tc-mirror` если нет.
2. Самовызывается через `docker run grpc-tc-mirror` (host-запуск авто-обёрнут).
3. Внутри контейнера: вайпает Conan cache (если не `SKIP_CACHE_CLEAN=1`).
4. `conan export` всех 7 рецептов.
5. `conan install --build=missing` для Release + Debug build_type.
6. `conan install --deployer=extensions/deployers/legacy_nupkg.py` → 7 `.nupkg` в `output-grpc-1601-upstream/`.

Время: **15-25 минут** на native gcc84-x86_64 машине.

### Шаг 3: Контроль артефактов

```bash
ls -lh output-grpc-1601-upstream/
# Ждём 7 файлов:
#   abseil.lin.gcc84.static.x86_64.20230802.1[.1].nupkg
#   c-ares.lin.gcc84.static.x86_64.1.25.0[.1].nupkg
#   grpc.lin.gcc84.static.x86_64.1.60.1[.1].nupkg
#   openssl.lin.gcc84.static.x86_64.1.1.11[.1].nupkg
#   protobuf.lin.gcc84.static.x86_64.4.25.2[.1].nupkg
#   re2.lin.gcc84.static.x86_64.20230301[.1].nupkg
#   zlib.lin.gcc84.static.x86_64.1.3.0[.1].nupkg
```

#### Sanity-checks внутри `.nupkg`

```bash
# 1. abseil/protobuf inline-namespace должен быть lts_20230802 (НЕ 20240116/20250127)
mkdir /tmp/check && cd /tmp/check && rm -rf *
unzip -q <repo>/output-grpc-1601-upstream/abseil.lin.gcc84.static.x86_64.20230802.1.1.nupkg
grep ABSL_OPTION_INLINE_NAMESPACE_NAME include/absl/base/options.h
# должно быть `lts_20230802`

# 2. protobuf .proto файлы well-known типов на месте
unzip -l <repo>/output-grpc-1601-upstream/protobuf.lin.gcc84.static.x86_64.4.25.2.1.nupkg | grep '\.proto$'
# 12 файлов: any, api, descriptor, duration, empty, field_mask, source_context,
#            struct, timestamp, type, wrappers, cpp_features под proto/google/protobuf/
# (compiler/plugin.proto + java/ ОТСУТСТВУЮТ — это правильно)

# 3. protobuf libprotolib.a alias на libprotoc.a (для static, deployer a611fc1)
unzip -l <repo>/output-grpc-1601-upstream/protobuf.lin.gcc84.static.x86_64.4.25.2.1.nupkg | grep -E 'libprotolib|libprotoc'
# Жду libprotoc.a, libprotolib.a (alias-симлинк на первый)
# Для shared-варианта: libprotoc.so, libprotoc.so.25.2.0, libprotolib.so, libprotolib.so.25.2.0

# 4. zlib libzlib.a alias на libz.a (для static)
unzip -l <repo>/output-grpc-1601-upstream/zlib.lin.gcc84.static.x86_64.1.3.0.1.nupkg | grep -E 'libz|libzlib'
# Жду libz.a, libzlib.a (alias-симлинк)
# Для shared: libz.so, libz.so.1, libz.so.1.3.0, libzlib.so → симлинк
```

### Шаг 4: Публикация на ProGet

```bash
# Через nuget push (или curl, если без NuGet CLI)
for pkg in output-grpc-1601-upstream/*.nupkg; do
    nuget push "$pkg" \
        -Source https://proget.inc.elara.local/nuget/main \
        -ApiKey <YOUR_PROGET_KEY>
done

# Альтернативно через curl
for pkg in output-grpc-1601-upstream/*.nupkg; do
    curl -X PUT \
        -H "X-NuGet-ApiKey: <YOUR_PROGET_KEY>" \
        -F "package=@$pkg" \
        https://proget.inc.elara.local/nuget/main
done
```

## ARM (armv7hf + arm64) — cross-build

Подробный runbook: `conan-recipes/test-astra/TESTING_ARM.md`. Краткая последовательность:

```bash
export REGISTRY=proget.inc.elara.local/main

# Smoke (pre-flight, ~2 мин)
./test-astra/test_arm_cross.sh smoke arm
./test-astra/test_arm_cross.sh smoke arm64

# Полный билд (~25-40 мин)
./test-astra/test_arm_cross.sh build arm     # → output-armv7hf/
./test-astra/test_arm_cross.sh build arm64   # → output-armv8/
```

После — те же sanity-checks (но с другими профилями: `lin-gcc75-arm-linaro` и `lin-gcc75-arm64-linaro`), и публикация:

```bash
for pkg in output-armv7hf/*.nupkg output-armv8/*.nupkg; do
    nuget push "$pkg" -Source https://proget.inc.elara.local/nuget/main \
        -ApiKey <YOUR_PROGET_KEY>
done
```

## TeamCity конфигурация (будущее)

Сейчас legacy `GR121` (Linux x86_64) и `GR122` (Linux ARM) TC-конфиги собирают через старые скрипты. **Решение по их замене — за лидом** (см. память `feedback_tc_layout_needs_lead`). Варианты:

- **(а)** Заменить GR121/GR122 на новые `IN-658-LINUX-X64`, `IN-658-LINUX-ARM` (запускают `run_grpc_1601_upstream.sh` и `test_arm_cross.sh build`).
- **(б)** Параллельно запускать новый и старый — пока тестово, затем переключиться.
- **(в)** Завести новый раздел `CONAN-RECIPES` сбоку.

Координировать с TC-админами.

### Готовый шаблон TC-конфига (для варианта а или б)

```
Build configuration: IN-658-LINUX-X64
─────────────────────────────────────
Build steps:
  1. VCS: pull conan-recipes master
  2. Command line:
     LEGACY_NUPKG_VERSION_SUFFIX=.1 \
         ./test-astra/run_grpc_1601_upstream.sh
  3. NuGet: push output-grpc-1601-upstream/*.nupkg
            → proget.inc.elara.local/nuget/main

Build agents: gcc84-build-x86_64 (Docker-capable)
Triggers: VCS trigger on master
Artifact paths: output-grpc-1601-upstream/*.nupkg
Timeout: 45 minutes
```

## Troubleshooting

### `docker pull` падает на x509-сертификате
См. `HELP.txt[X]`.

### `conan` не найден внутри образа
Проверь что в Dockerfile.grpc-tc-mirror установлен через offline `pip` из `packages-linux/conan-2.27.1.tar.gz`. Проверка `conan --version` после билда образа.

### Cache содержит несоветистимую `abseil/20240116.2`
`run_grpc_1601_upstream.sh` шаг 0 проверяет cache. Если падает — `conan remove '*' -c` внутри контейнера.

### `.nupkg` собрался но не содержит `proto/<...>.proto`
Проверь что в master есть коммит `6674d29` (proto/ mirror). Без него deployer оставляет proto/ пустым. `git log extensions/deployers/legacy_nupkg.py | head`.

### `LD_LIBRARY_PATH`-стенки у потребителей
**Актуально только для shared-build** (`SHARED=True`). При static (дефолт) этот блок неприменим — `.a` встраиваются в потребителя на линковке.

Для shared: RUNPATH не propagates транзитивно у Linux loader'а. На runtime у потребителя:
```bash
export LD_LIBRARY_PATH="$(find /home/<user> -maxdepth 4 -path '*/lib/native/lin-gcc84-shared-x86_64*' -type d | tr '\n' ':')$LD_LIBRARY_PATH"
```

Другие сценарии (включая stale `.1`-слоты на dev-VM): см. `test-astra/HELP.txt` блоки `[0]`–`[12]`.

## Контроль качества — что проверять после публикации

1. **Тестовая dev-VM** (например свежеподнятая Astra18.13) — поставить `.nupkg` из ProGet, собрать `grpc_sdk` и `el_conf`. Должно пройти **без локальных sed-правок** (если использован вариант Б миграционной стратегии — без `.1`-суффикса) либо с обновлёнными `_dependencies` у downstream (вариант А или В).
2. **Сравнение бинарей** — `nm`/`objdump` на `libprotobuf.so` из старого билда vs нового — главное чтобы:
   - Все символы `absl::lts_20230802::*` присутствуют (не `lts_20240116/20250127`).
   - `LogMessageFatal::LogMessageFatal(char const*, int)` определён.
   - Размер сопоставим (±20%).
3. **`ar t` libprotoc.so / libprotolib.so** — оба должны содержать одинаковые `.o` файлы (libprotolib — симлинк).

## Контакты

- Conan-recipes maintainer — текущий разработчик.
- TC админ — devops отдел.
- ProGet — devops.
