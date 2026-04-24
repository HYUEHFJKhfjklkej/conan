# IN-353: Сборка C++ third party пакетов без внесения изменений

## Проблема

Текущая система сборки требует модификации CMakeLists.txt каждого third party пакета:
- Добавление include() кастомных CMake-модулей (ResolveDependencies, ConfigureCompiler и др.)
- Добавление CMakeLists.var с метаданными пакета
- Добавление nuget/ (.nuspec, .targets шаблоны)
- Применение патчей и адаптация под cmake/toolchains/

Это приводит к:
- Большим затратам времени при добавлении нового пакета (пример: gRPC)
- Повторной работе при обновлении версии пакета
- Сложности поддержки большого количества пропатченных пакетов

## Решение: Conan 2.x

Использовать Conan для сборки third party пакетов **без модификации** их исходников.

После сборки результат упаковывается в **тот же формат zip-артефактов**,
что и текущая система (CMakeLists.var, .targets, .nuspec, include/, lib/).
Потребители (SURA1, SURA2) **не замечают разницы**.

```
БЫЛО:                                    СТАЛО:

1. Скачать исходники                     1. Скачать исходники
2. ПРОПАТЧИТЬ CMakeLists.txt             2. НЕ ТРОГАТЬ исходники
   + CMakeLists.var                      3. conan create (conanfile.py)
   + ResolveDependencies                 4. package-legacy.py → zip
   + ConfigureTargets
   + nuget/
3. cmake → build → install
4. zip-артефакт                          Тот же zip-артефакт
```

## Архитектура

```
conan-recipes/
├── CONCEPT.md                  # Этот документ
├── DEPLOY.md                   # Инструкция по развёртыванию на TeamCity
├── ARCHITECTURE.md             # Детальная архитектура миграции
├── profiles/                   # Профили платформ
│   ├── lin-gcc84-x86_64        # Linux x64 GCC 8.4
│   ├── lin-gcc84-i686          # Linux x86 GCC 8.4
│   ├── lin-gcc75-arm-linaro    # ARM Linaro GCC 7.5 (cross)
│   ├── lin-gcc-aarch64-linaro  # ARM64 Linaro GCC 7.5 (cross)
│   ├── win-v142-x64            # Windows x64 MSVC 192
│   ├── win-v142-x86            # Windows x86 MSVC 192
│   ├── linux-gcc               # Linux generic (для тестов)
│   └── windows-msvc            # Windows generic (для тестов)
├── gtest/
│   ├── conanfile.py            # Рецепт: собирает gtest из оригинальных исходников
│   └── src/v1.14.0.tar.gz     # Исходники для offline-сборки
├── example/                    # Проект-потребитель (для проверки)
│   ├── conanfile.txt
│   ├── CMakeLists.txt
│   └── src/
├── teamcity/
│   ├── build-recipe.sh         # Сборка + legacy-упаковка для TeamCity
│   ├── build-matrix.sh         # Все комбинации профиль × shared/static
│   └── package-legacy.py       # Упаковка в legacy zip-формат
├── setup.bat                   # Offline-установка Conan на Windows
├── build_test.bat              # Тест: собрать gtest + прогнать тесты
└── build_test_legacy.bat       # Тест: собрать + упаковать в legacy zip
```

## Принцип работы

### 1. Conan-рецепт (conanfile.py)

Рецепт описывает КАК собрать пакет, не модифицируя его:

```python
class GTestConan(ConanFile):
    name = "gtest"
    version = "1.14.0"

    def source(self):
        # Скачать оригинальные исходники (или взять из src/)
        get(self, "https://github.com/.../v1.14.0.tar.gz", strip_root=True)

    def generate(self):
        # Передать нужные параметры через CMake toolchain (снаружи!)
        tc = CMakeToolchain(self)
        tc.variables["BUILD_GMOCK"] = True
        tc.generate()

    def build(self):
        # Собрать оригинальный CMake — без патчей
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        # Какие библиотеки пакет предоставляет (аналог CMakeLists.var)
        self.cpp_info.components["libgtest"].libs = ["gtest"]
        self.cpp_info.components["gtest_main"].libs = ["gtest_main"]
        self.cpp_info.components["libgmock"].libs = ["gmock"]
        self.cpp_info.components["gmock_main"].libs = ["gmock_main"]
```

Ключевой момент: **исходники пакета не модифицируются**. Все настройки передаются
через CMake-переменные (-D), toolchain файлы и Conan-профили.

