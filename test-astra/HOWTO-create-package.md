# Как создать пакет — правильный путь (на примере zlib)

> Учебная/смоук-версия — `HOWTO-packages.md`. **Здесь — как собрать ПОСТАВЛЯЕМЫЙ
> пакет правильно** (компилятор gcc 8.4 в Docker), на конкретном примере **zlib** —
> это самая простая зависимость grpc (лист, без своих зависимостей), на ней удобно показать.

## Идея в двух словах

«Боевой» пакет = собран компилятором **gcc 8.4 внутри Docker-образа `grpc-tc-mirror`**,
а не системным gcc голой VM. Имя такого `.nupkg` содержит **`gcc84`**. Имя и структуру
файла делает упаковщик `legacy_nupkg.py` сам — его трогать не надо.

Внутри образа уже выставлен нужный профиль: `ENV PROFILE=…/lin-gcc84-x86_64`
(`Dockerfile.grpc-tc-mirror`). Поэтому «правильно собрать» = «собрать внутри образа
с `$PROFILE`».

## Предусловия (один раз)

- Образ `grpc-tc-mirror` собран. Если нет — собери по `HELP.txt` блок `[3]`.
- **Рецепты вшиты в образ** (`COPY` в Dockerfile) — пакет соберётся из той версии
  рецепта, что была на момент сборки образа. Если правил рецепт zlib — либо пересобери
  образ (`[3]`), либо смонтируй репо (см. «Свой рецепт» ниже).

## Шаг 1 — собрать поставляемый zlib (gcc84, в Docker)

Три команды внутри образа: собрать Release, собрать Debug, упаковать в `.nupkg`.
Результат кладём в смонтированный `output/`:

```bash
mkdir -p output
sudo docker run --rm \
  -v "$(pwd)/output:/work/conan-recipes/output" \
  grpc-tc-mirror \
  bash -lc '
    set -e
    conan create zlib/ --version=1.3.1 -pr:h="$PROFILE" -pr:b="$PROFILE" \
        -s build_type=Release --build=missing --no-remote
    conan create zlib/ --version=1.3.1 -pr:h="$PROFILE" -pr:b="$PROFILE" \
        -s build_type=Debug   --build=missing --no-remote
    conan install --requires=zlib/1.3.1 -pr:h="$PROFILE" -pr:b="$PROFILE" \
        --no-remote --deployer=extensions/deployers/legacy_nupkg.py \
        --deployer-folder=output/
  '
```

Что здесь важно:
- **Release и Debug — оба обязательны:** упаковщику нужны обе сборки.
- последняя команда (`--deployer=…legacy_nupkg.py`) — это и есть «сделать `.nupkg`».
- `$PROFILE` внутри образа уже `lin-gcc84-x86_64` — поэтому имя выйдет с `gcc84`.
  (Кавычки одинарные: `$PROFILE` раскрывается **внутри** контейнера, не снаружи.)

Идёт пару минут (zlib маленький).

## Шаг 2 — проверить результат

```bash
ls -lh output/zlib.*.nupkg
unzip -l output/zlib.lin.gcc84.shared.x86_64.1.3.1.nupkg | head
```

**Ожидаемо:**
- файл назван `zlib.lin.gcc84.shared.x86_64.1.3.1.nupkg` — ключевой признак боевого
  пакета это **`gcc84`** в имени;
- внутри есть `lib/native/.../*.a` и папка `include/`.

> Если в имени `gcc8` (без «4») — это смоук с голой VM (`astra-gcc`), **не для поставки**.

## Любая другая зависимость grpc

Замени `zlib` и версию. Имя каталога рецепта = Conan-имя; версия — из таблицы
«Что мигрировано» в `README.md`:

| Каталог рецепта | `--version` | имя в `.nupkg` |
|---|---|---|
| `zlib` | 1.3.1 | zlib |
| `abseil` | 20250127.0 | absl |
| `c-ares` | 1.34.6 | cares |
| `re2` | 20251105 | re2 |
| `protobuf` | 5.29.6 | protobuf |
| `openssl` | 3.4.5 | openssl |

Legacy-имя в файле может отличаться от Conan-имени — это делает `LEGACY_NAME_MAP` в
упаковщике автоматически (`gtest→googletest`, `abseil→absl`, `c-ares→cares`).

## Весь набор grpc разом

Если нужен не один пакет, а вся ветка (grpc 1.78.1 + 6 зависимостей) — не пиши команды
руками, образ умеет это сам (`HELP.txt [4]`):

```bash
mkdir -p output
sudo docker run --rm -v "$(pwd)/output:/work/conan-recipes/output" grpc-tc-mirror
ls -la output/*.nupkg     # 7 файлов, все gcc84
```

## Свой рецепт (если правил рецепт и не хочешь пересобирать образ)

Образ несёт рецепт на момент своей сборки. Чтобы собрать **текущий локальный** рецепт —
смонтируй репо поверх вшитого:

```bash
sudo docker run --rm \
  -v "$(pwd):/work/conan-recipes" \
  grpc-tc-mirror \
  bash -lc 'set -e
    conan create zlib/ --version=1.3.1 -pr:h="$PROFILE" -pr:b="$PROFILE" -s build_type=Release --build=missing --no-remote
    conan create zlib/ --version=1.3.1 -pr:h="$PROFILE" -pr:b="$PROFILE" -s build_type=Debug   --build=missing --no-remote
    conan install --requires=zlib/1.3.1 -pr:h="$PROFILE" -pr:b="$PROFILE" --no-remote --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/'
```

## Три контракта (не нарушать)

1. **Имя/структуру `.nupkg` не менять** — за них отвечает `legacy_nupkg.py`, руками не трогаем.
2. **Всё offline** — исходники в `<pkg>/src/*.tar.gz`, `conandata.yml` (URL/sha256) не трогаем.
3. **Боевой пакет — всегда gcc84/Docker.** Голая VM (`astra-gcc`) даёт `gcc8` — это только смоук.

## Опубликовать на ProGet

После проверки — залить пакет на фид (если есть права); как именно — по внутреннему
регламенту / у того, кто публикует. **Смоук-пакеты (`gcc8`) не публиковать.**

## Если падает

- `conan: command not found` внутри `bash -lc` → образ собран неправильно; пересобери (`[3]`).
- Падение на `tool_requires`/cmake → потерян `-pr:b` (в командах выше он есть).
- Имя вышло `gcc8`, а не `gcc84` → ты собрал не в образе (или `$PROFILE` сбит) — собирай
  через `docker run grpc-tc-mirror`, профиль приходит из `ENV` образа.
- Глубже — `HELP.txt` (блоки `[3]`, `[4]`, `[9]` — приёмка/проверка ELF-архитектуры).
