# IN-658 — статус миграции third-party библиотек на Conan 2.x

**Дата:** 2026-05-26
**Состояние:** x86_64 закрыт. ARM-фаза следующая.
**Линия:** master в `bitbucket.inc.elara.local` / fork `HYUEHFJKhfjklkej/conan` на GitHub.

## TL;DR

Все 7 пакетов цепочки `grpc/1.60.1` (grpc, protobuf, abseil, re2, c-ares, openssl, zlib) собираются Conan 2.27.1, упаковываются в legacy-совместимые `.nupkg` через deployer `extensions/deployers/legacy_nupkg.py`, и **end-to-end успешно консумируются** двумя downstream-продуктами:

- `grpc_sdk` 1.3.0 — собирается, линкуется, тесты запускаются (7 из 9 проходят; 2 падающих — баг в их test-коде, не наша часть).
- `el_conf` 0.22.0-alpha — собирается полностью, все 30+ компонентов и плагинов, тесты `device_config_manager_test`, `elecont_protocol_client_test`, `config_builder_test`, `file_factory_test`, `sura_connector_client_test` проходят.

## Что было сделано

### Цепочка коммитов в `conan-recipes` (master)

| Коммит | Эффект |
|---|---|
| `03a20c0` | `_legacy_component_names()` в deployer — `components` в CMakeLists.var несут legacy-имя пакета (`zlib`), не upstream-basename либы (`z`). Закрыло `cannot find -lzlib`. |
| `3d9ae77` | `LEGACY_NAME_MAP["c-ares"] = "cares"` — дефис в имени ломал `add_definitions(-D${_name}_..._DEFINE)` в `ResolveDependencies.cmake`. |
| `615cf9f` | Пин abseil `20230802.1` (не `20240116.2`) для линии grpc 1.60.1 + `EXPORTS[abseil]=20230802.1` в `run_grpc_1601_upstream.sh`. Inline-namespace `lts_20230802` теперь совпадает с legacy `absl/0.2.0`. |
| `6674d29` | Deployer зеркалит `*.proto` из `include/` в отдельный `proto/` (легаси-layout). Закрыло `google/protobuf/timestamp.proto: File not found` у downstream. |
| `5df4aa6` | `HELP.txt` блок `[12]` — диагностика и reinstall-процедура stale `.1`-слотов на dev-VM. |
| `3b3485a` | `test-astra/diff_two_dirs.sh` — exhaustive comparator двух деревьев (12 осей: tree, md5, perms, owner, xattr, ACL, SELinux, MIME, line endings, symlinks, realpath, inode). Помог найти причину разницы между нашим и легаси `proto/`. |
| `457ad47` | Deployer исключает `compiler/plugin.proto` и `java/java_features.proto` из `proto/`-mirror — эти upstream-extras ломали protoc downstream. |
| `7bb065d` | `_make_keepdirs()` пропускает непустые папки — `.keepdir` маркер не остаётся в `proto/` после заполнения, downstream framework перестаёт принимать его за `.proto`-файл. |
| `a611fc1` | `libprotolib.so → libprotoc.so` alias + components emits BOTH `protoc` и `protolib`. Закрыло `cannot find -lprotolib` у `profibus_dp_ui_plugin`. |

### Скрипт сборки

`test-astra/run_grpc_1601_upstream.sh` — собирает все 7 пакетов цепочки `grpc/1.60.1` в Docker-образе `proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0` (тот же что TeamCity использует), деплоит в `output-grpc-1601-upstream/`. С `LEGACY_NUPKG_VERSION_SUFFIX=.1` имена имеют суффикс `.1` для coexistence с легаси на ProGet.

### Документация

`conan-recipes/test-astra/HELP.txt` — runbook из 12+ диагностических блоков. Особо актуальные: `[11]` (abseil namespace mismatch), `[12]` (reinstall stale `.1`-slots).

## Что НЕ закрыто

### 1. Сегфолт `grpc_sdk_test` на `GrpcServiceTcp/.StartStop`

