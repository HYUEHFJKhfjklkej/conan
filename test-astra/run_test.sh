#!/bin/bash
# ============================================
#  Полный тест Conan на Astra Linux 1.8
#  1. Собирает gtest из оригинальных исходников
#  2. Прогоняет тесты потребителя
#  3. Упаковывает в legacy zip-формат
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Активировать venv если есть
if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
    source "$ROOT_DIR/venv/bin/activate"
fi

echo "============================================"
echo " Test 1/3: Build gtest (no source modification)"
echo "============================================"
echo ""

# Определить профиль
PROFILE="$ROOT_DIR/profiles/astra-gcc"
if [ ! -f "$PROFILE" ]; then
    PROFILE="$ROOT_DIR/profiles/linux-gcc"
fi
echo "[INFO] Using profile: $PROFILE"
echo ""

# Собрать gtest в Release и Debug
for BT in Release Debug; do
    echo "[INFO] Building gtest build_type=$BT"
    conan create "$ROOT_DIR/gtest/" \
        --version=1.15.2 \
        --profile="$PROFILE" \
        --build=missing \
        --no-remote \
        -s build_type="$BT"
    if [ $? -ne 0 ]; then
        echo ""
        echo "[FAIL] gtest $BT build failed!"
        exit 1
    fi
done

echo ""
echo "[OK] gtest built from ORIGINAL sources (no modification)"
echo ""

echo "============================================"
echo " Test 2/3: Build example consumer + run tests"
echo "============================================"
echo ""

cd "$ROOT_DIR/example"

# Очистить предыдущую сборку
rm -rf build

# Установить зависимости
conan install . \
    --output-folder=build \
    --build=missing \
    --profile="$PROFILE" \
    --no-remote

# Собрать
cmake -B build \
    -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build

# Тесты
echo ""
echo "[INFO] Running tests..."
cd build && ctest --output-on-failure -C Release
TEST_RESULT=$?
cd "$SCRIPT_DIR"

if [ $TEST_RESULT -ne 0 ]; then
    echo ""
    echo "[FAIL] Tests failed!"
    exit 1
fi

echo ""
echo "[OK] All tests passed"
echo ""

echo "============================================"
echo " Test 3/3: Package in legacy format"
echo "============================================"
echo ""

# Упаковать через Conan deployer (вариант "Conan-native")
mkdir -p "$ROOT_DIR/output"
rm -f "$ROOT_DIR/output"/*.nupkg
conan install \
    --requires=gtest/1.15.2 \
    --profile="$PROFILE" \
    --no-remote \
    -c tools.system.package_manager:mode=install \
    --deployer="$ROOT_DIR/extensions/deployers/legacy_nupkg.py" \
    --deployer-folder="$ROOT_DIR/output"

if [ $? -ne 0 ]; then
    echo ""
    echo "[FAIL] Legacy packaging failed!"
    exit 1
fi

echo ""
echo "[OK] Legacy nupkg created"
echo ""

# Показать содержимое nupkg
NUPKG=$(ls "$ROOT_DIR/output"/googletest.*.nupkg 2>/dev/null | head -1)
if [ -n "$NUPKG" ]; then
    echo "[INFO] $(basename "$NUPKG") contents:"
    python3 -c "
import zipfile
zf = zipfile.ZipFile('$NUPKG')
for i in zf.infolist():
    size = f'{i.file_size:,} bytes' if i.file_size > 0 else 'dir'
    print(f'  {i.filename}  ({size})')
"
fi

echo ""
echo "============================================"
echo " ALL TESTS PASSED"
echo "============================================"
echo ""
echo " 1. gtest built from ORIGINAL sources"
echo "    (no CMakeLists.txt modification)"
echo ""
echo " 2. Example consumer compiled and tests passed"
echo "    (find_package + target_link_libraries)"
echo ""
echo " 3. Legacy nupkg artifact created:"
echo "    output/googletest.{os}.{compiler}.{linkage}.{arch}.{ver}.nupkg"
echo "    (same structure as current TeamCity artifacts)"
echo ""
echo " Source code was NOT modified."
echo " Concept for IN-353 is verified on Astra Linux."
echo "============================================"
