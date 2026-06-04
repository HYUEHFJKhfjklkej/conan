# Как создать пакет с нуля: пишем Conan-рецепт

## 1. Что такое рецепт и общая картина (глоссарий)

Этот гайд — для самого начинающего специалиста. Если ты почти ничего не знаешь про Conan, Python, YAML, C++ и патчи — он для тебя. Термины объясняются простыми словами один раз — в глоссарии ниже.

Наша задача: взять чужую C++ библиотеку (например `zlib`) и собрать из неё **`.nupkg`** — пакет в старом («legacy») формате, который ждут сборки Elara/SU2. Раньше это делали руками в TeamCity, теперь — Conan по **рецепту** (папка `<pkg>/` с инструкцией). Сам компилятор ты не запускаешь — пишешь инструкцию, всё делает Conan.

Главное правило всего гайда: **не пиши рецепт с нуля**. Бери готовый, проверенный, и добавляй минимум правок. Сомневаешься — спрашивай наставника, не угадывай (§10.3).

### Общая картина (три шага = три команды)

```
рецепт (<pkg>/)
      │
      │  conan create   ← собрать библиотеку (компиляция)
      ▼
готовая сборка в кэше Conan
      │
      │  conan install --deployer   ← упаковать в legacy-формат
      ▼
   .nupkg  в папке output/
```

Рецепт сам `.nupkg` не делает — он только собирает библиотеку. Форму `.nupkg` придаёт отдельный упаковщик (деплоер). Команды детально — §9.

### Мини-глоссарий (единственное место определений)

| Термин | Что это простыми словами |
|---|---|
| **Conan** | менеджер пакетов для C++: по рецепту собирает либы и хранит у себя. У нас версия 2.29.0. |
| **Рецепт** | папка `<pkg>/` с инструкцией по сборке одной библиотеки. |
| **`conanfile.py`** | главный файл рецепта; Python-инструкция (что скачать, как собрать, что упаковать). |
| **`conandata.yml`** | данные рецепта в формате YAML (`ключ: значение`): откуда брать исходники (`url` + `sha256`) и список патчей. |
| **Апстрим** | оригинальный проект библиотеки (её авторы, их сайт/репозиторий). Для zlib — `zlib.net` и `madler/zlib` на GitHub. |
| **Исходники / архив** | сами `.tar.gz` с кодом библиотеки (`.tar.gz` — как `.zip`, сжатая папка). |
| **`sha256`** | контрольная сумма архива (64-символьная строка). Сверь строку через `shasum -a 256`. Conan ею проверяет, что архив целый и не подменён. |
| **`exports_sources`** | поле рецепта: «вшей вот эти файлы (наш архив) в рецепт», чтобы они были под рукой офлайн. |
| **Патч** | маленький файл с правками к чужому коду. Свой код в чужие исходники дописываем только патчами, сам архив не трогаем. |
| **`settings` / `options`** | настройки сборки. `settings` — общие (Release/Debug, архитектура). `options` — для конкретной либы (shared/static). |
| **`deployer` / упаковщик** | скрипт `legacy_nupkg.py`: берёт готовую сборку и складывает в `.nupkg`. Руками не трогаем (кроме `LEGACY_NAME_MAP`). |
| **`.nupkg`** | итоговый пакет в старом формате (по сути `.zip`: `lib/` + `include/`). Его ждут сборки Elara/SU2. |
| **smoke-тест** | быстрый прогон «жив или нет» (англ. «проверка на дым»), не полноценные тесты. |
| **Наставник** | более опытный коллега. Первый рецепт делают вместе с ним. |

### Контракты (не нарушать)

Три нерушимых правила проекта. Дальше в гайде они помечены словом **(контракт)**.

- **Апстримные `url` и `sha256` в `conandata.yml` не меняем.** Они «как у апстрима» (наши рецепты — зеркала conan-center). Любые свои изменения исходников — только патчами в `patches/` (§7).
- **В деплоере `legacy_nupkg.py` руками трогаем только `LEGACY_NAME_MAP`.** Имя файла и всю внутреннюю раскладку `.nupkg` он собирает сам — это «байт-совместимость» со старой схемой TeamCity.
- **Slot-tag (`shared`/`static`) — это селектор, а не содержимое.** Внутри пакета всегда статические `.a`. Тег лишь указывает downstream, какой пакет брать; по умолчанию `.shared.`.

---

## 2. Структура каталога рецепта

Рецепт — это **один каталог в корне репозитория** `conan-recipes`. Разберём на самом простом примере — `zlib/`.

**Имя каталога = Conan-имя пакета** = значение поля `name` в `conanfile.py`. У zlib (`conanfile.py`, строка 11):

```python
    name = "zlib"
```

Значит каталог называется `zlib/`. Так же: `openssl/`, `grpc/`, `protobuf/`, `re2/`, `c-ares/`, `abseil/`, `gtest/`. Имя каталога и имя готового `.nupkg`-файла — **не всегда одно и то же** (каталог `gtest/`, но `.nupkg` — `googletest`); это карта `LEGACY_NAME_MAP`, §8.

### Дерево каталога (реальный `zlib/`)

