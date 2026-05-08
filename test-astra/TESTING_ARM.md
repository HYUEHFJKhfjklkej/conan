# IN-658 ARM cross-build — инструкция по тестированию

Файл собирает всё, что нужно сделать на CI/Astra-машине, чтобы
получить 14 `.nupkg` (7 для armv7hf + 7 для armv8) после ARM-фазы
проекта IN-658.

Источник правды по архитектуре фазы:
- `test-astra/NEXT_STEPS.md` (секция «Финальный runbook ARM-фазы»)
- `test-astra/HELP.txt` блоки `[5]…[8k]`

Всё необходимое уже залито в `master` коммитом
**`7b4dff5 ARM cross-build hardening: env passthrough, build-profile
leak fix, abseil aarch64 patch`**. Этот документ — путеводитель.

---

## 1. Что закоммичено в 7b4dff5

| Файл | Зачем |
|---|---|
| `test-astra/test_arm_cross.sh` | Пробрасывает `-e CONAN_USER_TOOLCHAIN=...` и `-v conan-cache-${ARCH}:/root/.conan2` в `docker run`. Без этого env-fallback в рецептах видел пустую переменную и transitive abseil под grpc собирался системным `/usr/bin/c++`. |
| `profiles/lin-gcc84-x86_64` | Добавлен `[buildenv]` блок с native `CC=gcc, CXX=g++, AR/AS/LD/NM/RANLIB/STRIP`. Изолирует build-context от leak'а ARM-toolchain через host-profile `[buildenv]`. |
| `abseil/patches/20250127.0-0001-stacktrace-aarch64-binutils232.patch` | Заменяет `xpaclri` (ARMv8.3-A inline asm) на `hint #7` (NOP-encoded equivalent). Linaro 7.5-2019.12 binutils 2.32 не понимает мнемонику `xpaclri`. |
| `abseil/conandata.yml` | Регистрирует patch выше для версии `20250127.0`. |
| `test-astra/HELP.txt` | Блоки `[8j]` (recon arm64 base image) и `[8k]` (verify env-fallback fix actually took effect). |
| `test-astra/NEXT_STEPS.md` | Финальный canonical runbook (секции 1-6) — заменяет старую цепочку ручных шагов 4b.* |

## 2. Что доказано локально (macOS эмуляция CI)

Эмуляция собрана в `/tmp/local-emulation/` на Apple Silicon через
публичные образы (тот же релиз linaro 7.5-2019.12, что и в CI):

- ✅ env-fallback API `tc.blocks["user_toolchain"]` подтверждён работоспособным в Conan 2.27.1 (исходники UserToolchainBlock).
- ✅ **abseil top-level под armv7hf**: 92 ARM EABI5 .so (`Tag_CPU_arch: v7`, `Tag_FP_arch: VFPv3-D16`).
- ✅ **abseil top-level под armv8 c xpaclri-патчем**: 100% built, 184 .so (`ELF 64-bit ARM aarch64`).
- ✅ `CMAKE_C_COMPILER` в build folder = реальный linaro `arm-linux-gnueabihf-gcc` / `aarch64-linux-gnu-gcc` (а не системный `/usr/bin/c++`).
- ✅ Bash syntax всех скриптов в `test-astra/`, Python AST всех 8 `conanfile.py`, парсинг обоих ARM-профилей через `conan profile show`.

## 3. Что НЕ доказано локально (требует CI)

- ⚠️ **Full grpc tree (7 .nupkg)** под обе arch — у меня под qemu emulation падает на bug в Linaro 7.5 binutils 2.32 BFD-ld (`invalid string offset .strtab` при cross-link против shared abseil `.so`). Production CI binutils может быть другой версии — не блокирующий. Если упадёт — workaround в секции 7.
- ⚠️ Имена 14 `.nupkg` через deployer `extensions/deployers/legacy_nupkg.py` (под `armv7hf→arm` и `armv8→arm64` маппинг).
- ⚠️ arm64 base image `/opt/linaro-aarch64-7.5.0/...` пути в `profiles/toolchains/linaro-aarch64.cmake` — best-guess зеркало armv7hf, реальные пути нужно подтвердить probes из `[8j]`.

