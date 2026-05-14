# Conan-инфраструктура (IN-353 / IN-658): что построено, преимущества, куда дальше

**Аудитория:** лид, разработчики которые будут поддерживать пайплайн после
закрытия IN-353, devops/CI команда, новый человек которому надо понять
«зачем мы это делаем».

**Статус документа:** актуально на 2026-05-14. Покрывает закрытое
(IN-353 x86_64 + IN-658 arm/arm64 sandbox arm64) и roadmap'ы. По мере
закрытия задач — обновляется.

---

## TL;DR

1. **Что построено.** Conan 2.27.1-пайплайн для 8 third-party C++ либ
   (gtest, zlib, abseil, c-ares, re2, protobuf, openssl, grpc), который
   на выходе даёт legacy `.nupkg` идентичный по имени/структуре тому что
   собирает существующий TC-флоу (`GR113` и его соседи). Закрыты:
   x86_64-сборка, ARM cross-build (armv7hf + arm64) с pre-baked Docker
   image в ProGet, TC sandbox прогон arm64 c публикацией 7 `.nupkg`.

2. **Главное преимущество.** Дерево зависимостей решается **автоматически
   и детерминированно**. Добавить новую либу — `~30 минут` (новый
   `conanfile.py` + tarball + патч) против **дней** в текущем флоу
   (новый TC-проект + Bitbucket-обёртка + toolchain + Build Steps). Все
   8 либ уже мигрированы и проверены.

3. **Сколько ещё работы.** Сборочно — фактически закрыто; осталось
   формальное: arm-арка в TC, согласование с лидом layout'а
   прод-конфигов (3 варианта в §7.1), Confluence-статья. **Опционально**
   — Conan-feed в ProGet (cross-agent cache, ~5-10 мин вместо 4 часов
   cold-build) и push наших ARM-`.nupkg` в боевой NuGet feed.

4. **Роль ProGet.** Уже используется как Docker feed (base images +
   pre-baked mirror) и NuGet feed (legacy x86_64 distribution для
   downstream). **Можно добавить:** Conan feed (cross-agent cache),
   расширенный NuGet feed под arm/arm64 outputs, retention policies,
   service accounts. ProGet — единственный внешний registry, всё
   остальное (Git, TC, агенты) остаётся как есть.

5. **Где живут флаги сборки.** Это самое неочевидное изменение для
   повседневной работы: вместо TC Parameters / Build Step UI, флаги
   живут **в git-репо** — в Conan profile (`[settings]`, `[options]`,
   `[conf]`, `[buildenv]`) или в `profiles/toolchains/*.cmake`. Каждый
   тип флага имеет одно канонiчное место. Подробная карта legacy → Conan
   соответствий, примеры (compiler flags, hardening, defines, per-package
   options, ad-hoc override из TC) и анти-паттерны — §4.

---

## 1. Контекст: зачем вся эта возня

### 1.1 Что было/есть до Conan-флоу

Каждая third-party C++ либа на TeamCity — отдельный проект в дереве
`SURA2/COMPONENTS/CMAKE/<LIB>/<Platform>/<GRxxx BUILD ...>`:

- `GR113 BUILD Linux x64 DynamicRT` — grpc на Linux x86_64
- `GR121 BUILD Linux ARM DynamicRT` — grpc на Linux armv7hf-linaro
- `GR122 BUILD Linux ARM64 DynamicRT` — grpc на Linux arm64-linaro
- + аналогичные `GR700+` для protobuf, `GR800+` для openssl, и т.д.

У каждого билд-конфига:

- **Bitbucket-репо с обёрткой** (`bitbucket.inc.elara.local` → проект
  с именем либы) — содержит свой `CMakeLists.txt`, который тянет
  upstream-сорсы и оборачивает их под легаси-сборку.
- **Toolchain-файлы вручную написанные** в `cmake/toolchains/` той же
  обёртки: `linux_x86_64.cmake`, `linux_arm-linaro.cmake`,
  `linux_arm64-linaro.cmake` — каждый со своим набором флагов
  (`-m64 -march=core2 -fPIC -static-libgcc -static-libstdc++` для x64,
  плюс кросс-настройки для ARM).
- **8 Build Steps в TC**: CleanUp, Static Analysis, Coverage Analysis,
  Check Coverage, Build Release, Build Debug, PVS Analysis, Guardant
  Protect — все наследуются от `<Root project> / CMAKE: 113 BUILD Linux
  x64 DynRT` template.
- **66 параметров TC** на конфиг (видим в Parameters tab у `GR113`):
  `IsRelease`, `useUpgradedBuild`, `Protect`, `PrereleaseSuffix`,
  `CustomDefines`, `projectName`, `build.vcs.number` и пр.
- **Артефакты** публикуются в **ProGet NuGet feed** (точное имя feed'а
  пока не подтверждено, но pattern в Artifact paths указывает на
  `<projectName>.zip!/lin.gcc.shared.<arch>` zip-архив). Оттуда downstream
  продукты тянут через `nuget restore` и `<package id=...>` в
  `packages.config`/`.csproj`.

### 1.2 Что в этом подходе плохо

| Проблема | Симптом |
|---|---|
| **Граф зависимостей не описан нигде** | grpc зависит от protobuf+abseil+openssl+c-ares+re2+zlib. Какие версии совместимы — знание в голове DevOps'а. Обновили abseil → надо помнить пересобрать protobuf и grpc вручную. ABI-сюрприз вылезает у потребителя в проде. |
| **Per-lib boilerplate** | Каждая новая либа: завести Bitbucket-репо, написать обёртку CMakeLists.txt, написать N toolchain-файлов, завести TC-проект, настроить 8 Build Steps, прописать 30-60 параметров, цепануть к downstream. Минимум 1-2 дня devops-работы **на одну либу**. |
| **Cross-platform = N копий конфигов** | x86_64, armv7hf, arm64, Windows — четыре независимых билд-конфига на одну либу, каждый со своим toolchain и параметрами. Расхождения между ними — реальная проблема (например когда стенд-Windows отстал от Linux в опциях). |
| **Reproducibility — никакая** | Артефакт от 2026-04-01 и от 2026-05-01 могут отличаться, и в логах TC нет способа сказать «это тот же или другой бинарь». package_id-хэша нет, build numbers просто инкрементные. |
| **Кеш — нет** | Каждый билд начинает с CleanUp шага. 4-5 часов на grpc Debug-сборку даже если поменялась одна строчка комментария в `CMakeLists.txt` обёртки. |
| **Версионирование upstream** | Новая версия grpc (1.78 → 1.80) = переписать обёртку CMakeLists.txt под новые targets, исследовать новые опции CMake, переписать toolchain если изменились expected переменные. **Часы-дни на каждой версии каждой либы.** |

### 1.3 Почему именно Conan, а не «свой кастомный фреймворк»

