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

## Шаг 4b (count < 7) — patch рецептов через env-fallback

**Подтверждено 2026-05-07 13:49:** даже `--build="*" + -c` дал count = 2.
Conan 2.27.1 **не** пропагирует `[conf]` (и `-c` на CLI) к транзитивным
нодам — это баг Conan, не профиль. `self.conf.get(...)` в `generate()`
транзитивного пакета возвращает пусто.

**4b.0 подтвердил это эмпирически (2026-05-07 ~14:00):** из 6 build
folder'ов abseil только один (top-level) имел `CMAKE_C_COMPILER` ==
linaro-gcc, остальные 5 — `/usr/bin/c++` (Stretch g++ 6.3 → policy_checks.h).

Workaround: читать путь к toolchain из **переменной окружения**, которая
видна всем процессам в контейнере (включая транзитивные builds), и
явно вписывать его в CMakeToolchain.

**Статус: 4b.1 + 4b.3 уже сделаны в коммите `de4802b`** (5 файлов:
Dockerfile.grpc-tc-mirror, abseil/protobuf/re2/grpc conanfile.py).
Осталось: 4b.2 (запуск с env) + 4b.4 (verify).

### 4b.0. Pre-flight: какой компилятор CMake реально подцепил для упавшей abseil

Подтверждение что причина — именно фолбэк на системный g++, а не
кривой linaro path. На хосте, где `conan-cache` bind-mounted:

```bash
# Любой abseil build folder, даже самый свежий упавший:
sudo find "$(pwd)/conan-cache/p/b" -path '*absei*' -name CMakeCache.txt \
    -exec grep -E "CMAKE_C_COMPILER:|CMAKE_CXX_COMPILER:|CMAKE_AR:|CMAKE_SYSTEM_PROCESSOR:" {} +
```

Интерпретация:

- `CMAKE_C_COMPILER:FILEPATH=/usr/bin/cc` (или `/usr/bin/gcc`,
  `/usr/bin/g++`) → системный Stretch g++ 6.3, toolchain не сработал.
  Идём в 4b.1–4b.4.
- `CMAKE_C_COMPILER:FILEPATH=/opt/linaro-arm-7.5.0/.../arm-linux-gnueabihf-gcc`
  → linaro-toolchain подцепился, но всё равно ругается на «GCC 7+».
  Тогда `policy_checks.h` валится по другой причине (компилятор
  не сообщает свою версию правильно, или какой-то define ломает
  макрос). Иной патч — копаем сам `policy_checks.h:59` в abseil
  source, проверяем `__GNUC__` evaluation.

### 4b.1. ✅ Сделано (`de4802b`) — Dockerfile

Добавлен `ENV CONAN_USER_TOOLCHAIN=""` в `Dockerfile.grpc-tc-mirror`.
По-умолчанию пусто — x86_64 native builds не затронуты.

### 4b.2. Пересобрать docker image и запустить с env для ARM

```bash
cd ~/conan-master
git pull

# Пересобираем образ — он подхватит и новый ENV, и патчи рецептов.
sudo docker build \
    --build-arg BASE_IMAGE=$REGISTRY/library/gcc75-build-arm:0.1.0 \
    -f Dockerfile.grpc-tc-mirror -t grpc-tc-mirror-arm .

# Запускаем с CONAN_USER_TOOLCHAIN — тогда env-fallback в generate() сработает.
cd test-astra
sudo docker run --rm \
    -v "$(pwd)/conan-cache:/root/.conan2" \
    -v "$(pwd)/output-arm:/work/conan-recipes/output" \
    -v "$(pwd):/host" \
    -e CONAN_USER_TOOLCHAIN=/work/conan-recipes/profiles/toolchains/linaro-arm.cmake \
    -e PROFILE=/work/conan-recipes/profiles/lin-gcc75-arm-linaro \
    -e PROFILE_BUILD=/work/conan-recipes/profiles/lin-gcc84-x86_64 \
    grpc-tc-mirror-arm bash -c '
        ./test-astra/run_test_grpc.sh 2>&1 | tee /host/run-final.log;
        echo "=== LINARO-ARM-TC count ===";
        grep -c "==LINARO-ARM-TC==" /host/run-final.log
    '
```

При успехе — ещё подкрутить `test-astra/test_arm_cross.sh` чтобы
проброс `-e CONAN_USER_TOOLCHAIN=...` шёл автоматически из `case ARCH=arm`.

### 4b.3. ✅ Сделано (`de4802b`) — patch `generate()` в рецептах

Файлы: `abseil/conanfile.py`, `re2/conanfile.py`,
`protobuf/conanfile.py`, `grpc/conanfile.py`.
Шаблон правки (вставлен перед `tc.generate()`):

```python
        _user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
        if _user_tc:
            tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
```

`openssl/` использует `AutotoolsToolchain` (не CMakeToolchain) и читает
`CC`/`CXX` из `[buildenv]` — не патчился. Если транзитивный openssl-под-grpc
позже сломается на той же причине — патчим отдельно.

### 4b.4. Проверка (после 4b.2)

После запуска:

```bash
# count маркеров (ожидаем >= 7 — по одному на каждый recipe в графе):
grep -c "==LINARO-ARM-TC==" run-final.log

# Артефакты:
ls -la output-arm/*.nupkg     # ожидаем 7 файлов

# Если что-то упало — компилятор по факту в каждом build:
sudo find "$(pwd)/conan-cache/p/b" -name CMakeCache.txt \
    -exec grep -E "CMAKE_C_COMPILER:" {} + | sort -u
```