```
zlib/
├── conanfile.py                       # сам рецепт: как скачать, собрать, упаковать
├── conandata.yml                      # данные: откуда брать исходники + список патчей
├── src/                               # офлайн-копии архивов с исходниками
│   ├── zlib-1.3.1.tar.gz
│   └── zlib-1.3.0.tar.gz
├── patches/                           # локальные правки исходников (по версиям)
│   └── 1.3.1/
│       └── 0001-fix-cmake.patch
└── test_package/                      # маленькая проверочная сборка (smoke-тест)
    ├── CMakeLists.txt
    ├── conanfile.py
    └── test_package.c
```

`conanfile.py` — скрипт на Python: класс `class ZlibConan(ConanFile)` с полями-«паспортом» (`name`, `settings`, `options`) и четырьмя методами-шагами — стандартным «скелетом» любого рецепта: `source()` (взять исходники), `build()` (собрать), `package()` (разложить результат), `package_info()` (рассказать CMake про библиотеку). Подробно и про две офлайн-правки в нём — §6.

`test_package/` — крошечная тестовая программа, проверяет «собранную либу реально можно подключить». Её мини-рецепт подключает только что собранный пакет (`zlib/test_package/conanfile.py`, строки 15–16):

```python
    def requirements(self):
        self.requires(self.tested_reference_str)
```

Запускать его не нужно: `conan create` прогоняет `test_package/` сам после сборки. Если `test_package` падает **на скачивании зависимости** — это про офлайн, а не про твой рецепт; зови наставника (§10.3).

### Короткое резюме

| Элемент | Зачем |
|---|---|
| `conanfile.py` | рецепт (Python): как скачать, собрать, упаковать |
| `conandata.yml` | данные (YAML): `url` + `sha256`, список патчей |
| `src/*.tar.gz` | офлайн-архивы; имя — как строит `source()` (zlib `zlib-<версия>`, gtest `v<версия>`) |
| `patches/<version>/` | свои правки исходников, по версиям |
| `test_package/` | smoke-тест; авто-проверка после `conan create` |

---

## 3. Откуда брать рецепт: conan-center-index

Готовые рецепты для тысяч C++ библиотек лежат в официальной коллекции **conan-center-index** (CCI). Берём оттуда и слегка дорабатываем под офлайн (§5–6). Наши рецепты — по сути **зеркала** conan-center плюс пара офлайн-добавок.

Ссылки:
- каталог (поиск, версии, опции): **https://conan.io/center**
- сами рецепты (исходники): **https://github.com/conan-io/conan-center-index** → `recipes/<pkg>/all/`

### Шаг 1. Найти на сайте

Открой **https://conan.io/center**, найди библиотеку по имени, открой её страницу — там видно версии и опции.
Ожидаемо: на странице есть список версий и ссылка на исходный рецепт (GitHub). Если не так: библиотеки нет в каталоге → canonical-рецепта нет, см. конец раздела.

### Шаг 2. Взять код из репозитория

Репозиторий — **https://github.com/conan-io/conan-center-index**, структура `recipes/<pkg>/all/`. Внутри `all/` (обслуживает все версии сразу) лежат `conanfile.py`, `conandata.yml`, `test_package/`, иногда `patches/`. У некоторых пакетов вместо `all/` — каталоги под версии (`1.x/`, `2.x/`); бери тот, где есть нужная версия.

### Шаг 3. Скопировать к нам

Наш репозиторий проще: **один пакет = один каталог `<pkg>/` в корне**, без промежуточного `recipes/.../all/`. Скопируй **всё содержимое** `recipes/<pkg>/all/` прямо в новый `<pkg>/` — не только `conanfile.py`, `conandata.yml`, `test_package/`, но и **любые соседние файлы рядом с `conanfile.py`**: `CMakeLists.txt`, `*.cmake`, `*.patch` и т.п. У некоторых либ (например bzip2) у апстрима нет своего CMake — рецепт несёт **собственный `CMakeLists.txt`** рядом с `conanfile.py`, и без него сборка упадёт `CMakeLists.txt not found`.
Ожидаемо: в `conan-recipes/<pkg>/` появились `conanfile.py`, `conandata.yml` и все sibling-файлы из `all/` (как в примере `zlib/`). Если не так: скопировал лишний уровень `all/` — перенеси файлы на уровень выше.

### Правило копирования (запомни по имени — на него ссылается весь гайд)

Где брать офлайн-правки (§5–6) зависит от того, ОТКУДА ты копировал:

- **(а) Чистый рецепт с conan.io/center (CCI).** Офлайн-правок там НЕТ — это апстрим «как есть». Значит две правки (`exports_sources` и офлайн-ветку в `source()`, §6) добавляешь **сам**.
- **(б) Наш соседний рецепт (`zlib/`, `openssl/`, `grpc/`).** Офлайн-правки **уже на месте**. Тогда ты их не дописываешь, а **проверяешь, что есть**, и меняешь под свою либу (имя файла архива и т.п.). У `zlib/conanfile.py` уже есть и `exports_sources = "src/*.tar.gz"` (строка 33), и `export_sources()` (строки 35–36) — дублировать не надо.

Не дописывай правки вслепую: сначала открой скопированный `conanfile.py` и посмотри, что в нём уже есть. Контракт нерушим в обоих случаях.

### Если canonical-рецепта нет

