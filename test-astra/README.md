# test-astra/

Build- и диагностические скрипты для Linux/Astra. Команды сборки и контракты —
в корневом [`../README.md`](../README.md); диагностика — в [`HELP.txt`](HELP.txt).

## Скрипты

| Скрипт | Что делает |
|---|---|
| `install_deps.sh` | apt: gcc, cmake, python3-venv (один раз, sudo) |
| `setup.sh` | venv + offline-установка Conan из `../packages-linux/` |
| `run_test.sh` / `run_test_zlib.sh` | один артефакт (gtest / zlib) |
| `run_test_grpc.sh` | всё дерево grpc **1.78.1** → 7 `.nupkg` в `output/` |
| `run_grpc_1601_upstream.sh` | дерево grpc **1.60.1**, `ARCH=x86_64\|arm\|arm64\|all` (тянет станок с ProGet) |
| `build_1601_nodocker.sh` | то же без docker — когда станок поднимает сам TeamCity |
| `test_arm_cross.sh smoke\|build arm\|arm64` | ARM cross через Docker-зеркало (линия 1.78) |
| `prebake_push.sh [arch...]` | собрать+залить образы `grpc-tc-mirror-<arch>` в ProGet |
| `smoke_build_pkg.sh <arch>` | собрать один пакет (zlib) в образе — быстрая проверка |
| `free_space.sh` | почистить диск агента (docker build-кэш / volume'ы / output) |

Без интернета работают все шаги, кроме `install_deps.sh` (нужен apt — или
offline-репозиторий Astra). x86_64 CI-сборка (`run_test_grpc.sh` на профиле
`lin-gcc84-x86_64`) запускается **в Docker** `grpc-tc-mirror`, не на голой dev-VM.

**Доки:** добавить рецепт — `HOWTO-new-recipe-short.md` (кратко) /
`GUIDE-new-recipe-from-zero.md` (подробно); собрать существующий рецепт —
`HOWTO-create-package.md`; диагностика — `HELP.txt`; TeamCity 1.60.1 — HELP `[24]`/`[25]`.

## Если другая версия GCC

`profiles/astra-gcc` по умолчанию задаёт `compiler.version=8`. Под другой GCC:

```bash
gcc --version            # узнать major
nano profiles/astra-gcc  # поправить compiler.version
```