**Это НЕ наш баг.** Воспроизводится в обоих build-type (Debug и Release) на TC-идентичном docker-образе. Корень — паттерн в `grpc_sdk/tests/GRPCServiceTest.cpp`:
- `template<typename> class GRPCService` объявлен в анонимном namespace.
- `TYPED_TEST_CASE` с 2 типами из анон-namespace — gtest на 2-м типе считает fixture-класс «другим» и фаерит check.

Фикс — в репозитории `grpc_sdk`: вынести `class GRPCService` из анонимного namespace в named. Ответственность — команда grpc_sdk.

Подробности: память `project-grpc-sdk-typed-test-fixture-collision`.

### 2. Локальные workaround'ы на dev-VM требуют production-стратегии

На dev-astra18-13 пользователь применял `sed`-правки в установленных легаси-пакетах:
- `utf8_range.lin.gcc84.shared.x86_64.0.1.0/CMakeLists.var`: `absl:0.2.0 → absl:0.2.0.1`
- Аналогично для protobuf-legacy и других.

Это **не код el_conf**, не уйдёт в git. Для CI / новых сборок нужно одно из:

- **(А)** Пересобрать легаси-пакеты `utf8_range/0.1.0`, `cares/1.19.0`, и т.п. с обновлённым `_dependencies` пинящим `.1`-версии — наша команда.
- **(Б)** Поставить наши пакеты на ProGet **без `.1` суффикса**, прямо вытеснив легаси. Тогда легаси-пины автоматически резолвятся в наши.
- **(В)** Каждый downstream обновляет свой `_dependencies` пинить `.1`-версии — координация с командами el_conf/grpc_sdk/sura.

Решение — за лидом. Подробности: `DOWNSTREAM-MIGRATION.md`.

### 3. ARM-фаза IN-658

Не начата. Инфраструктура готова:
- `test-astra/test_arm_cross.sh` — обёртка над docker run с linaro-toolchains.
- `Dockerfile.grpc-tc-mirror` (multi-stage) — собирает образ для arm/arm64 cross.
- Профили `profiles/lin-gcc75-arm-linaro`, `profiles/lin-gcc75-arm64-linaro`.
- `test-astra/TESTING_ARM.md` — runbook.

Следующий шаг: прогнать `./test-astra/test_arm_cross.sh build arm` / `build arm64`, проверить артефакты.

## Риски

| Риск | Митигация |
|---|---|
| Дублирование `.1`-пакетов с legacy на ProGet — кеш потребителей может перепутать | Производственная стратегия (А/Б/В выше) убирает дубликат |
| Свежие билды зависят от `git pull` в conan-recipes на каждой VM | Документация `DEVOPS-RUNBOOK.md` фиксирует процедуру |
| Test segfault в grpc_sdk блокирует ctest на CI | Команда grpc_sdk должна пофиксить, мы дали воспроизводимый кейс |
| ARM linaro 7.5 binutils 2.32 баги (gold linker workaround, stacktrace patch) | Уже учтены в текущих `conanfile.py` патчах abseil |

## Артефакты

- **Репозиторий:** `bitbucket.inc.elara.local` (master через `HYUEHFJKhfjklkej/conan.git` GitHub-mirror)
- **Output:** `conan-recipes/output-grpc-1601-upstream/*.nupkg` (7 файлов после `run_grpc_1601_upstream.sh`)
- **Документация:** `conan-recipes/docs/IN-658/` (этот документ + 4 связанных)
- **Diagnostics:** `conan-recipes/test-astra/HELP.txt` (блоки 0-12)
- **Tools:** `conan-recipes/test-astra/diff_two_dirs.sh`

## Связанные документы

- `CONFLUENCE.md` — общий overview миграции, контекст.
- `DEVOPS-RUNBOOK.md` — как собрать и опубликовать `.nupkg` на CI.
- `DOWNSTREAM-MIGRATION.md` — что нужно командам el_conf / grpc_sdk / sura.
- `DEVELOPER.md` — для следующего разработчика conan-recipes (англ).
