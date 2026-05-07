# ARM grpc — что делать дальше

Состояние на 2026-05-07 13:25 (после прогона `[8h] step 4` из `HELP.txt`):

- 5 из 7 пакетов собрались как top-level: **zlib**, **abseil**, **c-ares**, **re2**, **openssl**.
- **protobuf** упал — но **не** на «GCC 7 or higher» (другая причина, надо смотреть).
- **grpc** упал — потому что пересобирает **abseil как транзитивную** → опять `policy_checks.h "GCC 7 or higher"`.
- `LINARO-ARM-TC count = 3` — маркеры получили те 3 пакета, что реально пересобирались (zlib, abseil, c-ares); re2 и openssl были в кеше от прошлых неудачных попыток.

Главный вывод: **abseil как top-level собирается** — теория про `[conf] *:user_toolchain` подтверждена.
Главная проблема: **финальный `--requires=grpc/1.78.1` пересобирает abseil как транзитивную**, и в этом контексте toolchain снова отваливается.

---

## Шаг 1. Понять, почему упал protobuf

На хосте Astra, в `~/conan-master/test-astra` (где лежит `cli-conf.log`):

```bash
grep -B 1 -A 8 "protobuf/.*build failed\|protobuf/5.29.6.*Error in build" cli-conf.log | head -40
grep -B 2 -A 4 "error:" cli-conf.log | grep -A 4 "protoa6eb2b0ca6e3c" | head -30
```

Что искать в выводе:
- упоминание `abseil`/`absl::` headers → protobuf не нашёл наш собранный abseil;
- упоминание `-m64`/`x86`/`architecture` → x86-флаги протекли в ARM-сборку;
- что-то про `cppstd 17`/`std::string_view` → компилятор не получил `-std=c++17`.

Отправь вывод в чат — по нему точечно поправим.

---

## Шаг 2. Сравнить package_id для abseil top-level vs abseil под grpc

```bash
grep -E "abseil/20250127.0.*(Building|Build folder|package_id)" cli-conf.log | head -20
grep -B 1 -A 1 "abseil/20250127.0" cli-conf.log | grep -E "options|shared|cppstd|libcxx" | sort -u | head -20
```

Если **package_id разные** — `grpc` форсирует options на `abseil` через свой `requirements()`. Тогда fix — собирать abseil сразу с теми же options, либо patch `grpc/conanfile.py`.

---

## Шаг 3 (решающий). Финальный install с `--build="*"` + `-c`

Это force-rebuild **всех** пакетов в графе grpc с явным toolchain через CLI:

```bash
sudo docker run --rm \
    -v "$(pwd)/conan-cache:/root/.conan2" \
    -v "$(pwd):/host" \
    -e PROFILE=/work/conan-recipes/profiles/lin-gcc75-arm-linaro \
    -e PROFILE_BUILD=/work/conan-recipes/profiles/lin-gcc84-x86_64 \
    grpc-tc-mirror-arm bash -c '
        conan install --requires=grpc/1.78.1 \
            -pr:h=$PROFILE -pr:b=$PROFILE_BUILD \
            --build="*" --no-remote \
            -s build_type=Release \
            -o "*/*:shared=True" \
            -c "*:tools.cmake.cmaketoolchain:user_toolchain=[\"/work/conan-recipes/profiles/toolchains/linaro-arm.cmake\"]" \
            2>&1 | tee /host/grpc-final.log | tail -30;
        echo "=== LINARO-ARM-TC count ===";
        grep -c "==LINARO-ARM-TC==" /host/grpc-final.log
    '
```

Развилка по `LINARO-ARM-TC count`:

| count | смысл | что делать |
|---|---|---|
| **≥ 7** | `--build="*"` + `-c` пробрасывают toolchain ко всем нодам | → **Шаг 4a** |
| **< 7** | toolchain всё равно теряется на транзитивных нодах | → **Шаг 4b** |

---

## Шаг 4a (если count ≥ 7) — фикс в `run_test_grpc.sh`

Заменить Step 2 (строки 56–63) на:

```bash
for BT in Release Debug; do
    conan install --requires=grpc/1.78.1 \
        -pr:h="$PROFILE" -pr:b="$PROFILE_BUILD" \
        --build="*" --no-remote \
        -s build_type="$BT" \
        -o "*/*:shared=$SHARED" \
        -c "*:tools.cmake.cmaketoolchain:user_toolchain=[\"$ROOT_DIR/profiles/toolchains/linaro-arm.cmake\"]"
done
```

Step 3 (deployer) — оставить как есть, но добавить тот же `-c`. Закоммитить, пересобрать docker-образ, запустить `test_arm_cross.sh build arm`. Должны получить 7 `.nupkg` в `output-arm/`.

---

## Шаг 4b (если count < 7) — patch `grpc/conanfile.py` (и `protobuf/`, если та же причина)

Conan 2.x не пробрасывает `[conf] user_toolchain` к транзитивным нодам даже из CLI. Тогда — добавить в `generate()` каждого подозрительного рецепта:

```python
def generate(self):
    tc = CMakeToolchain(self)
    user_tc = self.conf.get(
        "tools.cmake.cmaketoolchain:user_toolchain",
        default=[], check_type=list,
    )
    for path in user_tc:
        tc.user_presets_path = path  # или явный include через preset
    tc.generate()
```

Точный код напишу после Шага 3 — нужно увидеть какие рецепты теряют toolchain.

---

## Финальный шаг (когда все 7 binary в кеше) — получить `.nupkg`

```bash
sudo docker run --rm \
    -v "$(pwd)/conan-cache:/root/.conan2" \
    -v "$(pwd)/output-arm:/work/conan-recipes/output" \
    -e PROFILE=/work/conan-recipes/profiles/lin-gcc75-arm-linaro \
    -e PROFILE_BUILD=/work/conan-recipes/profiles/lin-gcc84-x86_64 \
    grpc-tc-mirror-arm bash -c '
        conan install --requires=grpc/1.78.1 \
            -pr:h=$PROFILE -pr:b=$PROFILE_BUILD \
            --no-remote -o "*/*:shared=True" \
            --deployer=/work/conan-recipes/extensions/deployers/legacy_nupkg.py \
            --deployer-folder=/work/conan-recipes/output
    '
ls -la output-arm/*.nupkg     # ожидаем 7 файлов
```

Имена должны быть `<pkg>.lin.gcc.shared.arm.<ver>.nupkg` (см. `legacy_nupkg.py`).