- **Канонично, не самописно.** Conan 2.x — стандарт C++ ecosystem, recipes
  есть в `conan-center-index` (1500+ либ). Мы зеркалим recipes upstream
  с минимальными правками (offline-патч и патч-файлы в `patches/`).
  Когда выходит новая версия — bump `conandata.yml` + sha256 +
  закатить (если надо) дельта-патч. Никакого reverse-engineering CMake.
- **Версионирование, графы, dependency resolution** — нативно из коробки,
  не надо изобретать.
- **Package_id-хэширование** — детерминированный «один бинарь = один
  хэш». Cache hits/misses, ABI-rollback по hash'у — всё нативно.
- **Кросс-платформа из одного файла** — `conanfile.py` тот же для Linux
  x64, Linux arm/arm64, Windows. Меняется только profile.
- **Offline-friendly** — `--no-remote` + предзагруженные source tarballs
  в `src/` + pip wheels в `packages-linux/`. Работает в закрытом
  контуре, который у нас и есть.

---

## 2. Что построено в IN-353 + IN-658

### 2.1 Архитектура одной картинкой

```
┌───────────────────────────────────────────────────────────────────────┐
│ Уровень 1: Recipes (источник истины «как собирать»)                   │
│ ┌────────────────────────────────────────────────────────────────┐    │
│ │ conan-recipes/                                                 │    │
│ │  ├── gtest/, zlib/, abseil/, c-ares/, re2/,                    │    │
│ │  │   protobuf/, openssl/, grpc/                                │    │
│ │  │   Каждая папка = canonical conan-center-index recipe        │    │
│ │  │   + 2 offline-патча в conanfile.py (source helper)          │    │
│ │  │   + локальные патчи в patches/<version>/                    │    │
│ │  │   + src/<upstream>.tar.gz (offline source archive)          │    │
│ │  ├── profiles/                                                 │    │
│ │  │   ├── astra-gcc, lin-gcc84-x86_64                           │    │
│ │  │   ├── lin-gcc75-arm-linaro, lin-gcc-aarch64-linaro          │    │
│ │  │   └── toolchains/{linaro-arm.cmake,linaro-aarch64.cmake}    │    │
│ │  └── extensions/deployers/legacy_nupkg.py                      │    │
│ │      (Conan deployer → байт-совместимый .nupkg)                │    │
│ └────────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────────┘
                              ▼  Dockerfile.grpc-tc-mirror (multi-stage)
┌───────────────────────────────────────────────────────────────────────┐
│ Уровень 2: Docker mirror image                                        │
│  Stage 1: gcc84-build-x86_64:0.1.0 (TC's CI base) → копирует          │
│            /usr/local/gcc-8.4 → /opt/x64-native-gcc                   │
│  Stage 2: gcc75-build-arm{,64}:0.1.0 + Python 3.11 standalone         │
│            + Conan 2.27.1 + /opt/x64-native-gcc от Stage 1            │
│            + ENV PROFILE / CONAN_USER_TOOLCHAIN                       │
│            + CMD ./test-astra/run_test_grpc.sh                        │
└───────────────────────────────────────────────────────────────────────┘
                              ▼  docker push proget.../grpc-tc-mirror-{arm,arm64}:0.1.0
┌───────────────────────────────────────────────────────────────────────┐
│ Уровень 3: ProGet (registry & distribution)                           │
│  ┌────────────────────────────┐  ┌─────────────────────────────────┐  │
│  │ Docker feed `main`         │  │ NuGet feed (existing legacy)    │  │
│  │ ├── library/               │  │ ├── grpc.lin.gcc.shared.x64.*   │  │
│  │ │   ├── gcc84-build-x86_64 │  │ │   (от GR113, x86_64)          │  │
│  │ │   ├── gcc75-build-arm    │  │ ├── protobuf.lin.gcc.shared.x64 │  │
│  │ │   ├── gcc75-build-arm64  │  │ └── ...                         │  │
│  │ │   ├── grpc-tc-mirror-arm │  └─────────────────────────────────┘  │
│  │ │   │   :0.1.0  ← pre-bake │  ┌─────────────────────────────────┐  │
│  │ │   └── grpc-tc-mirror-arm64                                       │
│  │ │       :0.1.0  ← pre-bake │  │ Conan feed `conan-internal`     │  │
│  │ └── ...                    │  │ (ещё НЕ создан, см. §6.2)       │  │
│  └────────────────────────────┘  └─────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
                              ▼  docker pull от TC агента
┌───────────────────────────────────────────────────────────────────────┐
│ Уровень 4: TeamCity build (per-arch sandbox / прод)                   │
│  SANDBOX/GRPC_CONAN_ARM/conan                                         │
│   Build Step: `bash ./test-astra/run_prebake.sh arm64`                │
│   Cache: named volume conan-cache-arm64-prebake (~10-15 GB)           │
│   Artifacts: output-arm64-prebake/*.nupkg => arm64/                   │
│                                                                       │
│  test-astra/run_prebake.sh — driver:                                  │
│   1. Auto-detect docker (group / passwordless sudo / fail-fast)       │
│   2. Disk pre-flight (>=30 GB в /var/lib/docker)                      │
│   3. Fresh pull from ProGet                                           │
│   4. docker run + mount conan-cache + конаносборка                    │
│   5. Verify 7 .nupkg                                                  │
└───────────────────────────────────────────────────────────────────────┘
                              ▼  TC Artifacts → ...
┌───────────────────────────────────────────────────────────────────────┐
│ Уровень 5: Distribution (что есть сейчас vs roadmap)                  │
│  СЕЙЧАС: 7 .nupkg в TC Artifacts; consumers скачивают вручную / via   │
│  TC REST API.                                                         │
│                                                                       │
│  ЦЕЛЬ: автоматический `nuget push` в ProGet NuGet feed →              │
│         downstream продукты тянут через `nuget restore` как и         │
│         сейчас. Имя feed'а и согласование с лидом — open question     │
│         (§7.3).                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

### 2.2 Закрытые этапы (chronology)

| Этап | Когда | Что доказали |
|---|---|---|
| Conan recipes для 8 либ (canonical-first) | до 2026-04-30 | offline сборка работает на gcc-12 Debian-bookworm |
| x86_64 фаза — TC-байт-совместимый `.nupkg` | 2026-05-06 | `grpc.lin.gcc.shared.x64.1.78.1.nupkg` 430 MB матчит CI-эталон по имени и размеру; deployer `legacy_nupkg.py` стабилизирован |
| ARM cross-build (armv7hf + arm64) на Astra | 2026-05-08…12 | 14 `.nupkg` собрались, ELF-acceptance 12/12 .so правильной арки (`Tag_CPU_arch: v7 + VFPv3` / `aarch64`) |
| Pre-baked images в ProGet (`grpc-tc-mirror-arm{,64}:0.1.0`) | 2026-05-13 | push 5+5 GB прошёл, `docker pull` round-trip работает |
| E2E build в pre-baked image на dev-astra | 2026-05-13 | 7 `.nupkg` в `output-arm64-prebake/`, размеры в шкале с эталоном |
| TC sandbox arm64 (`SANDBOX/GRPC_CONAN_ARM/conan`) | 2026-05-14 | Build #5 зелёный, 7 .nupkg в TC Artifacts с правильными именами `<pkg>.lin.gcc75.shared.arm64-linaro.<ver>.nupkg` |

### 2.3 Открытые задачи

| Задача | Зависит от |
|---|---|
| TC sandbox **arm** (armv7hf-linaro) | Копирование/параметризация существующего конфига; cold-build ~2h:20m |
| Прод TC-конфиг — куда положить (replace GR121/122 / parallel / отдельный раздел) | Решение лида, §7.1 |
| Confluence-статья | После прод-handoff'а |
| **Опционально:** Conan-feed в ProGet | Создание feed'а в ProGet, обновление профилей в `conan-recipes`, §6.2 |
| **Опционально:** push `.nupkg` в существующий NuGet feed | Согласование с лидом (имя feed'а, версионирование, потенциальные коллизии), §7.3 |

---

## 3. Преимущества vs текущая инфраструктура

### 3.1 Сравнение по конкретным фичам

| Аспект | Текущий TC-флоу | Conan-флоу | Эффект |
|---|---|---|---|
| **Описание зависимостей** | В голове DevOps'а / в комментариях обёртки CMakeLists.txt | Декларативно в `conanfile.py.requires()` + `tool_requires()` | Conflict-detection на этапе `conan install`, до начала сборки |
| **Dependency resolution** | Ручной — сначала собери protobuf, потом grpc, версии вручную | Автоматический граф (Conan строит DAG, заказывает порядок) | Невозможно собрать grpc с несовместимым protobuf — Conan сразу ругнётся |
| **Per-build deterministicность** | Build number + дата | `package_id` (SHA1 от settings+options+deps+recipe_revision) | Точное «этот бинарь = тот бинарь» по hash'у |
| **Cache between builds** | Нет, CleanUp перед каждым | Conan local cache (`/root/.conan2/p/...`) + named volume для контейнера | Inkrementальный билд после изменения одного recipe = 5-15 мин против 4 часов |
| **Cross-agent cache** | Нет (каждый агент собирает с нуля) | Опционально через Conan remote (ProGet Conan feed) — pull готовых package_id | Cold-агент: 5-10 мин (pull) vs 4 часа (full build), §6.2 |
| **Добавить новую либу** | 1-2 дня devops (новый Bitbucket-репо, обёртка CMakeLists, toolchain, TC-проект, Build Steps, параметры) | ~30 мин (copy recipe из conan-center-index, добавить 2 offline-патча, положить tarball, проверить profile) | На roadmap'е IN-353: curl, boost — для них **уже** дешевле сделать Conan-флоу с нуля чем TC |
| **Обновить версию существующей либы** | Переписать обёртку CMakeLists.txt, проверить toolchain, обновить TC-параметры | Bump `conandata.yml` (url + sha256), при необходимости передёрнуть `patches/` | Часы → минуты |
| **Перенос на новую платформу** | Новые TC-конфиги (per-arch, per-OS, per-compiler) | Новый profile + (опционально) новый toolchain.cmake | Часы → ~30 мин |
| **Reproducibility** | «билд от такой-то даты» | `conan list <pkg>/<ver>:<package_id>` точечно | Откат к конкретной версии байт-в-байт |
| **Offline-сборка** | Через ProGet (apt + .tar.gz) — уже работает | Тоже через ProGet + `--no-remote` — работает | Паритет (не выигрыш и не проигрыш) |
| **Поддерживаемый объём кода** | ~30-50 строк CMakeLists.txt обёртки **на либу** | ~20-50 строк `conanfile.py` (mirror upstream) + 0-2 патч-файлов | Сопоставимо, но Conan-флоу шарит инфраструктуру (deployer, профили) между всеми либами |
| **Соответствие индустрии** | Самописное, никого больше не нанимаешь как «знатока нашей TC-обёртки» | Conan 2.x — стандарт C++; человек с базовым Conan'ом включается за день | Onboarding-time для нового разработчика короче |

### 3.2 Конкретные цифры (что подтверждено)

- **Cold-build full tree (7 .nupkg)** на dev-astra: **15-25 мин** (8+ cores).
  На TC агенте `ba-deb12-01` (default Build pool, ~2-4 cores): **2h:21m**
  (Build #4, 2026-05-13).
- **Warm-build (cache hit)**: **5-15 мин** (Build #5, 2026-05-14 — все 7
  package_id найдены в named volume `conan-cache-arm64-prebake`,
  пересборки не было, прошёл только deployer).
- **Image size**: `grpc-tc-mirror-arm64:0.1.0` — 5.13 GB,
  `grpc-tc-mirror-arm:0.1.0` — 4.84 GB. Total push в ProGet — ~10 GB
  (5 GB реально, остальное — shared base layers).
- **Conan cache в named volume** после одной сборки: ~10-15 GB
  (source-распаковки + build folders + final packages Debug + Release).
- **Артефакты на выходе** (для arm64-linaro): 7 .nupkg, totals
  ~490 MB (grpc 401 + protobuf 65 + abseil 12 + openssl 9 + re2 3
  + c-ares 0.5 + zlib 0.2).

### 3.3 Что НЕ улучшилось (честно)

- **Compile-time самой source code** — не лучше и не хуже. Используем
  ту же base CI-image, тот же compiler (gcc 8.4 для x64, gcc 7.5 linaro
  для ARM), те же флаги. Compilation идентична.
- **`.nupkg` выходной формат** — намеренно идентичен (это контракт с
  downstream). Размеры и структура совпадают с CI-эталоном.
- **Toolchain quirks** — `-fuse-ld=gold`, abseil aarch64 patch против
  binutils 2.32 баг — нужны в любом флоу. Это linaro-tax, а не Conan-tax.
- **Offline-сборка** — оба флоу работают в закрытом контуре. Паритет.

---

## 4. Где живут флаги, опции и settings (карта legacy TC → Conan)

Главное изменение для девопса/билд-инженера в повседневной работе:
**флаги теперь живут в git-репо, а не в TC UI.** Это плюс
(code-review, diff, rollback), но требует другого workflow. Этот
раздел — карта «было → стало» с примерами.

### 4.1 Где флаги жили в legacy TC

| Что | Где | Кто видел |
|---|---|---|
| `-march=core2 -fPIC -static-libgcc -static-libstdc++` (compiler) | `cmake/toolchains/linux_x86_64.cmake` в Bitbucket-обёртке (`<lib>` репо) | Любой через git clone обёртки |
| `-DCMAKE_BUILD_TYPE=Release`, `-DBUILD_SHARED_LIBS=ON` | TC Build Step (Release/Debug — отдельные шаги) | TC UI и Build Log |
| `-DCUSTOM_DEFINES="%CustomDefines%"`, `-DGENERATE_MAP=${GENERATE_MAP}` | TC Build Step + TC Parameter `%CustomDefines%` | TC UI Parameters tab |
| `update-alternatives --auto` для GCC 5.3 vs 8.4 | TC Build Step + TC Parameter `useUpgradedBuild` | TC UI |
| Опции пакета (включить TLS, отключить tests) | В CMakeLists.txt обёртки `option(...)` или через `-D<OPTION>=...` в TC Build Step | TC UI + Bitbucket |
| Per-version поведение (`PrereleaseSuffix`) | TC Parameter | TC UI |

Проблема legacy: один тип «настройки» жил в нескольких местах. Чтобы
понять «какой `-D` дойдёт до cmake», нужно было прочитать TC Build
Step, Parameters tab, и `linux_x86_64.cmake` из bitbucket — три разных
источника.

### 4.2 Где флаги живут в Conan-флоу

Каждый тип «настройки» имеет **одно** канонiчное место:

| Тип | Канонiчное место | Влияет на `package_id`? |
|---|---|---|
| **`[settings]`** — дискриминаторы build'а (compiler, version, arch, build_type, cppstd) | Conan profile (`profiles/lin-gcc-aarch64-linaro` etc.) | ✅ Да |
| **`[options]`** — per-package toggles (`shared`, `fPIC`, `with_tests`) | Conan profile `[options]` или `recipe default_options`, override через CLI `-o "<pkg>/*:<opt>=<val>"` | ✅ Да |
| **`[conf]`** ad-hoc compiler/linker flags (`cflags`, `cxxflags`, `sharedlinkflags`, `defines`) | Conan profile `[conf]` section | ❌ Нет (по умолчанию). Можно явно включить, но обычно нежелательно |
| **`[buildenv]`** env-style flags (`CFLAGS`, `CXXFLAGS`, `LDFLAGS`, `CC`, `CXX`) | Conan profile `[buildenv]` section | ❌ Нет |
| **`platform_tool_requires`** — build tools (cmake, perl, ninja) | Conan profile `[platform_tool_requires]` | ✅ Косвенно (через recipe revision) |
| **CMake-only низкоуровневые флаги** (`add_compile_options(-fXYZ)` без видимости Conan'у) | `profiles/toolchains/<arch>.cmake` | ❌ Нет (опасно — кеш не инвалидируется при правке) |

«Один тип = одно место» означает: чтобы понять «какой `-D` дойдёт до
gcc», читаешь **один** профиль + (опционально) `linaro-<arch>.cmake`,
если флаг низкоуровневый.

### 4.3 Прямое соответствие legacy → Conan

| Я хочу… | Legacy TC | Conan |
|---|---|---|
| Поменять compiler version (gcc 5.3 vs 8.4) | TC Parameter `useUpgradedBuild` + update-alternatives | Edit profile `[settings] compiler.version=8.4` или создать `lin-gcc53-x86_64` второй profile |
| Поменять build type (Release vs Debug) | Отдельные TC Build Steps `Build Release` / `Build Debug` | `-s build_type=Release` или edit profile `[settings] build_type=Release`. `run_test_grpc.sh` собирает оба и пакует в один `.nupkg` |
| Static vs shared | TC Parameter + `-DBUILD_SHARED_LIBS=ON` в Build Step | `-o "*/*:shared=True"` (CLI) или profile `[options] *:shared=True`. `run_test_grpc.sh` дефолтит True |
| Включить тесты grpc | `-DgRPC_BUILD_TESTS=ON` в TC Build Step | Опция в `grpc/conanfile.py`: `options = {"with_tests": [True, False]}`, → `-o "grpc/*:with_tests=True"` |
| Добавить custom define (`-DENABLE_FOO=1`) для всех либ | TC Parameter `%CustomDefines%` + `-DCUSTOM_DEFINES=...` в Build Step | `[conf] *:tools.build:defines=["ENABLE_FOO=1"]` в profile |
| То же, но только для grpc | То же, но в TC только GR113 | `[conf] grpc/*:tools.build:defines=["ENABLE_FOO=1"]` |
| Hardening flags (`-fstack-protector`, `-Wl,-z,now`) | Edit `cmake/toolchains/linux_x86_64.cmake` в Bitbucket-обёртке | `[conf] *:tools.build:cxxflags=["-fstack-protector-strong"]` + `*:tools.build:sharedlinkflags=["-Wl,-z,now"]` |
| Cross-compile с linaro toolchain | TC переключал на arm-агент + другая обёртка с `linux_arm-linaro.cmake` | profile `lin-gcc75-arm-linaro` + `[conf] user_toolchain="…/linaro-arm.cmake"` + env-fallback патч в 4 рецептах (§8.1) |
| Override один параметр для одного билда (ad-hoc) | Edit TC Parameter → Run | TC Custom script добавляет к conan install: `-c "user.app:foo=bar"` или `-o "<pkg>/*:opt=val"`, читается из `env.X` TC parameter |
| Изменить parallelism (`-j N`) | TC Build Step CMake args | `[conf] tools.build:jobs=4` в profile или env `CONAN_CPU_COUNT=4` |

### 4.4 Полный пример: profile с флагами

Базовый `lin-gcc75-arm-linaro` (то что у нас сейчас, без compiler-flags
— они в toolchain.cmake):

```
[settings]
os=Linux
arch=armv7hf
compiler=gcc
compiler.version=7.5
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

[platform_tool_requires]
cmake/3.25.1
perl/5.36.0

[buildenv]
PATH=+(path)/opt/linaro-arm-7.5.0/.../bin
CC=arm-linux-gnueabihf-gcc
CXX=arm-linux-gnueabihf-g++
AR=arm-linux-gnueabihf-ar
…

[conf]
*:tools.cmake.cmaketoolchain:user_toolchain=["/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"]
```

Расширенная версия с hardening + custom defines + parallelism +
per-package options:

```
[settings]
os=Linux
arch=armv7hf
compiler=gcc
compiler.version=7.5
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

[platform_tool_requires]
cmake/3.25.1
perl/5.36.0

[options]
*:shared=True
*:fPIC=True
grpc/*:with_tests=False
openssl/*:no_deprecated=True

[buildenv]
PATH=+(path)/opt/linaro-arm-7.5.0/.../bin
CC=arm-linux-gnueabihf-gcc
CXX=arm-linux-gnueabihf-g++
AR=arm-linux-gnueabihf-ar
AS=arm-linux-gnueabihf-as
LD=arm-linux-gnueabihf-ld
NM=arm-linux-gnueabihf-nm
RANLIB=arm-linux-gnueabihf-ranlib
STRIP=arm-linux-gnueabihf-strip
# Дополнительные env-флаги (видны и autotools-пакетам как openssl):
CFLAGS=-fPIC -fstack-protector-strong
CXXFLAGS=-fPIC -fstack-protector-strong
LDFLAGS=-Wl,-z,now -Wl,-z,relro

[conf]
*:tools.cmake.cmaketoolchain:user_toolchain=["/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"]
# Hardening для всех CMake-пакетов в графе:
*:tools.build:cxxflags=["-fstack-protector-strong", "-fPIC"]
*:tools.build:cflags=["-fstack-protector-strong", "-fPIC"]
*:tools.build:sharedlinkflags=["-Wl,-z,now", "-Wl,-z,relro"]
*:tools.build:exelinkflags=["-Wl,-z,now", "-Wl,-z,relro"]
# Custom defines для всех:
*:tools.build:defines=["NDEBUG"]
# Custom defines только для grpc:
grpc/*:tools.build:defines=["GRPC_ENABLE_CUSTOM_X=1"]
# Параллелизм:
tools.build:jobs=4
```

**Префиксы в `[conf]` и `[options]`:**

| Префикс | Кому применится |
|---|---|
| `*:cxxflags=…` | Всем пакетам в графе (host context) |
| `grpc/*:cxxflags=…` | Только grpc и его сборке, не транзитивным deps |
| `&:cxxflags=…` | Только consumer-проекту (у нас нет, мы только либы) |
| Без префикса | Синоним `&:` (только consumer) |
| `&!`, `*!` префиксы | Реверсивные: к consumer'у с минусом, к всем — наоборот (редкие сценарии) |

### 4.5 Как прокинуть флаг из TC ad-hoc (без правки профиля)

Если нужно **разово** собрать с особым флагом, не плодя профили:

**В TC Build Configuration → Parameters → добавь:**
```
env.EXTRA_DEFINES = "-DENABLE_FOO=1 -DDEBUG_X=1"
```

**В Custom script:**
```bash
#!/bin/bash
set -euo pipefail

# Прокидываем env vars в docker run внутри run_prebake.sh
# Создаём ad-hoc оверрайд через CONAN_*_FLAGS env (читаются профилем
# через jinja2 templating если у нас на это настроено), или через
# дополнительный аргумент к conan install (через wrapper).
export CONAN_EXTRA_CXXFLAGS="${EXTRA_DEFINES:-}"

./test-astra/run_prebake.sh arm64
```

В `run_test_grpc.sh` (или wrapper-скрипте) подхватываем:
```bash
EXTRA_CONF=""
if [[ -n "${CONAN_EXTRA_CXXFLAGS:-}" ]]; then
    EXTRA_CONF="-c tools.build:cxxflags+=[\"$CONAN_EXTRA_CXXFLAGS\"]"
fi

conan install --requires=grpc/1.78.1 \
    -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
    $EXTRA_CONF \
    --build=missing --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py
```

Это **не лучшая практика** (флаг не в git, не воспроизводимо), но
работает для разовых проб. Для долгого использования — копировать
профиль и положить флаг туда: `lin-gcc75-arm-linaro-debugfoo`.

### 4.6 Как проверить что флаг реально дошёл до gcc

После добавления флага и пересборки:

```bash
# 1. Что Conan видит из профиля:
conan profile show -pr:h=lin-gcc75-arm-linaro -pr:b=lin-gcc84-x86_64

# 2. Что попало в сгенерированный CMakeToolchain:
ls /root/.conan2/p/b/<pkg-hash>/b/build/Release/generators/
cat /root/.conan2/p/b/<pkg-hash>/b/build/Release/generators/conan_toolchain.cmake \
    | grep -iE 'cxxflags|cflags|defines'

# 3. Что попало в сгенерированный AutotoolsToolchain (для autotools пакетов):
cat /root/.conan2/p/b/<pkg-hash>/b/build/Release/generators/conanbuild.sh \
    | grep -iE 'CXXFLAGS|CFLAGS|LDFLAGS'

# 4. Что реально передалось компилятору (последняя инстанция истины):
grep -h 'arm-linux-gnueabihf-g++.*\.cc\.o' \
    /root/.conan2/p/b/<pkg-hash>/b/build/Release/CMakeFiles/*.dir/*.make \
    | head -1
```

Если флаг не появляется в (4), но появляется в (2)/(3) — значит cmake
его принял, но конкретный target его не использует (`PRIVATE` vs
`PUBLIC` issue в самом recipe). Если не появляется в (2) — `[conf]`
ключ не тот, проверь `conan config show <key>` для правильного имени.

### 4.7 Что НЕЛЬЗЯ делать (анти-паттерны)

1. **`add_compile_options(-fXYZ)` в `linaro-<arch>.cmake` для флага влияющего на ABI.**
   CMake-уровень невидим Conan'у, package_id не пересчитывается. Если
   ты изменил `-fno-rtti` → `-frtti` в toolchain.cmake — Conan **возьмёт
   старый кешированный пакет**, ABI поедет, downstream сломается без
   видимых причин. Такие флаги должны жить в `[conf] tools.build:cxxflags`
   (тогда они хэшируются в package_id, кеш инвалидируется).

2. **Конфигурация через CLI `-c` без записи в profile.**
   Делает билд невоспроизводимым (нужно помнить какие именно `-c` были
   у того release-билда). Для разовой пробы — OK; для постоянного — в
   профиль.

3. **Дублирование флагов в `[buildenv]` CFLAGS и `[conf] tools.build:cxxflags`.**
   Они оба применятся, флаг задвоится в командной строке gcc. Обычно
   не критично (gcc последний `-O3` побеждает первый `-O2`), но
   некоторые комбинации (`-static-libgcc -static-libgcc`) могут давать
   warning'и или быть отвергнуты strict линкером.

4. **Override `[settings] compiler.cppstd` для отдельного пакета через `[options]`.**
   `cppstd` — settings, не options. Можно только глобально в профиле
   или per-package через `<pkg>/*:compiler.cppstd=20` в `[settings]`
   (с двоеточием — это работает в Conan 2.x).

---

## 5. Что можно ещё улучшить (roadmap)

### 5.1 Краткосрочное (1-4 недели)

| Улучшение | Что даст | Сложность |
|---|---|---|
| **arm-арка в TC sandbox** | Полная пара arm + arm64 в sandbox; готовность для лида | Низкая — копирование конфига, ~2h:20m cold-build |
| **TC parameterization (`env.ARCH`)** | Один Build Configuration Template + два child-конфига (`Sandbox_GrpcConanArm_Arm`, `Sandbox_GrpcConanArm_Arm64`) — DRY | Средняя — TC Template + parametrized image/profile |
| **Cleanup script** для conan-cache volume retention | Контролируемое удаление volume'ов старше N дней — не накапливаются на агентах | Низкая — cron + `docker volume ls --filter` |
| **Build Mirror Image как отдельный TC config** | Авто-обновление `grpc-tc-mirror-{arm,arm64}:NEXT_VER` при изменении `Dockerfile.grpc-tc-mirror` | Средняя — VCS Trigger + `docker build/push` step + service account для ProGet push |

### 5.2 Среднесрочное (1-3 месяца)

| Улучшение | Что даст | Сложность |
|---|---|---|
| **ProGet Conan feed** | Cross-agent cache — новый агент собирает за 5-10 мин (pull) вместо 4 часов (build) | Средняя — создать feed, `conan remote add`, conan upload в build agent, переключить consumers на `--remote=elara-proget` |
| **Push `.nupkg` в существующий NuGet feed** | Boomerang — наши arm/arm64 артефакты попадают туда же где x86_64, downstream продукты `nuget restore` их без изменений | Низкая технически, **высокая** на согласование (нужен лид + знание точного feed'а) |
| **Upgrade Conan 2.27.1 → 2.28+** | Выкинуть env-fallback патчи в 4 рецептах (это workaround под баг 2.27.1 с transitive `[conf]` пропагацией) | Низкая — обновить wheel в `packages-linux/`, re-test |
| **Retention rules на ProGet Docker feed** | Старые `:0.x.0` теги mirror-образов авточистка → меньше storage burn | Низкая — ProGet UI, Settings → Retention |
| **Service account** на ProGet | TC агент логинится под scoped acct, не под админкой; меньше blast radius на компрометацию | Низкая — ProGet UI, User Management |

### 5.3 Долгосрочное (3-12 месяцев, Phase 3 IN-353)

| Улучшение | Что даст | Сложность / зависимости |
|---|---|---|
| **Downstream consumes Conan напрямую** через `conan install` / `find_package` вместо `nuget restore .nupkg` | Выкинуть `legacy_nupkg.py` deployer полностью; downstream получает нативные Conan-пакеты со всеми метаданными | **Высокая** — затрагивает потребителей (продуктовые билды), требует синхронизированный переход; **только** после того как Conan-флоу полностью стабилизирован и в проде |
| **Расширение Conan-recipes на curl/boost/прочие либы из roadmap'а IN-353** | Постепенная миграция всего стека third-party C++ на единый source-of-truth | Средняя per-lib (~30-60 мин) — выигрыш растёт нелинейно с числом либ |
| **Per-arch агенты в TC** (debian + arm-emulation + arm64-emulation) | Возможность собирать **нативно** на ARM-хосте, минуя cross-build | **Высокая** — нужны физические/виртуальные ARM-агенты, qemu или Apple Silicon |

---

## 6. Роль ProGet (детально)

### 6.1 Что уже используется

ProGet (`proget.inc.elara.local`) — единственный internal registry в
этой схеме. Все три типа feed'ов, которые мы используем или планируем,
живут на нём:

#### Docker feed `main` — **используется**

Хранит:
- **Base CI-images:** `library/gcc84-build-x86_64:0.1.0`,
  `library/gcc75-build-arm:0.1.0`, `library/gcc75-build-arm64:0.1.0`,
  `library/build-tools:0.1.0`, `library/nuget:4.8.1`.
- **Pre-baked mirror images (новое):** `library/grpc-tc-mirror-arm:0.1.0`,
  `library/grpc-tc-mirror-arm64:0.1.0` — наш вклад.

Pull-флоу: TC-агент `docker pull proget.inc.elara.local/main/library/...`.
Push-флоу (для mirror images): pre-bake на dev-astra или будущий TC
config «Build Mirror Image» — `docker login + docker push`.

#### NuGet feed (имя пока не подтверждено, существующий) — **используется частично**

Хранит:
- Legacy `.nupkg` от текущих TC-конфигов (`GR113`, etc.) —
  `grpc.lin.gcc.shared.x64.<ver>.nupkg` и аналоги для protobuf/abseil/etc.

Pull-флоу: downstream продукты `nuget restore -Source <feed-url>` через
`packages.config`/`.csproj` deps.

Push-флоу (что мы хотим добавить):
- наши arm/arm64 `.nupkg` —
  `grpc.lin.gcc75.shared.arm64-linaro.<ver>.nupkg` и т.д.
- Имена **не конфликтуют** с x86_64 (`<id>` в `.nuspec` разные: `x64` vs
  `arm64-linaro`), коллизий не будет.
- **Open question:** конкретно в какой feed пушить (sandbox-feed для
  валидации vs боевой; согласование с лидом).

### 6.2 Что можно добавить

#### Conan feed `conan-internal` (ещё НЕ создан)

**Что хранит:** Conan recipes + бинарные packages per package_id.

**Структура (после `conan upload "*/*" -r elara-proget --confirm`):**

