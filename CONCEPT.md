# IN-353: Сборка C++ third party пакетов без внесения изменений

## Проблема

Текущая система сборки требует модификации CMakeLists.txt каждого third party пакета:
- Добавление include() кастомных CMake-модулей (ResolveDependencies, ConfigureCompiler и др.)
- Адаптация под install.json
- Применение патчей

Это приводит к:
- Большим затратам времени при добавлении нового пакета (пример: gRPC)
- Повторной работе при обновлении версии пакета
- Сложности поддержки большого количества пропатченных пакетов

## Решение: Conan 2.x

Использовать Conan как систему управления C++ зависимостями. Conan позволяет:
- Собирать пакеты из оригинальных исходников без модификации
- Управлять версиями и зависимостями
- Поддерживать кросс-платформенную сборку (Linux/Windows) через профили
- Кэшировать собранные пакеты (не пересобирать каждый раз)

## Архитектура

```
conan-recipes/
├── CONCEPT.md              # Этот документ
├── profiles/
│   ├── linux-gcc           # Release Linux GCC 12
│   ├── linux-gcc-debug     # Debug Linux GCC 12
│   ├── windows-msvc        # Release Windows MSVC 193
│   └── windows-msvc-debug  # Debug Windows MSVC 193
├── gtest/
│   └── conanfile.py        # Рецепт: собирает gtest из исходников
├── example/
│   ├── conanfile.py         # Проект-потребитель
│   ├── CMakeLists.txt
│   └── src/
│       ├── example.hpp
│       ├── example.cpp
│       └── example_test.cpp
└── <другие пакеты>/        # Добавляются по аналогии с gtest
    └── conanfile.py
```

## Принцип работы

### 1. Conan-рецепт (conanfile.py)

Рецепт описывает КАК собрать пакет, не модифицируя его:

```python
class GTestConan(ConanFile):
    def source(self):
        # Скачать оригинальные исходники
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
```

Ключевой момент: исходники пакета не модифицируются. Все настройки передаются
через CMake-переменные (-D), toolchain файлы и Conan-профили.

### 2. Профили

Профиль определяет целевую платформу, компилятор и тип сборки:

```ini
[settings]
os=Linux
compiler=gcc
compiler.version=12
build_type=Release
arch=x86_64
```

Один и тот же рецепт собирает пакет под разные платформы — достаточно
указать нужный профиль.

### 3. Потребитель

Проект, использующий third party пакеты, подключает их через стандартный
CMake find_package():

```cmake
find_package(GTest REQUIRED)
target_link_libraries(my_target GTest::gtest)
```

Conan генерирует необходимые CMake-конфиги автоматически.

## Инструкция по сборке

### Предварительные требования

- Python 3.x
- Conan 2.x: `pip install conan`
- CMake >= 3.15
- Компилятор (gcc/msvc)

### Шаг 1: Настройка Conan (один раз)

```bash
conan profile detect
```

### Шаг 2: Сборка gtest из рецепта

```bash
# Linux
cd conan-recipes
conan create gtest/ --profile=profiles/linux-gcc

# Windows
conan create gtest/ --profile=profiles/windows-msvc
```

Conan скачает исходники gtest, соберёт их и поместит в локальный кэш.

### Шаг 3: Сборка проекта-потребителя

```bash
cd example

# Установить зависимости (gtest возьмётся из кэша)
conan install . --output-folder=build --build=missing --profile=../profiles/linux-gcc

# Сконфигурировать и собрать
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Запустить тесты
cd build && ctest --output-on-failure
```

## Добавление нового third party пакета

Для добавления нового пакета (например, spdlog):

1. Создать директорию `conan-recipes/spdlog/`
2. Создать `conanfile.py` по аналогии с gtest
3. Собрать: `conan create spdlog/ --profile=profiles/linux-gcc`

Пример минимального рецепта:

```python
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get


class SpdlogConan(ConanFile):
    name = "spdlog"
    version = "1.13.0"
    settings = "os", "compiler", "build_type", "arch"

    def source(self):
        get(self, "https://github.com/gabime/spdlog/archive/refs/tags/v1.13.0.tar.gz",
            strip_root=True)

    def layout(self):
        cmake_layout(self)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["SPDLOG_BUILD_EXAMPLE"] = False
        tc.variables["SPDLOG_BUILD_TESTS"] = False
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["spdlog"]
```

## Интеграция с внутренней системой сборки

Внутренние CMake-модули (ConfigureCompiler, ResolveDependencies и др.)
продолжают использоваться для ВАШИХ проектов. Разделение:

- **Внутренний код**: собирается вашей системой сборки (кастомные модули, install.json)
- **Third party**: собирается Conan-рецептами из оригинальных исходников

Conan и внутренняя система сборки не конфликтуют — Conan предоставляет
стандартные CMake-таргеты через find_package(), которые ваш CMake подхватывает.

## Преимущества

| Критерий | Текущий подход | Conan |
|----------|---------------|-------|
| Модификация исходников | Да | Нет |
| Обновление версии | Повторный патчинг | Смена version в рецепте |
| Кросс-платформенность | Ручная адаптация | Профили |
| Кэширование сборок | Нет | Да (Conan cache) |
| Время добавления пакета | Часы/дни (gRPC) | Минуты |
| Воспроизводимость | Зависит от патчей | Детерминированная |
