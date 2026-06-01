# test-astra/

Build- и диагностические скрипты для Linux/Astra. Команды сборки и контракты —
в корневом [`../README.md`](../README.md); диагностика — в [`HELP.txt`](HELP.txt).

## Скрипты

| Скрипт | Что делает |
|---|---|
| `install_deps.sh` | apt: gcc, cmake, python3-venv (один раз, sudo) |
| `setup.sh` | venv + offline-установка Conan из `../packages-linux/` |
| `run_test.sh` / `run_test_zlib.sh` | один артефакт (gtest / zlib) |
| `run_test_grpc.sh` | всё дерево grpc → 7 `.nupkg` в `output/` |
| `test_arm_cross.sh smoke\|build arm\|arm64` | ARM cross через Docker-зеркало |

Без интернета работают все шаги, кроме `install_deps.sh` (нужен apt — или
offline-репозиторий Astra). x86_64 CI-сборка (`run_test_grpc.sh` на профиле
`lin-gcc84-x86_64`) запускается **в Docker** `grpc-tc-mirror`, не на голой dev-VM.

## Если другая версия GCC

`profiles/astra-gcc` по умолчанию задаёт `compiler.version=8`. Под другой GCC:

```bash
gcc --version            # узнать major
nano profiles/astra-gcc  # поправить compiler.version
```