```
proget.inc.elara.local/conan/conan-internal/
└── grpc/1.78.1/_/_/
    └── revisions/<recipe_revision_hash>/
        ├── export/
        │   ├── conanfile.py
        │   ├── conandata.yml
        │   └── patches/...
        └── packages/
            ├── <package_id_for_arm-linaro_Release_shared>/
            ├── <package_id_for_arm64-linaro_Release_shared>/
            ├── <package_id_for_x86_64_Release_shared>/
            ├── <package_id_for_arm-linaro_Debug_shared>/
            └── ...
```

Один recipe — N бинарных packages (по одному на каждую комбинацию
settings/options/deps).

**Что даёт:**

- **Cross-agent cache.** Builder-агент собрал → `conan upload`. Любой
  consumer-агент (включая TC-сборщик у downstream-проекта) → `conan
  install --remote=elara-proget --build=missing` → пакеты приходят
  готовыми за 30 сек вместо 4-часовой сборки.
- **Бинарный rollback.** «Соберись с grpc/1.78.1#abc123 — тем самым
  binary что был в проде на прошлой неделе» — Conan по package_id
  найдёт в remote и поднимет точно его.
- **Гибкая retention.** Удалить все package_id для устаревшего
  recipe_revision — одна команда, ProGet прочистит blob storage сам.

