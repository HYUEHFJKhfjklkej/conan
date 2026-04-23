# Развёртывание на TeamCity

## Общая схема

```
┌──────────────┐     push      ┌───────────────────┐   trigger    ┌──────────────────────┐
│  Разработчик  │ ──────────► │    Bitbucket        │ ──────────► │      TeamCity         │
│              │              │ bitbucket.inc.      │              │  teamcity.inc.       │
│              │              │ elara.local         │              │  elara.local         │
└──────────────┘              │ repo: conan-recipes │              │                      │
                              └───────────────────┘              │  1. conan create      │
                                                                  │  2. package-legacy.py │
                                                                  │  3. zip → Artifacts   │
                                                                  └──────────┬───────────┘
                                                                             │
                                                                    Тот же zip-артефакт
                                                                    (CMakeLists.var,
                                                                     .targets, .nuspec)
                                                                             │
                                                                             ▼
                                                                  ┌──────────────────┐
                                                                  │ SURA1/SURA2      │
                                                                  │ (потребители)    │
                                                                  │ Ничего не меняют │
                                                                  └──────────────────┘
```

**Ключевой принцип:** Conan собирает пакеты из оригинальных исходников (без патчей),
а `package-legacy.py` упаковывает результат в тот же формат zip-артефактов, что
и текущая система. Потребители (SURA) не замечают разницы.

---

## Шаг 1: Bitbucket — создать репозиторий

В Bitbucket (bitbucket.inc.elara.local):

1. Проект: тот же, где лежат COMPONENTS
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

## Шаг 2: Подготовить TeamCity-агентов

Начать с **SANDBOX pool** (ba-deb-prb), чтобы не затронуть основные сборки.

### На Linux-агенте

```bash
pip3 install conan==2.27.1
conan profile detect
```

### На Windows-агенте

```bat
pip install conan==2.27.1
conan profile detect
```

Conan Server на этом этапе **не нужен** — zip-артефакты публикуются
как обычные TeamCity artifacts (artifact dependencies).

---

## Шаг 3: Создать проект в TeamCity

### 3.1 Структура проекта

```
SURA2
└── COMPONENTS
    └── CONAN                                ← новый проект
        ├── GTEST                            ← subproject на пакет
        │   ├── CN100 Linux x64 shared       ← Build Configuration
        │   ├── CN101 Linux x64 static
        │   ├── CN110 Windows x64 shared
        │   ├── CN111 Windows x64 static
        │   └── CN900 PACKAGE                ← собирает все zip в один артефакт
        ├── FMT                              ← IN-352
        │   ├── CN200 Linux x64 shared
        │   └── ...
        └── ...                              ← другие пакеты
```

### 3.2 Создать VCS Root (на уровне проекта CONAN)

- **Type**: Git
- **Fetch URL**: `ssh://git@bitbucket.inc.elara.local/<PROJECT>/conan-recipes.git`
- **Default branch**: `refs/heads/master`
- **Branch specification**: `+:refs/heads/*`
- **Authentication**: SSH key (использовать существующий ключ из Bitbucket VCS Root)

### 3.3 Шаблон (Build Configuration Template)

Создать шаблон **CONAN BUILD Template**, чтобы не дублировать настройки:

**Parameters (в шаблоне):**

| Параметр | Значение по умолчанию | Описание |
|----------|----------------------|----------|
| package.name | — | Имя пакета (gtest, curl, fmt) |
| package.version | — | Версия (1.14.0, 8.0.1) |
| conan.profile | lin-gcc84-x86_64 | Имя профиля из profiles/ |
| shared | True | Shared (True) или Static (False) |

**Build Step 1: Build and Package** (Command Line)

Runner type: Command Line
Custom script:

```bash
#!/bin/bash
set -euo pipefail

echo "##teamcity[progressMessage 'Conan: %package.name% %package.version% (%conan.profile%, shared=%shared%)']"

# 1. Собрать пакет из оригинальных исходников (БЕЗ модификации)
conan create %package.name%/ \
    --profile=profiles/%conan.profile% \
    -o "%package.name%/*:shared=%shared%" \
    --build=missing

# 2. Упаковать в legacy zip-формат (тот же что в текущих артефактах)
python3 teamcity/package-legacy.py \
    --name %package.name% \
    --version %package.version% \
    --profile %conan.profile% \
    --shared %shared% \
    --output output

echo "##teamcity[buildStatus text='%package.name% %package.version% (%conan.profile%, shared=%shared%)']"
```

**Artifact paths:**
```
output/*.zip
```

**Windows-вариант** Build Step (для Windows-агентов):

```bat
conan create %package.name%/ --profile=profiles/%conan.profile% -o "%package.name%/*:shared=%shared%" --build=missing

python teamcity\package-legacy.py --name %package.name% --version %package.version% --profile %conan.profile% --shared %shared% --output output
```

---

## Шаг 4: Создать Build Configurations

### GTEST

Создать из шаблона CONAN BUILD Template, переопределив параметры:

| Build Config | package.name | package.version | conan.profile | shared | Agent |
|---|---|---|---|---|---|
| CN100 Linux x64 shared | gtest | 1.14.0 | lin-gcc84-x86_64 | True | Linux |
| CN101 Linux x64 static | gtest | 1.14.0 | lin-gcc84-x86_64 | False | Linux |
| CN102 Linux x86 shared | gtest | 1.14.0 | lin-gcc84-i686 | True | Linux |
| CN103 Linux ARM Linaro | gtest | 1.14.0 | lin-gcc75-arm-linaro | True | Linux |
| CN110 Windows x64 shared | gtest | 1.14.0 | win-v142-x64 | True | Windows |
| CN111 Windows x64 static | gtest | 1.14.0 | win-v142-x64 | False | Windows |
| CN112 Windows x86 shared | gtest | 1.14.0 | win-v142-x86 | True | Windows |

**Agent Requirements:**
- Linux configs: `teamcity.agent.jvm.os.name` contains `Linux`
- Windows configs: `teamcity.agent.jvm.os.name` contains `Windows`

**Triggers:**
- VCS Trigger с file filter: `+:gtest/**` (только при изменении рецепта gtest)

### CN900 PACKAGE gtest (опционально)

Если нужна единая точка, собирающая все варианты:

- **Snapshot Dependencies**: CN100, CN101, CN110, CN111, ...
- **Artifact Dependencies**: собрать все zip из зависимостей
- **Build Step**: объединить zip-ы или просто пометить как готовые

---

## Шаг 5: Тестовый прогон

### Вручную на агенте (до создания Build Configuration)

```bash
# Склонировать репо
git clone ssh://git@bitbucket.inc.elara.local/<PROJECT>/conan-recipes.git
cd conan-recipes

# Собрать gtest
conan create gtest/ --profile=profiles/lin-gcc84-x86_64 --build=missing

# Упаковать в legacy формат
python3 teamcity/package-legacy.py \
    --name gtest --version 1.14.0 \
    --profile lin-gcc84-x86_64 --shared True \
    --output output

# Проверить zip
ls -la output/googletest.zip
unzip -l output/googletest.zip
```

### Через TeamCity

1. Запустить **CN100 Linux x64 shared** → Run
2. Проверить Artifacts → `googletest.zip` с правильной структурой
3. Запустить **CN110 Windows x64 shared** → Run
4. Сравнить zip со старыми артефактами из EXTERNAL → GOOGLETEST

---

## Шаг 6: Подключить к потребителю

Когда gtest собран и zip лежит в артефактах TeamCity:

**Вариант A: Artifact Dependency (рекомендуется)**