Развилка:
- ✅ count >= 7 + 7 .nupkg → задача закрыта. Дальше — поправить
  `test_arm_cross.sh` (auto-set `-e CONAN_USER_TOOLCHAIN`) и почистить
  HELP.txt от диагностики которая больше не нужна.
- ❌ count всё ещё 0/2 → перейти к 4b.5 (различить две возможные причины).

### 4b.5. Если count всё ещё 0/2 — две проверки, чтобы понять причину

Подтверждено 2026-05-07 ~14:57: после `de4802b` патч не подействовал
(count = 0, та же `policy_checks.h "GCC 7 or higher"`, новый build
folder abseia8915fac5df4c). Возможные причины:

а) **Docker-образ не пересобран** (закешировались слои с старыми
   рецептами).
b) **API `tc.blocks["user_toolchain"].values["paths"]` не работает** в
   Conan 2.27.1 как override (внутри блок перетирает `values` из
   `context()` при рендере).

#### Проверка 1: попал ли патч в собранный образ

```bash
sudo docker run --rm grpc-tc-mirror-arm \
    grep -n CONAN_USER_TOOLCHAIN /work/conan-recipes/abseil/conanfile.py
```

- Видна строка `_user_tc = os.environ.get(...)` → патч в образе ✅, идём к Проверке 2.
- Пусто → образ закеширован. Пересобрать с `--no-cache`:

  ```bash
  cd ~/conan-master
  sudo docker build --no-cache \
      --build-arg BASE_IMAGE=$REGISTRY/library/gcc75-build-arm:0.1.0 \
      -f Dockerfile.grpc-tc-mirror -t grpc-tc-mirror-arm .
  ```

  И запускать заново 4b.2.

#### Проверка 2: сработал ли override на уровне generated conan_toolchain.cmake

```bash
sudo find "$(pwd)/conan-cache/p/b" -path '*absei*' -name conan_toolchain.cmake \
    -exec grep -B 2 -A 2 "user_toolchain\|linaro" {} +
```

- После комментария `# Include one or more CMake user toolchain…`
  идёт строка `include("/work/conan-recipes/profiles/toolchains/linaro-arm.cmake")`
  → override сработал ✅, но компилятор всё равно `/usr/bin/c++`.
  Тогда копать `linaro-arm.cmake` — он не выставляет `CMAKE_C_COMPILER`
  на уровне Conan toolchain phase.
- Только пустой комментарий, без `include` → API `tc.blocks` не
  принимает override. Переходим к 4b.6.

### 4b.5b. Если 4b.5 проверка 2 показала include(linaro) ✅, но `-m64` ломает ARM build

Подтверждено 2026-05-07 ~15:00: `==LINARO-ARM-TC==` появилось,
`The CXX compiler identification is GNU 7.5.0`, но build упал на
```
-- Conan toolchain: Defining architecture flag: -m64
arm-linux-gnueabihf-g++: error: unrecognized command line option '-m64'
```

Причина: env-fallback из 4b.3 пробрасывал linaro-toolchain
**универсально**, в т.ч. в build-context abseil (нужен для protoc как
build-tool на x86_64). В build-context `settings.arch=x86_64` →
ArchitectureBlock вписывает `-m64` → `CMAKE_C_COMPILER` мы перебили
на ARM-cross → `arm-linux-gnueabihf-g++ -m64` → fail.

**Fix:** применять env-fallback только когда target arch — ARM.
Сделано в коммите после `de4802b`: добавлен `arch` check в условие
во всех 4 recipes:

```python
        _user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
        if _user_tc and str(self.settings.arch) in (
                "armv7", "armv7hf", "armv7s",
                "armv8", "armv8_32", "armv8.3", "arm64ec"):
            tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
```

После: пересобрать образ (на этот раз можно без `--no-cache`,
потому что патч новых строк в `*/conanfile.py` ломает кеш слоя
`COPY <pkg>`), запустить 4b.2 заново.

### 4b.6. Жёсткий patch: дописывать `include(...)` в conan_toolchain.cmake после tc.generate()

Если 4b.5 показала что override через `tc.blocks` не работает, заменить
в каждом из 4 рецептов фрагмент:

```python
        _user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
        if _user_tc:
            tc.blocks["user_toolchain"].values["paths"] = [_user_tc]
        tc.generate()
```

на:

```python
        tc.generate()

        # Force-include user toolchain at the END of conan_toolchain.cmake.
        # Conan 2.27.1 ignores tc.blocks["user_toolchain"] override for
        # transitive deps; we patch the generated file directly. The whole
        # file is read by CMake BEFORE project(), so set(CMAKE_C_COMPILER ...)
        # in linaro-arm.cmake still applies.
        _user_tc = os.environ.get("CONAN_USER_TOOLCHAIN", "").strip()
        if _user_tc:
            from conan.tools.files import load, save
            _tc_path = os.path.join(self.generators_folder, "conan_toolchain.cmake")
            if os.path.exists(_tc_path):
                _content = load(self, _tc_path)
                _line = f'include("{_user_tc}")'
                if _line not in _content:
                    save(self, _tc_path, _content + f"\n\n{_line}\n")
```

После правки — пересобрать образ (`--no-cache` для гарантии), перезапустить 4b.2.

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