## 4. Pre-flight (один раз перед первым `build arm64`)

Inventory arm64 base image — подтвердить что пути в
`profiles/toolchains/linaro-aarch64.cmake` совпадают с реальностью.
Полный набор probes — в `HELP.txt [8j]`. Минимум:

```bash
export REGISTRY=<internal-registry>/main

sudo docker run --rm "$REGISTRY/library/gcc75-build-arm64:0.1.0" \
    bash -c 'find /opt -maxdepth 6 -type f \
        \( -name "aarch64-*-gcc"    -o -name "aarch64-*-g++" \
           -o -name "aarch64-*-ar"  -o -name "aarch64-*-strip" \
           -o -name "aarch64-*-ranlib" \) 2>/dev/null | sort'
```

Ожидаемый результат: пять бинарников под
`/opt/linaro-aarch64-7.5.0/gcc-linaro-7.5.0-2019.12-rc1-x86_64_aarch64-linux-gnu/bin/`
с triplet `aarch64-linux-gnu-`.

- Совпадает → GO, профиль и toolchain.cmake уже корректны.
- Не совпадает (другой dir/triplet) → поправить `_LINARO`, `_SYSROOT` и имена бинарей в `profiles/toolchains/linaro-aarch64.cmake`, закоммитить.
- canary `echo "int main(){}" | gcc - -o /tmp/x && file /tmp/x` (probe `[8j].7`) → должен дать `ELF 64-bit ARM aarch64`.

## 5. Прогон тестов

```bash
cd ~/conan-master            # или где у тебя лежит репо
git fetch origin
git rebase origin/master     # подтянуть 7b4dff5

export REGISTRY=<internal-registry>/main
# при ошибке x509 при docker pull — см. HELP.txt блок [X]

# 5.1) Smoke — pre-flight + image probes (~1-2 мин на каждый)
./test-astra/test_arm_cross.sh smoke arm
./test-astra/test_arm_cross.sh smoke arm64

# 5.2) Full build (~15-25 мин на каждый на нативном CI)
./test-astra/test_arm_cross.sh build arm
./test-astra/test_arm_cross.sh build arm64
```

После фикса в `7b4dff5` второй прогон того же arch — **минуты**, потому
что named volume `conan-cache-${ARCH}` сохраняет state Conan между
запусками контейнера.

## 6. Acceptance criteria

```bash
ls -1 output-arm/*.nupkg   | wc -l    # → 7
ls -1 output-arm64/*.nupkg | wc -l    # → 7
```

Точные имена 14 артефактов:

```
output-arm/grpc.lin.gcc.shared.arm.1.78.1.nupkg
output-arm/protobuf.lin.gcc.shared.arm.5.29.6.nupkg
output-arm/abseil.lin.gcc.shared.arm.20250127.0.nupkg
output-arm/openssl.lin.gcc.shared.arm.3.4.5.nupkg
output-arm/re2.lin.gcc.shared.arm.20251105.nupkg
output-arm/c-ares.lin.gcc.shared.arm.1.34.6.nupkg
output-arm/zlib.lin.gcc.shared.arm.1.3.1.nupkg

output-arm64/{те же 7 пакетов}.lin.gcc.shared.arm64.<ver>.nupkg
```

Имена строит `extensions/deployers/legacy_nupkg.py` через маппинг
`armv7hf→arm`, `armv8→arm64`. Версии должны быть те же, что в
закрытой x86_64-фазе.

## 7. Если что-то упало

### 7.1. `count == 0` или transitive `policy_checks.h "GCC 7+"`

Значит env-fallback не сработал. Различить три причины через
**`HELP.txt [8k]`**:

```bash
# (a) патч в образе?
sudo docker run --rm grpc-tc-mirror-arm \
    grep -n CONAN_USER_TOOLCHAIN /work/conan-recipes/abseil/conanfile.py
# Нет вывода → образ старый, пересобрать с --no-cache.

# (b) env-var доходит в контейнер?
sudo docker ps --no-trunc --format '{{.Command}}' | head -3
# Должно быть видно CONAN_USER_TOOLCHAIN=/work/.../linaro-arm.cmake.
# Нет → твой test_arm_cross.sh без фикса 7b4dff5; rebase.

# (c) override реально применился к conan_toolchain.cmake?
sudo find ./conan-cache-arm/p/b -path '*absei*' -name conan_toolchain.cmake \
    -exec grep -l "linaro" {} +
# Нет → API tc.blocks игнорируется (Conan-баг); fallback в HELP.txt [8i] check 2.
```

### 7.2. `xpaclri: selected processor does not support`

Значит abseil patch не применился. Проверить:
```bash
sudo docker run --rm grpc-tc-mirror-arm64 \
    cat /work/conan-recipes/abseil/conandata.yml | grep -A 2 "20250127.0"
# Должно быть видно "patches/20250127.0-0001-stacktrace-aarch64-binutils232.patch"
```
Не видно → образ собран до 7b4dff5, пересобрать.

### 7.3. `protoc` линкуется `arm-linux-gnueabihf-ld`

Значит build-profile [buildenv] override не дошёл. Проверить:
```bash
sudo docker run --rm grpc-tc-mirror-arm \
    conan profile show -pr:b /work/conan-recipes/profiles/lin-gcc84-x86_64
# В разделе [buildenv] должны быть CC=gcc, LD=ld и т.д.
```
Если пусто → образ собран до 7b4dff5, пересобрать.

### 7.4. `invalid string offset .strtab` при cross-link

Bug binutils 2.32 BFD-ld в Linaro 7.5 при работе со strtab от shared
abseil .so. Workaround (НЕ в коммите 7b4dff5, hotfix):
- Добавить в `profiles/lin-gcc75-arm-linaro` секцию:
  ```
  [conf]
  tools.build:exelinkflags=["-fuse-ld=gold"]
  tools.build:sharedlinkflags=["-fuse-ld=gold"]
  ```
- Или в `profiles/toolchains/linaro-arm.cmake` добавить:
  ```cmake
  set(CMAKE_EXE_LINKER_FLAGS_INIT    "-fuse-ld=gold")
  set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=gold")
  ```
  И аналогично для `linaro-aarch64.cmake`.

Gold linker не страдает этим bug'ом. Если поможет — залейте отдельным
коммитом с тегом patch'а.

### 7.5. `libz.so.1, needed by libprotobuf.so..., not found`

Cross-linker не находит rpath к нашему собранному zlib. Это связано
с пунктом 7.3 — если build-profile leak убран, эта ошибка исчезает
автоматически (protoc линкуется native ld'ом, который находит system
`libz.so.1`). Если ошибка остаётся после 7.3 fix → копать в Conan
generators у protobuf.

## 8. Контекст (зачем эти патчи)

- env-fallback fix — обходит баг Conan 2.27.1 где `*:tools.cmake.cmaketoolchain:user_toolchain` в `[conf]` host-profile не пропагируется в transitive nodes (см. `NEXT_STEPS.md` 4b.0).
- Build-profile `[buildenv]` overrides — изолирует build-context (для protoc, x86_64) от host-profile `[buildenv]` (cross armv7hf/armv8).
- xpaclri patch — backwards-compatible NOP-encoding для binutils, который не понимает ARMv8.3-A мнемонику.

После закрытия ARM-фазы:
- удалить TODO-коммент в `test_arm_cross.sh:169-170` (auto-set `-e CONAN_USER_TOOLCHAIN`) — сделано в 7b4dff5;
- свернуть в `HELP.txt` блоки 4b.5–4b.6 в `NEXT_STEPS.md` (исторические, диагностика теперь в `[8h]/[8i]/[8j]/[8k]`).
