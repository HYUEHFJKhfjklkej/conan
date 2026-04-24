#!/bin/bash
# ============================================
#  Установка Conan на Astra Linux 1.8 (offline)
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " Conan Environment Setup (Astra Linux 1.8)"
echo "============================================"
echo ""

# 1. Проверить Python
echo "[INFO] Checking Python..."
if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    PYTHON=python
else
    echo "[ERROR] Python not found!"
    echo "Install: sudo apt-get install python3 python3-pip python3-venv"
    exit 1
fi

echo "[OK] Python found: $($PYTHON --version)"

# 2. Проверить cmake
echo ""
echo "[INFO] Checking CMake..."
if command -v cmake &>/dev/null; then
    echo "[OK] CMake found: $(cmake --version | head -1)"
else
    echo "[WARN] CMake not found!"
    echo "Install: sudo apt-get install cmake"
    echo "Or: pip3 install cmake"
fi

# 3. Проверить gcc
echo ""
echo "[INFO] Checking GCC..."
if command -v gcc &>/dev/null; then
    echo "[OK] GCC found: $(gcc --version | head -1)"
else
    echo "[WARN] GCC not found!"
    echo "Install: sudo apt-get install build-essential"
fi

# 4. Создать venv
echo ""
echo "[INFO] Creating virtual environment..."
if [ -d "$ROOT_DIR/venv" ]; then
    echo "[INFO] venv already exists, skipping"
else
    $PYTHON -m venv "$ROOT_DIR/venv"
fi

# Активировать
source "$ROOT_DIR/venv/bin/activate"

# 5. Установить Conan из локальных пакетов (offline)
echo ""
echo "[INFO] Installing Conan from local packages (offline)..."

# Сначала setuptools (нужен для сборки .tar.gz пакетов)
pip install --upgrade pip setuptools wheel 2>/dev/null || true

if [ -d "$ROOT_DIR/packages-linux" ]; then
    echo "[INFO] Using packages-linux/ (source distributions)"
    pip install --no-index --find-links="$ROOT_DIR/packages-linux" conan
elif [ -d "$ROOT_DIR/packages" ]; then
    echo "[INFO] Using packages/ (Windows wheels, may not work on Linux)"
    pip install --no-index --find-links="$ROOT_DIR/packages" conan
else
    echo "[INFO] No local packages found, installing from pip..."
    pip install conan==2.27.1
fi

echo "[OK] Conan installed: $(conan --version)"

# 6. Настроить Conan profile
echo ""
echo "[INFO] Detecting Conan profile..."
conan profile detect --force

echo ""
echo "============================================"
echo " Done! Environment is ready."
echo "============================================"
echo ""
echo " Activate venv:  source venv/bin/activate"
echo ""
echo " Next steps:"
echo "   cd test-astra"
echo "   ./run_test.sh"
echo ""