**Размер на ProGet** (примерно): 8 recipes × ~6-12 package_id (наши
арки × build_types × shared) × 5-50 MB бинарь = **1-3 GB на всё**.
Это меньше чем один наш Docker mirror image (5 GB).

**Что нужно настроить:**

1. ProGet UI → Feeds → New Feed → Type: Conan → Name: `conan-internal`.
2. Service account `tc-conan-uploader` с правами `Feed Administrator`
   на `conan-internal`. Credentials в TC Project Parameter
   (`env.CONAN_PASSWORD` тип password).
3. В `run_test_grpc.sh` или отдельном post-step:
   ```bash
   conan remote add elara-proget https://proget.inc.elara.local/conan/conan-internal/
   conan remote login elara-proget tc-conan-uploader -p "$CONAN_PASSWORD"
   conan upload "*/*" -r elara-proget --confirm
   ```
4. Consumer agents добавляют тот же remote (но логинятся под
   read-only acct) + `conan install --remote=elara-proget`.

#### Retention policies (для обоих feed'ов)

ProGet поддерживает retention rules (`Settings → Retention`):

- **Docker feed:** «Удалять теги старше 30 дней, кроме `:latest` и
  `:1.0.0`+» — наши `:0.1.0`, `:0.2.0` старые автоматически очистятся.
