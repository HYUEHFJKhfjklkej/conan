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

# Собрать gtest
conan create "$ROOT_DIR/gtest/" \
    --profile="$PROFILE" \
    --build=missing \
    --no-remote

if [ $? -ne 0 ]; then
    echo ""
    echo "[FAIL] gtest build failed!"
    exit 1
fi

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

# Определить имя профиля
PROFILE_NAME=$(basename "$PROFILE")

# Упаковать в legacy zip
mkdir -p "$ROOT_DIR/output"
python3 "$ROOT_DIR/teamcity/package-legacy.py" \
    --name gtest \
    --version 1.14.0 \
    --profile "$PROFILE_NAME" \
    --shared False \
    --output "$ROOT_DIR/output"

if [ $? -ne 0 ]; then
    echo ""
    echo "[FAIL] Legacy packaging failed!"
    exit 1
fi

echo ""
echo "[OK] Legacy zip created"
echo ""

# Показать содержимое zip
echo "[INFO] Zip contents:"
python3 -c "
import zipfile, sys, os
zf = zipfile.ZipFile('$ROOT_DIR/output/googletest.zip')
for i in zf.infolist():
    size = f'{i.file_size:,} bytes' if i.file_size > 0 else 'dir'
    print(f'  {i.filename}  ({size})')
"

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
echo " 3. Legacy zip artifact created:"
echo "    output/googletest.zip"
echo "    (same structure as current TeamCity artifacts)"
echo ""
echo " Source code was NOT modified."
echo " Concept for IN-353 is verified on Astra Linux."
echo "============================================"