Нужной либы в CCI может не быть вообще. Тогда рецепт пишем **сами, но по тем же конвенциям**: та же структура каталога (§2), те же методы `source()/build()/package()/package_info()`, тот же формат `conandata.yml`. За образец — ближайший по типу сборки наш рецепт: `zlib/` (самый простой), `openssl/`, `grpc/`. Это сложнее и ошибок больше — делать **с наставником**.
Ожидаемо: даже самописный рецепт выглядит как наши существующие. Если не так: структура расходится с `zlib/` — сверься с примером и позови наставника.

---

## 4. conandata.yml — источники и контрольные суммы

`conandata.yml` — это **данные** к рецепту: откуда взять исходники и какие патчи накладывать. Два блока: `sources` и `patches`.

### Блок `sources` построчно (реальный zlib)

```yaml
sources:
  "1.3.1":
    url:
      - "https://zlib.net/fossils/zlib-1.3.1.tar.gz"
      - "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
    sha256: "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
```

- **`"1.3.1":`** — версия в кавычках, работает как **ключ**. Через этот ключ связаны три вещи: `--version=1.3.1` при сборке (§9), блок в `sources` и (если есть) блок в `patches`.
- **`url:`** — список ссылок (`-` = элемент списка YAML) на архив апстрима. Несколько ссылок = **зеркала**: первая недоступна — Conan берёт следующую.
- **`sha256:`** — контрольная сумма архива (§1). Не сходится — Conan останавливается с ошибкой `sha256 ... failed`.

Апстримные `url` и `sha256` **не меняем (контракт)** — не правь ссылки, не подставляй `file://`. Нужно изменить сами исходники — только патчами в `patches/` (§7); архив и сумма при этом не трогаются (патч ложится после распаковки).

> **Откуда брать сам `sha256`, если пишешь рецепт руками** (нет готового `conandata.yml` из CCI): легитимная сумма берётся **со стороны апстрима/CCI**, а не из твоего скачанного файла — скопируй её из `conandata.yml` соответствующего рецепта в conan-center-index (ссылки в §3) или из официального чексумма апстрима. Твой `shasum -a 256` (§5) эту сумму только **подтверждает**, источником её не является — иначе любой битый/подменённый архив «совпадёт сам с собой».

### Пример со второй версией: переименование архива (zlib 1.3.0)

В zlib есть и ключ `1.3.0`. Комментарий прямо в файле:

```yaml
  "1.3.0":
    # Legacy version requested by GR113/120 consumers. Upstream tag is "v1.3"
    # (file zlib-1.3.tar.gz) — the offline copy in src/ is renamed to
    # zlib-1.3.0.tar.gz so conanfile.py picks it up via the
    # "zlib-${version}.tar.gz" lookup convention.
    url:
      - "https://github.com/madler/zlib/releases/download/v1.3/zlib-1.3.tar.gz"
    sha256: "ff0ba4c292013dbc27530b3a81e1f9a813cd39de01ca5e0f8bf355702efa593e"
```

У апстрима тег `v1.3`, файл — `zlib-1.3.tar.gz`. Но рецепт ищет по шаблону `zlib-<версия>.tar.gz`, то есть для `1.3.0` ждёт `zlib-1.3.0.tar.gz`. Поэтому **локальную копию в `src/` переименовывают** под имя из `source()`, а `url` в YAML остаётся апстримным (контракт). Подробнее про укладку — §5.

### Блок `patches`

```yaml
patches:
  "1.3.1":
    - patch_file: "patches/1.3.1/0001-fix-cmake.patch"
      patch_description: "separate static/shared builds, disable debug suffix"
      patch_type: "conan"
```

Снова ключ-версия, под ним список патчей: путь (`patch_file`), описание (`patch_description`), тип (`patch_type`). Это легальный способ менять исходники, не трогая `url`/`sha256`. Детально — §7.

Ожидаемо: в `conandata.yml` есть `sources` с ключами-версиями в кавычках, у каждой — `url` (список) и `sha256`; при необходимости — `patches` с теми же ключами. Если не так: при сборке вылетает `sha256 ... failed` (→ §10.2).

---

## 5. Положить исходники в src/ (offline)

На боевой машине **нет интернета**, скачать исходники Conan не может. Решение: один раз скачать архив заранее и положить в `<pkg>/src/`; сборка берёт его с диска.

### Шаг 1. Скачать архив

Возьми любую ссылку из поля `url` своего `conandata.yml` (§4). Качай **с машины, где есть интернет** (например с Mac):

```bash
curl -L -o zlib-1.3.1.tar.gz "https://zlib.net/fossils/zlib-1.3.1.tar.gz"
```

Ожидаемо: файл `zlib-1.3.1.tar.gz` появился, не ноль байт. Если не так: нет интернета — скачай на другой машине, перенеси файл.

### Шаг 2. Сверить sha256 локально (секунда на Mac vs 10–25 мин на dev-VM)

Сверь контрольную сумму с полем `sha256` в `conandata.yml` (§1), пока не запустил долгую сборку:

```bash
shasum -a 256 zlib-1.3.1.tar.gz
```

(на Linux — `sha256sum zlib-1.3.1.tar.gz`).
Ожидаемо: 64-символьная строка совпадает с `sha256` для твоей версии. Если не так: сумма не совпала (→ §10.2). Сумму в `conandata.yml` под битый файл **не подгоняй (контракт)** — сначала добейся правильного архива.