- **Conan feed:** «Удалять package revisions старше последних 5 для
  каждого package_id» — recipe revisions накапливаются при каждом
  изменении `conanfile.py`, retention их сдерживает.

Без retention — feed бесконечно растёт, через год storage заполнен
старыми ревизиями которые никто не использует.

#### Service accounts с scoped permissions

Сейчас у нас всё под одной админ-учёткой (что у пользователя есть).
Лучшая практика:

| Account | Scope | Использование |
|---|---|---|
| `tc-docker-puller` | Read on Docker feed `main` | TC agents для pull mirror images |
| `tc-docker-pusher` | Write on Docker feed `main`, namespace `library/grpc-tc-mirror-*` | Build Mirror Image config (когда заведём) |
| `tc-conan-uploader` | Write on Conan feed `conan-internal` | Builder TC config после успешного билда |
| `tc-conan-puller` | Read on Conan feed `conan-internal` | Consumer agents |
| `tc-nuget-pusher` | Write on NuGet feed | Publish-step после успешного билда |

Это **future work**, пока админка работает — не блокер.

### 6.3 Что ProGet не покрывает

| Не делает ProGet | Кто делает |
|---|---|
| TC build configs | TeamCity (его XML конфиги в TC Data Directory) |
| Git/VCS recipe-кода | Bitbucket (`bitbucket.inc.elara.local`) |
| Compilation сама | Docker container на TC агенте |
| Downstream продукты (как они тянут пакеты) | Их собственные `.csproj` / `packages.config` |
| Jira-тикеты, документация | Jira + Confluence |

