# Проверка концепта на рабочем Windows ПК

Цель: убедиться, что gtest собирается из оригинальных исходников
через Conan БЕЗ модификации, прямо на вашей рабочей машине.

Время: ~15 минут.

---

## Шаг 1: Проверить, что всё установлено

Открыть **PowerShell** (или **cmd**) и выполнить:

```powershell
python --version
# Нужен 3.6+. Если нет: https://www.python.org/downloads/

cmake --version
# Нужен 3.15+. Если нет: https://cmake.org/download/

git --version
# Если нет: https://git-scm.com/download/win
```

Проверить компилятор — открыть **Developer PowerShell for VS** 
(или "x64 Native Tools Command Prompt for VS"):
```powershell
cl
# Должно показать: Microsoft (R) C/C++ Optimizing Compiler Version ...
```

Если нет Developer PowerShell — обычный PowerShell, но проверить:
```powershell
# Найти cl.exe
where cl
# Или
& "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
```

---

## Шаг 2: Установить Conan

```powershell
pip install conan
```

Проверить:
```powershell
conan --version
# Должно показать: Conan version 2.x.x
```

Если "conan не найден":
```powershell
# Найти, куда pip установил
python -m site --user-site
# Добавить Scripts в PATH, например:
$env:PATH += ";$env:APPDATA\Python\Python312\Scripts"
```

---

## Шаг 3: Первичная настройка Conan

```powershell
conan profile detect
```

Проверить:
```powershell
conan profile show
```

Должно показать что-то вроде:
```
[settings]
arch=x86_64
build_type=Release
compiler=msvc
compiler.cppstd=14
compiler.version=193
os=Windows
```

---

## Шаг 4: Склонировать репозиторий

Если репо уже в Bitbucket:
```powershell
cd C:\Users\<ваш_логин>\Desktop
git clone ssh://git@bitbucket.inc.elara.local:7999/<PROJECT>/conan-recipes.git
cd conan-recipes
```

Если ещё НЕ в Bitbucket — создать файлы вручную:

```powershell
mkdir C:\Users\<ваш_логин>\Desktop\conan-recipes
cd C:\Users\<ваш_логин>\Desktop\conan-recipes
mkdir gtest
mkdir profiles
mkdir example\src
```

### Создать gtest\conanfile.py

```powershell
notepad gtest\conanfile.py
```

Вставить:
```python
from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import get


class GTestConan(ConanFile):
    name = "gtest"
    version = "1.14.0"
    description = "Google Testing and Mocking Framework"
    license = "BSD-3-Clause"
    url = "https://github.com/google/googletest"

    settings = "os", "compiler", "build_type", "arch"
    options = {
        "shared": [True, False],
        "build_gmock": [True, False],
        "hide_symbols": [True, False],
    }
    default_options = {
        "shared": False,
        "build_gmock": True,
        "hide_symbols": False,
    }

    def source(self):
        get(self, f"https://github.com/google/googletest/archive/refs/tags/v{self.version}.tar.gz",
            strip_root=True)

    def layout(self):
        cmake_layout(self)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["BUILD_GMOCK"] = self.options.build_gmock
        tc.variables["INSTALL_GTEST"] = True
        tc.variables["gtest_force_shared_crt"] = True
        tc.variables["BUILD_SHARED_LIBS"] = self.options.shared
        tc.variables["gtest_hide_internal_symbols"] = self.options.hide_symbols
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.components["libgtest"].libs = ["gtest"]
        self.cpp_info.components["gtest_main"].libs = ["gtest_main"]
        self.cpp_info.components["gtest_main"].requires = ["libgtest"]

        if self.options.build_gmock:
            self.cpp_info.components["libgmock"].libs = ["gmock"]
            self.cpp_info.components["libgmock"].requires = ["libgtest"]
            self.cpp_info.components["gmock_main"].libs = ["gmock_main"]
            self.cpp_info.components["gmock_main"].requires = ["libgmock"]

        if self.settings.os == "Linux":
            self.cpp_info.components["libgtest"].system_libs = ["pthread"]
```

Сохранить и закрыть.

### Создать example\CMakeLists.txt

```powershell
notepad example\CMakeLists.txt
```

Вставить:
```cmake
cmake_minimum_required(VERSION 3.15)
project(example_with_gtest LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(GTest REQUIRED)

add_executable(example_test src/example.cpp src/example_test.cpp)
target_link_libraries(example_test GTest::gtest GTest::gtest_main)

enable_testing()
add_test(NAME example_test COMMAND example_test)
```