### Шаг 3. Положить в `<pkg>/src/`

```bash
mkdir -p zlib/src
cp zlib-1.3.1.tar.gz zlib/src/
```

Ожидаемо: файл лежит как `zlib/src/zlib-1.3.1.tar.gz`. Если не так: проверь, что папка именно `<pkg>/src/`, а не `<pkg>/`.

### Шаг 4. Имя файла — как строит `source()` в ТВОЁМ рецепте

> **Это самая частая ошибка во всём гайде.** Имя файла в `src/` обязано совпадать с тем, что строит метод `source()`. Имя **НЕ универсально** — нет конвенции «всегда `имя-версия`». Открой `source()` в своём рецепте и прочти строку `local_archive = ...`, не угадывай по шаблону. Не совпало → сборка падает `source ... No such file` (→ §10.2).

- У **zlib**: `f"zlib-{self.version}.tar.gz"` → для `1.3.1` файл `zlib-1.3.1.tar.gz`.
- У **gtest**: `f"v{self.version}.tar.gz"` → для `1.15.2` файл `v1.15.2.tar.gz` (без слова `gtest`!).

`{self.version}` — это то, что ты передаёшь в `--version=...` при сборке (§9); Conan подставит его в имя и будет искать файл ровно с таким именем.

### Переименование

Если апстрим назвал архив иначе, чем ждёт `source()`, — **переименуй** (только имя файла, содержимое и `sha256` не трогаем, контракт). Реальный случай: тег `v1.3` даёт `zlib-1.3.tar.gz`, а рецепт ищет `zlib-1.3.0.tar.gz`:

```bash
cp zlib-1.3.tar.gz zlib/src/zlib-1.3.0.tar.gz
```

Ожидаемо: в `src/` лежит `zlib-1.3.0.tar.gz`, хотя скачали `zlib-1.3.tar.gz` (→ §10.2 при ошибке).

---

## 6. conanfile.py — две offline-правки (главное)

**Самая важная часть гайда.** Обычный рецепт с conan-center при сборке лезет в интернет за архивом. На боевой машине интернета нет. Поэтому кладём архив рядом (в `src/`, §5) и учим рецепт брать его оттуда — ровно **две правки**. Больше ничего не трогаем.

Сначала проверь, нет ли правок уже (см. «Правило копирования» в §3): при копировании нашего рецепта обе правки уже на месте — у `zlib/conanfile.py` `exports_sources` на строке 33, офлайн-ветка `source()` на строках 51–58.

### Правка 1 — поле `exports_sources`

В тело класса (рядом с `name`, `settings`, `options`), с отступом 4 пробела. Дословно из `zlib/conanfile.py` (строки 30–33):

```python
    # Bundle the upstream archive with the recipe so offline machines
    # (no internet) can still build. Conan copies it into the recipe
    # cache when the recipe is exported.
    exports_sources = "src/*.tar.gz"
```

Маска `"src/*.tar.gz"` = «вшей все `.tar.gz` из `src/` в рецепт при export». Без неё офлайн-архив до сборки не доедет.

> **Если в скопированном рецепте `exports_sources` УЖЕ есть** и перечисляет файлы (например `"CMakeLists.txt"` — как у bzip2), то `"src/*.tar.gz"` нужно **дописать к списку**, а не заменить строку — иначе затрёшь файл, который нужен сборке (`CMakeLists.txt not found`):
> ```python
>     exports_sources = "CMakeLists.txt", "src/*.tar.gz"
> ```

### Правка 2 — метод `source()`

Логика: **сперва ищем вшитый архив; нашли — `unzip`; не нашли — только тогда `get` из интернета.** Дословно из `zlib/conanfile.py`, строки 51–58:

```python
    def source(self):
        # Prefer the bundled archive (offline-friendly).
        local_archive = os.path.join(self.export_sources_folder, "src", f"zlib-{self.version}.tar.gz")
        if os.path.exists(local_archive):
            unzip(self, local_archive, destination=self.source_folder, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version],
                destination=self.source_folder, strip_root=True)
```

Разбор load-bearing строк:

- **`self.export_sources_folder`** — папка, куда Conan распаковал то, что мы вшили правкой 1. Имя файла `f"zlib-{self.version}.tar.gz"` бери из канона, что копируешь: у zlib `zlib-{version}`, у **gtest** — `f"v{self.version}.tar.gz"` (`gtest/conanfile.py`, строка 62), иначе для gtest получишь «No such file».
- **`if exists: unzip / else: get`** — это и есть офлайн-развилка. `unzip` распаковывает локальный архив без интернета; `get` качает из сети (проверяет sha256 и распаковывает).
- **`strip_root=True`** — выкинуть верхнюю папку из архива (внутри `zlib-1.3.1.tar.gz` всё в подпапке `zlib-1.3.1/`), чтобы исходники легли сразу в `source_folder`.
- **`**self.conan_data["sources"][self.version]`** — данные из `conandata.yml` (url + sha256) для версии; `**` разворачивает их в аргументы `get`.
- **Контраст с gtest:** у gtest ветка `get(...)` вызвана БЕЗ `destination` — просто `get(self, **self.conan_data["sources"][self.version], strip_root=True)` (`gtest/conanfile.py`, строка 66). У gtest другой layout, `destination` не нужен. Не «причёсывай» аргументы под zlib — оставляй как в каноне, который копируешь.