ProGet — **только storage + retrieval** для пакетов разных типов.
Полноценный artifact repository, не CI и не VCS.

---

## 7. Open questions / решения нужны от лида

### 7.1 Куда положить прод-TC-конфиг (после успешного sandbox)

Три варианта, у каждого свои trade-offs:

| Вариант | Плюсы | Минусы |
|---|---|---|
| **A. Заменить `GR121`/`GR122` in-place** | Артефакты идут по тем же URL/в тот же NuGet feed под теми же именами; downstream-продукты ничего не меняют | Blast radius: snapshot/artifact зависимости от downstream-проектов на `GR121`/`GR122` могут сломаться (если они есть). Нужен audit зависимостей перед заменой. |
| **B. Создать `GR123` + `GR124` параллельно** | Zero-risk для downstream (старые `GR121`/`GR122` работают); можно поэтапно переключать потребителей; легко rollback | Дублирование инфры — поддерживать оба пути несколько месяцев; downstream-продукты в какой-то момент всё равно надо переключить |
| **C. Отдельный раздел `SURA2/COMPONENTS/CONAN/GRPC`** | Чисто разделяет migration-фазу от legacy; будет естественное место для остальных Conan-миграций (zlib, abseil, ... из IN-353) | Structural change в TC иерархии; grep `SURA2/COMPONENTS/CMAKE/` больше не покрывает grpc; потенциальная путаница «где живёт grpc» |