### Создать example\conanfile.py

```powershell
notepad example\conanfile.py
```

Вставить:
```python
from conan import ConanFile
from conan.tools.cmake import CMake, cmake_layout


class ExampleConsumer(ConanFile):
    name = "example"
    version = "1.0.0"
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    def requirements(self):
        self.requires("gtest/1.14.0")

    def layout(self):
        cmake_layout(self)

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
        cmake.test()
```

### Создать example\src\example.hpp

```powershell
notepad example\src\example.hpp
```

```cpp
#pragma once

int add(int a, int b);
int multiply(int a, int b);
```

### Создать example\src\example.cpp

```powershell
notepad example\src\example.cpp
```

```cpp
#include "example.hpp"

int add(int a, int b) {
    return a + b;
}

int multiply(int a, int b) {
    return a * b;
}
```

### Создать example\src\example_test.cpp

```powershell
notepad example\src\example_test.cpp
```

```cpp
#include <gtest/gtest.h>
#include "example.hpp"

TEST(ExampleTest, Add) {
    EXPECT_EQ(add(2, 3), 5);
    EXPECT_EQ(add(-1, 1), 0);
    EXPECT_EQ(add(0, 0), 0);
}

TEST(ExampleTest, Multiply) {
    EXPECT_EQ(multiply(2, 3), 6);
    EXPECT_EQ(multiply(-1, 5), -5);
    EXPECT_EQ(multiply(0, 100), 0);
}
```

---

## Шаг 5: Собрать gtest через Conan

ВАЖНО: выполнять из **Developer PowerShell for VS** (или из обычного
PowerShell, но после запуска vcvars64.bat — чтобы cl.exe был доступен).

```powershell
cd C:\Users\<ваш_логин>\Desktop\conan-recipes

# Собрать gtest из оригинальных исходников (БЕЗ модификации!)
conan create gtest/ --build=missing
```

Что произойдёт:
1. Conan скачает исходники gtest 1.14.0 с GitHub (~2 МБ)
2. Распакует их
3. Сконфигурирует cmake (передаст настройки через toolchain, НЕ патча CMakeLists.txt)
4. Соберёт MSVC компилятором
5. Упакует в локальный кэш Conan

Это займёт 2-5 минут. В конце должно быть:
```
gtest/1.14.0: Package '...' created
```

ЕСЛИ ОШИБКА "нет доступа к github.com":
- Проверить прокси: `echo %HTTP_PROXY%`
- Если есть прокси, задать для Conan:
  ```powershell
  $env:HTTP_PROXY = "http://proxy.elara.local:8080"
  $env:HTTPS_PROXY = "http://proxy.elara.local:8080"
  conan create gtest/ --build=missing
  ```

ЕСЛИ ОШИБКА "cl is not recognized":
- Открыть "Developer PowerShell for VS" вместо обычного PowerShell
- Или запустить:
  ```powershell
  & "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
  ```

---

## Шаг 6: Проверить, что пакет создан

```powershell
conan list "gtest/1.14.0:*"
```

Должно показать пакет с хэшем и настройками (compiler=msvc и т.д.).

---

## Шаг 7: Собрать пример-потребитель

```powershell
cd C:\Users\<ваш_логин>\Desktop\conan-recipes\example

# Установить зависимости
conan install . --output-folder=build --build=missing

# Собрать
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake
cmake --build build --config Release

# Запустить тесты
cd build
ctest --output-on-failure -C Release
```

Должно показать:
```
[==========] Running 6 tests from 2 test suites.
[----------] 3 tests from ExampleTest/Add
...
[  PASSED  ] 6 tests.
```

---

## Шаг 8: Готово!

Если вы видите "6 tests PASSED" — концепт работает:
- gtest собран из ОРИГИНАЛЬНЫХ исходников
- Ни один файл gtest НЕ был модифицирован
- Ваш проект подключил gtest через стандартный find_package()

Можно показать коллегам / руководителю и переходить к развёртыванию
на серверах (Conan Server + TeamCity).

---

## Быстрая шпаргалка (все команды подряд)

```powershell
# Установка (один раз)
pip install conan
conan profile detect

# Сборка gtest
cd C:\Users\<логин>\Desktop\conan-recipes
conan create gtest/ --build=missing

# Сборка примера
cd example
conan install . --output-folder=build --build=missing
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake
cmake --build build --config Release
cd build && ctest --output-on-failure -C Release
```
