# Развёртывание инфраструктуры: Bitbucket + TeamCity + Conan

## Общая схема

```
┌──────────────┐     push      ┌───────────────────┐   trigger   ┌──────────────────┐
│  Разработчик  │ ──────────► │    Bitbucket        │ ─────────► │    TeamCity       │
│              │              │ bitbucket.inc.      │             │ teamcity.inc.    │
│              │              │ elara.local         │             │ elara.local      │
└──────────────┘              │ repo: conan-recipes │             │                  │
                              └───────────────────┘             └────────┬─────────┘
                                                                         │
                                                                conan create
                                                                conan upload
                                                                         │
                                                                         ▼
                                                                ┌──────────────┐
                                                                │ Conan Server │
                                                                │ conan.elara  │
                                                                │ .local:9300  │
                                                                └──────┬───────┘
                                                                       │
                                                              conan install
                                                                       │
                                                                       ▼
                                                                ┌──────────────┐
                                                                │ SURA1/SURA2  │
                                                                │ COMPONENTS   │
                                                                │ (потребители)│
                                                                └──────────────┘
```

## Текущее состояние инфраструктуры

### TeamCity (teamcity.inc.elara.local)
- **38 агентов**: Linux Debian/Debian12, Ubuntu, Rosa, Astra + Windows
- **Пулы**: Build pool (22 агента), SANDBOX pool (2), Sura1 pool, Node(s) pool
- **Проекты**: SURA1, SURA2 → COMPONENTS → CMAKE → пакеты

### Текущая сборка third party (пример CURL)
Каждый пакет имеет:
- 6+ Build Configuration (Windows x86/x64 Static/Dynamic, Linux, Linux ARM)
- 7 шагов в каждой: CleanUp → SetVersion → SkipLogic → StaticAnalysis → BuildRelease → BuildDebug → GuardantProtect
- 86 параметров
- Наследование от шаблона (CMAKE 100 BUILD Windows x86 StaticRT и др.)
- Требует пропатченный CMakeLists.txt в Bitbucket

### Что меняется с Conan
- Один `conanfile.py` заменяет все Build Configuration для пакета
- Профили заменяют отдельные шаблоны (x86/x64/Static/Dynamic)
- Не нужен пропатченный CMakeLists.txt — исходники берутся как есть

---

## Шаг 1: Поднять Conan Server

### Вариант A: Docker на любом Linux-сервере (рекомендуется)

Файлы `docker-compose.yml` и `server.conf` уже подготовлены в этом репозитории.

```bash
# На сервере (например, на одном из ba-deb12-* или отдельном)
cd /opt/conan-server
cp docker-compose.yml server.conf .

# ВАЖНО: отредактировать server.conf — задать пароли и jwt_secret!
vim server.conf

# Запустить
docker-compose up -d

# Проверить
curl http://localhost:9300/v1/ping
```

### Вариант B: pip install (без Docker)

```bash
pip install conan_server
# Скопировать server.conf в ~/.conan_server/server.conf
conan_server
```

### Настроить DNS

Попросить администратора добавить запись:
```
conan.elara.local → <IP сервера с Conan Server>
```

Или добавить в `/etc/hosts` на агентах:
```
192.168.x.x conan.elara.local
```

---

## Шаг 2: Bitbucket — создать репозиторий

В Bitbucket (bitbucket.inc.elara.local):

1. Проект: тот же, где лежат COMPONENTS (вероятно SURA2 или Infrastructure)
2. Создать репозиторий: **conan-recipes**

```bash
cd conan-recipes
git init
git add .
git commit -m "IN-353: Conan recipes for building third party packages without modification"
git remote add origin ssh://git@bitbucket.inc.elara.local/<PROJECT>/conan-recipes.git
git push -u origin master
```

---

## Шаг 3: Подготовить TeamCity-агентов

Для тестирования — начать с **SANDBOX pool** (ba-deb-prb, ba-td-astra-01), чтобы не затронуть основные сборки.

### На Linux-агенте (ba-deb-prb)

```bash
# Установить Conan
pip3 install conan

# Первичная настройка
conan profile detect

# Добавить Conan Server
conan remote add elara http://conan.elara.local:9300

# Авторизоваться
conan remote login elara builder -p <пароль_из_server.conf>

# Проверка
conan remote list
conan search --remote=elara "*"
```

### На Windows-агенте (если нужно на этом этапе)

```bat
pip install conan
conan profile detect
conan remote add elara http://conan.elara.local:9300
conan remote login elara builder -p <пароль>
```

---

## Шаг 4: Создать проект в TeamCity

### 4.1 Структура проекта

```
SURA2 (или Root)
└── COMPONENTS
    └── CONAN                          ← новый проект
        ├── CN100 BUILD gtest Linux    ← Build Configuration
        ├── CN101 BUILD gtest Windows
        ├── CN900 PACKAGE gtest        ← упаковка + upload
        └── ...
```

Именование по вашей конвенции: CN = Conan prefix.

### 4.2 Создать VCS Root