**Запрос лиду:** какой вариант, какие потребители GR121/122 нужно
учесть, deadline.

### 7.2 Конфиг «Build Mirror Image» — нужен ли отдельный

Сейчас pre-bake mirror image (`grpc-tc-mirror-arm{,64}:0.1.0`) делается
вручную с dev-astra. Когда image обновится (новая версия Conan, новая
linaro toolchain, новый рецепт что-то ломает) — нужна пересборка.

**Варианты:**

- **A. Отдельный TC билд-конфиг «Build Mirror Image».** VCS trigger на
  изменение `Dockerfile.grpc-tc-mirror` или `packages-linux/`. Build
  Step: `docker build --build-arg ... + docker push`. Snapshot dep на
  него у sandbox/прод сборщика — если image устарел, сначала обновится.
- **B. Manual ad-hoc rebuild на dev-astra.** Когда нужно — человек
  заходит на dev-astra, делает `docker build + push`. Не часто (раз в
  месяц-два, при значимых изменениях).

**Запрос лиду:** A или B. (А — лучше для долгосрочной поддержки, но это
ещё один structural билд-конфиг, его место в TC иерархии — тоже
вопрос.)

### 7.3 Push `.nupkg` в боевой NuGet feed

Сейчас наши `.nupkg` (arm/arm64) — в TC Artifacts, не в ProGet NuGet.
Чтобы downstream продукты их получили, нужно их пушнуть в существующий
NuGet feed где сейчас лежит `grpc.lin.gcc.shared.x64.*` от GR113.

**Вопросы лиду:**
- Конкретное имя feed'а (`nuget`? `internal-nuget`? `third-party-cpp`?).
- Какие версии пушить (только tagged releases?  каждый успешный билд?).
- Coexistence с `GR121`/`GR122` (если они тоже пушат свои arm
  артефакты, не будет ли коллизий — нужно проверить имена).
- Когда переключать downstream-продукты на «новые» имена
  `<pkg>.lin.gcc75.shared.arm64-linaro.<ver>` (если они вообще раньше
  получали arm-артефакты — это надо узнать).

### 7.4 Conan feed — создавать ли сейчас или после прод-handoff'а

ProGet Conan feed — большая фича (см. §6.2), решает cross-agent cache
проблему. Но:

- Технически независима от прод-handoff'а — можно заводить когда
  угодно.
- Требует ProGet админ-усилия (создать feed) и время на
  experiment (как настроить conan upload step, какие service accts).

**Запрос лиду:** заводим сейчас (параллельно с прод-handoff'ом, чтобы
запустить сразу на проде) или через 1-2 месяца после стабилизации?

---

## 8. Известные quirks и их статус

### 8.1 Conan 2.27.1 — `[conf] *:user_toolchain` не пропагируется на transitive deps

**Симптом:** при cross-build для ARM, `--requires=grpc/...` пересобирает
abseil как транзитивную, и в этом контексте `tools.cmake.cmaketoolchain:user_toolchain`
теряется → системный `/usr/bin/c++` (Stretch g++ 6.3) → `policy_checks.h:59
"GCC 7 or higher"`.

**Workaround (в `master`):** env-fallback patch в `generate()` четырёх
рецептов:

```python
# abseil/, re2/, protobuf/, grpc/  conanfile.py
_user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
if _user_tc and str(self.settings.arch) in (
        "armv7", "armv7hf", "armv7s",
        "armv8", "armv8_32", "armv8.3", "arm64ec"):
    tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
tc.generate()
```

Arch-гейт критичен: без него toolchain leak'ает в build context (x86_64
для protoc), и `arm-linux-gnueabihf-g++ -m64` падает.

**Когда выкинется:** Conan 2.28+ скорее всего фиксит. План — bump'нуть
Conan, проверить что без патчей работает, удалить env-fallback из 4
рецептов.

### 8.2 `[buildenv]` host-profile leak в build context

**Симптом:** профиль `lin-gcc75-arm-linaro` со своим `[buildenv]` (CC,
CXX, AR/AS/LD/NM/RANLIB/STRIP с префиксом `arm-linux-gnueabihf-`)
пробрасывает эти переменные **и** в build context (где должен быть
x86_64 native compiler для protoc).

**Workaround:** профиль `lin-gcc84-x86_64` (который используется как
`pr:b`) имеет **явный** `[buildenv]` с native gcc — он перекрывает leak.