> ВАЖНО (SameFileError): **не** скармливай локальный файл в `get` через `get(self, "file://...")` — Conan падает с `SameFileError` (копирует файл сам в себя). Именно поэтому для вшитого архива зовём `unzip()`, а `get()` оставляем только для скачивания из сети.

### Нужные импорты

Чтобы `unzip`, `get` и патч-функции работали, вверху файла должна быть строка из `conan.tools.files` (`zlib/conanfile.py`, строка 3):

```python
from conan.tools.files import apply_conandata_patches, export_conandata_patches, get, load, replace_in_file, save, unzip
```

Главное — чтобы в списке были `unzip` и `get`. **Если их нет** — допиши недостающее имя **в существующую строку** через запятую. **Не** создавай вторую строку импорта — иначе `NameError: name 'unzip' is not defined`.

Ожидаемо: `conan create` офлайн проходит этап `source` без обращения к сети. Если не так — `SameFileError`, `No such file` или `NameError` (→ §10.2).

Все прочие методы (`build()`, `package()`, `package_info()`, поля класса) **берём из канона и не трогаем** — чем меньше отличий, тем легче обновлять. Патчи подключаются отдельно — §7.

---

## 7. Патчи — если апстрим не собирается как есть

**Патч** (§1) нужен, когда исходники не собираются у нас как есть или собираются не так, как надо: падают на нашем компиляторе; CMake-файл делает не то (лепит суффикс к `.so`, мешает static и shared); надо поправить ассемблер/флаги под ARM. Реальный пример — zlib: его CMake не разделяет static/shared и навешивает `debug`-суффикс, патч `0001-fix-cmake.patch` это чинит.

Правка исходников — **только через патч (контракт)**; распаковывать архив и руками править `.c`/`CMakeLists.txt` нельзя.

### Куда класть файл

```
<pkg>/patches/<version>/NNNN-короткое-описание.patch
```

`<version>` — версия, к которой патч применяется; `NNNN` — порядковый номер с нулями (`0001`, `0002`, …), так патчи применяются по порядку. Реальный путь: `zlib/patches/1.3.1/0001-fix-cmake.patch`. Для версии без патчей каталога `patches/<version>/` просто нет — это нормально.

### Зарегистрировать в `conandata.yml`

Сам `.patch` не подхватится автоматически — пропиши его в блоке `patches:` (формат и поля — §4):

```yaml
patches:
  "1.3.1":
    - patch_file: "patches/1.3.1/0001-fix-cmake.patch"
      patch_description: "separate static/shared builds, disable debug suffix"
      patch_type: "conan"
```

`patch_file` — путь относительно каталога рецепта `<pkg>/`; `patch_type` для наших правок — `"conan"`.

### Как рецепт применяет патчи (две строки в `conanfile.py`)

Обе функции импортируются из `conan.tools.files` (у zlib строка импорта уже есть, §6):

```python
from conan.tools.files import apply_conandata_patches, export_conandata_patches, get, load, replace_in_file, save, unzip
```

**1) Положить патчи в кэш** — метод `export_sources()` (у нашего `zlib/conanfile.py` уже есть, строки 35–36; см. «Правило копирования» §3):

```python
    def export_sources(self):
        export_conandata_patches(self)
```

**2) Применить к распакованным исходникам** — `apply_conandata_patches(self)`. У zlib он в служебном `_patch_sources()`, который зовётся из `build()`:

```python
    def _patch_sources(self):
        apply_conandata_patches(self)
        # ... дальше идут точечные replace_in_file (это уже специфика zlib) ...

    def build(self):
        self._patch_sources()
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
```

Главное — чтобы `apply_conandata_patches` сработал **до** `cmake.configure()` (внутри `build()`, как у zlib, или в конце `source()`).

### Как сделать сам `.patch` (формат — частый источник ошибок)

Самая частая беда — неверные префиксы путей внутри файла, поэтому первый патч делай **с наставником**. `apply_conandata_patches` по умолчанию срезает один уровень пути (`strip=1`), то есть ждёт привычные префиксы `a/` и `b/` (как у `git diff`). Другие префиксы (`orig/`, `edited/`) → `hunk FAILED`.

Надёжный способ получить `a/`/`b/` — делать diff **внутри git-репозитория**, а не сравнивать две папки:

```bash
# 1. Распаковать исходники апстрима в рабочую папку и сделать её git-репозиторием:
tar xzf <pkg>/src/<имя-как-в-source>.tar.gz
cd <распакованная-папка>
git init -q && git add -A && git commit -qm base   # зафиксировали оригинал

# 2. Внести нужные правки прямо в этих файлах (поправить CMakeLists.txt и т.п.).

# 3. Сохранить разницу в файл патча — git сам проставит префиксы a/ и b/:
git diff > /путь/к/0001-короткое-описание.patch
```

> Почему НЕ `git diff --no-index orig/ edited/`: он проставит префиксы `orig/`/`edited/`, которые `apply_conandata_patches` со своим `strip=1` снять не сможет — патч не ляжет, `hunk FAILED` ничего не объяснит. Делай через `git init` + `git diff`.