- **Type**: Git
- **Fetch URL**: `ssh://git@bitbucket.inc.elara.local/<PROJECT>/conan-recipes.git`
- **Default branch**: `refs/heads/master`
- **Authentication**: SSH key (использовать существующий)

### 4.3 Build Configuration: CN100 BUILD gtest Linux

**General Settings:**
- Name: `CN100 BUILD gtest Linux`
- Build number format: `%package.version%`

**Parameters:**
| Имя | Значение | Тип |
|-----|----------|-----|
| package.name | gtest | Config |
| package.version | 1.14.0 | Config |
| conan.profile | profiles/linux-gcc | Config |
| conan.remote | elara | Config |
| env.CONAN_PASSWORD | *** | Password |

**Build Steps:**

**Step 1: Build package** (Command Line)
```bash
#!/bin/bash
set -euo pipefail

echo "##teamcity[progressMessage 'Building %package.name% %package.version%']"

# Собрать пакет из оригинальных исходников
conan create %package.name%/ --profile=%conan.profile% --build=missing

# Загрузить в Conan Server
conan upload "%package.name%/*" --remote=%conan.remote% --confirm

echo "##teamcity[buildStatus text='%package.name% %package.version% uploaded to %conan.remote%']"
```

**Agent Requirements:**
- `teamcity.agent.jvm.os.name` contains `Linux`
- Или agent pool = SANDBOX (для тестирования)

**Triggers:**
- VCS Trigger: при изменениях в `%package.name%/**`

### 4.4 Build Configuration: CN101 BUILD gtest Windows

Аналогично CN100, но:
- Профиль: `profiles/windows-msvc`
- Agent requirement: Windows
- Скрипт (bat):

```bat
conan create %package.name%/ --profile=%conan.profile% --build=missing
conan upload "%package.name%/*" --remote=%conan.remote% --confirm
```

### 4.5 Build Configuration: CN900 PACKAGE gtest (опционально)

Если нужна цепочка как в текущей системе (CU900 PACKAGE):

- **Snapshot Dependencies**: CN100, CN101
- **Step**: просто проверка, что пакет доступен в remote

```bash
conan search "%package.name%/%package.version%@" --remote=%conan.remote%
```

---

## Шаг 5: Тестовый прогон

### На агенте вручную (до настройки TeamCity)

```bash
# Склонировать репо
git clone ssh://git@bitbucket.inc.elara.local/<PROJECT>/conan-recipes.git
cd conan-recipes

# Собрать gtest
conan create gtest/ --profile=profiles/linux-gcc --build=missing

# Загрузить в Conan Server
conan upload "gtest/*" --remote=elara --confirm

# Проверить, что пакет в remote
conan search "gtest/1.14.0@" --remote=elara

# Собрать пример-потребитель
cd example
conan install . --output-folder=build --build=missing --profile=../profiles/linux-gcc
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build
cd build && ctest --output-on-failure
```

### Через TeamCity

1. Запустить CN100 BUILD gtest Linux → Run
2. Проверить лог — должно быть "uploaded to elara"
3. Запустить CN101 BUILD gtest Windows → Run

---

## Шаг 6: Подключить к существующему проекту (потребителю)

Когда gtest собран и лежит в Conan Server, можно подключить его к любому
проекту из COMPONENTS, который использует gtest.

В Build Steps существующего проекта добавить **новый первый шаг**:

```bash
# Step 0 (перед существующими шагами): Install Conan dependencies
conan install . --output-folder=build --build=missing \
  --profile=linux-gcc --remote=elara
```

И в шаге cmake добавить флаг:
```bash
cmake ... -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake
```

---

## Шаг 7: Jira — связать с CI

1. В commit-messages указывать `IN-353`
2. В TeamCity → Administration → Issue Trackers:
   - Type: JIRA
   - Server URL: URL вашей Jira
   - Pattern: `IN-\d+`

---

## Чек-лист развёртывания

### Этап 1: Инфраструктура
- [ ] Поднять Conan Server (docker-compose на выделенном сервере)
- [ ] Настроить DNS или /etc/hosts: conan.elara.local
- [ ] Задать безопасные пароли в server.conf
- [ ] Проверить доступность: `curl http://conan.elara.local:9300/v1/ping`

### Этап 2: Код
- [ ] Создать репо conan-recipes в Bitbucket
- [ ] Залить рецепты, профили, скрипты

### Этап 3: TeamCity
- [ ] Установить Conan на агентах SANDBOX pool (ba-deb-prb)
- [ ] Настроить conan remote и авторизацию на агентах
- [ ] Создать проект CONAN в TeamCity
- [ ] Создать VCS Root → conan-recipes
- [ ] Создать CN100 BUILD gtest Linux
- [ ] Тестовый прогон — Run

### Этап 4: Проверка
- [ ] gtest собрался без ошибок
- [ ] gtest загружен в Conan Server
- [ ] Пример-потребитель собрался и тесты прошли
- [ ] Показать результат на код-ревью / демо команде