**Когда выкинется:** возможно Conan 2.28+ это разруливает автоматически
(separate buildenv per context). Тогда explicit buildenv в `lin-gcc84-x86_64`
можно ослабить или удалить.

### 8.3 Linaro 7.5 binutils 2.32 — BFD-ld баг с `.strtab corruption`

**Симптом:** cross-link против shared abseil `.so` падает с `invalid
string offset .strtab`.

**Workaround:** `CMAKE_*_LINKER_FLAGS_INIT="-fuse-ld=gold"` в
`profiles/toolchains/linaro-{arm,aarch64}.cmake`. Gold не падает.

**Когда выкинется:** при апгрейде linaro toolchain — но это вне нашей
power (linaro в CI base image, обновление = новый ProGet tag
`gcc75-build-arm{,64}:0.2.0` от devops). Не наш scope.

### 8.4 abseil aarch64 — `xpaclri` (ARMv8.3-A inline asm) против binutils 2.32

**Симптом:** abseil 20250127 на aarch64 содержит `xpaclri` (ARMv8.3
pointer-auth hint), но linaro 7.5 binutils 2.32 эту мнемонику не знает.

**Workaround:** patch `abseil/patches/20250127.0-0001-stacktrace-aarch64-binutils232.patch`,
заменяет `xpaclri` на `hint #7` (NOP-encoded equivalent). Зарегистрирован
в `abseil/conandata.yml`.

**Когда выкинется:** обновление linaro до 2020.* (binutils 2.34+). Не
наш scope.

### 8.5 `file(1)` на Stretch — quirk на protobuf aarch64 `.so`

**Симптом:** `file libprotobuf.so.5.29.6` (на arm64 .nupkg) сообщает
`ELF 64-bit LSB ARM, EABI5` вместо ожидаемого `aarch64`.

**Причина:** `file(1)` magic-database на Stretch конфликтует EM_ARM (40)
и EM_AARCH64 (183) при EABI-флаге.

**Не bug:** `readelf -h` (authoritative) показывает `Machine: AArch64` —
бинарь корректный.

**Документация:** HELP.txt блок `[9a]`. Не workaround в коде, это
"знать и не пугаться".

### 8.6 ARM base images — путь `/opt/linaro-aarch64-7.5.0/` vs `/opt/linaro-arm64-7.5.0/`

**Симптом:** в `gcc75-build-arm64:0.1.0` корень linaro лежит в
`/opt/linaro-arm64-7.5.0/`, а не в `/opt/linaro-aarch64-7.5.0/` (как
можно было бы ожидать по имени target tuple).

**Hardcoded в:** `profiles/toolchains/linaro-aarch64.cmake`.

**Не bug:** просто так базовый образ устроен. Если когда-нибудь devops
переименует — нужно поправить toolchain.cmake.

---

## 9. FAQ

**Q: «Зачем `legacy_nupkg.py` deployer? Conan native package недостаточно?»**
A: Downstream-продукты сейчас потребляют `.nupkg` через `nuget restore`
+ `packages.config`/`.csproj`. У них там `<package id="grpc.lin.gcc.shared.x64"
version="..."/>`. Если бы мы выкатили нативный Conan-package, они бы не
смогли его принять без правок ВСЕХ потребителей. Поэтому переходный
deployer — пакуем Conan-output в legacy format. Когда downstream
мигрирует на Conan-consume — deployer уходит.

**Q: «Зачем pre-bake image в ProGet, если test_arm_cross.sh всё равно работает?»**
A: `test_arm_cross.sh` каждый раз делает `docker build` mirror image
(~3-5 мин overhead на каждом TC прогоне). Pre-baked image: TC `docker
pull` immutable image (быстро, кешируется на агенте) и сразу `docker
run`. Плюс — ProGet image immutable и проверяемый через digest, не
зависит от состояния VCS на момент build'а.

**Q: «Почему conan-cache отдельный per-arch (arm-prebake vs arm64-prebake)?»**
A: Package_id зависит от `settings.arch`. Кеш для armv7hf и кеш для
arm64 — это разные package_id'ы, разные бинарники. Mixing их в одном
volume не сэкономит — Conan их хранит как разные пакеты. Разделяем на
два volume'а просто для понятности и для retention/cleanup.

**Q: «Что если ProGet упадёт?»**
A: Локальные кеши на dev-astra и TC агентах продолжат работать (они
держат уже скачанные images и conan packages). Новые билды на свежих
агентах — `docker pull` упадёт, билд не сможет стартовать. Это
single-point-of-failure всей нашей инфры (как и Bitbucket, и TC сам).
Backup ProGet — это уже devops-вопрос на уровне инфры.

**Q: «Можно ли откатиться к старому TC-флоу?»**
A: Да, `GR113`, `GR121`, `GR122` живы и трогать их без согласования с
лидом нельзя. Наш sandbox-флоу полностью независим. В случае проблем с
прод-handoff — остаёмся на legacy, ничего не сломается.

**Q: «Сколько времени займёт миграция остальных либ из IN-353 (curl, boost)?»**
A: Для одной либы среднего размера (curl): ~30 мин на recipe + тарбол +
sanity-build. boost — больше, потому что многомодульная (компоненты
filesystem, regex, system и т.д. отдельные packages), ~1-2 дня. Это
**гораздо меньше** чем эти же либы через TC-флоу (там были бы дни-недели
на каждую).

---

## 10. Ссылки

- `test-astra/HELP.txt` — нумерованные диагностические блоки `[0]`…`[10]`
  + `[X]`. Конкретные команды для troubleshooting.
- `test-astra/NEXT_STEPS.md` — историческая хроника ARM-фазы IN-658
  (Шаги 1-3, 4a/4b развилки, 4b.0-4b.6 микро-шаги).
- `test-astra/TESTING_ARM.md` — runbook «как собрать 14 .nupkg на
  Astra/CI».
- `test-astra/run_prebake.sh` — driver для prebake-acceptance.
- `Dockerfile.grpc-tc-mirror` — multi-stage build mirror image.
- `extensions/deployers/legacy_nupkg.py` — Conan deployer →
  legacy-compatible `.nupkg`.
- `README.md` (root) — общий overview проекта `conan-recipes`.
- Jira: **IN-353** (зонт), **IN-658** (текущая ARM-фаза).
- ProGet UI: `https://proget.inc.elara.local`.
- TeamCity: `https://teamcity.inc.elara.local`,
  `SANDBOX/GRPC_CONAN_ARM/conan` (BuildTypeId `Sandbox_GrpcConanArm_Conan`).

---

## 11. История изменений

| Дата | Что |
|---|---|
| 2026-05-14 | Создан документ. Описано закрытие TC sandbox arm64. |
| 2026-05-14 | Добавлен §4 «Где живут флаги, опции и settings» — карта legacy TC → Conan + примеры. Сдвинута нумерация §5-§11; обновлены cross-references; в TL;DR добавлен пункт 5. |
