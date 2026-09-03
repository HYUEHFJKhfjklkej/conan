#!/bin/bash
# test_legacy_consume.sh — прогнать наш .nupkg через ЛЕГАСИ-фреймворк Elara и
# проверить, доезжают ли заголовки до цели потребителя.
#
# Зачем: пакет может собираться и лежать в фиде, но у потребителя не
# подключаться. Для headers-only пакетов (rapidjson, nlohmann_json) это
# штатный случай: у них пустой `components`, значит IMPORTED-таргета резолвер
# не создаёт, и привычный `target_link_libraries(app <пакет>)` заголовков не
# приносит. Скрипт воспроизводит это локально, за один прогон, без TeamCity.
#
# Использование:
#   FRAMEWORK=~/su2/zlib/cmake ./test-astra/test_legacy_consume.sh
#   FRAMEWORK=... PKG=nlohmann_json VERSION=3.12.0 ./test-astra/test_legacy_consume.sh
#
# Обязательный env:
#   FRAMEWORK     путь к каталогу cmake/ из ЛЮБОГО репозитория SU2
#                 (bitbucket.inc.elara.local/scm/SU2/<pkg>.git, ветка develop).
#                 Фреймворк одинаков во всех репо. Нужны как минимум
#                 ResolveDependencies.cmake и FindInstalledPackage.cmake;
#                 чего нет — берётся из test-astra/legacy-consumer/cmake-shim.
#
# Опциональный env:
#   PKG           имя пакета (по умолч. rapidjson)
#   VERSION       версия в имени .nupkg (по умолч. вытаскивается из файла)
#   NUPKG         путь к .nupkg; по умолч. первый найденный
#                 output-$PKG-*/$PKG.*.nupkg
#   MODE          link|include|project|all (по умолч. all) — способ, которым
#                 потребитель забирает заголовки
#   WITH_QT=1     добавить класс с Q_OBJECT и AUTOMOC (нужен Qt5 в CMAKE_PREFIX_PATH
#                 или QT5_ROOT_DIR)
#   WORK          рабочий каталог (по умолч. .legacy-consume/$PKG)
#   PLATFORM      TARGET_PLATFORM (по умолч. LINUX)
#   ARCH_CPU      TARGET_ARCH_CPU (по умолч. X86_64)
#   SHARED        BUILD_SHARED_LIBS (по умолч. ON — слот shared)
#   KEEP=1        не удалять рабочий каталог на старте
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

PKG="${PKG:-rapidjson}"
MODE="${MODE:-all}"
PLATFORM="${PLATFORM:-LINUX}"
ARCH_CPU="${ARCH_CPU:-X86_64}"
SHARED="${SHARED:-ON}"
WORK="${WORK:-$ROOT_DIR/.legacy-consume/$PKG}"
HARNESS="$SCRIPT_DIR/legacy-consumer"

fail() { echo "[FAIL] $*" >&2; exit 1; }

[ -n "${FRAMEWORK:-}" ] || fail "нужен FRAMEWORK=<путь к cmake/ из репо SU2>
       Фреймворк не хранится здесь: это внутренний код Elara, а этот
       репозиторий публичный. Возьмите каталог cmake/ из любого клона SU2."
[ -d "$FRAMEWORK" ] || fail "FRAMEWORK не каталог: $FRAMEWORK"
for _m in ResolveDependencies.cmake FindInstalledPackage.cmake; do
    [ -f "$FRAMEWORK/$_m" ] || fail "в FRAMEWORK нет $_m"
done

# .nupkg: явный путь или первый подходящий из output-*.
if [ -z "${NUPKG:-}" ]; then
    NUPKG="$(ls -1 "$ROOT_DIR"/output-"$PKG"-*/"$PKG".*.nupkg 2>/dev/null | head -1)"
fi
[ -n "$NUPKG" ] && [ -f "$NUPKG" ] || fail "не найден .nupkg для $PKG (задайте NUPKG=...)
       искал: output-$PKG-*/$PKG.*.nupkg"