Дальше: положи файл в `<pkg>/patches/<version>/`, пропиши в `conandata.yml`, убедись что в `conanfile.py` есть `export_conandata_patches(self)` и `apply_conandata_patches(self)`.
Ожидаемо: в логе `conan create` строка `Apply patch (conan): ...`, сборка проходит. Если не так — `hunk FAILED` или `No such file` (→ §10.2).

---

## 8. Имена пакета и карта LEGACY_NAME_MAP

У пакета **два имени**: **Conan-имя** (имя каталога = поле `name`; им пользуешься в командах, `conan create zlib/`) и **legacy-имя** (попадёт в `.nupkg`, под ним пакет ищут потребители Elara). Для большинства либ они **совпадают** (`zlib`→`zlib`, `openssl`→`openssl`, `re2`, `protobuf`, `grpc`). У некоторых отличаются — тогда вступает карта.

### Карта LEGACY_NAME_MAP

Словарь «Conan-имя → legacy-имя» в `extensions/deployers/legacy_nupkg.py`:

```python
# Маппинг имён Conan → legacy
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    "abseil": "absl",
    "c-ares": "cares",
}
```

`gtest` → `googletest`, `abseil` → `absl`, `c-ares` → `cares` (дефис убран: downstream `ResolveDependencies.cmake` подставляет имя в `-D<имя>_..._DEFINE` и не чистит дефис — `-Dc-ares_...` ломает компилятор).

Имени нет в карте → деплоер берёт Conan-имя как есть. Поэтому `zlib`, `openssl`, `re2`, `protobuf`, `grpc` записывать не нужно.

**Когда добавлять строку:** имена совпадают → ничего не делаешь, карту не трогаешь. Имена отличаются → добавляешь **одну строку**. Например, либа `mylib`, а смежники ждут `my-legacy-lib`:

```python
LEGACY_NAME_MAP = {
    "gtest": "googletest",
    "abseil": "absl",
    "c-ares": "cares",
    "mylib": "my-legacy-lib",
}
```

Ожидаемо: `.nupkg` начнётся с `my-legacy-lib`. Если не так — строку не добавил или ошибся в Conan-имени слева (→ §10.2). Больше в `legacy_nupkg.py` руками ничего не трогаем (контракт).

### Имя файла .nupkg и slot-tag

Имя собирается по шаблону:

```
<name>.<os>.<compiler>.<linkage>.<arch>.<ver>.nupkg
```

`<name>` — legacy-имя; `<os>` — `lin`/`win`/`mac`; `<compiler>` — `gcc8`/`gcc84`/`v142`; `<linkage>` — слот-тег `shared`/`static`; `<arch>` — `x86_64`/`x64`; `<ver>` — версия. Пример из смоук-сборки: `output/googletest.lin.gcc8.shared.x86_64.1.15.2.nupkg` (Conan-имя было `gtest` — сработала карта; тег `gcc8` = смоук, не для поставки, §9).

Slot-tag (`shared`/`static`) — **селектор, а не содержимое (контракт)**: внутри всегда `.a`, тег лишь указывает downstream какой пакет брать. По умолчанию оставляй `.shared.`.

---

## 9. Собрать и упаковать рецепт

Проверяем рецепт на учебной (смоук) сборке — быстро, на голой машине, без Docker. Все команды — **из корня репозитория** `conan-recipes/`. Замени `<pkg>` на имя каталога (`zlib`), `<ver>` на версию (`1.3.1`).

### Шаг 0. Активировать окружение

```bash
source venv/bin/activate
```

Ожидаемо: `conan --version` → `2.29.0`. Если `conan: command not found` — забыл `source venv/bin/activate` (→ §10.2). Если и `venv/` нет — нужна разовая настройка (только Linux/Astra, из корня репозитория):

```bash
sudo ./test-astra/install_deps.sh   # apt-зависимости: gcc, cmake, python3-venv
./test-astra/setup.sh               # создаёт venv и офлайн-ставит Conan из packages-linux/
source venv/bin/activate            # активировать (после setup.sh и в каждой новой сессии)
```

На **Mac** этих apt-скриптов может не быть — если `venv/` нет, не запускай `install_deps.sh`, спроси наставника.

### Шаг 1–2. Собрать Release и Debug

`conan create` собирает библиотеку и кладёт результат в кэш Conan:

```bash
conan create <pkg>/ --version=<ver> -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc -s build_type=Release --build=missing --no-remote
conan create <pkg>/ --version=<ver> -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc -s build_type=Debug   --build=missing --no-remote
```

Флаги (объясняются здесь один раз):
- `<pkg>/` — каталог с рецептом; `--version=<ver>` — какую версию собирать (она же в `conandata.yml`, §4).
- `-pr:h=profiles/astra-gcc` — **host-профиль**: чем и под что собирать саму библиотеку. `astra-gcc` = учебный (тег `gcc8`; **не** для поставки).
- `-pr:b=profiles/astra-gcc` — **build-профиль**: чем собирать вспомогательные инструменты (cmake, perl). **Указывай всегда** — без него Conan офлайн может попытаться достать инструмент из интернета и упасть. Точный список учить не надо.
- `-s build_type=Release` / `Debug` — режим сборки. **Нужны обе:** деплоер берёт из кэша и релизный, и отладочный вариант; соберёшь одну — упаковка (шаг 3) не найдёт вторую.
- `--build=missing` — собрать из исходников то, чего нет в кэше.
- `--no-remote` — не ходить в интернет; всё локально (исходники из `src/`, пакеты из `packages-linux/`).

