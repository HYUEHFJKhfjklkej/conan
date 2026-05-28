# Инфраструктура проекта conan-recipes

> **Аудитория:** новый сотрудник в команде, DevOps, лид, архитектор.
> **Цель документа:** дать единое описание того, из каких сервисов, образов,
> агентов, тулчейнов и конфигов состоит build-инфраструктура `conan-recipes`,
> чтобы можно было ввести нового человека в курс дела за один просмотр.
>
> Документ **комплементарен** `DEVOPS-RUNBOOK.md`: там — операционные команды
> ("как собрать и опубликовать"), здесь — описание самой среды ("из чего она
> сделана"). Если ищете команды — идите в runbook; если "почему именно так
> устроено" — оставайтесь здесь.

---

## 1. Обзор архитектуры

Высокоуровневая схема потока сборки `.nupkg`-артефактов от исходников до
потребителя:

```text
                   ┌──────────────────────────┐
                   │   Bitbucket Server        │
                   │  bitbucket.inc.elara      │
                   │  (project SU2 / CYPA2)    │
                   └──────────────┬───────────┘
                                  │ git clone / git push (HTTP, LDAP)
                                  ▼
            ┌──────────────────────────────────────────┐
            │           TeamCity (incvc / TC)            │
            │  ┌────────────────────────────────────┐    │
            │  │  TC server (incvc.inc.elara.local) │    │
            │  └─────────────────┬──────────────────┘    │
            │   28 build agents  │  (vSphere VMs,         │
            │   default / sandbox│   Debian / Astra /     │
            │   / sign / qa pool │   Ubuntu / Win)        │
            └──────┬─────────────┴───────────┬────────────┘
                   │ docker pull / docker run│ pip install (offline)
                   ▼                         ▼
   ┌──────────────────────────┐    ┌─────────────────────────────┐
   │  ProGet (Docker registry) │    │  ProGet (NuGet feed)         │
   │  proget.inc.elara/main    │    │  proget.inc.elara/main       │
   │  gcc84-build-x86_64:0.1.0 │    │  abseil/protobuf/grpc.nupkg  │
   │  gcc75-build-arm:0.1.0    │    │  + .1 coexistence слоты      │
   │  gcc75-build-arm64:0.1.0  │    └─────────────────────────────┘
   └──────────────────────────┘                  │
                                                 │ nuget restore / SDK
                                                 ▼
                                      ┌─────────────────────┐
                                      │ Downstream products  │
                                      │  el_conf, grpc_sdk,  │
                                      │  sura ...            │
                                      └─────────────────────┘
```

**Поток в словах:**

1. Разработчик пушит изменение в `conan-recipes` на Bitbucket (master).
2. TeamCity запускает sandbox/prod-конфиг, выбирает build-агента из пула.
3. Агент `git clone` репо, билдит локально образ `grpc-tc-mirror` из
   `Dockerfile.grpc-tc-mirror` (base — `gcc84-build-x86_64:0.1.0` из ProGet).
4. `docker run grpc-tc-mirror` запускает `test-astra/run_test_grpc.sh` (или
   `run_grpc_1601_upstream.sh` для legacy-линии 1.60.1) — внутри контейнера
   `conan export → conan install → deployer legacy_nupkg.py`.
5. На выходе 7 `.nupkg` в `output-*/`. TeamCity публикует их как Build
   Artifacts; вручную/автоматически они уходят `nuget push` на ProGet NuGet
   feed.
6. Downstream-команды (`el_conf`, `grpc_sdk`, `sura`) тянут пакеты по
   legacy-именам в их `_dependencies` / `packages.config`.

Все сервисы — внутри закрытой сети `172.17.0.0/24`. Доступа в публичный
интернет нет ни у агентов, ни у dev-VM пользователя.

---

## 2. Bitbucket (Git)

### URL и проекты

- **Сервер:** `http://bitbucket.inc.elara.local` (Bitbucket Server, on-prem).
- **Аутентификация:** Active Directory (LDAP), пара `Git.Username` /
  `Git.Password` хранится в TeamCity как параметры конфигурации (Password
  type).
- **Project keys:**
  - `SU2` — "СУРА 2", главный проект, где живёт CMake-фреймворк (`cmake/`
    папка вшита в каждый репозиторий, ~27 модулей).
  - `CYPA2` / `SURA2` — старые ключи, частично пересекаются.

### Репозитории

| Репо | Назначение | Default branch |
|---|---|---|
| `conan-recipes` | Рецепты Conan 2.x для third-party (gtest/zlib/abseil/c-ares/re2/protobuf/openssl/grpc) | `master` (зеркало GitHub `HYUEHFJKhfjklkej/conan.git`) |
| `grpc_sdk` | Внутренний SDK поверх grpc, потребитель наших `.nupkg` | `develop` |
| `el_conf` | Сервис конфигурации, потребитель | `develop` |
| `sura` | Основной продукт линии СУРА | `develop` |
| `zlib`, `abseil`, `protobuf`, `grpc` (legacy forks) | Старые форки, остаются как ground-truth для байт-совместимости | `develop` |

### Особенности

- **Default branch у legacy-репо — `develop`**, у нашего `conan-recipes` —
  `master`. Это исторически.
- В каждом legacy-репо корне лежит папка `cmake/` с фреймворком
  (`PlatformHelper.cmake`, `InstallComponent.cmake`,
  `ResolveDependencies.cmake`, ...). Все ~27 `.cmake` синхронизированы между
  репо одинаковыми коммитами.
- Web UI: `bitbucket.inc.elara.local/projects/SU2/repos/<pkg>/browse/cmake/`.

### Контракт коммита

- В `conan-recipes/master` запрещено пушить `CLAUDE.md` и `ARCHITECTURE.md`
  (оба в `.gitignore` — это локальные scratchpad'ы для maintainer'а и для
  Claude Code).
- Изменения в `conandata.yml` (URL/sha256) — не делать. Локальные правки
  идут через `<pkg>/patches/<version>/*.patch`, регистрируются в
  `conandata.yml → patches → "<ver>"`.

---

## 3. TeamCity (CI/CD)

### Сервер

- **vCenter:** `incvc.inc.elara.local`.
- **TC server VM:** живёт в `INC / Services / `, отдельная виртуалка
  (детали — на схеме `reference_vsphere_layout.md`).
- **Web UI:** TeamCity 2024.x (точная версия — у devops).
- **Всего агентов зарегистрировано:** 28 (по состоянию на 2026-05-12).

### Build-агенты (vSphere)

Папка vCenter `INC / BuildAgents/` содержит:

```text
BuildAgents/
├── clones/                   # заготовки для клонирования новых агентов
├── sign-agents/              # отдельный пул для Guardant Protect (подпись)
├── temp-agents/              # временные, например ba-temp-deb12-dotnet
├── v1/, v2/                  # версии шаблонов
├── ba-rosa-01.inc.elara.local      # Rosa Linux
├── ba-ubu-01.inc.elara.local       # Ubuntu
├── ba-win-10.inc.elara.local       # Windows 10
└── ba-deb-XX.inc.elara.local       # Debian (несколько)
```

**Пулы агентов:**

- **Default pool** — основной, держит `ba-deb12-01` (Debian 12), агенты
  для повседневной сборки.
- **SANDBOX pool** — `ba-deb-pvs (disabled)`, `ba-tst-astra-01`. Часто
  выключены, включаются вручную из TC Admin → Agents.
- **QA Agents**, **Stand-Win7**, **sign-agents** — специальные пулы,
  отдельные машины.

### Конфиги, связанные с conan-recipes

**Прод (legacy, ручные TC-скрипты — заменяются на conan-based):**

- `GR113` — Linux x64 DynamicRT (grpc, protobuf, zlib) — собирает
  `<pkg>.lin.gcc84.shared.x86_64.*.nupkg` старыми shell-скриптами через
  CMake-фреймворк напрямую.
- `GR121` — Linux x64 StaticRT — статические варианты тех же пакетов.
- `GR122` — ARM cross — armv7hf через linaro.
- `GR120` — упаковочный/публикующий конфиг (`nuget push` на ProGet).

**Sandbox (новые conan-based):**

- `SANDBOX/GRPC_CONAN_ARM/conan` (BuildTypeId `Sandbox_GrpcConanArm_Conan`)
  — arm64 cross через `test-astra/run_prebake.sh arm64`. Закрыт 2026-05-14,
  builds #4/#5 успешны, артефакты в `arm64/*.nupkg`.
- `SANDBOX/GRPC_CONAN_ARM/conan_arm` — armv7hf, аналогичный (в работе).

### Ключевые параметры TC-конфига (из `GS113 BUILD Linux x64 DynamicRT`)

Видно прямо в TC → Edit Configuration → Parameters:

| Параметр | Значение | Назначение |
|---|---|---|
| `ARMHost.Address` | `172.17.0.167` | ARM-тестовый хост для downstream-прогона |
| `Ftp.Address` | `172.17.0.5` | FTP-сервер артефактов |
| `DC.Address` | `incdc1.inc.elara.local` | Active Directory (LDAP) |
| `Git.Address` | `http://bitbucket.inc.elara.local` | Bitbucket |
| `Docker.Repository` | `proget.inc.elara.local/main` | ProGet Docker registry |
| `buildImageName` | `gcc84-build-x86_64` | Имя base-образа |
| `buildImageVersion` | `0.1.0` | Тег base-образа |
| `Coverage` | `True` | Включён lcov (DynamicRT debug) |
| `IsRelease` | `False` | DynamicRT = Debug |
| `IsDisableStatic` | `True` | Только shared в DynamicRT |
| `Guardant.Url` | `http://172.17.0.89:5000/api/executor` | Лицензионный сервер |

В StaticRT/Release конфигах: `Coverage=False`, `IsRelease=True`,
`IsDisableStatic=False`.

### Сценарий миграции legacy → conan

См. `STATUS.md` и `DOWNSTREAM-MIGRATION.md`. Окончательная структура
TC-конфигов (replace GR121/GR122 in-place vs параллельно vs отдельный
раздел `SURA2/COMPONENTS/CONAN/`) — на согласовании с лидом.

### 3.7 Контракт линкажа (важно)

В именах легаси `.nupkg` сегмент `shared` / `static` обозначает **slot
runtime-CRT** (Windows: MSVC `/MD` vs `/MT`; Linux: динамический libstdc++
vs `-static-libstdc++`), а **не** способ линковки самих наших библиотек.

| Свойство | Значение для IN-658 |
|---|---|
| **Slot-тег в имени `.nupkg`** | `.shared.x86_64.` (DynamicRT, GR113-эквивалент) |
| **Что лежит внутри `lib/native/<suffix>/`** | Static `.a` файлы (всегда) |
| **Как downstream выбирает slot** | Через `BUILD_SHARED_LIBS` в своём CMake. `ON` → резолвер ищет `.shared.x86_64.`, `OFF` → `.static.x86_64.` |
| **Что у нас выбрано** | DynamicRT slot (`.shared.x86_64.`), потому что el_conf/grpc_sdk/sura собираются с `BUILD_SHARED_LIBS=ON` |

В deployer (`extensions/deployers/legacy_nupkg.py`) этот контракт
закодирован так:

```python
# Default slot — DynamicRT (downstream el_conf, grpc_sdk, sura
# read this slot through BUILD_SHARED_LIBS=ON).
# Env override LEGACY_NUPKG_LINKAGE=static для StaticRT (GR121-equivalent).
linkage = os.environ.get("LEGACY_NUPKG_LINKAGE", "shared")
```

Почему "врать" в имени? Это legacy-имя унаследовано от старого TC-скрипта
(GR113) который **по convention'у** тэгировал артефакт как DynamicRT
независимо от того что содержимое уже статическое. Downstream-резолвер
matches по литералу — переименовать = всё сломать.

**Практический критерий:** если хотите видеть `.static.x86_64.` slot
(GR121-эквивалент), запускаете build с `LEGACY_NUPKG_LINKAGE=static`
env. Сейчас это не используется (downstream не настроен на StaticRT
slot), но архитектурно поддерживается.

---

## 4. Docker / ProGet (Docker registry)

### Registry

- **URL:** `proget.inc.elara.local/main`
- **Тип:** ProGet Docker feed (HTTP-only внутри сети, может потребовать
  `insecure-registries` в `/etc/docker/daemon.json` — см.
  `test-astra/HELP.txt` блок `[X]`).
- **Аутентификация:** анонимный pull для всех агентов; push — у devops.

### Базовые образы (production CI-тулчейны)

Эти образы поставляются и поддерживаются devops, лежат в Bitbucket в
проекте `SU2`, ветка `develop`, рядом с `gcc84-build-x86_64/Dockerfile`.
Цепочка слоёв (по состоянию 2026-05-04):

```text
nuget:4.8.1                          # Mono + NuGet CLI для упаковки .nupkg
  └── build-tools:0.1.0              # + cmake, protoc, clang-tools,
      │                                 lcov, powershell, build-essential
      └── gcc84-build-x86_64:0.1.0   # + gcc84/gcc53, qt5, linuxdeployqt, pvs-studio
```

| Образ | Назначение | Особенности |
|---|---|---|
| `library/gcc84-build-x86_64:0.1.0` | Native Linux x86_64 | Debian Stretch + gcc 8.4 в `/usr/local/gcc-8.4/` (через update-alternatives), cmake 3.31.7 в `/opt/cmake-3.31.7-linux-x86_64/`, protoc в `/opt/protoc/`, Qt 5.15.2, PowerShell, PVS-Studio |
| `library/gcc75-build-arm:0.1.0` | ARM cross (armv7hf) | Debian Stretch + linaro 7.5-2019.12 в `/opt/linaro-arm-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf/` |
| `library/gcc75-build-arm64:0.1.0` | ARM64 cross (armv8) | Debian Stretch + linaro 7.5-2019.12 в `/opt/linaro-arm64-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_aarch64-linux-gnu/` (NB: директория `linaro-arm64`, **не** `linaro-aarch64`) |

**Что внутри `gcc84-build-x86_64`:**

- OS: Debian Stretch (9, EOL). APT через `archive.debian.org` +
  `proget.inc.elara.local/debian`. APT-proxy:
  `http://servers2:servers@172.17.0.153:8080`.
- Кастомные deb-пакеты из ProGet: `gcc84-devel-elara`, `gcc53-devel-elara`,
  `cmake-devel-elara`, `protoc-devel-elara`, `clang-devel-elara`,
  `lcov-devel-elara`, `syslibgen-devel-elara`, `qt5-devel-elara`,
  `linuxdeployqt-devel-elara`, `pvs-studio`.
- Дефолтный компилятор: gcc 8.4 (приоритет в `update-alternatives`),
  gcc 5.3 — fallback.
- ENV: `QTS_ROOT_DIR=/opt/Qt/5.15.2`, `QT_QPA_PLATFORM=offscreen`,
  `PATH += /opt/{cmake-.../bin, clang-tools/bin, protoc, syslibgen,
  lcov/bin, linuxdeployqt}`.
- Компиляторных флагов (`CFLAGS`/`CXXFLAGS`/`LDFLAGS`) **в образе нет** —
  они приходят из TeamCity Build Configuration (Build Steps → Command Line
  / Parameters), не из Dockerfile.

### Производные образы (наш Dockerfile.grpc-tc-mirror)

Билдятся на каждом агенте локально из репо. Не публикуются в registry
(кроме pre-baked, см. ниже).

- `grpc-tc-mirror` — native x86_64. `BASE_IMAGE=gcc84-build-x86_64:0.1.0`.
- `grpc-tc-mirror-armv7hf` — ARM cross. `BASE_IMAGE=gcc75-build-arm:0.1.0` +
  `X64_BASE_IMAGE=gcc84-build-x86_64:0.1.0` для build-context.
- `grpc-tc-mirror-arm64` — ARM64 cross. `BASE_IMAGE=gcc75-build-arm64:0.1.0`
  + `X64_BASE_IMAGE=gcc84-build-x86_64:0.1.0`.

### Multi-stage Dockerfile.grpc-tc-mirror

Файл `Dockerfile.grpc-tc-mirror` — двухстадийный, единый для x86_64 и cross:

**Stage 1 (`x64_native_tc`):**

```dockerfile
ARG X64_BASE_IMAGE=proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0
FROM ${X64_BASE_IMAGE} AS x64_native_tc
RUN cp -aL /usr/local/gcc-8.4/. /opt/x64-native-gcc/ && \
    cd /opt/x64-native-gcc/bin && \
    ln -sf gcc-8.4 gcc && ln -sf g++-8.4 g++ && \
    ln -sf gcc-8.4 cc  && ln -sf g++-8.4 c++ && \
    ln -sf cpp-8.4 cpp && \
    ln -sf gcc-ar-8.4 gcc-ar && ln -sf gcc-nm-8.4 gcc-nm && \
    ln -sf gcc-ranlib-8.4 gcc-ranlib
```

- Берёт `/usr/local/gcc-8.4/` из CI-образа.
- `cp -aL` dereference'ит симлинки — копия самодостаточна, COPY в Stage 2
  не оставит dangling ссылок.
- Создаёт unsuffixed-aliases (`gcc → gcc-8.4`), потому что
  `gcc84-devel-elara` именует бинари с суффиксом версии.

**Stage 2 (актуальный mirror):**

```dockerfile
ARG BASE_IMAGE=gcc:8
FROM ${BASE_IMAGE}
COPY --from=x64_native_tc /opt/x64-native-gcc /opt/x64-native-gcc
WORKDIR /work/conan-recipes
COPY test-astra packages-linux profiles extensions \
     zlib abseil c-ares re2 protobuf openssl grpc  /work/conan-recipes/
RUN tar -xzf packages-linux/cpython-3.11.10+20240909-x86_64-linux-gnu.tar.gz \
        -C /opt && \
    ln -sf /opt/python/bin/python3 /usr/local/bin/python3 && \
    ...
RUN /opt/python/bin/python3 -m pip install --no-index \
        --find-links=packages-linux conan && \
    ln -sf /opt/python/bin/conan /usr/local/bin/conan
ENV PROFILE=/work/conan-recipes/profiles/lin-gcc84-x86_64
ENV CONAN_USER_TOOLCHAIN=""
CMD ["bash", "-lc", "./test-astra/run_test_grpc.sh"]
```

**Почему именно multi-stage:**

- ARM/ARM64 base-образы (`gcc75-build-arm:0.1.0`, `gcc75-build-arm64:0.1.0`)
  поставляют только Debian Stretch system gcc 6.3. Но abseil 20250127
  hard-rejects gcc < 7 в `policy_checks.h:59` (`#error "GCC 7 or higher"`).
- Build-context (`pr:b`) для cross-сборок — x86_64 (protoc, кодогенерация).
  Ему нужен gcc-8.4 — а в arm/arm64-образе его нет.
- Решение: тянем `/usr/local/gcc-8.4` из x86_64-образа через первую стадию,
  кладём в стабильный путь `/opt/x64-native-gcc/`. Профиль
  `lin-gcc84-x86_64` использует именно этот путь — и для native x86_64
  билда, и для build-context при cross-сборке.

**Сборка образа с правильными ARG (closed-network):**

```bash
docker build \
    --build-arg X64_BASE_IMAGE=proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0 \
    --build-arg BASE_IMAGE=proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0 \
    -f Dockerfile.grpc-tc-mirror \
    -t grpc-tc-mirror .
```

Оба ARG ведут на один ProGet-образ для native x86_64. Для cross —
`BASE_IMAGE` меняется на ARM-вариант, `X64_BASE_IMAGE` остаётся x86_64.

### Pre-baked images (sandbox arm64)

В TC sandbox-конфигах `SANDBOX/GRPC_CONAN_ARM/*` используется pre-baked
вариант — `grpc-tc-mirror-arm64` запушен в ProGet как готовый образ,
`run_prebake.sh` делает `docker pull` свежей версии перед каждым прогоном
(а не локальный `docker build`). Это экономит ~3-5 минут на агенте.

---

## 5. ProGet (NuGet feed)

### Адресация

- **Feed URL для чтения:** `proget.inc.elara.local/main` (NuGet v2/v3).
- **Endpoint для `nuget push`:** `https://proget.inc.elara.local/nuget/main`.
- **API key:** хранится у devops; в TC выставляется параметром
  `ProGet.ApiKey` (Password type).

### Что лежит в feed'е

- Все легаси-пакеты Elara (build'ы из GR113 — DynamicRT / GR121 — StaticRT):
  - `abseil/0.2.0`, `protobuf/4.25.2`, `zlib/1.3.0`, `openssl/1.1.11`,
    `re2/0.2.0`, `cares/1.19.0`, `grpc/1.60.1` — `.lin.gcc84.shared.x86_64.<ver>.nupkg`
    (GR113 — DynamicRT slot) и `.lin.gcc84.static.x86_64.<ver>.nupkg`
    (GR121 — StaticRT slot).
- **IN-658 миграция целится в `.shared.x86_64.` slot (GR113-эквивалент)** —
  downstream-резолвер (`ResolveDependencies.cmake` в el_conf, grpc_sdk,
  sura) ищет пакеты по этому тегу. Содержимое наших `.nupkg` — static
  `.a` (см. §3.7 «Контракт линкажа»). Slot-tag и контент — независимые
  свойства.
- `.1`-варианты после публикации (coexistence-стратегия):
  - `abseil.lin.gcc84.shared.x86_64.20230802.1.1.nupkg` —
    upstream-собранный, версия с суффиксом `.1`.
  - Включается через `LEGACY_NUPKG_VERSION_SUFFIX=.1` env-var в
    `run_grpc_1601_upstream.sh`.
- ARM-варианты (после полного закрытия sandbox arm/arm64) пойдут как
  `<pkg>.lin.gcc75.shared.arm-linaro.<ver>.nupkg` /
  `...arm64-linaro.<ver>...` — имена не конфликтуют с x64-слотами в feed.

### Стратегия coexistence

См. `STATUS.md` § "Что НЕ закрыто" и `DOWNSTREAM-MIGRATION.md`. Три
варианта (на согласовании с лидом):

- **(А)** Пересобрать `utf8_range`, `cares` и т.п. с обновлёнными
  `_dependencies` пинами `.1`-версий.
- **(Б)** Опубликовать наши пакеты **без** `.1` суффикса, физически
  вытеснив легаси.
- **(В)** Каждый downstream обновляет свои `_dependencies`.

### Гоча

ProGet требует, чтобы `.nuspec` лежал **строго в корне zip**. Старый
deployer клал его в `<variant_dir>/nuget/<pkg>.nuspec` — pkg падал
с `Server Error: Package is not valid; no .nuspec file found`. Фикс —
коммит `f011bd8` в master (упаковка от `staging/<pkg_id>/` напрямую).

---

## 6. Dev-VM для разработчика

### Размещение

- **vCenter:** `incvc.inc.elara.local`.
- **Папка:** `INC / devops-vm / Pushkarev/`.
- **VM:** `dev-astra18-13`.

### Конфигурация VM

| Параметр | Значение |
|---|---|
| Guest OS (фактический) | **Debian 10** (а не Astra Linux 1.8 как намекает имя!) |
| ESXi | 6.7+ |
| Host | `inc-esx-pp04.inc.elara.local` |
| Storage | `shared-nfs-03` |
| IP | `172.17.6.32` |
| Доступ | SSH, vSphere Console (VNC) |

### Что должно быть установлено

- Docker (`apt install docker.io` или ProGet `docker-ce`).
- Git client (стандартный `apt install git`).
- Python 3.11+ — **не системный**! Поставляется через
  `packages-linux/cpython-3.11.10+20240909-x86_64-linux-gnu.tar.gz` или
  через venv от `./test-astra/setup.sh`. Системный python на dev-VM может
  быть Python 3.7, который Conan 2.27.1 уже не примет.
- venv с Conan 2.27.1 — создаётся `./test-astra/setup.sh` через offline
  pip install из `packages-linux/conan-2.27.1.tar.gz`.
- Сетевой доступ к ProGet (тест: `curl -sI
  https://proget.inc.elara.local/`).

### Disk usage

- `~/.conan2/` (Conan cache) — может вырасти до 5-10 ГБ после полного
  билда grpc-tree.
- `~/conan-recipes/output*/` — выходные `.nupkg`, ~500 МБ за один билд
  (grpc сам 430 МБ).
- Volume `conan-cache-arm64` / `conan-cache-arm64-prebake` (Docker named
  volumes) — отдельные кеши для ARM-cross, тоже 5+ ГБ каждый.
- Рекомендация: **минимум 50 ГБ свободного места** в `/var/lib/docker` и
  столько же в `$HOME`. Скрипт `run_prebake.sh` отказывается стартовать
  если в `/var/lib/docker` <30 ГБ (override через `MIN_FREE_GB=<n>`).

### Контракт использования dev-VM

- **Все сборки — только через `docker run grpc-tc-mirror`**, никогда не
  нативно на хосте. См. memory `feedback_x86_64_needs_docker.md`.
- Симптом промашки (попытка нативного билда): `CMake Error: The
  CMAKE_C_COMPILER: /opt/x64-native-gcc/bin/gcc is not a full path to an
  existing compiler tool` — этого пути на хосте нет, он создаётся **только**
  Stage 1 Dockerfile'а.
- Каждый sh-orchestrator (`run_test_grpc.sh`, `run_legacy_versions.sh`,
  `run_grpc_1601_upstream.sh`, `run_proto_4252_canonical.sh`) сам
  определяет, что он на хосте, и `exec docker run` себя в зеркало.

---

## 7. Python / Conan

### Версия Conan

- **Зафиксирована: 2.27.1.** Поднятие версии — отдельная инженерная
  задача, потому что в рецептах закрепощено несколько workaround'ов под
  баги именно этой версии (см. ниже).
- Источник пакета — `packages-linux/conan-2.27.1.tar.gz` (offline) и
  `packages/` (Windows-зеркало).

### Установка

В Dockerfile.grpc-tc-mirror:

```dockerfile
RUN /opt/python/bin/python3 -m pip install --no-index \
        --find-links=packages-linux \
        pip setuptools wheel \
    && /opt/python/bin/python3 -m pip install --no-index \
        --find-links=packages-linux conan \
    && ln -sf /opt/python/bin/conan /usr/local/bin/conan
```

`--no-index --find-links=packages-linux` — без обращения к pypi. В
`packages-linux/` лежат все колёса Conan и его зависимости
(`certifi`, `jinja2`, `pyyaml`, `requests`, ...).

Деplyment на dev-VM: `./test-astra/setup.sh` создаёт venv в
`conan-recipes/venv/` через тот же оффлайн-pip.

### Python

- В Docker'е — standalone Python 3.11.10 из
  `packages-linux/cpython-3.11.10+20240909-x86_64-linux-gnu.tar.gz`.
  Распаковывается в `/opt/python/`, статически слинкован против glibc 2.17+
  — работает на Stretch (Debian 9) без вопросов.
- Stretch system python — 2.7 / 3.5, не поддерживает Conan 2.x.
- `ensurepip` в python-build-standalone `install_only` тарболах **сломан**
  на Stretch — мы намеренно не используем venv внутри Docker'а (Docker
  сам по себе изоляция).

### Cache location

- По умолчанию: `~/.conan2/`.
- В Docker'е: `/root/.conan2/` (root user).
- Для ARM-cross — отдельный named volume `conan-cache-${ARCH}`
  (`conan-cache-arm`, `conan-cache-arm64`); для prebake-flow — отдельный
  `conan-cache-${ARCH}-prebake`, чтобы dev-кеш не контаминировался.

---

## 8. Toolchain

### 8.1 x86_64 native (gcc 8.4)

- **Compiler:** gcc 8.4 в `/opt/x64-native-gcc/` (alias из
  `/usr/local/gcc-8.4/` Stage 1).
- **glibc:** Debian Stretch (2.24).
- **C++ standard:** `c++17` (профиль `lin-gcc84-x86_64`,
  `compiler.cppstd=17`).
- **libcxx:** `libstdc++11` (`compiler.libcxx=libstdc++11` — dual-ABI
  GCC ≥5).
- **Кросс-cmake:** 3.31.7 из `/opt/cmake-3.31.7-linux-x86_64/`. (Профиль
  пишет `cmake/3.25.1` как минимум, реальная — выше.)
- **Build_type:** `Release` по умолчанию (профиль), но deployer требует
  оба `Release` + `Debug` в кеше. `run_grpc_1601_upstream.sh` явно
  делает оба прогона.

### 8.2 ARM 32-bit cross (armv7hf, linaro 7.5)

- **Cross-compiler:** `arm-linux-gnueabihf-gcc` (linaro 7.5.0-2019.12).
- **Путь в образе:** `/opt/linaro-arm-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf/bin/`.
- **Toolchain-файл:** `profiles/toolchains/linaro-arm.cmake`.
- **Профиль:** `profiles/lin-gcc75-arm-linaro` (`arch=armv7hf`).
- **Особенности:**
  - `CMAKE_*_LINKER_FLAGS_INIT="-fuse-ld=gold"` — workaround под bug
    linaro BFD-ld (binutils 2.32): `.strtab corruption` при cross-link
    shared C++ libraries. Gold ships как
    `arm-linux-gnueabihf-ld.gold` в linaro 7.5.

### 8.3 ARM 64-bit cross (armv8 / aarch64, linaro 7.5)

- **Cross-compiler:** `aarch64-linux-gnu-gcc` (linaro 7.5.0-2019.12).
- **Путь в образе:** `/opt/linaro-arm64-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_aarch64-linux-gnu/bin/`.
  **Внимание:** базовый каталог `/opt/linaro-arm64-...`, **не**
  `/opt/linaro-aarch64-...` (несоответствие имени arch и каталога —
  CI-конвенция).
- **Toolchain-файл:** `profiles/toolchains/linaro-aarch64.cmake`.
- **Профиль:** `profiles/lin-gcc-aarch64-linaro` (`arch=armv8`).
- **Особенности:**
  - `abseil/patches/20250127.0-0001-stacktrace-aarch64-binutils232.patch`
    — заменяет `xpaclri` (ARMv8.3-A inline asm) на `hint #7`
    (NOP-эквивалент); тот же binutils-2.32 root cause.
  - `-fuse-ld=gold` — аналогично armv7hf.

### Linaro path quirk

Имя каталога с rc1-суффиксом
(`gcc-linaro-7.5.0-2019.12-rc1-x86_64_*`) — артефакт CI snapshot'а.
Публичный релиз linaro называется без `rc1`. Если работаете с публичным
архивом — нужны симлинки на rc1-имена, иначе toolchain-файлы упадут.

### Acceptance артефактов (ELF)

После сборки arm/arm64 — обязательная проверка:

```bash
# armv7hf
file output-arm/<pkg>/lib/native/lin-gcc75-shared-arm-linaro/lib*.a
# ожидаем: current ar archive (контент — static .a даже в `shared`-tag slot'е)
# внутри: ELF 32-bit LSB ARM, EABI5
ar x lib<pkg>.a && readelf -A <obj>.o | grep -E 'Tag_CPU_arch|Tag_FP_arch'
# ожидаем: Tag_CPU_arch: v7, Tag_FP_arch: VFPv3

# arm64
file output-arm64/<pkg>/lib/native/lin-gcc75-shared-arm64-linaro/lib*.a
# ожидаем: current ar archive, содержимое — ELF 64-bit LSB ARM aarch64
```

Сценарий есть в `test-astra/HELP.txt` блок `[9]`.

---

## 9. Профили Conan

Файлы в `profiles/`:

| Профиль | Host arch | Compiler | Use case |
|---|---|---|---|
| `lin-gcc84-x86_64` | `x86_64` | gcc 8.4 | Native Linux x86_64 |
| `lin-gcc75-arm-linaro` | `armv7hf` | linaro gcc 7.5 | ARM cross (armv7hf) |
| `lin-gcc-aarch64-linaro` | `armv8` | linaro gcc 7.5 | ARM64 cross |
| `lin-gcc84-i686` | `x86` | gcc 8.4 | 32-bit Linux (редко) |
| `win-v143-x64` | `x86_64` | MSVC v193 | Windows x64 (тестовый) |
| `win-v142-x64`, `win-v142-x86` | x86_64/x86 | MSVC v142 | Старый MSVC (legacy линии) |
| `windows-msvc`, `windows-msvc-debug` | x86_64 | MSVC | Дженерик MSVC варианты |
| `linux-gcc`, `linux-gcc-debug` | x86_64 | system gcc | **Diagnostic only**, не для прод-билдов |
| `astra-gcc` | x86_64 | system gcc | Default для dev-VM ручного `conan create` (но не для CI) |

Структура каждого профиля — `[settings]`, `[platform_tool_requires]`,
`[buildenv]`, `[conf]`.

### Пример: lin-gcc84-x86_64

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

**Почему `/opt/x64-native-gcc/bin/gcc`**, а не просто `gcc`:

- На arm/arm64 base-образе системный `gcc` — Stretch 6.3, abseil 20250127
  отказывается с ним собираться.
- Профиль может выступать как `pr:b` (build-context) для ARM-host сборки.
  Тогда buildenv от arm-профиля (`CC=arm-linux-gnueabihf-gcc`) **утекает**
  в build-context, и protoc собирается arm-компилятором — фейл.
- Жёстко пинить `/opt/x64-native-gcc/bin/gcc` в обоих `[buildenv]` и
  `[conf]` — единственный способ обезопасить build-context.

### Пример: lin-gcc75-arm-linaro

```ini
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
PATH=+(path)/opt/linaro-arm-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_arm-linux-gnueabihf/bin
CC=arm-linux-gnueabihf-gcc
CXX=arm-linux-gnueabihf-g++
AR=arm-linux-gnueabihf-ar
...

[conf]
*:tools.cmake.cmaketoolchain:user_toolchain=["/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"]
```

### Quirk Conan 2.27.1: user_toolchain не пропагируется

`[conf]` ключ `*:tools.cmake.cmaketoolchain:user_toolchain` **не**
доходит до транзитивных deps при `--requires=grpc/...`. Top-level abseil
собирается linaro, но `grpc → abseil (транзит)` использует системный
`/usr/bin/c++` (Stretch g++ 6.3) → `policy_checks.h: GCC 7 or higher`.

**Workaround** — env-fallback в `generate()` каждого затронутого recipe
(`abseil`, `re2`, `protobuf`, `grpc`):

```python
_user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
if _user_tc and str(self.settings.arch) in (
        "armv7", "armv7hf", "armv7s",
        "armv8", "armv8_32", "armv8.3", "arm64ec"):
    tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
tc.generate()
```

Arch-gate критичен — иначе toolchain утекает в build-context (x86_64
protoc), и `arm-linux-gnueabihf-g++ -m64` падает.

`Dockerfile.grpc-tc-mirror` объявляет `ENV CONAN_USER_TOOLCHAIN=""` —
пустой по умолчанию (x86_64 не затронут). ARM-cross прогон выставляет
переменную через `docker run -e CONAN_USER_TOOLCHAIN=/work/.../linaro-arm.cmake`.

---

## 10. CMake-фреймворк (Elara legacy)

Папка `cmake/` вшита в каждый legacy-репо Bitbucket project `SU2`,
~27 модулей:

```text
cmake/
├── toolchains/
├── ClangTools.cmake
├── CMakeCommon.cmake               # reads BUILD_RELEASE, PRERELEASE_SUFFIX, SOURCE_REVISION
├── ConfigureCompiler.cmake
├── ConfigureNuspecs.cmake          # генерит .nuspec
├── ConfigureTargets.cmake          # генерит .targets
├── CustomTargetLinkLibraries.cmake # link-имена (candidate for -lzlib bug)
├── FindInstalledPackage.cmake
├── GenerateGrpcCpp.cmake
├── GenerateSysDBCpp.cmake
├── GitPatch.cmake
├── GoogleTest.cmake
├── HttpHelper.cmake
├── InstallComponent.cmake          # раскладка lib/ include/
├── InstallPackage.cmake
├── LayoutGroups.cmake
├── NuGetInstall.cmake              # зовёт nuget pack
├── NuGetProto.cmake
├── PackageVersion.cmake
├── PlatformHelper.cmake            # TARGET_PLATFORM, TARGET_ARCH_CPU, BUILD_SHARED_LIBS
├── Qt5Configure.cmake
├── QtTest.cmake
├── ResolveDependencies.cmake       # резолвер у потребителя
├── SimpleXmlParser.cmake
├── SystemDbVersion.cmake
├── Utils.cmake
└── VersionChecker.cmake
```

### Точные имена cmake-vars, которые читает фреймворк

| Функция (`PlatformHelper.cmake`) | Читает | Допустимые значения |
|---|---|---|
| `get_platform_prefix` | `TARGET_PLATFORM` | `"LINUX"`, `"WINDOWS"`, `"WINCE800"` |
| `get_processor_prefix` | `TARGET_ARCH_CPU` | `"X86_64"`, `"ARM_IMX6Q"` (с `_`→`-`) |
| `get_compiler_prefix` | автодетектит `${CMAKE_CXX_COMPILER} -dumpversion` | `"gcc84"` (8.4 → 84) |
| `get_library_prefix` | `BUILD_SHARED_LIBS` | `"shared"` / `"static"` |
| `get_package_suffix` | composite | `lin.gcc84.shared.x86_64` (если `BUILD_SHARED_LIBS=ON`) / `lin.gcc84.static.x86_64` (если `OFF`) |
| `get_folder_suffix` | composite | `lin-gcc84-shared-x86_64` / `lin-gcc84-static-x86_64` |

`CMakeCommon.cmake` также читает `BUILD_RELEASE`, `PRERELEASE_SUFFIX`,
`SOURCE_REVISION` (эти три — эмпирические, не верифицированы из
исходника).

В Conan-обёртке legacy/*/conanfile.py минимальный набор:

```python
tc.cache_variables["TARGET_PLATFORM"] = "LINUX"
tc.cache_variables["TARGET_ARCH_CPU"] = "X86_64"
tc.cache_variables["BUILD_RELEASE"] = (
    "YES" if self.settings.build_type == "Release" else "NO"
)
tc.cache_variables["PRERELEASE_SUFFIX"] = ""
tc.cache_variables["SOURCE_REVISION"] = ""
```

---

## 11. Зависимости от внешних сервисов

| Сервис | URL / IP | Назначение |
|---|---|---|
| Active Directory | `incdc1.inc.elara.local` | LDAP для TC, Bitbucket, Git |
| FTP | `172.17.0.5` | Артефакты релизов, downstream-релизы |
| Guardant license (Linux) | `http://172.17.0.89:5000/api/executor` | Лицензии для билда |
| Guardant license (Windows) | `http://172.17.0.240:5000/api/executor` | Лицензии Win |
| ARM host (физический) | `172.17.0.167` | Downstream-тесты на реальном ARM |
| APT-proxy (для Stretch) | `http://servers2:servers@172.17.0.153:8080` | APT через corporate proxy |
| ProGet Docker feed | `proget.inc.elara.local/main` | Базовые Docker-образы |
| ProGet NuGet feed | `proget.inc.elara.local/main` | `.nupkg` legacy + наши |
| ProGet Debian feed | `proget.inc.elara.local/debian` | Кастомные `*-devel-elara` deb-пакеты |
| Bitbucket | `http://bitbucket.inc.elara.local` | Git, CMake-фреймворк, Dockerfiles |
| TeamCity | (адрес у devops) | CI orchestrator |
| vCenter | `incvc.inc.elara.local` | vSphere — управление VM |

---

## 12. Network topology

- Все production-сервисы — во внутренней сети `172.17.0.0/24`
  (вкл. `172.17.6.32` где dev-VM).
- **Доступа в публичный интернет нет** ни у TC-агентов, ни у dev-VM —
  это закрытый контур.
- DNS: `*.inc.elara.local` резолвится через корпоративный AD (incdc1).
- ProGet (Docker registry) — HTTP, без TLS. Может потребовать
  `insecure-registries: ["proget.inc.elara.local"]` в
  `/etc/docker/daemon.json`. Сценарий и проверка — в
  `test-astra/HELP.txt` блок `[X]` (`docker pull x509: certificate
  signed by unknown authority`).
- ProGet (NuGet) — HTTPS, корпоративный CA. NuGet CLI его принимает.
- Доступ извне — только через корпоративный VPN.

---

## 13. Безопасность и credentials

| Что | Где хранится | Уровень доступа |
|---|---|---|
| TC параметры (`Git.Username`, `Git.Password`, `ProGet.ApiKey`) | TC Configuration → Parameters (Password type) | TC admins |
| LDAP password разработчика | Active Directory | Сам сотрудник |
| ProGet API key | TC + у devops | devops + admins |
| Git LDAP credentials | Через AD-учётку, отдельно не хранятся | Каждый сотрудник |
| SSH ключи на dev-VM | `~/.ssh/` пользователя на VM | Сам пользователь |
| Guardant ключи | Лицензионные сервера, на агентах не лежат | Бухгалтерия + IT |

**Правила:**

- Никаких secrets в репе! Если что-то случайно закоммитили — rotate
  immediately (через AD и через TC).
- Code review должен ловить `password=...`, `apikey=...`, `Bearer ...`
  в diff'ах.
- `CLAUDE.md` и `ARCHITECTURE.md` в `conan-recipes` — local-only,
  `.gitignore`-d. Они могут содержать конкретные пути и команды — но
  не secrets.

---

## 14. Резервирование / disaster recovery

> **TODO — уточнить у devops.** На уровне отдельных сервисов:

- **Bitbucket** — стандартный Atlassian backup, расписание у devops.
- **TeamCity** — артефакты хранятся на server-VM, ретеншн настраивается
  per-config. Базы данных — отдельный backup.
- **ProGet** — backup feed'ов на отдельный том. Уточнить периодичность.
- **vCenter (VM)** — snapshots? hot backup?
- **dev-VM `Pushkarev/dev-astra18-13`** — персональная, бэкапа нет.
  Источники истины — Bitbucket (`git push --ff-only` обязателен).

Конкретные RPO/RTO — у devops.

---

## 15. Контакты

| Роль | Кто | Где спросить |
|---|---|---|
| `conan-recipes` maintainer | Pushkarev (dev-VM `dev-astra18-13`) | прямо |
| TC / ProGet админ | devops отдел | в Slack/Teams канал devops |
| Bitbucket / AD | IT отдел | helpdesk |
| Архитектор IN-353 / IN-658 | лид команды | прямо |
| grpc_sdk maintainer | команда grpc_sdk | для consumer-side PR'ов |
| el_conf maintainer | команда el_conf | для consumer-side вопросов |

---

## 16. Связанные документы

В этом же `docs/IN-658/`:

- `STATUS.md` — что сделано, что осталось, риски.
- `CONFLUENCE.md` — overview-страница миграции.
- `DEVOPS-RUNBOOK.md` — операционные команды (билд + публикация).
- `DOWNSTREAM-MIGRATION.md` — что должны сделать downstream-команды.
- `MIGRATION-PLAYBOOK.md` — пошаговый playbook.
- `USAGE.md` — как пользоваться нашими `.nupkg` со стороны downstream.
- `DEVELOPER.md` — для следующего разработчика conan-recipes (англ).
- `CONANFILE-ANATOMY.md` — анатомия `conanfile.py` в этом репо.
- `README.md` — индекс всех документов IN-658.

В корне `conan-recipes/`:

- `README.md` (~1000 строк, ru) — полный обзор + чек-лист «добавить
  пакет».
- `CLAUDE.md` — local-only context dump для maintainer/Claude.
- `Dockerfile.grpc-tc-mirror` — multi-stage Docker для x86_64 + cross.
- `profiles/` — все Conan profiles.
- `extensions/deployers/legacy_nupkg.py` — упаковщик `.nupkg`.
- `test-astra/HELP.txt` — диагностические блоки `[0]`–`[12]` + `[X]`.
- `test-astra/TESTING_ARM.md` — single-doc runbook для ARM.
- `test-astra/NEXT_STEPS.md` — исторический журнал ARM-фазы.

---

## 17. Глоссарий

| Термин | Значение |
|---|---|
| **IN-353** | Тикет миграции на Conan 2.x, x86_64-фаза (закрыт). |
| **IN-658** | Подтикет IN-353, ARM cross + TC sandbox + публикация. |
| **deployer** | `extensions/deployers/legacy_nupkg.py` — упаковщик `.nupkg`. |
| **variant_dir** | Имя подкаталога вида `lin.gcc84.shared.x86_64` (с точками). |
| **lib_suffix** | Тот же подкаталог, но через дефисы: `lin-gcc84-shared-x86_64`. |
| **legacy `.nupkg`** | Артефакт CI старой схемы — zip с `.nuspec` + `CMakeLists.var` + `lib/native/...`. |
| **CI-эталон** | Артефакт от ручных TC-скриптов (GR113/GR120/GR121/GR122) до миграции. |
| **closed network** | Корпоративная сеть `172.17.0.0/24` без выхода в публичный интернет. |
| **ProGet** | Inedo ProGet — наш inhouse package registry (Docker + NuGet + Debian feeds). |
| **mirror image** | Образ `grpc-tc-mirror`, билдится из `Dockerfile.grpc-tc-mirror`. |
| **prebake** | Pre-baked variant mirror image — pull уже готового образа из ProGet вместо `docker build`. |
| **`.1`-суффикс** | `LEGACY_NUPKG_VERSION_SUFFIX=.1` — coexistence-стратегия параллельно с легаси. |
| **dual-ABI gcc** | gcc ≥5 с `libstdc++11` — std::string и др. в новом ABI namespace `__cxx11`. |
| **dual-RT (Dynamic/Static)** | DynamicRT = Debug + shared + Coverage; StaticRT = Release + static. |

---

## 18. Известные TODO в инфраструктуре

- [ ] **`run_test_grpc.sh` self-wrap в Docker** — `run_test_grpc.sh` пока
  не делает auto self-wrap (в отличие от `run_legacy_versions.sh` /
  `run_grpc_1601_upstream.sh`). Запускать только внутри `docker run
  grpc-tc-mirror`.
- [ ] **`test_arm_cross.sh` env propagation** — раньше скрипт не пробрасывал
  `-e CONAN_USER_TOOLCHAIN` и `-v conan-cache:/root/.conan2`. Фикс был
  в коммите `8278d55` + env-fallback в recipes, но имеет смысл
  верифицировать что в текущем master всё на месте.
- [ ] **arm-арка sandbox в TC** — конфиг
  `SANDBOX/GRPC_CONAN_ARM/conan_arm` (armv7hf) не закрыт. arm64
  закрыт 2026-05-14.
- [ ] **Layout прод-TC после миграции** — replace GR121/GR122
  in-place / параллельно GR123/GR124 / отдельный раздел
  `SURA2/COMPONENTS/CONAN/` — выбор за лидом. См.
  `STATUS.md` §"Что НЕ закрыто".
- [ ] **Conan-feed в ProGet (`conan-internal`)** — опциональная следующая
  фаза. Включит cross-agent cache: `conan upload */* -r elara-proget
  --confirm` на builder, `--remote=elara-proget --build=missing` на
  consumer-агентах. Эффект: новые TC-агенты получают package_id за
  5-10 мин вместо 2h:20m холодного билда.
- [ ] **DR / backup deklarations** — раздел "Резервирование" пока без
  конкретики, уточнить у devops.
- [ ] **Build Mirror Image config в TC** — нужен ли отдельный TC-конфиг,
  который автоматически пересобирает `grpc-tc-mirror` (или его
  pre-baked вариант) при изменении `Dockerfile.grpc-tc-mirror`?
  Решение за лидом.

---

*Документ — статичный snapshot инфраструктуры на 2026-05. По мере
изменений (новые TC-конфиги, обновление до Conan ≥2.28, миграция с
Debian Stretch base, и т.п.) — обновлять. Источник истины для оперативных
команд — `DEVOPS-RUNBOOK.md`.*