# Версия из имени файла: <pkg>.<os>.<compiler>.<linkage>.<arch>.<version>.nupkg
BASENAME="$(basename "$NUPKG" .nupkg)"
if [ -z "${VERSION:-}" ]; then
    VERSION="${BASENAME#"$PKG".}"
    VERSION="$(echo "$VERSION" | awk -F. '{ for (i=5; i<=NF; i++) printf "%s%s", $i, (i<NF ? "." : "") }')"
fi
[ -n "$VERSION" ] || fail "не смог вывести версию из имени $BASENAME (задайте VERSION=...)"

if [ -n "${WITH_QT:-}" ]; then
    _qt_cfg=""
    for _d in "${QT5_ROOT_DIR:-}" "${CMAKE_PREFIX_PATH:-}"; do
        [ -n "$_d" ] || continue
        [ -f "$_d/lib/cmake/Qt5/Qt5Config.cmake" ] && _qt_cfg="$_d"
    done
    [ -n "$_qt_cfg" ] || fail "WITH_QT=1, но Qt5 не найден.
       Нужен QT5_ROOT_DIR с lib/cmake/Qt5/Qt5Config.cmake внутри
       (на станке Qt это тот же путь, что читает рецепт qwt)."
fi

command -v cmake >/dev/null 2>&1 || fail "нет cmake"
command -v unzip >/dev/null 2>&1 || fail "нет unzip"

echo "[INFO] пакет:     $PKG / $VERSION"
echo "[INFO] .nupkg:     $NUPKG"
echo "[INFO] фреймворк:  $FRAMEWORK"
echo "[INFO] платформа:  $PLATFORM / $ARCH_CPU / shared=$SHARED"
echo "[INFO] работа в:   $WORK"

[ -n "${KEEP:-}" ] || rm -rf "$WORK"
mkdir -p "$WORK"

# 1. Пакет ложится сиблингом потребителя как <pkg>.bin — это ветка
#    "Found binary package" в resolve_dependencies (_source_build_dir =
#    CMAKE_SOURCE_DIR/..). Фид и nuget.exe при этом не нужны.
PKG_DIR="$WORK/$PKG.bin"
rm -rf "$PKG_DIR"; mkdir -p "$PKG_DIR"
unzip -o -q "$NUPKG" -d "$PKG_DIR" || fail "unzip $NUPKG"
[ -f "$PKG_DIR/CMakeLists.var" ] || fail "в пакете нет CMakeLists.var"

echo ""
echo "--- components из пакета ---"
sed -n '/^set(components/,/^[[:space:]]*)/p' "$PKG_DIR/CMakeLists.var" | sed 's|^|    |'
COMPONENTS="$(sed -n '/^set(components/,/^[[:space:]]*)/p' "$PKG_DIR/CMakeLists.var" \
              | sed '1d;$d' | tr -d ' \t' | grep -c '[^[:space:]]')"
echo "    -> компонентов: $COMPONENTS"
LIBS="$(find "$PKG_DIR/lib" -type f \( -name '*.a' -o -name '*.so*' -o -name '*.lib' \) 2>/dev/null | wc -l | tr -d ' ')"
echo "    -> файлов библиотек: $LIBS"
echo ""

# 2. Потребитель.
SRC="$WORK/consumer"
rm -rf "$SRC"; mkdir -p "$SRC/cmake"
cp "$HARNESS/CMakeLists.txt" "$SRC/"
cp -R "$HARNESS/app" "$SRC/"