В существующей Build Configuration потребителя (SURA2 → COMPONENTS → CMAKE → GOOGLETEST):
1. Добавить **Artifact Dependency** на CN900 PACKAGE gtest
2. Артефакт `googletest.zip` скачается в ту же директорию, что и раньше
3. Потребитель работает как раньше — никаких изменений в коде

**Вариант B: Полная замена**

Заменить старую Build Configuration (GT910 RELEASE) на новую Conan-based.
Артефакты те же, потребители не заметят.

---

## Шаг 7: Добавление новых пакетов

Для каждого нового пакета (например fmt, IN-352):

### 1. Создать рецепт

```
conan-recipes/
└── fmt/
    ├── conanfile.py     ← описывает как собрать
    └── src/             ← исходники (для offline сборки)
```

### 2. Добавить конфиг в package-legacy.py

```python
PACKAGE_CONFIG = {
    ...
    "fmt": {
        "components": ["fmt"],
        "platforms": ["WINDOWS", "LINUX", "LINUX_ARM_LINARO", ...],
        "definitions": [],
        "dependencies": [],
    },
}
```

### 3. Создать Build Configurations в TeamCity

Из шаблона CONAN BUILD Template — только поменять параметры:
- `package.name` = fmt
- `package.version` = 10.2.1
- Тот же `conan.profile` и `shared`

### 4. Запустить и проверить

```bash
# Тест локально
conan create fmt/ --profile=profiles/lin-gcc84-x86_64 --build=missing
python3 teamcity/package-legacy.py --name fmt --version 10.2.1 --profile lin-gcc84-x86_64 --output output
unzip -l output/fmt.zip
```

---

## Порядок миграции пакетов

Начинать с простых (без зависимостей), постепенно переходить к сложным:

| Очередь | Пакет | Зависимости | Сложность |
|---------|-------|-------------|-----------|
| 1 | gtest | нет | простой (уже готов) |
| 2 | fmt | нет | простой (IN-352) |
| 3 | zlib | нет | простой |
| 4 | cjson | нет | простой |
| 5 | gflags | нет | простой |
| 6 | glog | gflags | одна зависимость |
| 7 | openssl | нет | средний (не CMake) |
| 8 | ssh2 | openssl | одна зависимость |
| 9 | curl | openssl, zlib, ssh2 | средний |
| 10 | protobuf | zlib | средний |
| 11 | grpc | protobuf, openssl, zlib, cares, absl | сложный |

---

## Чек-лист развёртывания

### Этап 1: Подготовка
- [ ] Создать репо conan-recipes в Bitbucket
- [ ] Залить рецепты, профили, скрипты
- [ ] Установить Conan на 1 Linux-агенте (SANDBOX pool)
- [ ] Установить Conan на 1 Windows-агенте

### Этап 2: TeamCity
- [ ] Создать проект CONAN в SURA2 → COMPONENTS
- [ ] Создать VCS Root → conan-recipes
- [ ] Создать шаблон CONAN BUILD Template
- [ ] Создать CN100 Linux x64 shared (gtest)
- [ ] Создать CN110 Windows x64 shared (gtest)
- [ ] Тестовый прогон → проверить артефакты

### Этап 3: Проверка
- [ ] zip-артефакт имеет ту же структуру что старый
- [ ] CMakeLists.var корректный
- [ ] .targets файл корректный
- [ ] include/ и lib/ содержат правильные файлы
- [ ] Потребитель собирается с новым zip без изменений

### Этап 4: Расширение
- [ ] Добавить остальные профили (ARM, ATOM, WinCE)
- [ ] Добавить fmt (IN-352)
- [ ] Установить Conan на все агенты Build pool
- [ ] Мигрировать следующие пакеты по таблице выше

### Этап 5: Conan Server (опционально, позже)
- [ ] Поднять Conan Server (docker-compose)
- [ ] Настроить DNS: conan.elara.local
- [ ] Добавить `conan upload` в build step
- [ ] Conan Server как дополнительный кэш (ускоряет пересборку)
