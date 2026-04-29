#!/bin/bash
# ============================================
#  Полный тест Conan для zlib (Linux/Astra)
#  1. Собирает zlib Release+Debug из оригинальных исходников
#  2. Упаковывает в legacy .nupkg-формат через Conan-deployer
#  Артефакт совпадает по структуре с тем, что сейчас делает TeamCity.
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/venv/bin/activate" ]; then
    source "$ROOT_DIR/venv/bin/activate"
fi

PROFILE="$ROOT_DIR/profiles/astra-gcc"
if [ ! -f "$PROFILE" ]; then
    PROFILE="$ROOT_DIR/profiles/linux-gcc"
fi

echo "============================================"
echo " Test 1/2: Build zlib (no source modification)"
echo "============================================"
echo "[INFO] Profile: $PROFILE"
echo ""

for BT in Release Debug; do
    echo "[INFO] Building zlib build_type=$BT"
    conan create "$ROOT_DIR/zlib/" \
        --version=1.3.1 \
        --profile="$PROFILE" \
        --build=missing \
        --no-remote \
        -s build_type="$BT"
    if [ $? -ne 0 ]; then
        echo ""
        echo "[FAIL] zlib $BT build failed!"
        exit 1
    fi
done

echo ""
echo "[OK] zlib built from ORIGINAL sources"
echo ""

echo "============================================"
echo " Test 2/2: Package in legacy .nupkg format"
echo "============================================"
echo ""

mkdir -p "$ROOT_DIR/output"
rm -f "$ROOT_DIR/output"/zlib.*.nupkg
conan install \
    --requires=zlib/1.3.1 \
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

NUPKG=$(ls "$ROOT_DIR/output"/zlib.*.nupkg 2>/dev/null | head -1)
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
echo " Artifact: output/zlib.{os}.{compiler}.{linkage}.{arch}.1.3.1.nupkg"
echo " (same structure as current TeamCity artifacts)"
echo "============================================"