# Настоящий фреймворк, поверх пробелы закрываются заглушками.
cp "$FRAMEWORK"/*.cmake "$SRC/cmake/" 2>/dev/null
[ -d "$FRAMEWORK/toolchains" ] && cp -R "$FRAMEWORK/toolchains" "$SRC/cmake/" 2>/dev/null
for _s in "$HARNESS"/cmake-shim/*.cmake; do
    _n="$(basename "$_s")"
    if [ -f "$SRC/cmake/$_n" ]; then
        echo "[INFO] $_n: настоящий из FRAMEWORK"
    else
        cp "$_s" "$SRC/cmake/$_n"
        echo "[INFO] $_n: ЗАГЛУШКА (в FRAMEWORK нет)"
    fi
done

cat > "$SRC/CMakeLists.var" <<VAR
set(project_name legacy_consumer)
set(legacy_consumer_major 0)
set(legacy_consumer_minor 0)
set(legacy_consumer_patch 1)
set(components
    )
set(test_components
    )
set(legacy_consumer_definitions
    )
set(legacy_consumer_dependencies
    $PKG:$VERSION
    )
VAR

# 3. Прогон по способам подключения.
[ "$MODE" = "all" ] && MODES="link include project" || MODES="$MODE"
RESULTS=""
RC_TOTAL=0

for M in $MODES; do
    echo ""
    echo "============================================================"
    echo " CONSUME_MODE=$M"
    echo "============================================================"
    BUILD="$WORK/build-$M"
    rm -rf "$BUILD"
    CM_ARGS=(-S "$SRC" -B "$BUILD"
             -DCMAKE_BUILD_TYPE=Release
             -DTARGET_PLATFORM="$PLATFORM"
             -DTARGET_ARCH_CPU="$ARCH_CPU"
             -DBUILD_SHARED_LIBS="$SHARED"
             -Ddep_name="$PKG"
             -DCONSUME_MODE="$M")
    [ -n "${WITH_QT:-}" ] && CM_ARGS+=(-DWITH_QT=ON)
    [ -n "${QT5_ROOT_DIR:-}" ] && CM_ARGS+=(-DQT5_ROOT_DIR="$QT5_ROOT_DIR" -DCMAKE_PREFIX_PATH="$QT5_ROOT_DIR")

    if cmake "${CM_ARGS[@]}" > "$BUILD.configure.log" 2>&1; then
        if cmake --build "$BUILD" -j > "$BUILD.build.log" 2>&1; then
            if "$BUILD/app/app" > "$BUILD.run.log" 2>&1; then
                RESULTS="$RESULTS\n  $M: PASS  ($(head -1 "$BUILD.run.log"))"
            else
                RESULTS="$RESULTS\n  $M: FAIL на запуске"
                RC_TOTAL=1
            fi
        else
            RESULTS="$RESULTS\n  $M: FAIL на компиляции — $(grep -m1 -iE "fatal error|No such file" "$BUILD.build.log" | sed 's/^[[:space:]]*//')"
            RC_TOTAL=1
        fi
    else
        RESULTS="$RESULTS\n  $M: FAIL на конфигурации — $(grep -m1 -iE "CMake Error|FATAL_ERROR|Unable to find|Not found package" "$BUILD.configure.log" | sed 's/^[[:space:]]*//')"
        RC_TOTAL=1
    fi
    tail -5 "$BUILD.configure.log" | sed 's|^|    |'
done

echo ""
echo "============================================================"
echo " ИТОГ: $PKG/$VERSION, компонентов $COMPONENTS, библиотек $LIBS"
echo "============================================================"
printf '%b\n' "$RESULTS"
echo ""
if [ "$COMPONENTS" = "0" ]; then
    echo " Пакет headers-only. Ожидаемая картина: link FAIL, include и project PASS."
    echo " Потребителю писать target_include_directories(<цель> PRIVATE \${$PKG""_INCLUDE_DIRS})."
    echo " target_link_libraries(<цель> $PKG) для такого пакета не работает: IMPORTED-таргета нет."
else
    echo " У пакета есть компоненты, ожидается PASS во всех способах."
fi
echo ""
echo " Логи: $WORK/build-<mode>.{configure,build,run}.log"
exit $RC_TOTAL
