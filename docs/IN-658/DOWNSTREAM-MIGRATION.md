# Миграция downstream-проектов на новые `.1`-пакеты

> Аудитория — команды `el_conf`, `grpc_sdk`, `sura`, и других продуктов которые потребляют `grpc`/`protobuf`/`abseil`/etc. через NuGet с ProGet.

## TL;DR

Мы пересобрали 7 third-party библиотек на Conan 2.x. Наши `.nupkg`-артефакты на ProGet выложены с **суффиксом `.1`** в версии:
- было: `absl.lin.gcc84.shared.x86_64.0.2.0.nupkg` (легаси)
- стало: `absl.lin.gcc84.shared.x86_64.0.2.0.1.nupkg` (наш)

Оба слота coexist на ProGet. **Чтобы ваш проект использовал наши пакеты, нужно обновить `_dependencies` в ваших `CMakeLists.var`** — заменить bare-версии на `.1`-версии.

## Какие пакеты обновили

| Имя | Старая версия | Новая `.1` |
|---|---|---|
| absl (abseil) | 0.2.0 | **0.2.0.1** |
| protobuf | 4.25.2 | **4.25.2.1** |
| grpc | 1.60.1 | **1.60.1.1** |
| zlib | 1.3.0 | **1.3.0.1** |
| cares (c-ares) | 1.25.0 | **1.25.0.1** |
| openssl | 1.1.11 | **1.1.11.1** |
| re2 | 20230301.1.0 | **20230301.1** (без изменений номера если уже мигрированы) |

## Что нужно сделать в вашем проекте

### Шаг 1: Найдите все `CMakeLists.var` с `_dependencies`

```bash
grep -rH '_dependencies' --include=CMakeLists.var .
```

Типичный вид:
```cmake
set(${project_name}_dependencies
    exceptions:0.5.0
    googletest:1.15.2
    grpc:1.60.1        ← если bare-версия, требует обновления
    protobuf:4.25.2    ← аналогично
    absl:0.2.0         ← аналогично
)
```

### Шаг 2: Обновите пины на `.1`-версии

Заменить:
```cmake
set(${project_name}_dependencies
    exceptions:0.5.0       # ← остаётся (не наш пакет)
    googletest:1.15.2      # ← остаётся
    grpc:1.60.1.1          # ← добавили .1
    protobuf:4.25.2.1      # ← добавили .1
    absl:0.2.0.1           # ← добавили .1
    re2:20230301.1.0       # ← обновили
    cares:1.25.0.1         # ← добавили .1
    openssl:1.1.11.1       # ← добавили .1
    zlib:1.3.0.1           # ← добавили .1
)
```

Делать ТОЛЬКО для тех зависимостей, которые **вы реально потребляете напрямую**. Транзитивные — резолвятся автоматически через `_dependencies` нашего grpc-пакета.

### Шаг 3: Пересоберите проект

```bash
rm -rf .build/lin.gcc.shared.x64
mkdir -p .build/lin.gcc.shared.x64 && cd .build/lin.gcc.shared.x64
cmake -DCMAKE_TOOLCHAIN_FILE=../../cmake/toolchains/linux_x86_64.cmake \
      -DCMAKE_BUILD_TYPE=Debug -DBUILD_SHARED_LIBS=ON ../..
# BUILD_SHARED_LIBS=ON → Elara framework's get_library_prefix() = "shared",
# резолвер ищет `.shared.x86_64.` slot — это GR113-эквивалент DynamicRT,
# куда мы публикуем наши .nupkg. Содержимое нашего .nupkg — static `.a`
# (см. INFRASTRUCTURE.md §3.7 «Контракт линкажа»).
cmake --build . -- -j$(nproc)
```

### Шаг 4: Сверка резолва

```bash
grep -E 'absl_INCLUDE_DIRS|^dependencies' .build/.../CMakeCache.txt | head -5
```

`absl_INCLUDE_DIRS` должен указывать на `.../absl.lin.gcc84.shared.x86_64.0.2.0.1/include` (с `.1`).

## Что вы получите

### protobuf — well-known типы доступны для protoc
- `proto/google/protobuf/timestamp.proto`, `duration.proto`, и т.д. готовы для `import` в ваших `.proto`-файлах.
- Если ваш `.proto` импортирует well-known тип, в `protobuf_generate_grpc_cpp()` укажите наш proto-dir в `IMPORT_DIRS`:
  ```cmake
  set(proto_imports_directory
      ${protobuf_proto_dir}     # или конкретный путь из CMakeCache
  )
  ```
  Или явный путь — `/home/<user>/protobuf.lin.gcc84.shared.x86_64.4.25.2.1/proto`.