Ожидаемо: обе команды кончаются `Build succeeded`, в логе виден зелёный прогон `test_package`. Если не так — типовые ошибки в §10.2.

`conan create` **сам** прогоняет `test_package/` (§2). Зелёный `test_package` = рецепт рабочий (либа собралась, заголовки и `.a` на месте, подключение работает). Падает на скачивании зависимости — это офлайн, не твой рецепт; зови наставника (→ §10.2).

### Шаг 3. Упаковать в .nupkg (деплоер)

```bash
conan install --requires=<pkg>/<ver> -pr:h=profiles/astra-gcc -pr:b=profiles/astra-gcc --no-remote --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/
```

- `--requires=<pkg>/<ver>` — взять из кэша уже собранный пакет; `-pr:h`/`-pr:b`/`--no-remote` — как выше.
- `--deployer=...legacy_nupkg.py` — какой упаковщик запустить; `--deployer-folder=output/` — куда положить `.nupkg`.

Ожидаемо: в `output/` появился `<legacy_name>.lin.gcc8.shared.x86_64.<ver>.nupkg`; внутри (это zip) — `lib/native/<suffix>/*.a` и `include/` (имя — §8). Если не так — имя «не то» или нет пары Release/Debug (→ §10.2).

### Важно: это смоук, не поставка

Профиль `astra-gcc` даёт тег **`gcc8`** — годится только убедиться, что рецепт жив.

> **АНТИ-ШАГ (жёстко): файл с тегом `gcc8` из `output/` НИКОГДА не отдавай смежникам.** Это мусор для самопроверки, даже при всех галочках чеклиста — `gcc8`-артефакт негоден к поставке.

**Поставляемый** артефакт собирается профилем `lin-gcc84-x86_64` (тег `gcc84`) и **только внутри Docker-образа** `grpc-tc-mirror` (на голой машине системный gcc не тот). Смоук-файл `...gcc8...` и боевой `...gcc84...` — два разных файла. Боевую сборку здесь не описываем, см.:
- `test-astra/HOWTO-create-package.md` — пошагово боевая сборка (именно `-create-package`; рядом `HOWTO-packages.md` — про другое, не путай);
- `test-astra/HELP.txt` — нумерованные блоки. Номер блока со временем сдвигается, поэтому найди блок про сборку по словам `conan create` / `deployer`, а не по номеру.

---

## 10. Проверка, типовые ошибки и чеклист "рецепт с 0"

### 10.1. Как понять, что рецепт готов

Три шага, все должны пройти (команды и флаги — §9):

1. **`conan create` Release и Debug** → оба `Build succeeded`, без `ERROR`.
2. **`test_package` зелёный** — прогоняется автоматически внутри `conan create`; в конце вывода блок `<pkg>/<ver> (test package): ...` и `Running test()` без ошибок.
3. **`.nupkg` появился в `output/`** после `conan install --deployer` (§9, шаг 3). Проверь содержимое, не распаковывая:

```bash
ls output/
unzip -l output/<legacy_name>.lin.gcc8.shared.x86_64.<ver>.nupkg
```

Ожидаемо: файл в `output/` есть, внутри — `lib/native/<suffix>/*.a` и `include/`. Тег `gcc8` = смоук, смежникам не отдаём (§9). Любая осечка на шагах 1–3 → каталог ошибок §10.2.

### 10.2. Каталог типовых ошибок

| Симптом (что видишь) | Причина | Фикс | § |
|---|---|---|---|
| `sha256 signature failed` / `checksum ... does not match` | сумма архива в `src/` не совпала с `sha256` в `conandata.yml` (битый архив или не тот файл) | перекачай архив по `url`, сверь `shasum -a 256`. Сумму в YAML под битый файл не правь (контракт) | §5 |
| `source ... No such file` / архив не найден | файла нет в `<pkg>/src/`, или имя не совпадает с тем, что строит `source()` (zlib `zlib-<версия>`, gtest `v<версия>`) | открой `source()`, положи/переименуй архив под нужное имя в `src/` | §5 |
| `SameFileError` | в `source()` локальный файл подан через `get(file://...)` | бери локальный архив через `unzip()`, а не `get()` (точный код ниже) | §6 |
| падение на `tool_requires` / `cmake` / `perl` | забыл `-pr:b` (build-профиль) — Conan офлайн тянет инструмент из сети | добавь `-pr:b=profiles/astra-gcc` в `conan create` и `conan install` | §9 |
| `NameError: name 'unzip' is not defined` (или `get`) | функция вызвана в `source()`, но не импортирована | допиши имя в **существующую** строку `from conan.tools.files import ...` через запятую, не создавай вторую | §6 |
| `patch ... hunk FAILED` / `No such file` (патч) | патч под другую версию, «не те» префиксы путей, или `patch_file` не совпадает с файлом | сделай патч через `git init`+`git diff` (`a/`/`b/`), сверь версию и путь, зови наставника | §7 |
| имя `.nupkg` «не то» (напр. `gtest` вместо `googletest`) | legacy-имя ≠ Conan-имя, а записи в карте нет | добавь строку в `LEGACY_NAME_MAP` в `legacy_nupkg.py`; больше в нём ничего не трогай (контракт) | §8 |
| `.nupkg` вообще не появился в `output/` | не собрана пара Release + Debug | вернись к §9 шаг 1–2, собери оба типа | §9 |
| `test_package` падает на скачивании зависимости | офлайн — нужной зависимости нет под рукой (не про твой код) | не угадывай, зови наставника | §10.3 |
| `conan: command not found` | не активировал venv | `source venv/bin/activate`; `conan --version` → `2.29.0` | §9 |

