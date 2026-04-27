# Тестирование Conan на Astra Linux 1.8

## Быстрый старт

```bash
# 1. Получить репозиторий на Astra
git clone git@github.com:HYUEHFJKhfjklkej/conan.git conan-recipes
cd conan-recipes

# 2. Установить системные зависимости (один раз, с sudo)
sudo ./test-astra/install_deps.sh

# 3. Установить Conan (offline, из packages-linux/)
./test-astra/setup.sh

# 4. Активировать окружение
source venv/bin/activate

# 5. Запустить полный тест
./test-astra/run_test.sh
```

## Что тестируется

1. **gtest собирается из оригинальных исходников** — без патчей, без модификации
2. **Пример-потребитель** — компилируется через `find_package(gtest)`, тесты проходят
3. **Legacy zip** — создаётся с структурой `astra.gcc.static.x64/` как в TeamCity

## Что нужно с интернетом, что без

| Шаг | Интернет | Почему |
|---|---|---|
| `install_deps.sh` | да (или offline-репа Astra) | apt-get install build-essential cmake python3 git |
| `setup.sh` | нет | pip --no-index из `packages-linux/` |
| `run_test.sh` | нет | conan --no-remote, gtest из `gtest/src/v1.14.0.tar.gz` |

Если на машине build-essential, cmake, python3, git уже установлены — интернет не нужен совсем, шаг 2 можно пропустить.

## Содержимое packages-linux/

Полный комплект для offline pip-установки Conan 2.27.1:
- `conan-2.27.1.tar.gz` — сам Conan
- зависимости: pyyaml, requests, urllib3, jinja2, markupsafe, distro, patch_ng, fasteners, python_dateutil, certifi, charset_normalizer, colorama, idna, six, packaging, setuptools, wheel

Колёса собраны под `cp311 manylinux2014_x86_64` — совместимо с Astra Linux 1.8 (Python 3.11).

## Если ошибка с версией GCC

Профиль `profiles/astra-gcc` по умолчанию задаёт `compiler.version=8`. Если на машине другая версия GCC:

```bash
gcc --version             # узнать major
nano profiles/astra-gcc   # поправить compiler.version
```

## Тест в Docker (на dev-машине)

Без доступа к Astra можно прогнать тот же сценарий в Docker (linux/amd64 эмуляция):

```bash
docker build --platform=linux/amd64 -f Dockerfile.astra-test -t conan-astra-test .
docker run --rm --platform=linux/amd64 conan-astra-test
```

База — `gcc:12-bookworm`, близко к Astra 1.8 (Debian-based).

## Результат

После успешного прогона `run_test.sh`:
- `output/googletest.zip` — legacy артефакт со структурой `astra.gcc.static.x64/{lib,include}`
- Концепт IN-353 подтверждён на Astra Linux