### abseil — inline-namespace `lts_20230802`
- Совместимо с легаси `absl/0.2.0`.
- Если ваши `.o` или `.a` старого билда содержат `lts_20240116/lts_20250127` — пересоберите против нашего `.1`.

### protobuf — `libprotolib.so` alias
- Если ваш `target_libraries` пинит `protolib` — наш пакет создаёт `libprotolib.so → libprotoc.so` симлинк, ничего менять не надо.
- Если пиннит `protoc` — тоже работает, оба имени экспортируются как components.

## Возможные проблемы и решения

### `cannot find -lprotolib`
Установлен старый `.1`-пакет protobuf (до коммита `a611fc1`). Перезагрузите свежий из ProGet/output:
```bash
rm -rf /home/user/protobuf.lin.gcc84.shared.x86_64.4.25.2.1
# скачать свежий .nupkg, распаковать заново
```

### `undefined reference to absl::lts_20240116::...`
Установлен старый `.1`-пакет absl (до коммита `615cf9f`). То же — переустановить свежий.

Проверка inline-namespace:
```bash
grep ABSL_OPTION_INLINE_NAMESPACE_NAME /home/user/absl.lin.gcc84.shared.x86_64.0.2.0.1/include/absl/base/options.h
# должно быть `lts_20230802`, не 20240116/20250127
```

### `google/protobuf/timestamp.proto: File not found`
В вашем `CMakeLists.var` пустой `proto_imports_directory`. Добавьте путь к protobuf'у:
```cmake
set(proto_imports_directory
    /home/user/protobuf.lin.gcc84.shared.x86_64.4.25.2.1/proto
)
```

(Лучше через переменную фреймворка `${protobuf_proto_dir}` если она у вас есть. Если нет — явный путь.)

### Build падает на цепочке абсейл-символов через legacy lib
Какой-то ваш downstream-`target_libraries` ссылается на `gsd_parser`/`profibus_utils`/подобные легаси-`.a` после `log`/`status`. Линкер ld в один проход не находит транзитивные absl-символы.

**Решение** (см. `STATUS.md` пункт 2): добавить проблемные absl-либы в `target_libraries_whole_archive` блок вашего `CMakeLists.var`:
```cmake
set(target_libraries_whole_archive
    log
)
```
Этот фреймворковый механизм оборачивает либы в `-Wl,--whole-archive ... -Wl,--no-whole-archive`, гарантируя что все символы попадут в бинарь.

Альтернативно — переставить в `target_libraries` потребителей absl ПЕРЕД самими absl-либами.

## Что мы НЕ меняли (и не надо пересобирать)

- `exceptions/0.5.0`
- `googletest/1.15.2` (наша поставка идентична)
- `crossplatform/0.4.0`
- `cs_system_data`, `cs_service_sdk`, `sqlite`, и др. — это ваши/чужие легаси, мы их не трогали.

## Cross-platform

То же самое применяется к Windows-сборкам (когда сделаем `win-msvc-x64` через Conan) и к ARM (после ARM-фазы IN-658). Имена слотов будут аналогичные с поправкой на `<os>.<compiler>.<linkage>.<arch>`.

## Связь / координация

Если что-то не работает после миграции:
- Сверьтесь с `STATUS.md` (известные не-наши баги, например grpc_sdk fixture-collision).
- Сверьтесь с `DEVOPS-RUNBOOK.md` (как переустановить пакет, как проверить inline-namespace).
- Свяжитесь с conan-recipes maintainer'ом.

## Альтернативные стратегии миграции (решение лидом)

Описанный выше путь — **вариант В** (downstream обновляет свои пины). Лид может выбрать другое:

- **Вариант А:** наша команда пересобирает легаси-пакеты (`utf8_range/0.1.0`, и т.п.) с обновлёнными `_dependencies` пинящими `.1`-версии. Тогда вы НЕ трогаете свои CMakeLists.var, всё резолвится автоматически.
- **Вариант Б:** наши пакеты публикуются БЕЗ `.1`-суффикса, вытесняя легаси. Тогда ваши пины `absl:0.2.0` автоматически резолвят наши пакеты.

Финал — за лидом, ожидайте уведомления.