### 2. Профили

Профиль определяет целевую платформу и компилятор. Один рецепт собирает пакет
под разные платформы — достаточно указать нужный профиль:

```ini
# profiles/lin-gcc84-x86_64
[settings]
os=Linux
compiler=gcc
compiler.version=8.4
compiler.libcxx=libstdc++11
build_type=Release
arch=x86_64
```

Маппинг на текущие платформы из CMakeLists.var:

| CMakeLists.var | Conan-профиль |
|---|---|
| LINUX (x64) | lin-gcc84-x86_64 |
| LINUX (x86) | lin-gcc84-i686 |
| LINUX_ARM_LINARO | lin-gcc75-arm-linaro |
| LINUX_ARM64_LINARO | lin-gcc-aarch64-linaro |
| WINDOWS (x64) | win-v142-x64 |
| WINDOWS (x86) | win-v142-x86 |

### 3. Legacy-упаковка (package-legacy.py)

После сборки Conan-ом результат упаковывается в тот же формат zip,
что и текущая система. Скрипт `package-legacy.py` генерирует:

- **CMakeLists.var** — метаданные пакета (project_name, version, components, platforms, dependencies)
- **.targets** — MSBuild-файл для NuGet-интеграции
- **.nuspec** — NuGet-спецификация

```
googletest.zip                       ← тот же формат
└── win.v142.static.x64/
    ├── build/native/*.targets       ← генерируется
    ├── include/                     ← из Conan-пакета
    ├── lib/native/                  ← из Conan-пакета
    │   ├── win-v142-static-x64/
    │   ├── win-v142-static-x64-d/
    │   └── net461/
    ├── nuget/*.nuspec               ← генерируется
    ├── proto/
    ├── CMakeLists.var               ← генерируется
    └── LICENSE.txt
```

### 4. Потребитель

Потребитель (SURA1, SURA2) получает **тот же zip-артефакт** из TeamCity
и использует его как раньше через `ResolveDependencies.cmake`.
**Никаких изменений на стороне потребителя не требуется.**

## Проверка концепта

### На Windows ПК (быстрая проверка)

```powershell
# Установить Conan (offline)
setup.bat

# Собрать gtest + прогнать тесты
build_test.bat

# Собрать + упаковать в legacy zip
build_test_legacy.bat
```

### На Linux

```bash
pip3 install conan
conan profile detect
conan create gtest/ --profile=profiles/linux-gcc --build=missing

python3 teamcity/package-legacy.py \
    --name gtest --version 1.14.0 \
    --profile linux-gcc --shared False \
    --output output

unzip -l output/googletest.zip
```

## Добавление нового пакета

Для каждого нового пакета:

1. Создать `conan-recipes/<пакет>/conanfile.py` (по аналогии с gtest)
2. Добавить конфиг в `PACKAGE_CONFIG` в `package-legacy.py`
3. Собрать: `conan create <пакет>/ --profile=profiles/...`
4. Упаковать: `python3 teamcity/package-legacy.py --name <пакет> ...`

Время: **~30 минут** вместо часов/дней при текущем подходе.

## Интеграция с текущей системой

```
Текущая система (не меняется):           Новая система (Conan):

Bitbucket: пропатченный форк             Bitbucket: conan-recipes/
    ↓                                        ↓
TeamCity: cmake с кастомным               TeamCity: conan create
          фреймворком                              + package-legacy.py
    ↓                                        ↓
Артефакт: googletest.zip                  Артефакт: googletest.zip
    ↓                                        ↓
Потребитель: ResolveDependencies ──────── Потребитель: ResolveDependencies
             (без изменений)                          (без изменений)
```

Системы не конфликтуют. Можно мигрировать пакеты по одному —
потребитель не заметит, откуда пришёл zip.

## Преимущества

| Критерий | Текущий подход | Conan |
|----------|---------------|-------|
| Модификация исходников | Да (патчи, CMakeLists.var) | Нет |
| Обновление версии | Перепатчить форк заново | Поменять version в conanfile.py |
| Кросс-платформенность | Ручная адаптация toolchains | Профили |
| Кэширование сборок | Нет | Да (Conan cache) |
| Время добавления пакета | Часы/дни (gRPC) | ~30 минут |
| Воспроизводимость | Зависит от патчей | Детерминированная |
| Формат артефактов | zip (CMakeLists.var, .targets) | **Тот же zip** |
| Изменения у потребителя | — | **Не требуются** |
