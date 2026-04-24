# Тестирование Conan на Astra Linux 1.8

## Быстрый старт

```bash
# 1. Установить системные зависимости (один раз, с sudo)
sudo ./test-astra/install_deps.sh

# 2. Установить Conan
./test-astra/setup.sh

# 3. Активировать окружение
source venv/bin/activate

# 4. Запустить полный тест
./test-astra/run_test.sh
```

## Что тестируется

1. **gtest собирается из оригинальных исходников** — без патчей, без модификации
2. **Пример-потребитель** — компилируется и тесты проходят
3. **Legacy zip** — создаётся с той же структурой что в TeamCity

## Если нет интернета

Все пакеты Python (Conan и зависимости) лежат в `packages/`.
Исходники gtest лежат в `gtest/src/v1.14.0.tar.gz`.
Установка и сборка работают полностью offline.

## Если ошибка с версией GCC

Astra Linux 1.8 идёт с GCC 8.x. Профиль `profiles/astra-gcc` настроен
под эту версию. Если версия другая:

```bash
# Проверить версию
gcc --version

# Отредактировать профиль
nano profiles/astra-gcc
# Поменять compiler.version=8 на вашу версию
```

## Результат

После успешного прогона `run_test.sh`:
- `output/googletest.zip` — legacy артефакт
- Концепт IN-353 подтверждён на Astra Linux