Точный рабочий код `source()` для случая `SameFileError` (дословно из `zlib/conanfile.py`):

```python
    def source(self):
        # Prefer the bundled archive (offline-friendly).
        local_archive = os.path.join(self.export_sources_folder, "src", f"zlib-{self.version}.tar.gz")
        if os.path.exists(local_archive):
            unzip(self, local_archive, destination=self.source_folder, strip_root=True)
        else:
            get(self, **self.conan_data["sources"][self.version],
                destination=self.source_folder, strip_root=True)
```

### 10.3. Главное правило: не угадывай

- **Не уверен — спроси наставника.** Лучше вопрос, чем сломанная байт-совместимость `.nupkg` (продукты Elara перестанут собираться).
- **Первый рецепт делай ВМЕСТЕ с наставником.** Цикл на dev-VM долгий (10–25 мин), каждая опечатка дорого стоит — сначала прогоняй локально на Mac.
- **Структурные решения — через тимлида**, не выдумывай локально.
- Бери за образец готовые рецепты: `zlib/` (самый простой), `openssl/`, `grpc/`.

### 10.4. Отрывной чеклист (он же оглавление)

Печатай и отмечай по ходу. Тег `(§N)` ведёт к разделу.

**Подготовка**
- [ ] Окружение активировано: `source venv/bin/activate`; `conan --version` → `2.29.0` (§9)
- [ ] Нашёл canonical-рецепт на conan.io/center; нет — пишу с нуля по образцу `zlib/` (§3)
- [ ] Понял по «Правилу копирования», ОТКУДА копирую: с CCI (правки добавляю сам) или с нашего рецепта (правки уже есть, проверяю) (§3)

**Каталог рецепта `<pkg>/`**
- [ ] Создал `<pkg>/` в корне; имя каталога = Conan-имя (поле `name`) (§2)
- [ ] `conanfile.py` — canonical; обе offline-правки на месте (§6):
  - [ ] поле `exports_sources = "src/*.tar.gz"`
  - [ ] `source()` — сначала локальный архив через `unzip()`, иначе `get()` (НЕ `get(file://...)`)
  - [ ] импорты `unzip` и `get` в одной строке `from conan.tools.files import ...`
- [ ] `conandata.yml` — `url` + `sha256` апстрима НЕ трогал; патчи прописаны (§4)
- [ ] Патчи, если нужны свои правки исходников (§7):
  - [ ] `export_sources(self): export_conandata_patches(self)` (у наших рецептов уже есть)
  - [ ] при сборке вызывается `apply_conandata_patches(self)`
  - [ ] импорты `apply_conandata_patches, export_conandata_patches` из `conan.tools.files`
  - [ ] патч сделан через `git init` + `git diff` (`a/`/`b/`), не `--no-index orig/ edited/`

**Оффлайн-исходники `src/` (§5)**
- [ ] Скачал архив апстрима (по `url`) с машины с интернетом
- [ ] Сверил `sha256` локально (`shasum -a 256`) — совпадает с `conandata.yml`
- [ ] Положил в `<pkg>/src/`; имя — как строит `source()` (zlib `zlib-<версия>`, gtest `v<версия>`); переименовал, если апстрим назвал иначе

**Карта имён — только если legacy-имя ≠ Conan-имя (§8)**
- [ ] Добавил строку в `LEGACY_NAME_MAP` в `extensions/deployers/legacy_nupkg.py`

**Сборка и проверка (смоук, профиль `astra-gcc`) (§9)**
- [ ] `conan create ... -s build_type=Release --build=missing --no-remote` → OK
- [ ] `conan create ... -s build_type=Debug --build=missing --no-remote` → OK
- [ ] `-pr:b=profiles/astra-gcc` присутствует в командах
- [ ] `test_package` зелёный (автоматически внутри `conan create`)

**Упаковка `.nupkg` (§9)**
- [ ] `conan install --requires=<pkg>/<ver> ... --deployer=...legacy_nupkg.py --deployer-folder=output/` → OK
- [ ] В `output/` появился `<legacy_name>.lin.gcc8.shared.x86_64.<ver>.nupkg`
- [ ] `unzip -l output/...nupkg` показывает `lib/native/<suffix>/*.a` и `include/`
- [ ] Понимаю: `gcc8`-файл — смоук, смежникам НЕ отдаю

**Перед поставкой (§9)**
- [ ] Боевую сборку (профиль `lin-gcc84-x86_64` в Docker `grpc-tc-mirror`) делаю по `test-astra/HOWTO-create-package.md` (не `HOWTO-packages.md`) и по блоку про сборку в `HELP.txt`
- [ ] Сомневаешься хоть в одном пункте — НЕ угадываешь, идёшь к наставнику (§10.3)
